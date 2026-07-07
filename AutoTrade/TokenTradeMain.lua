-- AutoTrade/TokenTradeMain.lua
--
-- NEW FILE. Add this to your AutoTrade fork at AutoTrade/TokenTradeMain.lua
-- and add "TokenTradeMain" to Loader.lua's FILES list (see README.md in
-- this folder for the exact line).
--
-- Delivers raw Tokens via an in-game TRADE (DeliveryMode = "TokenTrade"),
-- for orders where the buyer purchased raw Tokens directly rather than a
-- Spin gift product. Adapted from TradeMain.lua but:
--   - no item selection/verification (InventoryUtil not used)
--   - uses TradeActions.addTokensToTrade(amount) instead of addItemToTrade
--   - verification is BALANCE-BASED (local token balance before vs after,
--     via the same Replion Inventory:Get("Tokens") pattern GiftActions.lua
--     already uses and trusts for confirming a gift spent tokens), NOT
--     based on reading a token count back out of the trade replion state
--     -- that schema key was never confirmed, so this avoids depending on
--     it. The trade still goes through the exact same request/ready/
--     confirm/final-result flow as a normal secure trade.
--
-- Config fields used: BuyerName, BuyerUserId, TokenAmount, BridgeId,
-- DeadlineUnix, and the same Trade* timeout/retry knobs TradeMain.lua
-- already reads (TradeBuyerJoinTimeout, TradeOpenTimeout, TradeAutoConfirm,
-- etc.) -- reused as-is, nothing new to configure there.
--
-- NOT YET VERIFIED LIVE. Test with a small TokenAmount and
-- RequireManualConfirm=true / a throwaway buyer account before trusting
-- this unattended. In particular: confirm AddTokensToTrade's remote
-- signature really is just (amount) as clearTokens() implies, and that a
-- token-only offer (no items) is actually accepted by the trade UI/server
-- the same way an item-only offer is.

