-- AutoTrade/SupplyRAP.lua
-- RAP/current-price planning with retry and liquidity failsafes.

return function(ctx)
	local SupplyRAP = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger

	local ReplionPackage = require(ReplicatedStorage.Packages.Replion)
	local InventoryClient = require(ReplicatedStorage.Shared.Inventory).Client

	local function replionClient()
		return ReplionPackage.Client or ReplionPackage
	end

	local function trim(s)
		return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
	end

	local function waitReplion(name, timeout)
		local client = replionClient()
		local direct = nil
		pcall(function()
			direct = client:GetReplion(name)
		end)
		if direct then
			return direct
		end

		local done = false
		local result = nil
		task.spawn(function()
			local ok, replion = pcall(function()
				return client:WaitReplion(name)
			end)
			if ok then
				result = replion
			end
			done = true
		end)

		local started = os.clock()
		while not done and os.clock() - started < (tonumber(timeout or 10) or 10) do
			task.wait(0.1)
		end

		return result
	end

	function SupplyRAP.getItemKey(itemType, itemName)
		itemType = trim(itemType)
		itemName = trim(itemName)
		if itemType == "" or itemName == "" then
			return nil, "missing_item_type_or_name"
		end

		local attempts = {
			function()
				return InventoryClient:ItemToKey(itemType, { Name = itemName })
			end,
			function()
				return InventoryClient.ItemToKey(itemType, { Name = itemName })
			end,
		}

		for _, fn in ipairs(attempts) do
			local ok, key = pcall(fn)
			if ok and key and tostring(key) ~= "" then
				return tostring(key), nil
			end
		end

		return nil, "item_key_failed"
	end

	function SupplyRAP.keyToItem(key)
		local ok, item = pcall(function()
			return InventoryClient:KeyToItem(key)
		end)
		if ok and type(item) == "table" then
			return item
		end
		return nil
	end

	function SupplyRAP.itemToKey(itemType, item, ignore)
		if type(item) ~= "table" then
			return nil, "missing_item_table"
		end
		local ok, key = pcall(function()
			return InventoryClient:ItemToKey(itemType, item, ignore or { "TradeLock" })
		end)
		if ok and key then
			return tostring(key), nil
		end
		return nil, "item_to_key_failed"
	end

	local function getRAPControllerRAP(itemType, itemName, itemKey)
		local okCtrl, RAPController = pcall(function()
			return require(ReplicatedStorage.Controllers.Trading.RAPController)
		end)
		if not okCtrl or type(RAPController) ~= "table" then
			return nil
		end

		local item = SupplyRAP.keyToItem(itemKey)
		if type(item) ~= "table" then
			item = { Name = itemName }
		end

		local filteredKey = nil
		pcall(function()
			filteredKey = RAPController:GetFilteredItemKey(itemType, item)
		end)
		filteredKey = filteredKey or itemKey

		local ok, rap = pcall(function()
			return RAPController:FastGetRAP(itemType, item, filteredKey)
		end)

		if ok and tonumber(rap) and tonumber(rap) > 0 then
			return tonumber(rap), filteredKey
		end
		return nil
	end

	function SupplyRAP.getCurrentRAP(itemType, itemName)
		local itemKey, keyReason = SupplyRAP.getItemKey(itemType, itemName)
		if not itemKey then
			return nil, keyReason or "item_key_failed"
		end

		local rapViaController, filteredKey = getRAPControllerRAP(itemType, itemName, itemKey)
		if rapViaController then
			return rapViaController, nil, itemKey, filteredKey
		end

		local rapReplion = waitReplion("ItemRAP", 12)
		if not rapReplion then
			return nil, "itemrap_replion_missing", itemKey
		end

		local paths = {
			{ "Items", itemType, itemKey },
			{ "Items", tostring(itemType), tostring(itemKey) },
		}

		for _, path in ipairs(paths) do
			local ok, rap = pcall(function()
				return rapReplion:Get(path)
			end)
			if ok and tonumber(rap) and tonumber(rap) > 0 then
				return tonumber(rap), nil, itemKey, itemKey
			end
		end

		return nil, "rap_missing", itemKey
	end

	local function dayTimestamp(dt)
		local u = dt:ToUniversalTime()
		return DateTime.fromUniversalTime(u.Year, u.Month, u.Day).UnixTimestamp
	end

	local function readRenderedRapPoints()
		local Players = game:GetService("Players")
		local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChild("PlayerGui")
		if not playerGui then
			return {}
		end

		local points = {}
		for _, inst in ipairs(playerGui:GetDescendants()) do
			local rap = inst:GetAttribute("RAP")
			local count = inst:GetAttribute("Count")
			local date = inst:GetAttribute("Date")
			if rap ~= nil and count ~= nil then
				table.insert(points, {
					RAP = tonumber(rap) or 0,
					Count = tonumber(count) or 0,
					Date = date,
				})
			end
		end
		return points
	end

	function SupplyRAP.getRecentStats(itemType, itemName, daysBack, config)
		daysBack = tonumber(daysBack or 5) or 5

		local itemKey, keyReason = SupplyRAP.getItemKey(itemType, itemName)
		if not itemKey then
			return nil, keyReason or "item_key_failed"
		end

		local okChart, RAPChartController = pcall(function()
			return require(ReplicatedStorage.Controllers.Trading.RAPChartController)
		end)
		if not okChart or type(RAPChartController) ~= "table" or type(RAPChartController.Render) ~= "function" then
			return nil, "rap_chart_controller_missing"
		end

		local maxRetries = tonumber((config and config.SupplyRAPMaxRetries) or 4) or 4
		local retryDelay = tonumber((config and config.SupplyRAPRetryDelay) or 1.25) or 1.25
		local points = nil
		local lastReason = nil

		for attempt = 1, math.max(1, maxRetries) do
			local okRender, err = pcall(function()
				-- Normal client path. Do not call RequestRAPHistory directly.
				RAPChartController:Render("Index", itemType, itemKey)
			end)

			if okRender then
				task.wait(tonumber((config and config.SupplyRAPRenderWait) or 1.0) or 1.0)
				local rendered = readRenderedRapPoints()
				if type(rendered) == "table" and #rendered > 0 then
					points = rendered
					break
				end
				lastReason = "rap_chart_rendered_no_points"
			else
				lastReason = "rap_chart_render_error:" .. tostring(err)
			end

			if attempt < maxRetries then
				task.wait(retryDelay * (2 ^ math.min(attempt - 1, 3)))
			end
		end

		if type(points) ~= "table" or #points == 0 then
			return nil, lastReason or "rap_chart_points_missing"
		end

		local totalSales = 0
		local rapPoints = 0
		local rapTotal = 0

		for _, row in ipairs(points) do
			local rap = tonumber(row.RAP) or 0
			local count = tonumber(row.Count) or 0
			if rap > 0 then
				rapTotal += rap
				rapPoints += 1
			end
			if count > 0 then
				totalSales += count
			end
		end

		return {
			ItemKey = itemKey,
			Days = math.min(#points, daysBack),
			DaysBack = daysBack,
			TotalSales = totalSales,
			AvgSalesPerDay = totalSales / math.max(daysBack, 1),
			AvgRAP = rapPoints > 0 and math.round(rapTotal / rapPoints) or nil,
			Source = "RAPChartController.Render",
		}, nil
	end

	local function defaultPriceRules()
		return {
			{ MaxRap = 500, MaxMultiplier = 1.40, MaxExtra = 150 },
			{ MaxRap = 2000, MaxMultiplier = 1.25, MaxExtra = 300 },
			{ MaxRap = 5000, MaxMultiplier = 1.15, MaxExtra = 500 },
			{ MaxRap = math.huge, MaxMultiplier = 1.10, MaxExtra = 800 },
		}
	end

	local function getPriceRule(config, rap)
		local rules = type(config.SupplyPriceRules) == "table" and config.SupplyPriceRules or defaultPriceRules()
		for _, rule in ipairs(rules) do
			if rap <= (tonumber(rule.MaxRap) or math.huge) then
				return rule
			end
		end
		return rules[#rules] or { MaxMultiplier = 1, MaxExtra = 0 }
	end

	local function salesSafetyMultiplier(config, salesPerDay)
		salesPerDay = tonumber(salesPerDay or 0) or 0
		if salesPerDay <= 0 then
			return tonumber(config.SupplyNoSalesMultiplier or 0.90) or 0.90
		end
		if salesPerDay < 5 then
			return tonumber(config.SupplyLowSalesMultiplier or 0.90) or 0.90
		end
		if salesPerDay < 20 then
			return tonumber(config.SupplyMidSalesMultiplier or 0.95) or 0.95
		end
		return 1
	end

	function SupplyRAP.calculateMaxBuyPrice(config, itemType, itemName)
		local rap, rapReason, itemKey, filteredKey = SupplyRAP.getCurrentRAP(itemType, itemName)
		if not rap then
			return nil, rapReason or "rap_missing"
		end

		local stats, statsReason = nil, nil
		if config.SupplyUseRecentSales ~= false then
			stats, statsReason = SupplyRAP.getRecentStats(itemType, itemName, config.SupplyRAPDaysBack or 5, config)
		end

		if config.SupplyRequireRecentSalesForAutoBuy ~= false and config.SupplyAutoBuy == true then
			if type(stats) ~= "table" then
				return nil, "recent_sales_required:" .. tostring(statsReason or "missing")
			end
			if (tonumber(stats.TotalSales or 0) or 0) <= 0 and config.SupplyBlockNoSales ~= false then
				return nil, "no_recent_sales_manual_only"
			end
			local minSales = tonumber(config.SupplyMinSalesPerDayAutoBuy or 0) or 0
			if minSales > 0 and (tonumber(stats.AvgSalesPerDay or 0) or 0) < minSales then
				return nil, "low_liquidity_manual_only"
			end
		end

		local salesPerDay = stats and tonumber(stats.AvgSalesPerDay or 0) or 0
		local rule = getPriceRule(config, rap)
		local byMultiplier = rap * (tonumber(rule.MaxMultiplier) or 1)
		local byExtra = rap + (tonumber(rule.MaxExtra) or 0)
		local maxPrice = math.floor(math.min(byMultiplier, byExtra) * salesSafetyMultiplier(config, salesPerDay))

		local hardCap = tonumber(config.SupplyMaxTokensPerItem or 0) or 0
		if hardCap > 0 then
			maxPrice = math.min(maxPrice, hardCap)
		end

		maxPrice = math.max(1, maxPrice)
		Logger.info("Supply price plan:", itemName, "RAP", rap, "sales/day", string.format("%.2f", salesPerDay), "max", maxPrice)

		return maxPrice, nil, {
			RAP = rap,
			ItemKey = itemKey,
			FilteredKey = filteredKey,
			Stats = stats,
			StatsReason = statsReason,
			SalesPerDay = salesPerDay,
			Rule = rule,
		}
	end

	function SupplyRAP.isPriceSafe(config, itemType, itemName, price)
		price = tonumber(price)
		if not price then
			return false, "price_not_number"
		end
		if price <= 0 then
			return false, "price_not_positive"
		end

		local maxPrice, reason, info = SupplyRAP.calculateMaxBuyPrice(config, itemType, itemName)
		if not maxPrice then
			return false, reason or "max_price_failed", info
		end

		if price > maxPrice then
			return false, "price_above_max", info, maxPrice
		end

		return true, "price_safe", info, maxPrice
	end

	return SupplyRAP
end
