-- AutoTrade/Config.lua

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

-- Gift / token spending
-- LIVE TOKEN SPEND IS ENABLED.
Config.GiftWithTokens = true
Config.GiftDryRun = false
Config.AllowTokenSpend = true
Config.GiftMessage = ""

-- Gift success verification
Config.RequireTokenBalanceDecrease = true
Config.AssumeGiftSuccessWithoutTokenRead = false
Config.ConfirmTokenSpendTimeout = 12

-- General behavior
Config.TickDelay = 0.25
Config.RetryDelay = 1
Config.PrintDebug = true

-- Buyer waiting
Config.BuyerWaitTimeout = math.huge
Config.TradeBuyerJoinTimeout = 19 * 60
Config.TradeBuyerJoinPollSeconds = 2

-- Trade timing
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

-- Multi-item / multi-order support
Config.AllowMultiQuantityTrade = true
Config.AllowSameBuyerTradeBatching = true
Config.MaxTradeItemsPerBatch = 100

-- Completed popup
Config.CloseCompletedPopup = true
Config.CompletedPopupTimeout = 8

-- Old fallback values for older modules
Config.TimeoutTradeAccept = 15
Config.TimeoutFinalComplete = 45
Config.MaxAddAttempts = 10
Config.MaxReadyAttempts = 10
Config.MaxConfirmAttempts = 20

-- Gift timing
Config.MaxGiftAttempts = 1
Config.GiftRetryDelay = 1

local function copyTable(source)
	local result = {}

	for key, value in pairs(source) do
		result[key] = value
	end

	return result
end

local function applyPayload(target, payload)
	if type(payload) ~= "table" then
		return target
	end

	for key, value in pairs(payload) do
		if value ~= nil then
			target[key] = value
		end
	end

	return target
end

function Config.Resolve(ctx)
	local resolved = copyTable(Config)

	local bridge = nil

	if ctx and type(ctx) == "table" then
		bridge = ctx.Bridge or ctx.Payload or ctx.Job
	end

	if type(bridge) ~= "table" and type(getgenv) == "function" then
		bridge = getgenv().AutoTradeBridge
	end

	applyPayload(resolved, bridge)

	resolved.DeliveryMode = resolved.DeliveryMode or resolved.DefaultDeliveryMode
	resolved.ItemType = resolved.ItemType or resolved.DefaultItemType

	resolved.Quantity = tonumber(resolved.Quantity or 1) or 1
	resolved.OrderQuantity = tonumber(resolved.OrderQuantity or 1) or 1

	if resolved.BuyerUserId ~= nil then
		resolved.BuyerUserId = tonumber(resolved.BuyerUserId)
	end

	if resolved.DeadlineUnix ~= nil then
		resolved.DeadlineUnix = tonumber(resolved.DeadlineUnix)
	end

	return resolved
end

function Config.Get(ctx)
	return Config.Resolve(ctx)
end

return Config
