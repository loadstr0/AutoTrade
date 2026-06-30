-- AutoTrade/Config.lua

return function(ctx)
	local Config = {}

	-- Bridge/default payload fields. These are usually overwritten by Python JSON.
	Config.BuyerName = nil
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

	-- Defaults
	Config.DefaultDeliveryMode = "Trade"
	Config.DefaultItemType = "Sword"

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

	Config.TradeLocalReadyTimeout = 8
	Config.TradeBuyerReadyTimeout = 60

	Config.TradeConfirmRetryTimeout = 15
	Config.TradeLocalConfirmTimeout = 8
	Config.TradeBuyerConfirmTimeout = 60
	Config.TradeFinalTimeout = 30

	Config.TradeClearBeforeAdd = true
	Config.TradeAutoConfirm = true
	Config.RequireManualConfirm = false

	-- Quantity safety: keep false until multi-item trades are implemented and tested.
	Config.AllowMultiQuantityTrade = false

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

		resolved.Quantity = tonumber(resolved.Quantity or 1) or 1
		resolved.OrderQuantity = tonumber(resolved.OrderQuantity or 1) or 1

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

	function Config.PrintResolved(overrideCtx, Logger)
		local resolved = Config.Resolve(overrideCtx)
		Logger = Logger or (overrideCtx and overrideCtx.Modules and overrideCtx.Modules.Logger)

		if Logger and Logger.info then
			Logger.info("Resolved Config:")

			local keys = {
				"BuyerName",
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
				"TradeAutoConfirm",
				"RequireManualConfirm",
				"GiftDryRun",
				"AllowTokenSpend",
			}

			for _, key in ipairs(keys) do
				Logger.info(" ", key, "=", tostring(resolved[key]))
			end
		end

		return resolved
	end

	return Config
end
