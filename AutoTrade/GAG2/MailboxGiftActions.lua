-- AutoTrade/GAG2/MailboxGiftActions.lua
--
-- The actual delivery call: ReplicatedStorage.SharedModules.Networking's
-- Mailbox.SendBatch:Fire(recipientUserId, itemsTable, note).
--
-- CONFIRMED (2026-07-17, from the real MailboxController.lua source's own
-- sendBatch() function -- previously this was an educated guess, now
-- it's verified against the actual client code): despite being named
-- "Fire", this is NOT a one-way RemoteEvent-style call. The game's own
-- UI does:
--
--   local ok, success, message = pcall(function()
--       return Networking.Mailbox.SendBatch:Fire(userId, items, note)
--   end)
--   -- ok      = whether the pcall itself succeeded (no Lua-level error)
--   -- success = boolean, whether the SERVER accepted/processed the gift
--   -- message = string reason (empty string on a plain success, e.g.
--   --           "Gift sent!" is the UI's own fallback text; a real
--   --           string on failure, e.g. "Mailbox is full")
--
-- So this genuinely is a blocking request/response call under the hood
-- (a "Packet" RPC wrapper, per the original decompile notes) -- we get a
-- real, synchronous confirmation of success/failure, not just "the call
-- didn't error." This removes the biggest open question from the first
-- draft of this module: a completed call with success == true means the
-- server actually processed the gift, and success == false with a
-- message means it was cleanly rejected (e.g. mailbox full, invalid
-- recipient) -- neither of those is the ambiguous "who knows" state a
-- true fire-and-forget call would leave us in.
--
-- The only genuinely ambiguous case left is if the pcall ITSELF fails
-- (network drop / remote torn down mid-call) -- we can't tell whether
-- the server received and processed the request before the connection
-- died. That's the one case Heartbeat.lua's dangerous-phase tracking
-- below is for.
--
-- Stays in dry-run (log-only, no real Fire call) until both
-- config.MailboxGiftDryRun == false AND config.AllowMailboxSend == true,
-- same two-flag safety pattern as BB's token spend / gift gating.

return function(ctx)
	local MailboxGiftActions = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger
	local Heartbeat = ctx.Modules.Heartbeat

	local function getNetworking()
		local ok, Networking = pcall(function()
			return require(ReplicatedStorage.SharedModules.Networking)
		end)

		if not ok or type(Networking) ~= "table" or type(Networking.Mailbox) ~= "table" then
			return nil, "networking_module_unavailable"
		end

		if not Networking.Mailbox.SendBatch then
			return nil, "sendbatch_remote_missing"
		end

		return Networking.Mailbox, nil
	end

	-- Splits `items` into chunks of at most `maxPerSend` -- mirrors the
	-- real mailbox UI's own "up to N items per gift" cap (see
	-- MailboxController.lua), since we have no confirmation SendBatch
	-- itself would reject an oversized batch rather than silently
	-- truncating it server-side.
	local function chunkItems(items, maxPerSend)
		maxPerSend = maxPerSend or 20
		local chunks = {}
		local current = {}

		for _, item in ipairs(items) do
			table.insert(current, item)

			if #current >= maxPerSend then
				table.insert(chunks, current)
				current = {}
			end
		end

		if #current > 0 then
			table.insert(chunks, current)
		end

		return chunks
	end

	-- Sends one chunk. Returns ok, reason.
	local function sendChunk(mailbox, recipientUserId, items, note, dryRun, allowSend)
		Logger.info(
			"[MailboxGiftActions] Chunk:",
			#items,
			"item(s) ->",
			"recipientUserId=",
			recipientUserId,
			"dryRun=",
			dryRun,
			"allowSend=",
			allowSend
		)

		for _, item in ipairs(items) do
			Logger.info("   -", item.Category, item.ItemKey, "x" .. tostring(item.Count))
		end

		if dryRun or not allowSend then
			Logger.info("[MailboxGiftActions] DRY RUN / send disabled -- not actually firing SendBatch.")
			return true, "dry_run_skipped"
		end

		if Heartbeat then
			-- Genuinely ambiguous only between here and the pcall returning --
			-- a disconnect in this exact window is the one case we can't
			-- distinguish "server got it" from "server never saw it".
			Heartbeat.SetPhase("mailbox_remote_sent", {
				message = "Firing SendBatch for " .. tostring(#items) .. " item(s)",
				safeToRetry = false,
				dangerous = true,
			})
		end

		local pcallOk, success, message = pcall(function()
			return mailbox.SendBatch:Fire(recipientUserId, items, note or "")
		end)

		if not pcallOk then
			-- pcall itself failed (the error message is in `success` here,
			-- pcall's own convention) -- this IS the ambiguous case: we
			-- genuinely don't know if the server processed it before
			-- whatever broke the call happened.
			Logger.error("[MailboxGiftActions] SendBatch:Fire() raised an error:", success)

			if Heartbeat then
				Heartbeat.SetPhase("mailbox_unconfirmed", {
					message = "SendBatch:Fire() errored -- delivery status genuinely unknown: " .. tostring(success),
					safeToRetry = false,
					dangerous = true,
				})
			end

			return false, "sendbatch_fire_errored:" .. tostring(success)
		end

		-- Past this point we have a REAL answer from the server -- confirmed
		-- request/response, not a guess. Either outcome is a clean, known
		-- state, so neither is "dangerous" in the Heartbeat sense.
		if not success then
			local reason = (message and message ~= "") and message or "rejected_no_reason_given"
			Logger.warn("[MailboxGiftActions] Server rejected SendBatch:", reason)

			if Heartbeat then
				Heartbeat.SetPhase("mailbox_send_precheck", {
					message = "Server rejected SendBatch: " .. tostring(reason),
					safeToRetry = true,
					dangerous = false,
				})
			end

			return false, "sendbatch_rejected:" .. tostring(reason)
		end

		Logger.info("[MailboxGiftActions] Server confirmed SendBatch accepted:", message ~= "" and message or "(no message)")

		if Heartbeat then
			Heartbeat.SetPhase("mailbox_send_precheck", {
				message = "Server confirmed SendBatch accepted.",
				safeToRetry = true,
				dangerous = false,
			})
		end

		return true, "confirmed"
	end

	-- items: the already-resolved {Category, ItemKey, Count} list from
	-- ItemResolver.Resolve(). recipientUserId: numeric Roblox UserId.
	function MailboxGiftActions.SendBatch(recipientUserId, items, note, options)
		options = options or {}

		local dryRun = options.dryRun
		if dryRun == nil then
			dryRun = true
		end

		local allowSend = options.allowSend == true
		local maxPerSend = tonumber(options.maxPerSend) or 20

		if type(items) ~= "table" or #items == 0 then
			return false, "no_items_to_send"
		end

		if not recipientUserId then
			return false, "missing_recipient_user_id"
		end

		local mailbox, reason = getNetworking()

		if not mailbox then
			Logger.error("[MailboxGiftActions] Cannot access Mailbox networking:", reason)
			return false, reason
		end

		local chunks = chunkItems(items, maxPerSend)
		local sentChunks = 0

		for i, chunk in ipairs(chunks) do
			local ok, chunkReason = sendChunk(mailbox, recipientUserId, chunk, note, dryRun, allowSend)

			if not ok then
				return false, "chunk_" .. tostring(i) .. "_failed:" .. tostring(chunkReason)
			end

			sentChunks = sentChunks + 1

			if i < #chunks then
				task.wait(tonumber(options.sendDelay) or 1.5)
			end
		end

		if Heartbeat then
			Heartbeat.SetPhase("mailbox_send_precheck", {
				message = "All " .. tostring(sentChunks) .. " chunk(s) processed.",
				safeToRetry = true,
				dangerous = false,
			})
		end

		if dryRun or not allowSend then
			return true, "dry_run_skipped"
		end

		return true, "confirmed"
	end

	return MailboxGiftActions
end
