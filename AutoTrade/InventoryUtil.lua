-- AutoTrade/InventoryUtil.lua

return function(ctx)
	local InventoryUtil = {}

	local Players = ctx.Services.Players
	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local HttpService = ctx.Services.HttpService
	local Logger = ctx.Modules.Logger

	local LocalPlayer = Players.LocalPlayer

	local InventoryClient = nil
	local InventoryShared = nil

	pcall(function()
		InventoryClient = require(ReplicatedStorage.Shared.Inventory.Client)
	end)

	pcall(function()
		InventoryShared = require(ReplicatedStorage.Shared.Inventory.Shared)
	end)

	local function clean(text)
		text = tostring(text or "")
		text = text:gsub("^%s+", ""):gsub("%s+$", "")
		return text
	end

	local function lower(text)
		return clean(text):lower()
	end

	local function makeNameKey(itemName)
		-- This matches the known Blade Ball item key format:
		-- [["Name","Dune Cleaver"]]
		return HttpService:JSONEncode({
			{ "Name", itemName }
		})
	end

	local function callFindItemsWithKey(module, player, itemType, itemKey)
		if not module then
			return {}
		end

		local attempts = {
			function()
				return module:FindItemsWithKey(player, itemType, itemKey)
			end,

			function()
				return module.FindItemsWithKey(player, itemType, itemKey)
			end,
		}

		for _, fn in ipairs(attempts) do
			local ok, result = pcall(fn)

			if ok and type(result) == "table" then
				return result
			end
		end

		return {}
	end

	local function callFindItems(module, player, itemType, itemName)
		if not module then
			return {}
		end

		local function predicate(item)
			if type(item) ~= "table" then
				return false
			end

			local name =
				item.Name
				or item.name
				or item.DisplayName
				or item.displayName

			if not name then
				return false
			end

			name = lower(name)
			local wanted = lower(itemName)

			return name == wanted or name:find(wanted, 1, true) ~= nil
		end

		local attempts = {
			function()
				return module:FindItems(player, itemType, predicate)
			end,

			function()
				return module.FindItems(player, itemType, predicate)
			end,
		}

		for _, fn in ipairs(attempts) do
			local ok, result = pcall(fn)

			if ok and type(result) == "table" then
				return result
			end
		end

		return {}
	end

	local function isTradable(item)
		if type(item) ~= "table" then
			return false
		end

		if item.TradeLock == true then
			return false
		end

		if item.tradeLock == true then
			return false
		end

		return true
	end

	local function firstTradable(items)
		for _, item in ipairs(items) do
			if isTradable(item) then
				return item
			end
		end

		return nil
	end

	local function debugListInventory(itemType)
		Logger.warn("Could not find item. Printing small inventory debug list...")

		local inventory = nil

		if InventoryClient then
			pcall(function()
				inventory = InventoryClient:Get(LocalPlayer)
			end)
		end

		if not inventory and InventoryShared then
			pcall(function()
				inventory = InventoryShared:Get(LocalPlayer)
			end)
		end

		if type(inventory) ~= "table" then
			Logger.warn("Could not read inventory table.")
			return
		end

		local bucket = inventory[itemType]

		if type(bucket) ~= "table" then
			Logger.warn("Inventory has no bucket for itemType:", itemType)
			return
		end

		local count = 0

		for id, item in pairs(bucket) do
			count += 1

			if count <= 25 then
				local name =
					type(item) == "table"
					and (item.Name or item.name or item.DisplayName or item.displayName)
					or "?"

				Logger.warn("Inventory item:", tostring(id), tostring(name))
			end
		end

		Logger.warn("Total items in bucket", itemType, "=", count)
	end

	function InventoryUtil.findTradableItem(itemType, itemName)
		itemType = clean(itemType)
		itemName = clean(itemName)

		Logger.info("Searching inventory:", itemType, itemName)

		if itemName == "" then
			Logger.warn("Empty itemName.")
			return nil
		end

		local itemKey = makeNameKey(itemName)
		Logger.info("Item key:", itemKey)

		-- Best path: use FindItemsWithKey, same style as the actual trade UI.
		local matches = {}

		for _, module in ipairs({ InventoryShared, InventoryClient }) do
			local result = callFindItemsWithKey(module, LocalPlayer, itemType, itemKey)

			for _, item in ipairs(result) do
				table.insert(matches, item)
			end
		end

		Logger.info("FindItemsWithKey matches:", #matches)

		local selected = firstTradable(matches)

		if selected then
			Logger.info("Selected item from FindItemsWithKey:", selected.Name or selected.name or selected.DisplayName or "?")
			return selected
		end

		-- Fallback: try FindItems predicate search.
		local fallbackMatches = {}

		for _, module in ipairs({ InventoryShared, InventoryClient }) do
			local result = callFindItems(module, LocalPlayer, itemType, itemName)

			for _, item in ipairs(result) do
				table.insert(fallbackMatches, item)
			end
		end

		Logger.info("FindItems fallback matches:", #fallbackMatches)

		selected = firstTradable(fallbackMatches)

		if selected then
			Logger.info("Selected item from fallback:", selected.Name or selected.name or selected.DisplayName or "?")
			return selected
		end

		debugListInventory(itemType)

		return nil
	end

	return InventoryUtil
end
