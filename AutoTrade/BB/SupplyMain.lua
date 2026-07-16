-- AutoTrade/SupplyMain.lua

return function(ctx)
	local SupplyMain = {}

	local Logger = ctx.Modules.Logger
	local Heartbeat = ctx.Modules.Heartbeat
	local SupplyState = ctx.Modules.SupplyState
	local SupplyPlanner = ctx.Modules.SupplyPlanner
	local SupplyScanner = ctx.Modules.SupplyScanner
	local SupplyBuyer = ctx.Modules.SupplyBuyer

	local function phase(name, info)
		if Heartbeat and Heartbeat.SetPhase then
			Heartbeat.SetPhase(name, info or {})
		end
	end

	local function scanAndTeleport(config, plan)
		local maxAttempts = tonumber(config.SupplyMaxServersPerItem or config.SupplyMaxSearchAttempts or 15) or 15
		local retryDelay = tonumber(config.SupplyRetryDelay or 1) or 1

		for attempt = 1, maxAttempts do
			phase("supply_index_searching", { attempt = attempt, total = maxAttempts, safeToRetry = true, dangerous = false })

			local ok, reason = SupplyScanner.searchAndTeleportToListing(config, config.ItemType, config.ItemName, plan)
			if ok then
				return false, "supply_teleporting"
			end

			local r = tostring(reason or "")
			Logger.warn("Supply Index seller search failed:", r)

			if r:find("no_listings", 1, true) or r:find("seller_prompt_not_found", 1, true) or r:find("index_teleport_no_server_change", 1, true) then
				task.wait(retryDelay)
				continue
			end

			-- Hard failures should not spin forever.
			return false, r
		end

		return false, "supply_no_seller_found_after_retries"
	end

	local function continueAfterPurchasedReturning(config, state)
		local plan, planReason = SupplyPlanner.buildPurchasePlan(config)
		if not plan then
			return false, planReason or "supply_plan_failed_after_return"
		end

		if plan.Missing == 0 then
			SupplyState.Clear(config)
			return true, "supply_completed_after_return"
		end

		local ownedNow = plan and plan.Owned or 0
		local initialOwned = tonumber(state.InitialOwned or -1) or -1
		if ownedNow <= initialOwned then
			SupplyState.MarkManualCheck(config, state, "purchase_not_visible_after_return")
			return false, "manual_check_supply_purchase_not_visible_after_return"
		end

		if config.SupplyAllowMultiplePurchasesPerOrder == false then
			SupplyState.MarkManualCheck(config, state, "multiple_supply_purchases_disabled_and_still_missing")
			return false, "manual_check_still_missing_after_one_supply_purchase"
		end

		Logger.warn("Supply bought one copy but order still missing more. Continuing supply:", tostring(planReason))
		SupplyState.Clear(config)
		return scanAndTeleport(config, plan)
	end

	function SupplyMain.EnsureStock(config)
		phase("supply_start", { safeToRetry = true, dangerous = false })

		if config.SupplyEnabled == false then
			Logger.warn("Supply disabled. Skipping supply.")
			return false, "supply_disabled"
		end

		local state = SupplyState.Load(config)

		if state and state.Stage == "stale_dangerous_block" then
			phase("supply_stale_dangerous_block", { safeToRetry = false, dangerous = true, StaleBridgeId = state.StaleBridgeId })
			return false, "manual_check_stale_dangerous_supply_state:" .. tostring(state.StaleBridgeId)
		end

		if state and SupplyState.IsDangerous(state) then
			local ok, reason = SupplyBuyer.resumeAtBooth(config, state)
			if ok then
				local returnOk, returnReason = SupplyScanner.returnToPrivateServer(config, state)
				if returnOk then
					return false, "returning_to_private_server"
				end
				return false, returnReason
			end
			return false, reason
		end

		if state and state.Stage == "teleported_to_listing" then
			local ok, reason = SupplyBuyer.resumeAtBooth(config, state)
			if ok then
				local returnOk, returnReason = SupplyScanner.returnToPrivateServer(config, state)
				if returnOk then
					return false, "returning_to_private_server"
				end
				return false, returnReason
			end

			local r = tostring(reason or "")
			if r:find("listing_", 1, true)
				or r:find("no_matching", 1, true)
				or r:find("price", 1, true)
				or r:find("budget", 1, true)
				or r:find("not_enough_tokens", 1, true) then
				Logger.warn("Supply listing rejected after booth check, continuing search:", r)
				SupplyState.Clear(config)
				local plan = SupplyPlanner.buildPurchasePlan(config)
				if type(plan) == "table" then
					return scanAndTeleport(config, plan)
				end
			end

			return false, reason
		end

		if state and state.Stage == "purchased_returning" then
			return continueAfterPurchasedReturning(config, state)
		end

		local plan, planReason = SupplyPlanner.buildPurchasePlan(config)
		if not plan then
			return false, planReason or "supply_plan_failed"
		end

		if plan.Missing <= 0 then
			return true, "already_in_stock"
		end

		Logger.warn("Need supply before delivery:", config.ItemName, "missing", plan.Missing)
		return scanAndTeleport(config, plan)
	end

	function SupplyMain.Start(config)
		local ok, reason = SupplyMain.EnsureStock(config)
		if ok then
			return true, reason or "supply_ready"
		end
		return false, reason or "supply_failed"
	end

	return SupplyMain
end
