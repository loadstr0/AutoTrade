-- AutoTrade/InventoryUtil.lua

return function(ctx)
	local InventoryUtil = {}

	local Players = ctx.Services.Players
	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local HttpService = ctx.Services.HttpService
	local Logger = ctx.Modules.Logger

	local LocalPlayer = Players.LocalPlayer

	local function equalsIgnoreCase(a, b)
		return tostring(a or ""):lower() == tostring(b or ""):lower()
	end

	local function containsIgnoreCase(a, b)
		return tostring(a or ""):lower():find(tostring(b or ""):lower(), 1, true) ~= nil
	end

	local function trySharedFindItemsWithKey(itemType, itemName)
		local ok, result = pcall(function()
			local InventoryShared = require(ReplicatedStorage.Shared.Inventory.Shared)
			local key = HttpService:JSONEncode({ { "Name", itemName } })
			return InventoryShared:FindItemsWithKey(LocalPlayer, itemType, key)
		end)

		if ok and type(result) == "table" then
			return result
		end

		return {}
	end

	local function tryClientFindItems(itemType, itemName)
		local ok, result = pcall(function()
			local InventoryClient = require(ReplicatedStorage.Shared.Inventory.Client)
			return InventoryClient:FindItems(LocalPlayer, itemType, function(item)
				return item and (
					equalsIgnoreCase(item.Name, itemName)
					or equalsIgnoreCase(item.name, itemName)
					or equalsIgnoreCase(item.DisplayName, itemName)
					or containsIgnoreCase(item.Name, itemName)
				)
			end)
		end)

		if ok and type(result) == "table" then
			return result
		end

		return {}
	end

	function InventoryUtil.findTradableItem(itemType, itemName)
		Logger.info("Searching inventory:", itemType, itemName)

		local items = trySharedFindItemsWithKey(itemType, itemName)

		if #items == 0 then
			items = tryClientFindItems(itemType, itemName)
		end

		Logger.info("Inventory matches:", #items)

		for _, item in ipairs(items) do
			if type(item) == "table" and not item.TradeLock then
				Logger.info("Selected item:", item.Name or item.name or item.DisplayName or "?")
				return item
			end
		end

		return nil
	end

	return InventoryUtil
end
