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
		local maxServers = tonumber(config.SupplyMaxServersPerItem or 15) or 15
		local retryDelay = tonumber(config.SupplyRetryDelay or 1) or 1

		for attempt = 1, maxServers do
			phase("supply_searching", { attempt = attempt, total = maxServers, safeToRetry = true, dangerous = false })

			local listings, listReason = SupplyScanner.getListingCandidates(config, config.ItemType, config.ItemName)
			if type(listings) ~= "table" or #listings == 0 then
				Logger.warn("No supply listings found yet:", tostring(listReason))
				task.wait(retryDelay)
				continue
			end

			local listing, reason = SupplyScanner.chooseUnvisited(config, listings)
			if not listing then
				Logger.warn("No unvisited supply listing:", tostring(reason))
				task.wait(retryDelay)
				continue
			end

			local ok, tpReason = SupplyScanner.teleportToListing(config, listing, config.ItemType, config.ItemName)
			if ok then
				-- Usually the script is stopped by teleport before this returns.
				return false, "supply_teleporting"
			end

			Logger.warn("Supply teleport failed:", tostring(tpReason))
			task.wait(retryDelay)
		end

		return false, "supply_no_safe_listing_found"
	end

	function SupplyMain.EnsureStock(config)
		phase("supply_start", { safeToRetry = true, dangerous = false })

		if config.SupplyEnabled == false then
			Logger.warn("Supply disabled. Skipping supply.")
			return false, "supply_disabled"
		end

		local state = SupplyState.Load(config)

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
			if r:find("unsafe_listing_price", 1, true) or r:find("listing_not_found", 1, true) then
				Logger.warn("Supply listing rejected after booth check, continuing search:", r)
				return scanAndTeleport(config, nil)
			end

			return false, reason
		end

		if state and state.Stage == "purchased_returning" then
			local plan, planReason = SupplyPlanner.buildPurchasePlan(config)
			if plan and plan.Missing == 0 then
				SupplyState.Clear(config)
				return true, "supply_completed_after_return"
			end
			return false, "manual_check_supply_purchase_not_visible_after_return"
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
