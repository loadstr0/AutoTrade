-- AutoTrade/TradeMain.lua

return function(ctx)
	local TradeMain = {}

	local PlayersUtil = ctx.Modules.PlayersUtil
	local InventoryUtil = ctx.Modules.InventoryUtil
	local TradeActions = ctx.Modules.TradeActions
	local TradeState = ctx.Modules.TradeState
	local Logger = ctx.Modules.Logger
	local Config = ctx.Modules.Config

	local function getConfig()
		if type(Config.Resolve) == "function" then
			return Config.Resolve(ctx)
		end

		if type(Config.Get) == "function" then
			return Config.Get(ctx)
		end

		return Config
	end

	local function waitBuyerStillHere(buyerName)
		local buyer = PlayersUtil.findPlayer(buyerName)

		if not buyer then
			return nil, "buyer_left"
		end

		return buyer
	end

	local function waitForTradeOpen(timeout)
		timeout = tonumber(timeout or 12) or 12

		if TradeState.waitForTradeOpen then
			return TradeState.waitForTradeOpen(timeout)
		end

		if TradeState.waitOpen then
			return TradeState.waitOpen(timeout)
		end

		if TradeState.waitForTrade then
			return TradeState.waitForTrade(timeout)
		end

		task.wait(timeout)
		return true
	end

	local function addItem(item)
		if TradeActions.addItemToTrade then
			return TradeActions.addItemToTrade(item)
		end

		if TradeActions.addItem then
			return TradeActions.addItem(item)
		end

		return false, "missing_add_item_function"
	end

	local function readyUp()
		if TradeActions.readyUp then
			return TradeActions.readyUp()
		end

		if TradeActions.ready then
			return TradeActions.ready()
		end

		return false, "missing_ready_function"
	end

	local function confirmTrade()
		if TradeActions.confirmTrade then
			return TradeActions.confirmTrade()
		end

		if TradeActions.confirm then
			return TradeActions.confirm()
		end

		return false, "missing_confirm_function"
	end

	local function cancelTrade()
		if TradeActions.cancelTrade then
			pcall(function()
				TradeActions.cancelTrade()
			end)
		elseif TradeActions.cancel then
			pcall(function()
				TradeActions.cancel()
			end)
		end
	end

	local function sendRequest(buyer)
		if TradeActions.sendTradeRequest then
			return TradeActions.sendTradeRequest(buyer)
		end

		if TradeActions.sendRequest then
			return TradeActions.sendRequest(buyer)
		end

		return false, "missing_send_request_function"
	end

	function TradeMain.Start()
		local config = getConfig()

		Logger.info("Starting trade delivery.")

		if not config.BuyerName or config.BuyerName == "" then
			return false, "missing_buyer_name"
		end

		if not config.ItemName or config.ItemName == "" then
			return false, "missing_item_name"
		end

		if not config.ItemType or config.ItemType == "" then
			return false, "missing_item_type"
		end

		local buyer = PlayersUtil.findPlayer(config.BuyerName)

		if not buyer then
			return false, "buyer_not_found"
		end

		Logger.info("Buyer found:", buyer.Name, buyer.UserId)

		local cooldown = tonumber(config.TradeJoinCooldown or 10) or 10

		if cooldown > 0 then
			Logger.info("Waiting", cooldown, "seconds before sending trade request because of join cooldown.")
			task.wait(cooldown)

			buyer = PlayersUtil.findPlayer(config.BuyerName)

			if not buyer then
				return false, "buyer_left_during_join_cooldown"
			end

			Logger.info("Buyer still in server after cooldown:", buyer.Name, buyer.UserId)
		end

		local item = InventoryUtil.findTradableItem(config.ItemType, config.ItemName)

		if not item then
			return false, "item_not_found"
		end

		local retries = tonumber(config.TradeRequestRetries or 5) or 5
		local retryDelay = tonumber(config.TradeRequestRetryDelay or 3) or 3
		local openTimeout = tonumber(config.TradeOpenTimeout or 12) or 12

		for attempt = 1, retries do
			Logger.info("Trade attempt", attempt, "/", retries)

			buyer = waitBuyerStillHere(config.BuyerName)

			if not buyer then
				return false, "buyer_left_before_trade_request"
			end

			local requestOk, requestResult = sendRequest(buyer)

			if not requestOk then
				Logger.warn("Trade request failed:", tostring(requestResult))

				if attempt < retries then
					Logger.info("Retrying trade request in", retryDelay, "seconds...")
					task.wait(retryDelay)
				end

				continue
			end

			Logger.info("Trade request sent. Waiting for trade window/open state...")

			local openOk, openResult = waitForTradeOpen(openTimeout)

			if not openOk then
				Logger.warn("Trade window did not open or request was declined:", tostring(openResult))

				cancelTrade()

				if attempt < retries then
					Logger.info("Resending trade request in", retryDelay, "seconds...")
					task.wait(retryDelay)
				end

				continue
			end

			Logger.info("Trade window opened.")

			local addOk, addResult = addItem(item)

			if not addOk then
				Logger.warn("Add item failed:", tostring(addResult))
				cancelTrade()
				return false, "add_item_failed"
			end

			Logger.info("Item added to trade.")

			local readyOk, readyResult = readyUp()

			if not readyOk then
				Logger.warn("Ready failed:", tostring(readyResult))
				cancelTrade()
				return false, "ready_failed"
			end

			Logger.info("Ready sent.")

			local confirmWait = tonumber(config.TradeConfirmDelay or 6) or 6
			Logger.info("Waiting", confirmWait, "seconds before confirm.")
			task.wait(confirmWait)

			local confirmOk, confirmResult = confirmTrade()

			if not confirmOk then
				Logger.warn("Confirm failed:", tostring(confirmResult))
				cancelTrade()

				if attempt < retries then
					Logger.info("Trade failed/closed. Retrying in", retryDelay, "seconds...")
					task.wait(retryDelay)
				end

				continue
			end

			Logger.info("Confirm sent.")
			Logger.info("Trade delivery finished successfully.")

			return true, "trade_complete"
		end

		return false, "trade_request_declined_or_not_accepted"
	end

	return TradeMain
end
