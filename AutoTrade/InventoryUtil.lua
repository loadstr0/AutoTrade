-- AutoTrade/InventoryUtil.lua

return function(ctx)
	local InventoryUtil = {}

	local Players = ctx.Services.Players
	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local HttpService = ctx.Services.HttpService
	local Logger = ctx.Modules.Logger

	local LocalPlayer = Players.LocalPlayer

	local InventoryClient = nil

	pcall(function()
		InventoryClient = require(ReplicatedStorage.Shared.Inventory.Client)
	end)

	local function clean(text)
		text = tostring(text or "")
		text = text:gsub("^%s+", ""):gsub("%s+$", "")
		return text
	end

	local function makeNameKey(itemName)
		return HttpService:JSONEncode({
			{ "Name", itemName }
		})
	end

	local function call(label, fn)
		local ok, result = pcall(fn)

		if ok then
			return true, result
		end

		Logger.warn(label, "failed:", result)
		return false, nil
	end

	local function getInventory()
		if not InventoryClient then
			return nil
		end

		local attempts = {
			function()
				return InventoryClient.GetInventory(LocalPlayer)
			end,

			function()
				return InventoryClient.Get(LocalPlayer)
			end,

			function()
				return InventoryClient:GetInventory(LocalPlayer)
			end,
		}

		for _, fn in ipairs(attempts) do
			local ok, result = pcall(fn)

			if ok and type(result) == "table" then
				return result
			end
		end

		return nil
	end

	local function getInventoryItem(itemType, uuid)
		local inventory = getInventory()

		if type(inventory) ~= "table" then
			return nil
		end

		local bucket = inventory[itemType]

		if type(bucket) ~= "table" then
			return nil
		end

		return bucket[uuid]
	end

	local function isTradable(rawItem)
		if type(rawItem) ~= "table" then
			return true
		end

		if rawItem.TradeLock == true then
			return false
		end

		if rawItem.tradeLock == true then
			return false
		end

		if rawItem.Locked == true then
			return false
		end

		if rawItem.locked == true then
			return false
		end

		return true
	end

	local function collectUuidsFromResult(result, out)
		if type(result) ~= "table" then
			return
		end

		for _, value in pairs(result) do
			if type(value) == "string" then
				table.insert(out, value)
			elseif type(value) == "table" then
				local uuid =
					value.UUID
					or value.uuid
					or value.Id
					or value.id
					or value.ItemId
					or value.itemId

				if uuid then
					table.insert(out, tostring(uuid))
				end
			end
		end
	end

	local function dedupe(list)
		local seen = {}
		local out = {}

		for _, value in ipairs(list) do
			value = tostring(value)

			if not seen[value] then
				seen[value] = true
				table.insert(out, value)
			end
		end

		return out
	end

	local function findUuidsWithKey(itemType, itemName)
		local uuids = {}

		if not InventoryClient or type(InventoryClient.FindItemsWithKey) ~= "function" then
			return uuids
		end

		local itemKey = makeNameKey(itemName)

		Logger.info("Item key:", itemKey)

		local attempts = {
			{
				name = "dot player/type/key",
				fn = function()
					return InventoryClient.FindItemsWithKey(LocalPlayer, itemType, itemKey)
				end,
			},

			{
				name = "colon player/type/key",
				fn = function()
					return InventoryClient:FindItemsWithKey(LocalPlayer, itemType, itemKey)
				end,
			},
		}

		for _, attempt in ipairs(attempts) do
			local ok, result = call("FindItemsWithKey " .. attempt.name, attempt.fn)

			if ok then
				collectUuidsFromResult(result, uuids)
			end
		end

		return dedupe(uuids)
	end

	local function findUuidsFallback(itemType, itemName)
		local uuids = {}
		local inventory = getInventory()

		if type(inventory) ~= "table" then
			Logger.warn("Could not read inventory table.")
			return uuids
		end

		local bucket = inventory[itemType]

		if type(bucket) ~= "table" then
			Logger.warn("Inventory has no bucket:", itemType)
			return uuids
		end

		local wanted = clean(itemName):lower()

		for uuid, rawItem in pairs(bucket) do
			local matched = false

			if type(rawItem) == "table" then
				local name =
					rawItem.Name
					or rawItem.name
					or rawItem.DisplayName
					or rawItem.displayName

				if name and tostring(name):lower() == wanted then
					matched = true
				end

				if not matched and InventoryClient and type(InventoryClient.ItemToString) == "function" then
					local ok, itemString = pcall(function()
						return InventoryClient.ItemToString(rawItem)
					end)

					if ok and tostring(itemString):lower():find(wanted, 1, true) then
						matched = true
					end
				end
			end

			if matched then
				table.insert(uuids, tostring(uuid))
			end
		end

		return dedupe(uuids)
	end

	local function debugInventory(itemType)
		local inventory = getInventory()

		if type(inventory) ~= "table" then
			Logger.warn("Could not read inventory table.")
			return
		end

		local bucket = inventory[itemType]

		if type(bucket) ~= "table" then
			Logger.warn("Inventory has no bucket:", itemType)
			return
		end

		local count = 0

		for uuid, rawItem in pairs(bucket) do
			count += 1

			if count <= 25 then
				local extra = ""

				if type(rawItem) == "table" then
					extra = tostring(rawItem.Name or rawItem.DisplayName or rawItem.name or rawItem.displayName or "")
				end

				Logger.warn("Inventory item:", tostring(uuid), extra)
			end
		end

		Logger.warn("Total inventory items in", itemType, "=", count)
	end

	local function selectTradableItems(itemType, itemName, quantity, excluded)
		quantity = math.max(1, tonumber(quantity or 1) or 1)
		excluded = excluded or {}

		local uuids = findUuidsWithKey(itemType, itemName)

		Logger.info("FindItemsWithKey UUID matches:", #uuids)

		if #uuids == 0 then
			uuids = findUuidsFallback(itemType, itemName)
			Logger.info("Fallback UUID matches:", #uuids)
		end

		local selected = {}

		for _, uuid in ipairs(uuids) do
			if not excluded[uuid] then
				local rawItem = getInventoryItem(itemType, uuid)

				if isTradable(rawItem) then
					Logger.info("Selected inventory UUID:", uuid)

					table.insert(selected, {
						UUID = uuid,
						ItemType = itemType,
						ItemName = itemName,
						RawItem = rawItem,
					})

					excluded[uuid] = true

					if #selected >= quantity then
						return selected
					end
				else
					Logger.warn("Skipping locked/untradable UUID:", uuid)
				end
			end
		end

		return selected
	end

	function InventoryUtil.findTradableItems(itemType, itemName, quantity, excluded)
		itemType = clean(itemType)
		itemName = clean(itemName)
		quantity = math.max(1, tonumber(quantity or 1) or 1)

		Logger.info("Searching inventory:", itemType, itemName, "quantity", quantity)

		if itemType == "" or itemName == "" then
			Logger.warn("Missing itemType/itemName.")
			return nil, "missing_item_type_or_name"
		end

		local selected = selectTradableItems(itemType, itemName, quantity, excluded)

		if #selected >= quantity then
			return selected
		end

		Logger.warn("Not enough tradable copies:", itemType, itemName, "needed", quantity, "found", #selected)
		debugInventory(itemType)

		return nil, "not_enough_tradable_copies", selected
	end

	function InventoryUtil.findTradableItem(itemType, itemName)
		local items = InventoryUtil.findTradableItems(itemType, itemName, 1)

		if type(items) == "table" and items[1] then
			return items[1]
		end

		return nil
	end

	return InventoryUtil
end
