-- AutoTrade/Config.lua

return function(ctx)
	local Config = {}

	-- Bridge/default payload fields. These are usually overwritten by Python JSON.
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
	-- SAFE by default: no token spending unless Python/bridge explicitly turns this off/on.
	Config.GiftWithTokens = true
	Config.GiftDryRun = true
	Config.AllowTokenSpend = false
	Config.GiftMessage = ""
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

	-- Multi item / multi order support.
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
			resolved[k] = v
		end

		return resolved
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

		resolved.Quantity = math.max(1, tonumber(resolved.Quantity or 1) or 1)
		resolved.OrderQuantity = math.max(1, tonumber(resolved.OrderQuantity or 1) or 1)
		resolved.CreatedAt = tonumber(resolved.CreatedAt or 0) or 0
		resolved.DeadlineUnix = tonumber(resolved.DeadlineUnix or 0) or 0
		resolved.BuyerUserId = tonumber(resolved.BuyerUserId or 0) or nil

		if resolved.BuyerUserId == 0 then
			resolved.BuyerUserId = nil
		end

		return resolved
	end

	function Config.Resolve(overrideCtx)
		local useCtx = overrideCtx or ctx or {}
		local resolved = shallowCopyWithoutFunctions(Config)

		applyBridge(resolved, useCtx.Bridge)
		applyBridge(resolved, getgenv().AutoTradeBridge)

		return normalize(resolved)
	end

	function Config.Get(overrideCtx)
		return Config.Resolve(overrideCtx)
	end

	-- Compatibility for older Main.lua-style modules.
	function Config.ApplyBridge(bridge)
		applyBridge(Config, bridge)
		normalize(Config)
		return Config
	end

	function Config.Validate(config)
		config = config or Config.Resolve(ctx)

		if (not config.BuyerName or config.BuyerName == "") and not config.BuyerUserId then
			return false, "missing_buyer_identity"
		end

		if config.DeliveryMode == "Trade" then
			if not config.ItemType or config.ItemType == "" then
				return false, "missing_item_type"
			end

			if not config.ItemName or config.ItemName == "" then
				return false, "missing_item_name"
			end
		elseif config.DeliveryMode == "Gift" then
			if not config.ProductName and not config.ProductId then
				return false, "missing_product"
			end
		else
			return false, "unknown_delivery_mode"
		end

		return true
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
				"Grouped",
				"ResultFile",
				"TradeAutoConfirm",
				"RequireManualConfirm",
				"AllowMultiQuantityTrade",
				"AllowSameBuyerTradeBatching",
				"GiftDryRun",
				"AllowTokenSpend",
			}

			for _, key in ipairs(keys) do
				Logger.info(" ", key, "=", tostring(resolved[key]))
			end

			if type(resolved.GroupJobs) == "table" then
				Logger.info("  GroupJobs =", #resolved.GroupJobs)
			end
		end

		return resolved
	end

	return Config
end
