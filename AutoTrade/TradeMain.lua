-- AutoTrade/TradeMain.lua

return function(ctx)
	local TradeMain = {}

	local Logger = ctx.Modules.Logger
	local PlayersUtil = ctx.Modules.PlayersUtil
	local InventoryUtil = ctx.Modules.InventoryUtil
	local TradeState = ctx.Modules.TradeState
	local TradeActions = ctx.Modules.TradeActions

	function TradeMain.Start(config)
		if config.AllowTrade ~= true then
			return false, "trade_not_allowed"
		end

		Logger.info("Starting trade delivery.")

		local buyer = PlayersUtil.waitForPlayer(config.BuyerName, config.BuyerWaitTimeout)

		if not buyer then
			return false, "buyer_not_in_server"
		end

		Logger.info("Buyer found:", buyer.Name, buyer.UserId)

		local item = InventoryUtil.findTradableItem(config.ItemType, config.ItemName)

		if not item then
			return false, "item_not_found"
		end

		TradeActions.sendRequest(buyer)

		local replion = TradeState.waitForTrade(config.TimeoutTradeAccept)

		if not replion then
			return false, "trade_not_opened"
		end

		local added = false

		for attempt = 1, config.MaxAddAttempts do
			Logger.info("Add item attempt:", attempt)

			local ok = TradeActions.addItem(config.ItemType, item)

			if ok then
				added = true
				break
			end

			task.wait(config.RetryDelay)
		end

		if not added then
			return false, "add_item_failed"
		end

		local readyOk = false

		for attempt = 1, config.MaxReadyAttempts do
			Logger.info("Ready attempt:", attempt)

			local ok = TradeActions.ready()

			if ok then
				readyOk = true
				break
			end

			task.wait(config.RetryDelay)
		end

		if not readyOk then
			return false, "ready_failed"
		end

		Logger.info("Ready fired. Confirm will retry until accepted or attempts end.")
		task.wait(4)

		local confirmOk = false

		for attempt = 1, config.MaxConfirmAttempts do
			Logger.info("Confirm attempt:", attempt)

			local ok = TradeActions.confirm()

			if ok then
				confirmOk = true
				break
			end

			task.wait(0.5)
		end

		if not confirmOk then
			return false, "confirm_failed"
		end

		Logger.info("Trade confirm fired.")
		return true, "trade_confirmed"
	end

	return TradeMain
end
