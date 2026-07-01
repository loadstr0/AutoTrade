-- AutoTrade/SupplyRAP.lua

return function(ctx)
	local SupplyRAP = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger

	local Net = require(ReplicatedStorage.Packages.Net)
	local ReplionPackage = require(ReplicatedStorage.Packages.Replion)
	local InventoryClient = require(ReplicatedStorage.Shared.Inventory).Client
	local RequestRAPHistory = Net:RemoteFunction("RequestRAPHistory")

	local function getClientReplion()
		return ReplionPackage.Client or ReplionPackage
	end

	function SupplyRAP.getItemKey(itemType, itemName)
		local ok, key = pcall(function()
			return InventoryClient:ItemToKey(itemType, { Name = itemName })
		end)

		if ok and key then
			return key
		end

		ok, key = pcall(function()
			return InventoryClient.ItemToKey(itemType, { Name = itemName })
		end)

		if ok and key then
			return key
		end

		return nil
	end

	function SupplyRAP.keyToName(key)
		local ok, item = pcall(function()
			return InventoryClient:KeyToItem(key)
		end)

		if ok and type(item) == "table" then
			return item.Name or item.DisplayName
		end

		return nil
	end

	function SupplyRAP.getCurrentRAP(itemType, itemName)
		local itemKey = SupplyRAP.getItemKey(itemType, itemName)
		if not itemKey then
			return nil, "item_key_failed"
		end

		local client = getClientReplion()
		local okReplion, rapReplion = pcall(function()
			return client:WaitReplion("ItemRAP", 10)
		end)

		if not okReplion or not rapReplion then
			return nil, "itemrap_replion_missing"
		end

		local okGet, rap = pcall(function()
			return rapReplion:Get({ "Items", itemType, itemKey })
		end)

		if okGet and tonumber(rap) then
			return tonumber(rap), nil, itemKey
		end

		return nil, "rap_missing", itemKey
	end

	local function dayTimestamp(dt)
		local u = dt:ToUniversalTime()
		return DateTime.fromUniversalTime(u.Year, u.Month, u.Day).UnixTimestamp
	end

	function SupplyRAP.getRecentStats(itemType, itemName, daysBack)
		daysBack = tonumber(daysBack or 5) or 5

		local itemKey = SupplyRAP.getItemKey(itemType, itemName)
		if not itemKey then
			return nil, "item_key_failed"
		end

		local nowDt = DateTime.now()
		local startDt = DateTime.fromUnixTimestamp(nowDt.UnixTimestamp - daysBack * 86400)

		local ok, success, history = pcall(function()
			local s, h = RequestRAPHistory:InvokeServer(itemType, itemKey, startDt, nowDt)
			return s, h
		end)

		if not ok then
			return nil, "rap_history_error:" .. tostring(success)
		end

		if not success or type(history) ~= "table" then
			return nil, "rap_history_rejected"
		end

		local grouped = {}
		local totalSales = 0
		local rapPoints = 0
		local rapTotal = 0

		for _, row in ipairs(history) do
			if row.Date and row.RAP ~= nil and row.Count ~= nil then
				local ts = row.Date.UnixTimestamp
				if ts >= startDt.UnixTimestamp and ts <= nowDt.UnixTimestamp then
					local d = dayTimestamp(row.Date)
					grouped[d] = grouped[d] or { totalRap = 0, points = 0, totalSales = 0 }
					grouped[d].totalRap += tonumber(row.RAP) or 0
					grouped[d].points += 1
					grouped[d].totalSales += tonumber(row.Count) or 0
				end
			end
		end

		local days = 0
		for _, info in pairs(grouped) do
			days += 1
			totalSales += info.totalSales
			rapTotal += info.totalRap
			rapPoints += info.points
		end

		return {
			ItemKey = itemKey,
			Days = days,
			DaysBack = daysBack,
			TotalSales = totalSales,
			AvgSalesPerDay = totalSales / math.max(daysBack, 1),
			AvgRAP = rapPoints > 0 and math.round(rapTotal / rapPoints) or nil,
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
		return rules[#rules]
	end

	local function salesMultiplier(config, salesPerDay)
		salesPerDay = tonumber(salesPerDay or 0) or 0

		if salesPerDay <= 0 then
			return tonumber(config.SupplyNoSalesMultiplier or 0.95) or 0.95
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
		local rap, rapReason = SupplyRAP.getCurrentRAP(itemType, itemName)
		if not rap then
			return nil, rapReason or "rap_missing"
		end

		local stats = nil
		local statsReason = nil

		if config.SupplyUseRecentSales ~= false then
			stats, statsReason = SupplyRAP.getRecentStats(itemType, itemName, config.SupplyRAPDaysBack or 5)
		end

		local salesPerDay = stats and stats.AvgSalesPerDay or 0
		local rule = getPriceRule(config, rap)
		local byMultiplier = rap * (tonumber(rule.MaxMultiplier) or 1)
		local byExtra = rap + (tonumber(rule.MaxExtra) or 0)
		local maxPrice = math.floor(math.min(byMultiplier, byExtra) * salesMultiplier(config, salesPerDay))

		local hardCap = tonumber(config.SupplyMaxTokensPerItem or 0) or 0
		if hardCap > 0 then
			maxPrice = math.min(maxPrice, hardCap)
		end

		Logger.info("Supply price plan:", itemName, "RAP", rap, "sales/day", string.format("%.2f", salesPerDay), "max", maxPrice)

		return maxPrice, nil, {
			RAP = rap,
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

		local maxPrice, reason, info = SupplyRAP.calculateMaxBuyPrice(config, itemType, itemName)
		if not maxPrice then
			return false, reason, info
		end

		if price > maxPrice then
			return false, "price_above_limit", info, maxPrice
		end

		return true, "price_ok", info, maxPrice
	end

	return SupplyRAP
end
