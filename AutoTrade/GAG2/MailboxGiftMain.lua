-- AutoTrade/GAG2/MailboxGiftMain.lua
--
-- Orchestrates one MailboxGift order end-to-end, mirroring the shape of
-- AutoTrade/BB/GiftMain.lua (resolve buyer -> resolve items -> call the
-- delivery action -> write result -> update heartbeat) but adapted for
-- the mailbox system's different delivery model:
--
--   BB's Gift flow requires the buyer to be physically present in the
--   same server (the gift remote targets a live Player instance).
--   Grow a Garden 2's mailbox is a persistent, asynchronous system --
--   confirmed from MailboxController.lua, which reads/writes mailbox
--   state independent of who else is currently in the server -- so this
--   flow only needs a resolved Roblox UserId, not a live Player object.
--   (PlayersUtil.lua is still used as a fallback path to resolve a
--   UserId from a username via Players:GetUserIdFromNameAsync when the
--   order only gives us a name, same helper BB uses.)

return function(ctx)
	local MailboxGiftMain = {}

	local Logger = ctx.Modules.Logger
	local Heartbeat = ctx.Modules.Heartbeat
	local PlayersUtil = ctx.Modules.PlayersUtil
	local ItemResolver = ctx.Modules.ItemResolver
	local MailboxGiftActions = ctx.Modules.MailboxGiftActions

	local function resolveBuyerUserId(resolved)
		if resolved.BuyerUserId then
			local asNumber = tonumber(resolved.BuyerUserId)

			if asNumber then
				return asNumber, nil
			end
		end

		if resolved.BuyerName and resolved.BuyerName ~= "" then
			local userId = PlayersUtil.getUserIdFromName(resolved.BuyerName)

			if userId then
				return userId, nil
			end

			return nil, "could_not_resolve_userid_from_name:" .. tostring(resolved.BuyerName)
		end

		return nil, "no_buyer_identifier_in_order"
	end

	function MailboxGiftMain.Start(resolved)
		resolved = resolved or {}

		if Heartbeat then
			Heartbeat.SetJob(resolved)
			Heartbeat.SetPhase("mailbox_send_precheck", {
				message = "Resolving buyer and items for order " .. tostring(resolved.OrderId or resolved.BridgeId or "?"),
				safeToRetry = true,
				dangerous = false,
			})
		end

		Logger.dumpTable("[MailboxGiftMain] Starting order:", resolved)

		local buyerUserId, buyerReason = resolveBuyerUserId(resolved)

		if not buyerUserId then
			Logger.error("[MailboxGiftMain] Could not resolve buyer:", buyerReason)
			Logger.writeResultForBridge(resolved, false, buyerReason)

			if Heartbeat then
				Heartbeat.ClearJob()
			end

			return false, buyerReason
		end

		Logger.info("[MailboxGiftMain] Resolved buyer UserId:", buyerUserId)

		local items, itemsReason = ItemResolver.Resolve(resolved.MailboxItemsSpec)

		if not items then
			Logger.error("[MailboxGiftMain] Could not resolve items:", itemsReason)
			Logger.writeResultForBridge(resolved, false, itemsReason)

			if Heartbeat then
				Heartbeat.ClearJob()
			end

			return false, itemsReason
		end

		Logger.info("[MailboxGiftMain] Resolved", #items, "item(s) to send.")

		local ok, reason = MailboxGiftActions.SendBatch(buyerUserId, items, resolved.GiftMessage, {
			dryRun = resolved.MailboxGiftDryRun,
			allowSend = resolved.AllowMailboxSend,
			maxPerSend = resolved.MailboxMaxItemsPerSend,
			sendDelay = resolved.MailboxSendDelay,
		})

		Logger.writeResultForBridge(resolved, ok, reason, {
			BuyerUserId = buyerUserId,
			ItemCount = #items,
		})

		if Heartbeat then
			if ok then
				Heartbeat.SetPhase("idle", { message = "Order complete: " .. tostring(reason), safeToRetry = true, dangerous = false })
			else
				Heartbeat.SetPhase("idle", { message = "Order failed: " .. tostring(reason), safeToRetry = true, dangerous = false })
			end

			Heartbeat.ClearJob()
		end

		return ok, reason
	end

	return MailboxGiftMain
end
