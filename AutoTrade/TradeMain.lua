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

		Logger.info("Waiting for buyer to join server:")
		Logger.info("  BuyerName =", tostring(config.BuyerName))
		Logger.info("  BuyerUserId =", tostring(config.BuyerUserId))
		Logger.info("  Timeout =", timeout)

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

		if reason:find("our_item_removed_or_missing", 1, true) then
			return true
		end

		return false
	end

	local function getBridgeId(job, index)
		return tostring(job.BridgeId or job.OrderId or ("job_" .. tostring(index)))
	end

	local function getJobs(config)
		if type(config.GroupJobs) == "table" and #config.GroupJobs > 0 then
			return config.GroupJobs
		end

		return { config }
	end

	local function normalizeJob(config, job, index)
		local normalized = {}

		for k, v in pairs(config) do
			if type(v) ~= "function" and k ~= "GroupJobs" then
				normalized[k] = v
			end
		end

		if type(job) == "table" then
			for k, v in pairs(job) do
				normalized[k] = v
			end
		end

		normalized.BridgeId = getBridgeId(normalized, index)
		normalized.DeliveryMode = normalized.DeliveryMode or "Trade"
		normalized.ItemType = normalized.ItemType or config.DefaultItemType or "Sword"
		normalized.Quantity = math.max(1, tonumber(normalized.Quantity or 1) or 1)
		normalized.OrderQuantity = math.max(1, tonumber(normalized.OrderQuantity or 1) or 1)
		normalized.TotalQuantity = math.max(normalized.Quantity, normalized.OrderQuantity)

		return normalized
	end

	local function collectTradePlan(config)
		local rawJobs = getJobs(config)
		local jobs = {}
		local totalItems = 0

		for index, rawJob in ipairs(rawJobs) do
			local job = normalizeJob(config, rawJob, index)

			if job.DeliveryMode ~= "Trade" then
				return nil, "group_contains_non_trade_job"
			end

			if not job.BuyerName or job.BuyerName == "" then
				return nil, "missing_buyer_name_in_group"
			end

			if tostring(job.BuyerName):lower() ~= tostring(config.BuyerName):lower() then
				return nil, "group_contains_different_buyer"
			end

			if not job.ItemType or job.ItemType == "" then
				return nil, "missing_item_type_in_group"
			end

			if not job.ItemName or job.ItemName == "" then
				return nil, "missing_item_name_in_group"
			end

			totalItems += job.TotalQuantity
			table.insert(jobs, job)
		end

		local maxItems = cfgNumber(config, "MaxTradeItemsPerBatch", 100)

		if totalItems > maxItems then
			return nil, "too_many_items_for_trade_batch:" .. tostring(totalItems)
		end

		return {
			Jobs = jobs,
			TotalItems = totalItems,
		}
	end

	local function selectItemsForPlan(plan)
		local selected = {}
		local excluded = {}

		for _, job in ipairs(plan.Jobs) do
			Logger.info("Selecting items for job:", tostring(job.BridgeId), job.ItemType, job.ItemName, "x", job.TotalQuantity)

			local items, reason, partial = InventoryUtil.findTradableItems(job.ItemType, job.ItemName, job.TotalQuantity, excluded)

			if not items then
				return nil, "item_not_found_or_not_enough:" .. tostring(reason) .. ":" .. tostring(job.BridgeId), partial
			end

			job.SelectedItems = items

			for _, item in ipairs(items) do
				item.BridgeId = job.BridgeId
				item.OrderTitle = job.OrderTitle
				table.insert(selected, item)
			end
		end

		return selected
	end

	local function getUuids(items)
		local uuids = {}

		for _, item in ipairs(items) do
			local uuid = getItemUuid(item)

			if not uuid then
				return nil, "item_uuid_missing"
			end

			table.insert(uuids, uuid)
		end

		return uuids
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

	local function addSingleItemWithRetry(config, item, localUserId, index, total)
		local uuid = getItemUuid(item)
		local maxAttempts = cfgNumber(config, "MaxAddAttempts", 10)
		local verifyTimeout = cfgNumber(config, "TradeItemVerifyTimeout", 8)
		local retryDelay = cfgNumber(config, "TradeAddRetryDelay", 0.75)
		local lastReason = "unknown"

		if not uuid then
			return false, "item_uuid_missing"
		end

		for attempt = 1, maxAttempts do
			if TradeState.offerContainsItem and TradeState.offerContainsItem(localUserId, uuid) then
				Logger.info("Item already in offer before add retry:", tostring(uuid))
				return true
			end

			if attempt > 1 then
				Logger.info("Retrying AddItemToTrade for item", index, "/", total, "attempt", attempt, "/", maxAttempts)
				waitCountdownOrFail(config)
				task.wait(retryDelay)
			end

			phase("adding_items", { ItemName = item.ItemName, ItemType = item.ItemType, safeToRetry = true, dangerous = false })

			Logger.info("Adding trade item", index, "/", total, tostring(item.ItemType), tostring(item.ItemName), tostring(uuid), "attempt", attempt, "/", maxAttempts)

			local addOk, addResult = TradeActions.addItemToTrade(item)

			if addOk then
				local seenOk, seenReason = TradeState.waitItemInOffer(localUserId, uuid, verifyTimeout)

				if seenOk then
					Logger.info("Verified trade item", index, "/", total, "in offer:", tostring(uuid))
					return true
				end

				lastReason = tostring(seenReason)
				Logger.warn("AddItemToTrade returned true but item was not verified yet:", tostring(seenReason), tostring(uuid))
			else
				lastReason = tostring(addResult)
				Logger.warn("AddItemToTrade failed for item", index, "/", total, "attempt", attempt, "/", maxAttempts, tostring(addResult), tostring(uuid))
			end
		end

		return false, "add_item_failed_after_retries:" .. tostring(lastReason) .. ":" .. tostring(uuid)
	end

	local function addAndVerifyItems(config, items, localUserId, uuids)
		local clearBeforeAdd = cfgBool(config, "TradeClearBeforeAdd", true)
		local waitBetweenAdds = cfgBool(config, "TradeWaitBetweenItemAdds", true)

		if clearBeforeAdd and TradeActions.clearTradeContents then
			TradeActions.clearTradeContents()
		end

		for index, item in ipairs(items) do
			if index > 1 and waitBetweenAdds then
				Logger.info("Waiting for item-change cooldown before adding next item", index, "/", #items)
				local cooldownOk, cooldownReason = waitCountdownOrFail(config)

				if not cooldownOk then
					return false, "item_add_cooldown_failed:" .. tostring(cooldownReason)
				end
			end

			local addOk, addReason = addSingleItemWithRetry(config, item, localUserId, index, #items)

			if not addOk then
				return false, addReason
			end
		end

		local allPresent, missingUuid = TradeState.offerContainsAllItems(localUserId, uuids)

		if not allPresent then
			return false, "not_all_items_seen_in_offer:" .. tostring(missingUuid)
		end

		phase("items_verified", { Quantity = #items, safeToRetry = true, dangerous = false })

		Logger.info("All trade items added and verified:", #items)
		return true
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

	local function waitBuyerReady(config, buyerUserId, localUserId, uuids)
		local timeout = cfgNumber(config, "TradeBuyerReadyTimeout", 60)

		phase("waiting_buyer_ready", { safeToRetry = true, dangerous = false })

		Logger.info("Waiting for buyer to ready. Timeout:", timeout)

		local ok, reason = TradeState.waitBuyerReady(buyerUserId, localUserId, uuids, timeout)

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

	local function waitBuyerConfirmOrProcessing(config, buyerUserId, localUserId, uuids)
		local timeout = cfgNumber(config, "TradeBuyerConfirmTimeout", 60)

		phase("waiting_buyer_confirm", { safeToRetry = false, dangerous = true })

		Logger.info("Waiting for buyer confirm or processing. Timeout:", timeout)

		local ok, reason = TradeState.waitBuyerConfirmedOrProcessing(buyerUserId, localUserId, uuids, timeout)

		if not ok then
			return false, reason
		end

		phase("buyer_confirmed", { safeToRetry = false, dangerous = true })

		Logger.info("Buyer confirm/processing verified:", tostring(reason))
		return true
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

	local function runSingleAttempt(config, buyer, items, uuids)
		if TradeState.resetStatus then
			TradeState.resetStatus()
		end

		local localUserId = tostring(Players.LocalPlayer.UserId)
		local buyerUserId = getUserIdString(buyer)

		if not buyerUserId then
			return false, "missing_buyer_user_id"
		end

		phase("trade_attempt_start", { attempt = nil, safeToRetry = true, dangerous = false })

		Logger.info("Security check:")
		Logger.info("  LocalUserId =", localUserId)
		Logger.info("  BuyerUserId =", buyerUserId)
		Logger.info("  Item count =", #items)

		phase("trade_requesting", { BuyerName = buyer.Name, BuyerUserId = buyer.UserId, safeToRetry = true, dangerous = false })

		local requestOk, requestResult = TradeActions.sendTradeRequest(buyer)

		if not requestOk then
			return false, "trade_request_failed:" .. tostring(requestResult)
		end

		phase("waiting_trade_open", { safeToRetry = true, dangerous = false })

		Logger.info("Trade request sent. Waiting for real trade replion...")

		local openTimeout = cfgNumber(config, "TradeOpenTimeout", 15)
		local openOk, openReason = TradeState.waitForTradeOpen(buyer, openTimeout)

		if not openOk then
			return false, openReason
		end

		phase("trade_open", { safeToRetry = true, dangerous = false })

		Logger.info("Real trade opened for correct buyer:", tostring(openReason))

		local addOk, addReason = addAndVerifyItems(config, items, localUserId, uuids)

		if not addOk then
			return false, addReason
		end

		Logger.info("Items added and verified.")

		local countdownOk, countdownReason = waitCountdownOrFail(config)

		if not countdownOk then
			return false, countdownReason
		end

		local readyOk, readyReason = readyAndVerify(config, localUserId)

		if not readyOk then
			return false, readyReason
		end

		local buyerReadyOk, buyerReadyReason = waitBuyerReady(config, buyerUserId, localUserId, uuids)

		if not buyerReadyOk then
			return false, buyerReadyReason
		end

		local allPresent, missingUuid = TradeState.offerContainsAllItems(localUserId, uuids)

		if not allPresent then
			return false, "our_item_missing_before_confirm:" .. tostring(missingUuid)
		end

		local countdownOk2, countdownReason2 = waitCountdownOrFail(config)

		if not countdownOk2 then
			return false, countdownReason2
		end

		allPresent, missingUuid = TradeState.offerContainsAllItems(localUserId, uuids)

		if not allPresent then
			return false, "our_item_missing_after_countdown:" .. tostring(missingUuid)
		end

		local confirmOk, confirmReason = confirmAndVerify(config, localUserId)

		if not confirmOk then
			return false, confirmReason
		end

		local buyerConfirmOk, buyerConfirmReason = waitBuyerConfirmOrProcessing(config, buyerUserId, localUserId, uuids)

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

	function TradeMain.Start(overrideConfig)
		local config = getConfig(overrideConfig)

		phase("trade_start", { safeToRetry = true, dangerous = false })

		Logger.info("Starting secure trade delivery.")

		if not cfgBool(config, "AllowTrade", true) then
			return false, "trade_disabled_by_config"
		end

		if (not config.BuyerName or config.BuyerName == "") and not config.BuyerUserId then
			return false, "missing_buyer_identity"
		end

		local plan, planReason = collectTradePlan(config)

		if not plan then
			return false, planReason
		end

		Logger.info("Trade plan:", #plan.Jobs, "job(s),", plan.TotalItems, "item(s)")

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

		local items, selectReason = selectItemsForPlan(plan)

		if not items then
			return false, selectReason
		end

		local uuids, uuidReason = getUuids(items)

		if not uuids then
			return false, uuidReason
		end

		phase("items_selected", { Quantity = #items, safeToRetry = true, dangerous = false })

		Logger.info("Selected", #items, "item(s) for secure trade.")

		local retries = cfgNumber(config, "TradeRequestRetries", 5)
		local retryDelay = cfgNumber(config, "TradeRequestRetryDelay", 3)

		local lastReason = "unknown"

		for attempt = 1, retries do
			phase("trade_attempt", { attempt = attempt, safeToRetry = true, dangerous = false })

			Logger.info("Secure trade attempt", attempt, "/", retries)

			buyer, buyerReason = findBuyer(config)

			if not buyer then
				Logger.warn("Buyer left before trade request. Waiting again...")
				buyer, buyerReason = waitForBuyer(config)

				if not buyer then
					return false, "buyer_left_before_trade_request"
				end
			end

			local ok, reason = runSingleAttempt(config, buyer, items, uuids)

			if ok then
				phase("completed", { safeToRetry = false, dangerous = false })

				Logger.info("Secure trade delivery finished successfully.")
				return true, "trade_complete"
			end

			lastReason = reason
			phase("attempt_failed", { reason = tostring(reason), safeToRetry = true, dangerous = false })

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
