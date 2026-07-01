-- AutoTrade/SupplyPlanner.lua

return function(ctx)
	local SupplyPlanner = {}

	local Logger = ctx.Modules.Logger
	local InventoryUtil = ctx.Modules.InventoryUtil
	local SupplyRAP = ctx.Modules.SupplyRAP

	local function trim(s)
		return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
	end

	local function totalQuantity(config)
		local qty = tonumber(config.Quantity or config.OrderQuantity or 1) or 1
		qty = math.floor(qty)
		return math.max(1, qty)
	end

	function SupplyPlanner.checkTradeStock(config)
		local itemType = trim(config.ItemType or config.DefaultItemType or "Sword")
		local itemName = trim(config.ItemName or "")
		local needed = totalQuantity(config)

		if itemType == "" then
			return nil, "missing_item_type"
		end
		if itemName == "" then
			return nil, "missing_item_name"
		end

		local found, reason, partial = InventoryUtil.findTradableItems(itemType, itemName, needed, {})
		local count = type(found) == "table" and #found or (type(partial) == "table" and #partial or 0)
		local itemKey = nil
		pcall(function()
			itemKey = SupplyRAP.getItemKey(itemType, itemName)
		end)

		return {
			ItemType = itemType,
			ItemName = itemName,
			ItemKey = itemKey,
			Needed = needed,
			Owned = count,
			Missing = math.max(0, needed - count),
			ExistingItems = found or partial or {},
			Enough = count >= needed,
			Reason = reason,
		}
	end

	function SupplyPlanner.buildPurchasePlan(config)
		local stock, stockReason = SupplyPlanner.checkTradeStock(config)
		if not stock then
			return nil, stockReason or "stock_check_failed"
		end

		local maxQty = tonumber(config.SupplyMaxQuantityPerOrder or 3) or 3
		if stock.Needed > maxQty then
			return nil, "supply_quantity_cap_exceeded:" .. tostring(stock.Needed) .. ">" .. tostring(maxQty)
		end

		if stock.Enough then
			Logger.info("Supply not needed. Stock already enough:", stock.Owned, "/", stock.Needed)
			return {
				Needed = stock.Needed,
				Owned = stock.Owned,
				Missing = 0,
				Purchases = {},
				Stock = stock,
				TotalMaxCost = 0,
			}, "already_in_stock"
		end

		local maxPrice, priceReason, priceInfo = SupplyRAP.calculateMaxBuyPrice(config, stock.ItemType, stock.ItemName)
		if not maxPrice then
			return nil, priceReason or "could_not_calculate_max_price"
		end

		local totalMaxCost = maxPrice * stock.Missing
		local orderCap = tonumber(config.SupplyMaxTokensPerOrder or 0) or 0
		if orderCap > 0 and totalMaxCost > orderCap then
			return nil, "supply_order_cap_exceeded:" .. tostring(totalMaxCost) .. ">" .. tostring(orderCap)
		end

		local purchases = {}
		for i = 1, stock.Missing do
			table.insert(purchases, {
				ItemType = stock.ItemType,
				ItemName = stock.ItemName,
				ItemKey = stock.ItemKey,
				MaxBuyPrice = maxPrice,
				Index = i,
			})
		end

		Logger.warn("Supply needed:", stock.ItemName, "missing", stock.Missing, "max each", maxPrice, "total max", totalMaxCost)

		return {
			Needed = stock.Needed,
			Owned = stock.Owned,
			Missing = stock.Missing,
			Purchases = purchases,
			Stock = stock,
			ItemKey = stock.ItemKey,
			MaxBuyPrice = maxPrice,
			PriceInfo = priceInfo,
			TotalMaxCost = totalMaxCost,
		}, "supply_needed"
	end

	return SupplyPlanner
end
