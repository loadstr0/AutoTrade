-- AutoTrade/Config.lua

return function(ctx)
	local Config = {}

	-- Bridge/default payload fields.
	-- These are usually overwritten by Python JSON.
	Config.BuyerName = nil
	Config.BuyerUserId = nil

	Config.ItemName = nil
	Config.ItemType = nil
	Config.DeliveryMode = nil

	Config.ProductId = nil
	Config.ProductName = nil

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

	-- Defaults
	Config.DefaultDeliveryMode = "Trade"
	Config.DefaultItemType = "Sword"

	-- Queue behavior
	Config.QueueGroupSameBuyerTrades = true
	Config.QueueProcessOnlyReadyBuyers = true
	Config.QueueFailExpiredJobs = true

	-- Trade safety
	Config.AllowTrade = true

	-- Gift/token safety.
	-- LIVE TOKEN SPEND IS ENABLED.
	Config.GiftWithTokens = true
	Config.GiftDryRun = false
	Config.AllowTokenSpend = true
	Config.GiftMessage = ""

	-- Gift success verification.
	-- Keep this strict: do not assume gift success if token balance cannot be checked.
	Config.RequireTokenBalanceDecrease = true
	Config.AssumeGiftSuccessWithoutTokenRead = false
	Config.ConfirmTokenSpendTimeout = 12

	-- General behavior
	Config.TickDelay = 0.25
	Config.RetryDelay = 1
	Config.BuyerWaitTimeout = math.huge
	Config.PrintDebug = true

	-- Lua buyer waiting / queue behavior
	Config.TradeBuyerJoinTimeout = 19 * 60
	Config.TradeBuyerJoinPollSeconds = 2

	-- Trade timing / safety
	Config.TradeJoinCooldown = 30
	Config.TradeRequestRetries = 5
	Config.TradeRequestRetryDelay = 3

	Config.TradeOpenTimeout = 15
	Config.TradeItemVerifyTimeout = 8
	Config.TradeCountdownTimeout = 12

	Config.TradeWaitBetweenItemAdds = true
	Config.TradeAddRetryDelay = 0.75

	Config.TradeLocalReadyTimeout = 8
	Config.TradeBuyerReadyTimeout = 60

	Config.TradeConfirmRetryTimeout = 15
	Config.TradeLocalConfirmTimeout = 8
	Config.TradeBuyerConfirmTimeout = 60
	Config.TradeFinalTimeout = 30

	Config.TradeClearBeforeAdd = true
	Config.TradeAutoConfirm = true
	Config.RequireManualConfirm = false

	-- Multi-item / multi-order support.
	Config.AllowMultiQuantityTrade = true
	Config.AllowSameBuyerTradeBatching = true
	Config.MaxTradeItemsPerBatch = 100

	-- Completed popup
	Config.CloseCompletedPopup = true
	Config.CompletedPopupTimeout = 8

	-- Old fallback values. Safe to keep for older modules.
	Config.TimeoutTradeAccept = 15
	Config.TimeoutFinalComplete = 45
	Config.MaxAddAttempts = 10
	Config.MaxReadyAttempts = 10
	Config.MaxConfirmAttempts = 20

	-- Gift timing
	Config.MaxGiftAttempts = 1
	Config.GiftRetryDelay = 1

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
			resolved.DeliveryMode = resolved.DefaultDeliveryMode or "Trade"
		end

		if resolved.DeliveryMode == "Trade" then
			if not resolved.ItemType or resolved.ItemType == "" then
				resolved.ItemType = resolved.DefaultItemType or "Sword"
			end
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

		resolved.GiftWithTokens = normalizeBoolean(resolved.GiftWithTokens, true)
		resolved.GiftDryRun = normalizeBoolean(resolved.GiftDryRun, false)
		resolved.AllowTokenSpend = normalizeBoolean(resolved.AllowTokenSpend, true)

		resolved.TradeAutoConfirm = normalizeBoolean(resolved.TradeAutoConfirm, true)
		resolved.RequireManualConfirm = normalizeBoolean(resolved.RequireManualConfirm, false)

		resolved.AllowMultiQuantityTrade = normalizeBoolean(resolved.AllowMultiQuantityTrade, true)
		resolved.AllowSameBuyerTradeBatching = normalizeBoolean(resolved.AllowSameBuyerTradeBatching, true)

		return resolved
	end

	function Config.Resolve(overrideCtx)
		local useCtx = overrideCtx or ctx or {}
		local resolved = shallowCopyWithoutFunctions(Config)

		-- Apply global bridge first, then current ctx bridge over it.
		-- This avoids stale global data overriding the job BridgeWatcher is currently processing.
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

	function Config.PrintResolved(overrideCtx, Logger)
		local resolved = Config.Resolve(overrideCtx)
		Logger = Logger or (overrideCtx and overrideCtx.Modules and overrideCtx.Modules.Logger)

		if Logger and Logger.info then
			Logger.info("Resolved Config:")

			local keys = {
				"BuyerName",
				"BuyerUserId",
				"DeliveryMode",
				"ItemType",
				"ItemName",
				"ProductName",
				"ProductId",
				"Quantity",
				"OrderQuantity",
				"BridgeId",
				"DeadlineUnix",
				"ResultFile",
				"Grouped",
				"GroupJobs",
				"TradeAutoConfirm",
				"RequireManualConfirm",
				"AllowMultiQuantityTrade",
				"AllowSameBuyerTradeBatching",
				"GiftWithTokens",
				"GiftDryRun",
				"AllowTokenSpend",
				"RequireTokenBalanceDecrease",
				"AssumeGiftSuccessWithoutTokenRead",
			}

			for _, key in ipairs(keys) do
				local value = resolved[key]

				if key == "GroupJobs" and type(value) == "table" then
					Logger.info(" ", key, "=", tostring(#value), "jobs")
				else
					Logger.info(" ", key, "=", tostring(value))
				end
			end
		end

		return resolved
	end

	return Config
end
