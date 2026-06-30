-- AutoTrade/TradeMain.lua

return function(ctx)
	local TradeMain = {}

	local Players = ctx.Services.Players
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

	local function cfgNumber(config, key, default)
		local value = tonumber(config[key])

		if value == nil then
			return default
		end

		return value
	end

	local function cfgBool(config, key, default)
		local value = config[key]

		if value == nil then
			return default
		end

		return value == true
	end

	local function getItemUuid(item)
		if type(item) == "string" then
			return item
		end

		if type(item) == "table" then
			return item.UUID
				or item.uuid
				or item.Id
				or item.id
				or item.ItemId
				or item.itemId
		end

		return nil
	end

	local function getUserIdString(player)
		if typeof(player) == "Instance" and player:IsA("Player") then
			return tostring(player.UserId)
		end

		if type(player) == "table" and player.UserId then
			return tostring(player.UserId)
		end

		return nil
	end

	local function secondsUntilDeadline(config)
		local deadline = tonumber(config.DeadlineUnix or 0) or 0

		if deadline <= 0 then
			return nil
		end

		return math.max(0, deadline - os.time())
	end

	local function findBuyer(config)
		local buyer = PlayersUtil.findPlayer(config.BuyerName)

		if not buyer then
			return nil, "buyer_not_found"
		end

		return buyer
	end

	local function waitForBuyer(config)
		local timeout = cfgNumber(config, "TradeBuyerJoinTimeout", 19 * 60)
		local remaining = secondsUntilDeadline(config)

		if remaining ~= nil then
			timeout = math.max(1, math.min(timeout, remaining))
		end

		local pollSeconds = cfgNumber(config, "TradeBuyerJoinPollSeconds", 2)

		Logger.info("Waiting for buyer to join server:")
		Logger.info("  BuyerName =", tostring(config.BuyerName))
		Logger.info("  Timeout =", timeout)

		local start = os.clock()
		local lastLog = 0

		while os.clock() - start < timeout do
			local buyer = PlayersUtil.findPlayer(config.BuyerName)

			if buyer then
				Logger.info("Buyer joined/found:", buyer.Name, buyer.UserId)
				return buyer
			end

			if os.clock() - lastLog >= 10 then
				local left = math.max(0, math.floor(timeout - (os.clock() - start)))
				Logger.info("Still waiting for buyer to join...", left, "seconds left")
				lastLog = os.clock()
			end

			task.wait(pollSeconds)
		end

		return nil, "buyer_join_timeout"
	end

	local function safeCancel(reason)
		Logger.warn("Cancelling trade:", tostring(reason))

		pcall(function()
			TradeActions.cancelTrade()
		end)

		task.wait(1)
	end

	local function shouldRetry(reason)
		reason = tostring(reason or "")

		local retryableExact = {
			buyer_join_timeout = true,
			buyer_not_found = true,
			trade_open_timeout = true,
			trade_closed = true,
			buyer_ready_timeout = true,
			buyer_confirm_timeout = true,
			trade_closed_before_completed = true,
			final_result_timeout = true,
			send_trade_request_failed = true,
			trade_request_failed = true,
			local_ready_timeout = true,
			local_confirm_timeout = true,
			trade_canceled = true,
			trade_reverted = true,
			trade_closed_after_processing_without_completion_signal = true,
		}

		if retryableExact[reason] then
			return true
		end

		if reason:find("trade_request_failed", 1, true) then
			return true
		end

		if reason:find("confirm_timeout", 1, true) then
			return true
		end

		return false
	end

	local function checkQuantitySupported(config)
		local quantity = tonumber(config.Quantity or 1) or 1
		local orderQuantity = tonumber(config.OrderQuantity or 1) or 1
		local totalQuantity = math.max(quantity, orderQuantity)

		if totalQuantity > 1 and not cfgBool(config, "AllowMultiQuantityTrade", false) then
			Logger.warn("Multiple quantity orders are not safely supported yet:", totalQuantity)
			return false, "multi_quantity_not_supported_yet"
		end

		return true
	end

	local function waitCountdownOrFail(config)
		local timeout = cfgNumber(config, "TradeCountdownTimeout", 12)

		if not TradeState.waitNoItemCountdown then
			task.wait(4)
			return true
		end

		local ok, reason = TradeState.waitNoItemCountdown(timeout)

		if not ok then
			return false, reason
		end

		return true
	end

	local function addAndVerifyItem(config, item, localUserId, uuid)
		local clearBeforeAdd = cfgBool(config, "TradeClearBeforeAdd", true)

		if clearBeforeAdd and TradeActions.clearTradeContents then
			TradeActions.clearTradeContents()
		end

		local addOk, addResult = TradeActions.addItemToTrade(item)

		if not addOk then
			return false, "add_item_failed:" .. tostring(addResult)
		end

		Logger.info("AddItemToTrade returned success. Verifying item appears in our offer...")

		local verifyTimeout = cfgNumber(config, "TradeItemVerifyTimeout", 8)

		if TradeState.waitItemInOffer then
			local seenOk, seenReason = TradeState.waitItemInOffer(localUserId, uuid, verifyTimeout)

			if not seenOk then
				return false, seenReason
			end
		else
			Logger.warn("TradeState.waitItemInOffer missing. Cannot verify item in offer.")
			return false, "missing_item_offer_verification"
		end

		return true
	end

	local function readyAndVerify(config, localUserId)
		local readyOk, readyResult = TradeActions.readyUp(true)

		if not readyOk then
			return false, "ready_failed:" .. tostring(readyResult)
		end

		Logger.info("ReadyUp(true) sent. Verifying local ready state...")

		local timeout = cfgNumber(config, "TradeLocalReadyTimeout", 8)

		if TradeState.waitLocalReady then
			local ok, reason = TradeState.waitLocalReady(localUserId, timeout)

			if not ok then
				return false, reason
			end
		else
			Logger.warn("TradeState.waitLocalReady missing.")
			return false, "missing_local_ready_verification"
		end

		Logger.info("Verified local ready.")
		return true
	end

	local function waitBuyerReady(config, buyerUserId, localUserId, uuid)
		local timeout = cfgNumber(config, "TradeBuyerReadyTimeout", 60)

		if not TradeState.waitBuyerReady then
			return false, "missing_buyer_ready_verification"
		end

		Logger.info("Waiting for buyer to ready. Timeout:", timeout)

		local ok, reason = TradeState.waitBuyerReady(buyerUserId, localUserId, uuid, timeout)

		if not ok then
			return false, reason
		end

		Logger.info("Buyer ready verified.")
		return true
	end

	local function confirmAndVerify(config, localUserId)
		if cfgBool(config, "RequireManualConfirm", false) then
			Logger.warn("RequireManualConfirm is true. Stopping before confirm.")
			return false, "manual_confirm_required"
		end

		local autoConfirm = cfgBool(config, "TradeAutoConfirm", true)

		if not autoConfirm then
			Logger.warn("TradeAutoConfirm is false. Stopping before confirm.")
			return false, "manual_confirm_required"
		end

		local confirmRetryTimeout = cfgNumber(config, "TradeConfirmRetryTimeout", 15)
		local start = os.clock()
		local lastReason = nil

		Logger.info("Starting confirm loop. Timeout:", confirmRetryTimeout)

		while os.clock() - start < confirmRetryTimeout do
			local confirmOk, confirmResult = TradeActions.confirmTrade()

			if confirmOk then
				Logger.info("ConfirmTrade returned success. Verifying local confirm/processing...")

				if TradeState.waitLocalConfirmed then
					local ok, reason = TradeState.waitLocalConfirmed(localUserId, cfgNumber(config, "TradeLocalConfirmTimeout", 8))

					if ok then
						Logger.info("Local confirm/processing verified.")
						return true
					end

					lastReason = reason
					Logger.warn("Local confirm not verified yet:", tostring(reason))
				else
					return false, "missing_local_confirm_verification"
				end
			else
				lastReason = confirmResult
				Logger.warn("ConfirmTrade failed:", tostring(confirmResult))
			end

			task.wait(1)
		end

		return false, "confirm_timeout:" .. tostring(lastReason)
	end

	local function waitBuyerConfirmOrProcessing(config, buyerUserId, localUserId, uuid)
		local timeout = cfgNumber(config, "TradeBuyerConfirmTimeout", 60)

		if not TradeState.waitBuyerConfirmedOrProcessing then
			return false, "missing_buyer_confirm_verification"
		end

		Logger.info("Waiting for buyer confirm or processing. Timeout:", timeout)

		local ok, reason = TradeState.waitBuyerConfirmedOrProcessing(buyerUserId, localUserId, uuid, timeout)

		if not ok then
			return false, reason
		end

		Logger.info("Buyer confirm/processing verified:", tostring(reason))
		return true
	end

	local function waitFinalResult(config)
		local timeout = cfgNumber(config, "TradeFinalTimeout", 30)

		if not TradeState.waitFinalResult then
			return false, "missing_final_result_verification"
		end

		Logger.info("Waiting for final trade result. Timeout:", timeout)

		local ok, reason = TradeState.waitFinalResult(timeout)

		if not ok then
			return false, reason
		end

		Logger.info("Final trade result verified:", tostring(reason))
		return true
	end

	local function closeCompletedPopup(config)
		if not cfgBool(config, "CloseCompletedPopup", true) then
			return
		end

		if not TradeState.closeCompletedPopup then
			Logger.warn("TradeState.closeCompletedPopup missing.")
			return
		end

		local ok, reason = TradeState.closeCompletedPopup(cfgNumber(config, "CompletedPopupTimeout", 8))

		if ok then
			Logger.info("Closed completed popup:", tostring(reason))
		else
			Logger.warn("Could not close completed popup:", tostring(reason))
		end
	end

	local function runSingleAttempt(config, buyer, item, uuid)
		if TradeState.resetStatus then
			TradeState.resetStatus()
		end

		local localUserId = tostring(Players.LocalPlayer.UserId)
		local buyerUserId = getUserIdString(buyer)

		if not buyerUserId then
			return false, "missing_buyer_user_id"
		end

		Logger.info("Security check:")
		Logger.info("  LocalUserId =", localUserId)
		Logger.info("  BuyerUserId =", buyerUserId)
		Logger.info("  Item UUID =", uuid)

		local requestOk, requestResult = TradeActions.sendTradeRequest(buyer)

		if not requestOk then
			return false, "trade_request_failed:" .. tostring(requestResult)
		end

		Logger.info("Trade request sent. Waiting for real trade replion...")

		local openTimeout = cfgNumber(config, "TradeOpenTimeout", 15)
		local openOk, openReason = TradeState.waitForTradeOpen(buyer, openTimeout)

		if not openOk then
			return false, openReason
		end

		Logger.info("Real trade opened for correct buyer:", tostring(openReason))

		local addOk, addReason = addAndVerifyItem(config, item, localUserId, uuid)

		if not addOk then
			return false, addReason
		end

		Logger.info("Item added and verified.")

		local countdownOk, countdownReason = waitCountdownOrFail(config)

		if not countdownOk then
			return false, countdownReason
		end

		local readyOk, readyReason = readyAndVerify(config, localUserId)

		if not readyOk then
			return false, readyReason
		end

		local buyerReadyOk, buyerReadyReason = waitBuyerReady(config, buyerUserId, localUserId, uuid)

		if not buyerReadyOk then
			return false, buyerReadyReason
		end

		if TradeState.offerContainsItem and not TradeState.offerContainsItem(localUserId, uuid) then
			return false, "our_item_missing_before_confirm"
		end

		local countdownOk2, countdownReason2 = waitCountdownOrFail(config)

		if not countdownOk2 then
			return false, countdownReason2
		end

		if TradeState.offerContainsItem and not TradeState.offerContainsItem(localUserId, uuid) then
			return false, "our_item_missing_after_countdown"
		end

		local confirmOk, confirmReason = confirmAndVerify(config, localUserId)

		if not confirmOk then
			return false, confirmReason
		end

		local buyerConfirmOk, buyerConfirmReason = waitBuyerConfirmOrProcessing(config, buyerUserId, localUserId, uuid)

		if not buyerConfirmOk then
			return false, buyerConfirmReason
		end

		local finalOk, finalReason = waitFinalResult(config)

		if not finalOk then
			return false, finalReason
		end

		closeCompletedPopup(config)

		return true, "trade_complete"
	end

	function TradeMain.Start()
		local config = getConfig()

		Logger.info("Starting secure trade delivery.")

		if not cfgBool(config, "AllowTrade", true) then
			return false, "trade_disabled_by_config"
		end

		if not config.BuyerName or config.BuyerName == "" then
			return false, "missing_buyer_name"
		end

		if not config.ItemName or config.ItemName == "" then
			return false, "missing_item_name"
		end

		if not config.ItemType or config.ItemType == "" then
			return false, "missing_item_type"
		end

		local qtyOk, qtyReason = checkQuantitySupported(config)

		if not qtyOk then
			return false, qtyReason
		end

		local buyer, buyerReason = waitForBuyer(config)

		if not buyer then
			return false, buyerReason
		end

		Logger.info("Buyer found:", buyer.Name, buyer.UserId)

		local joinCooldown = cfgNumber(config, "TradeJoinCooldown", 30)

		if joinCooldown > 0 then
			Logger.info("Waiting", joinCooldown, "seconds before sending trade request because of join cooldown.")
			task.wait(joinCooldown)

			buyer, buyerReason = findBuyer(config)

			if not buyer then
				Logger.warn("Buyer left during join cooldown. Waiting again...")
				buyer, buyerReason = waitForBuyer(config)

				if not buyer then
					return false, "buyer_left_during_join_cooldown"
				end
			end

			Logger.info("Buyer still in server after cooldown:", buyer.Name, buyer.UserId)
		end

		local item = InventoryUtil.findTradableItem(config.ItemType, config.ItemName)

		if not item then
			return false, "item_not_found"
		end

		local uuid = getItemUuid(item)

		if not uuid then
			return false, "item_uuid_missing"
		end

		Logger.info("Selected item for secure trade:", tostring(uuid))

		local retries = cfgNumber(config, "TradeRequestRetries", 5)
		local retryDelay = cfgNumber(config, "TradeRequestRetryDelay", 3)

		local lastReason = "unknown"

		for attempt = 1, retries do
			Logger.info("Secure trade attempt", attempt, "/", retries)

			buyer, buyerReason = findBuyer(config)

			if not buyer then
				Logger.warn("Buyer left before trade request. Waiting again...")
				buyer, buyerReason = waitForBuyer(config)

				if not buyer then
					return false, "buyer_left_before_trade_request"
				end
			end

			local ok, reason = runSingleAttempt(config, buyer, item, uuid)

			if ok then
				Logger.info("Secure trade delivery finished successfully.")
				return true, "trade_complete"
			end

			lastReason = reason
			Logger.warn("Secure trade attempt failed:", tostring(reason))

			safeCancel(reason)

			if not shouldRetry(reason) then
				Logger.warn("Failure is not retryable:", tostring(reason))
				return false, reason
			end

			if attempt < retries then
				Logger.info("Retrying secure trade in", retryDelay, "seconds...")
				task.wait(retryDelay)
			end
		end

		return false, lastReason
	end

	return TradeMain
end
