-- AutoTrade/GAG2/Config.lua
--
-- Grow a Garden 2's bridge/default config. Mirrors AutoTrade/BB/Config.lua's
-- shape (Config.Resolve() applies the global getgenv().AutoTradeBridge,
-- then the current ctx.Bridge, over these defaults) but only defines the
-- MailboxGift-mode fields BB's Trade/Supply/TokenTrade system doesn't
-- need here -- there is no trade window, no token currency, and no
-- auto-supply/procurement step in this game's design (yet).

return function(ctx)
	local Config = {}

	-- Bridge/default payload fields -- usually overwritten by Python JSON
	-- (see core/lua_bridge.py's BridgePayload -> payload_to_dict()).
	Config.BuyerName = nil
	Config.BuyerUserId = nil

	Config.DeliveryMode = nil

	Config.Quantity = 1
	Config.OrderQuantity = 1

	Config.OrderTitle = nil
	Config.OrderId = nil
	Config.OrderUrl = nil
	Config.Price = nil

	Config.ResultFile = nil
	Config.BridgeId = nil
	Config.CreatedAt = nil
	Config.DeadlineUnix = nil

	Config.GroupJobs = nil
	Config.Grouped = false

	Config.DefaultDeliveryMode = "MailboxGift"

	-- Heartbeat / crash recovery.
	Config.HeartbeatFile = "gag2_autotrade_heartbeat.json"
	Config.HeartbeatSeconds = 3

	-- MailboxGift safety. STAYS SAFE BY DEFAULT (dry run, no real send)
	-- until core/lua_bridge.py's config.AUTOTRADE_MAILBOX_DRY_RUN /
	-- AUTOTRADE_ALLOW_MAILBOX_SEND are both explicitly flipped on the
	-- Python side AND a real send has been verified once. See
	-- grow_a_garden/config.py's module docstring for why this is still
	-- untested -- Networking.Mailbox.SendBatch has never actually been
	-- fired live outside the real MailboxController UI.
	Config.MailboxItemsSpec = nil
	Config.MailboxGiftDryRun = true
	Config.AllowMailboxSend = false
	Config.MailboxSendDelay = 1.5
	Config.GiftMessage = ""

	-- Max distinct items sent in one order's SendBatch call (mailbox UI
	-- itself caps a single send at 20 -- see MailboxController.lua's
	-- "Up to %d items per gift" check). If an order's spec somehow
	-- exceeds this, ItemResolver.lua will need to split it into multiple
	-- SendBatch calls -- not yet implemented, so orders like that fail
	-- loudly instead of silently under-delivering.
	Config.MailboxMaxItemsPerSend = 20

	-- General behavior
	Config.TickDelay = 0.25
	Config.RetryDelay = 1
	Config.PrintDebug = true

	local function shallowCopyWithoutFunctions(source)
		local copy = {}

		for k, v in pairs(source) do
			if type(v) ~= "function" then
				copy[k] = v
			end
		end

		return copy
	end

	local function applyBridge(resolved, bridge)
		if type(bridge) ~= "table" then
			return resolved
		end

		for k, v in pairs(bridge) do
			if v ~= nil then
				resolved[k] = v
			end
		end

		return resolved
	end

	local function getGlobalBridge()
		if type(getgenv) ~= "function" then
			return nil
		end

		local ok, env = pcall(getgenv)

		if not ok or type(env) ~= "table" then
			return nil
		end

		return env.AutoTradeBridge
	end

	local function normalizeBoolean(value, default)
		if value == nil then
			return default
		end

		if value == true or value == false then
			return value
		end

		if type(value) == "string" then
			local lowered = string.lower(value)

			if lowered == "true" or lowered == "1" or lowered == "yes" then
				return true
			end

			if lowered == "false" or lowered == "0" or lowered == "no" then
				return false
			end
		end

		return default
	end

	local function normalize(resolved)
		if not resolved.DeliveryMode or resolved.DeliveryMode == "" then
			resolved.DeliveryMode = resolved.DefaultDeliveryMode or "MailboxGift"
		end

		resolved.Quantity = tonumber(resolved.Quantity or 1) or 1
		resolved.OrderQuantity = tonumber(resolved.OrderQuantity or 1) or 1

		if resolved.BuyerUserId ~= nil and resolved.BuyerUserId ~= "" then
			resolved.BuyerUserId = tonumber(resolved.BuyerUserId)
		else
			resolved.BuyerUserId = nil
		end

		if resolved.DeadlineUnix ~= nil and resolved.DeadlineUnix ~= "" then
			resolved.DeadlineUnix = tonumber(resolved.DeadlineUnix)
		else
			resolved.DeadlineUnix = nil
		end

		resolved.MailboxGiftDryRun = normalizeBoolean(resolved.MailboxGiftDryRun, true)
		resolved.AllowMailboxSend = normalizeBoolean(resolved.AllowMailboxSend, false)

		return resolved
	end

	function Config.Resolve(overrideCtx)
		local useCtx = overrideCtx or ctx or {}
		local resolved = shallowCopyWithoutFunctions(Config)

		-- Apply global bridge first, then current ctx bridge over it --
		-- avoids stale global data overriding the job currently being
		-- processed (same reasoning as BB's Config.lua).
		applyBridge(resolved, getGlobalBridge())

		if type(useCtx) == "table" then
			applyBridge(resolved, useCtx.Bridge)
			applyBridge(resolved, useCtx.Payload)
			applyBridge(resolved, useCtx.Job)
		end

		return normalize(resolved)
	end

	function Config.Get(overrideCtx)
		return Config.Resolve(overrideCtx)
	end

	function Config.Validate(resolved)
		if resolved.DeliveryMode ~= "MailboxGift" then
			return false, "unsupported_delivery_mode:" .. tostring(resolved.DeliveryMode)
		end

		if not resolved.BuyerUserId then
			return false, "missing_buyer_user_id"
		end

		if type(resolved.MailboxItemsSpec) ~= "table" or #resolved.MailboxItemsSpec == 0 then
			return false, "no_items_resolved"
		end

		return true, nil
	end

	return Config
end