return function(ctx)
	local TokenTradeMain = {}

	local Players = ctx.Services.Players
	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local PlayersUtil = ctx.Modules.PlayersUtil
	local TradeActions = ctx.Modules.TradeActions
	local TradeState = ctx.Modules.TradeState
	local Logger = ctx.Modules.Logger
	local Config = ctx.Modules.Config
	local Heartbeat = ctx.Modules.Heartbeat

	local function getConfig(overrideConfig)
		if type(overrideConfig) == "table" then
			return overrideConfig
		end

		if type(Config.Resolve) == "function" then
			return Config.Resolve(ctx)
		end

		if type(Config.Get) == "function" then
			return Config.Get(ctx)
		end

		return Config
	end

	local function phase(name, info)
		if Heartbeat and Heartbeat.SetPhase then
			Heartbeat.SetPhase(name, info or {})
		end
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
		local buyer = nil

		if PlayersUtil.findPlayerByUserId and config.BuyerUserId then
			buyer = PlayersUtil.findPlayerByUserId(config.BuyerUserId)
			if buyer then
				return buyer
			end
		end

		buyer = PlayersUtil.findPlayer(config.BuyerName)
		if not buyer then
			return nil, "buyer_not_found"
		end

		if config.BuyerUserId and tonumber(config.BuyerUserId) and buyer.UserId ~= tonumber(config.BuyerUserId) then
			Logger.warn("Buyer name matched but UserId mismatch. Refusing:", buyer.Name, buyer.UserId, "expected", config.BuyerUserId)
			return nil, "buyer_user_id_mismatch"
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

		phase("waiting_buyer", { BuyerName = config.BuyerName, BuyerUserId = config.BuyerUserId, safeToRetry = true, dangerous = false })
		Logger.info("Waiting for buyer to join server (TokenTrade):", tostring(config.BuyerName))

		local start = os.clock()
		local lastLog = 0

		while os.clock() - start < timeout do
			local buyer = findBuyer(config)
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
		Logger.warn("Cancelling token trade:", tostring(reason))
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
			tokens_not_confirmed_before_ready = true,
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

	-- Same technique GiftActions.lua already uses and trusts for
	-- confirming a gift actually spent tokens.
	local function getLocalTokenBalance()
		local ok, result = pcall(function()
			local Replion = require(ReplicatedStorage.Packages.Replion)
			local inventory = Replion.Client:WaitReplion("Inventory")
			return inventory:Get("Tokens")
		end)

		if ok and type(result) == "number" then
			return result
		end

		return nil
	end

	local function waitForTokenDecrease(before, expectedDecrease, timeout)
		if type(before) ~= "number" then
			return false, nil
		end

		local start = os.clock()
		local last = before

		while os.clock() - start < timeout do
			local current = getLocalTokenBalance()

			if type(current) == "number" then
				last = current

				if current <= before - (expectedDecrease * 0.99) then
					-- allow tiny rounding slack, require ~full expected amount
					return true, current
				end
			end

			task.wait(0.5)
		end

		return false, last
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

	local function addTokensWithRetry(config, amount)
		local maxAttempts = cfgNumber(config, "MaxAddAttempts", 5)
		local retryDelay = cfgNumber(config, "TradeAddRetryDelay", 0.75)
		local lastReason = "unknown"

		for attempt = 1, maxAttempts do
			if attempt > 1 then
				Logger.info("Retrying AddTokensToTrade, attempt", attempt, "/", maxAttempts)
				waitCountdownOrFail(config)
				task.wait(retryDelay)
			end

			phase("adding_tokens", { TokenAmount = amount, safeToRetry = true, dangerous = false })
			Logger.info("Adding tokens to trade:", amount, "attempt", attempt, "/", maxAttempts)

			local addOk, addResult = TradeActions.addTokensToTrade(amount)

			if addOk then
				-- Give the trade UI a moment to reflect the change (mirrors
				-- the item-add settle time TradeMain.lua uses, since there
				-- is no confirmed "tokens in offer" replion field to poll).
				task.wait(1.5)
				return true
			end

			lastReason = tostring(addResult)
			Logger.warn("AddTokensToTrade failed, attempt", attempt, "/", maxAttempts, tostring(addResult))
		end

		return false, "add_tokens_failed_after_retries:" .. tostring(lastReason)
	end

	local function readyAndVerify(config, localUserId)
		phase("ready_sent", { safeToRetry = true, dangerous = false })

		local readyOk, readyResult = TradeActions.readyUp(true)
		if not readyOk then
			return false, "ready_failed:" .. tostring(readyResult)
		end

		Logger.info("ReadyUp(true) sent. Verifying local ready state...")

		local timeout = cfgNumber(config, "TradeLocalReadyTimeout", 8)
		local ok, reason = TradeState.waitLocalReady(localUserId, timeout)
		if not ok then
			return false, reason
		end

		Logger.info("Verified local ready.")
		return true
	end

	local function waitBuyerReadySimple(config, buyerUserId)
		-- Same as TradeMain.lua's waitBuyerReady, but without the
		-- offerContainsAllItems check (no items to verify here).
		local timeout = cfgNumber(config, "TradeBuyerReadyTimeout", 60)

		phase("waiting_buyer_ready", { safeToRetry = true, dangerous = false })
		Logger.info("Waiting for buyer to ready. Timeout:", timeout)

		local start = os.clock()
		local lastLog = 0

		while os.clock() - start < timeout do
			if not TradeState.getTrade() then
				return false, "trade_closed"
			end

			if TradeState.isReady(buyerUserId) then
				Logger.info("Buyer is ready.")
				return true
			end

			if os.clock() - lastLog >= 5 then
				Logger.info("Waiting for buyer to ready...")
				lastLog = os.clock()
			end

			task.wait(0.5)
		end

		return false, "buyer_ready_timeout"
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
			phase("confirm_sent", { safeToRetry = false, dangerous = true })

			local confirmOk, confirmResult = TradeActions.confirmTrade()

			if confirmOk then
				Logger.info("ConfirmTrade returned success. Verifying local confirm/processing...")

				local ok, reason = TradeState.waitLocalConfirmed(localUserId, cfgNumber(config, "TradeLocalConfirmTimeout", 8))
				if ok then
					phase("local_confirmed", { safeToRetry = false, dangerous = true })
					Logger.info("Local confirm/processing verified.")
					return true
				end

				lastReason = reason
				Logger.warn("Local confirm not verified yet:", tostring(reason))
			else
				lastReason = confirmResult
				Logger.warn("ConfirmTrade failed:", tostring(confirmResult))
			end

			task.wait(1)
		end

		return false, "confirm_timeout:" .. tostring(lastReason)
	end

	local function waitBuyerConfirmOrProcessingSimple(config, buyerUserId)
		local timeout = cfgNumber(config, "TradeBuyerConfirmTimeout", 60)

		phase("waiting_buyer_confirm", { safeToRetry = false, dangerous = true })
		Logger.info("Waiting for buyer confirm or processing. Timeout:", timeout)

		local start = os.clock()
		local lastLog = 0

		while os.clock() - start < timeout do
			if not TradeState.getTrade() then
				if TradeState.getLastStatus() == "Completed" then
					return true, "completed"
				end
				return false, "trade_closed_before_completed"
			end

			if TradeState.isProcessing() then
				return true, "processing"
			end

			if TradeState.isConfirmed(buyerUserId) then
				return true, "buyer_confirmed"
			end

			if os.clock() - lastLog >= 5 then
				Logger.info("Waiting for buyer confirm/processing...")
				lastLog = os.clock()
			end

			task.wait(0.5)
		end

		return false, "buyer_confirm_timeout"
	end

	local function waitFinalResult(config)
		local timeout = cfgNumber(config, "TradeFinalTimeout", 30)

		phase("processing", { safeToRetry = false, dangerous = true })
		Logger.info("Waiting for final trade result. Timeout:", timeout)

		local ok, reason = TradeState.waitFinalResult(timeout)
		if not ok then
			return false, reason
		end

		phase("completed", { safeToRetry = false, dangerous = false })
		Logger.info("Final trade result verified:", tostring(reason))
		return true
	end

	local function closeCompletedPopup(config)
		if not cfgBool(config, "CloseCompletedPopup", true) then
			return
		end
		if not TradeState.closeCompletedPopup then
			return
		end

		local ok, reason = TradeState.closeCompletedPopup(cfgNumber(config, "CompletedPopupTimeout", 8))
		if ok then
			Logger.info("Closed completed popup:", tostring(reason))
		else
			Logger.warn("Could not close completed popup:", tostring(reason))
		end
	end

	local function runSingleAttempt(config, buyer, tokenAmount)
		if TradeState.resetStatus then
			TradeState.resetStatus()
		end

		local localUserId = tostring(Players.LocalPlayer.UserId)
		local buyerUserId = getUserIdString(buyer)

		if not buyerUserId then
			return false, "missing_buyer_user_id"
		end

		phase("token_trade_attempt_start", { safeToRetry = true, dangerous = false })

		Logger.info("Security check:")
		Logger.info("  LocalUserId =", localUserId)
		Logger.info("  BuyerUserId =", buyerUserId)
		Logger.info("  TokenAmount =", tokenAmount)

		local balanceBefore = getLocalTokenBalance()
		if balanceBefore ~= nil then
			Logger.info("Token balance before trade:", balanceBefore)
		else
			Logger.warn("Could not read token balance before trade (Replion Inventory:Get('Tokens') failed).")
		end

		phase("trade_requesting", { BuyerName = buyer.Name, BuyerUserId = buyer.UserId, safeToRetry = true, dangerous = false })

		local requestOk, requestResult = TradeActions.sendTradeRequest(buyer)
		if not requestOk then
			return false, "trade_request_failed:" .. tostring(requestResult)
		end

		phase("waiting_trade_open", { safeToRetry = true, dangerous = false })
		local openTimeout = cfgNumber(config, "TradeOpenTimeout", 15)
		local openOk, openReason = TradeState.waitForTradeOpen(buyer, openTimeout)
		if not openOk then
			return false, openReason
		end

		phase("trade_open", { safeToRetry = true, dangerous = false })
		Logger.info("Real trade opened for correct buyer:", tostring(openReason))

		if TradeActions.clearTradeContents then
			TradeActions.clearTradeContents()
		end

		local addOk, addReason = addTokensWithRetry(config, tokenAmount)
		if not addOk then
			return false, addReason
		end

		local countdownOk, countdownReason = waitCountdownOrFail(config)
		if not countdownOk then
			return false, countdownReason
		end

		local readyOk, readyReason = readyAndVerify(config, localUserId)
		if not readyOk then
			return false, readyReason
		end

		local buyerReadyOk, buyerReadyReason = waitBuyerReadySimple(config, buyerUserId)
		if not buyerReadyOk then
			return false, buyerReadyReason
		end

		local countdownOk2, countdownReason2 = waitCountdownOrFail(config)
		if not countdownOk2 then
			return false, countdownReason2
		end

		local confirmOk, confirmReason = confirmAndVerify(config, localUserId)
		if not confirmOk then
			return false, confirmReason
		end

		local buyerConfirmOk, buyerConfirmReason = waitBuyerConfirmOrProcessingSimple(config, buyerUserId)
		if not buyerConfirmOk then
			return false, buyerConfirmReason
		end

		local finalOk, finalReason = waitFinalResult(config)
		if not finalOk then
			return false, finalReason
		end

		closeCompletedPopup(config)

		-- ── Authoritative check: did our token balance actually drop by
		-- (about) tokenAmount? This is the real confirmation, since we
		-- never verified an in-trade token count against a trusted schema.
		if cfgBool(config, "RequireTokenBalanceDecrease", true) and balanceBefore ~= nil then
			phase("verifying_token_spend", { safeToRetry = false, dangerous = false })

			local decreased, afterBalance = waitForTokenDecrease(
				balanceBefore, tokenAmount, cfgNumber(config, "ConfirmTokenTradeTimeout", 12)
			)

			if not decreased then
				Logger.warn(
					"Trade reported complete but token balance did not decrease as expected.",
					"before=", balanceBefore, "after=", tostring(afterBalance), "expected_decrease=", tokenAmount
				)
				return false, "trade_completed_but_balance_not_confirmed"
			end

			Logger.info("Token balance confirmed decreased:", balanceBefore, "->", afterBalance)
		end

		return true, "token_trade_complete"
	end

	function TokenTradeMain.Start(overrideConfig)
		local config = getConfig(overrideConfig)

		phase("token_trade_start", { safeToRetry = true, dangerous = false })
		Logger.info("Starting TokenTrade delivery.")

		if cfgBool(config, "TokenTradeDryRun", true) then
			Logger.warn("TokenTradeDryRun is true -- not sending a real trade request. No tokens will move.")
			return false, "dry_run_blocked"
		end

		if not cfgBool(config, "AllowTrade", true) then
			return false, "trade_disabled_by_config"
		end

		if (not config.BuyerName or config.BuyerName == "") and not config.BuyerUserId then
			return false, "missing_buyer_identity"
		end

		local tokenAmount = tonumber(config.TokenAmount)
		if not tokenAmount or tokenAmount <= 0 then
			return false, "missing_or_invalid_token_amount"
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
		end

		local retries = cfgNumber(config, "TradeRequestRetries", 5)
		local retryDelay = cfgNumber(config, "TradeRequestRetryDelay", 3)
		local lastReason = "unknown"

		for attempt = 1, retries do
			phase("token_trade_attempt", { attempt = attempt, safeToRetry = true, dangerous = false })
			Logger.info("TokenTrade attempt", attempt, "/", retries)

			buyer, buyerReason = findBuyer(config)
			if not buyer then
				Logger.warn("Buyer left before trade request. Waiting again...")
				buyer, buyerReason = waitForBuyer(config)
				if not buyer then
					return false, "buyer_left_before_trade_request"
				end
			end

			local ok, reason = runSingleAttempt(config, buyer, tokenAmount)

			if ok then
				phase("completed", { safeToRetry = false, dangerous = false })
				Logger.info("TokenTrade delivery finished successfully.")
				return true, "token_trade_complete"
			end

			lastReason = reason
			phase("attempt_failed", { reason = tostring(reason), safeToRetry = true, dangerous = false })
			Logger.warn("TokenTrade attempt failed:", tostring(reason))

			safeCancel(reason)

			if not shouldRetry(reason) then
				Logger.warn("Failure is not retryable:", tostring(reason))
				return false, reason
			end

			if attempt < retries then
				Logger.info("Retrying TokenTrade in", retryDelay, "seconds...")
				task.wait(retryDelay)
			end
		end

		return false, lastReason
	end

	return TokenTradeMain
end
