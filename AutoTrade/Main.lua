-- AutoTrade/Main.lua

return function(ctx)
	local Main = {}

	function Main.Start()
		local Logger = ctx.Modules.Logger
		local Config = ctx.Modules.Config

		ctx.Config = Config
		Config.ApplyBridge(ctx.Bridge)

		Logger.dumpTable("Bridge payload:", ctx.Bridge)
		Logger.dumpTable("Resolved Config:", {
			BuyerName = Config.BuyerName,
			DeliveryMode = Config.DeliveryMode,
			ItemName = Config.ItemName,
			ItemType = Config.ItemType,
			ProductName = Config.ProductName,
			ProductId = Config.ProductId,
			Quantity = Config.Quantity,
			OrderQuantity = Config.OrderQuantity,
			GiftWithTokens = Config.GiftWithTokens,
			GiftDryRun = Config.GiftDryRun,
			AllowTokenSpend = Config.AllowTokenSpend,
			RequireTokenBalanceDecrease = Config.RequireTokenBalanceDecrease,
		})

		local valid, err = Config.Validate()

		if not valid then
			Logger.error(err)
			Logger.writeResult(false, err)
			return false
		end

		local ok = false
		local reason = "unknown"

		if Config.DeliveryMode == "Gift" then
			ok, reason = ctx.Modules.GiftMain.Start(Config)
		elseif Config.DeliveryMode == "Trade" then
			ok, reason = ctx.Modules.TradeMain.Start(Config)
		else
			ok = false
			reason = "unknown_delivery_mode"
		end

		Logger.info("Finished:", tostring(ok), tostring(reason))
		Logger.writeResult(ok, reason, {
			DeliveryMode = Config.DeliveryMode,
			BuyerName = Config.BuyerName,
			ItemName = Config.ItemName,
			ItemType = Config.ItemType,
			ProductName = Config.ProductName,
			ProductId = Config.ProductId,
		})

		return ok
	end

	return Main
end
