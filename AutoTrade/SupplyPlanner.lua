-- AutoTrade/SupplyPlanner.lua

return function(ctx)
	local SupplyPlanner = {}

	local Logger = ctx.Modules.Logger
	local InventoryUtil = ctx.Modules.InventoryUtil
	local SupplyRAP = ctx.Modules.SupplyRAP

	local function totalQuantity(config)
		return math.max(1, tonumber(config.Quantity or config.OrderQuantity or 1) or 1)
	end

	function SupplyPlanner.checkTradeStock(config)
		local itemType = tostring(config.ItemType or config.DefaultItemType or "Sword")
		local itemName = tostring(config.ItemName or "")
		local needed = totalQuantity(config)

		if itemName == "" then
			return nil, "missing_item_name"
		end

		local found, reason, partial = InventoryUtil.findTradableItems(itemType, itemName, needed, {})
		local count = type(found) == "table" and #found or (type(partial) == "table" and #partial or 0)

		return {
			ItemType = itemType,
			ItemName = itemName,
			Needed = needed,
			Owned = count,
			Missing = math.max(0, needed - count),
			ExistingItems = found or partial or {},
			Enough = count >= needed,
			Reason = reason,
		}
	end

	function SupplyPlanner.buildPurchasePlan(config)
		local stock = SupplyPlanner.checkTradeStock(config)
		if not stock then
			return nil, "stock_check_failed"
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
			return nil, "supply_order_cap_exceeded"
		end

		local purchases = {}
		for i = 1, stock.Missing do
			table.insert(purchases, {
				ItemType = stock.ItemType,
				ItemName = stock.ItemName,
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
			MaxBuyPrice = maxPrice,
			PriceInfo = priceInfo,
			TotalMaxCost = totalMaxCost,
		}, "supply_needed"
	end

	return SupplyPlanner
end
