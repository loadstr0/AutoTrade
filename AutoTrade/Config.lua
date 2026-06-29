-- AutoTrade/Config.lua

return function(ctx)
	local Config = {}

	-- Runtime values from Python bridge.
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

	-- Defaults
	Config.DefaultDeliveryMode = "Trade"
	Config.DefaultItemType = "Sword"

	-- Trade safety
	Config.AllowTrade = true

	-- Gift/token safety.
	-- Default is SAFE: resolves and logs only. No tokens spent.
	-- For real token orders, Python/Lua bridge must pass:
	-- GiftDryRun = false
	-- AllowTokenSpend = true
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

	-- Trade timing
	Config.TimeoutTradeAccept = 15
	Config.TimeoutFinalComplete = 45
	Config.MaxAddAttempts = 10
	Config.MaxReadyAttempts = 10
	Config.MaxConfirmAttempts = 20

	-- Gift timing
	Config.MaxGiftAttempts = 1
	Config.GiftRetryDelay = 1

	local function applyBool(fieldName, bridge, ...)
		local keys = { ... }

		for _, key in ipairs(keys) do
			if bridge[key] ~= nil then
				Config[fieldName] = bridge[key] == true
				return
			end
		end
	end

	function Config.ApplyBridge(bridge)
		bridge = bridge or ctx.Bridge or getgenv().AutoTradeBridge or {}

		Config.BuyerName = bridge.BuyerName or bridge.buyerName or bridge.buyer or Config.BuyerName
		Config.ItemName = bridge.ItemName or bridge.itemName or bridge.item or Config.ItemName
		Config.ItemType = bridge.ItemType or bridge.itemType or bridge.type or Config.ItemType or Config.DefaultItemType
		Config.DeliveryMode = bridge.DeliveryMode or bridge.deliveryMode or bridge.mode or Config.DeliveryMode or Config.DefaultDeliveryMode

		Config.ProductId = tonumber(bridge.ProductId or bridge.productId or Config.ProductId)
		Config.ProductName = bridge.ProductName or bridge.productName or bridge.product or Config.ProductName

		Config.Quantity = tonumber(bridge.Quantity or bridge.quantity or Config.Quantity) or Config.Quantity or 1
		Config.OrderQuantity = tonumber(bridge.OrderQuantity or bridge.orderQuantity or bridge.RepeatCount or bridge.repeatCount or Config.OrderQuantity) or Config.OrderQuantity or 1

		applyBool("GiftWithTokens", bridge, "GiftWithTokens", "giftWithTokens")
		applyBool("GiftDryRun", bridge, "GiftDryRun", "giftDryRun")
		applyBool("AllowTokenSpend", bridge, "AllowTokenSpend", "allowTokenSpend")
		applyBool("RequireTokenBalanceDecrease", bridge, "RequireTokenBalanceDecrease", "requireTokenBalanceDecrease")
		applyBool("AssumeGiftSuccessWithoutTokenRead", bridge, "AssumeGiftSuccessWithoutTokenRead", "assumeGiftSuccessWithoutTokenRead")
		applyBool("AllowTrade", bridge, "AllowTrade", "allowTrade")

		Config.GiftMessage = bridge.GiftMessage or bridge.giftMessage or Config.GiftMessage or ""
		Config.OrderTitle = bridge.OrderTitle or bridge.orderTitle or Config.OrderTitle
		Config.OrderId = bridge.OrderId or bridge.orderId or Config.OrderId
		Config.OrderUrl = bridge.OrderUrl or bridge.orderUrl or Config.OrderUrl
		Config.Price = bridge.Price or bridge.price or Config.Price
		Config.ResultFile = bridge.ResultFile or bridge.resultFile or Config.ResultFile

		return Config
	end

	function Config.Validate()
		local missing = {}

		if not Config.BuyerName or Config.BuyerName == "" then
			table.insert(missing, "BuyerName")
		end

		if not Config.DeliveryMode or Config.DeliveryMode == "" then
			table.insert(missing, "DeliveryMode")
		end

		if Config.DeliveryMode == "Trade" then
			if not Config.ItemName or Config.ItemName == "" then
				table.insert(missing, "ItemName")
			end

			if not Config.ItemType or Config.ItemType == "" then
				table.insert(missing, "ItemType")
			end
		elseif Config.DeliveryMode == "Gift" then
			if not Config.ProductId and (not Config.ProductName or Config.ProductName == "") then
				table.insert(missing, "ProductId or ProductName")
			end
		else
			table.insert(missing, "valid DeliveryMode")
		end

		if #missing > 0 then
			return false, "Missing bridge fields: " .. table.concat(missing, ", ")
		end

		return true
	end

	return Config
end
