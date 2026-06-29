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

	local function findUuidsWithKey(itemType, itemName)
		local uuids = {}

		if not InventoryClient or type(InventoryClient.FindItemsWithKey) ~= "function" then
			return uuids
		end

		local itemKey = makeNameKey(itemName)

		Logger.info("Item key:", itemKey)

		-- IMPORTANT:
		-- In your diagnostic, this one worked:
		-- InventoryClient.FindItemsWithKey(LocalPlayer, "Sword", key)
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

		return uuids
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

		return uuids
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

	function InventoryUtil.findTradableItem(itemType, itemName)
		itemType = clean(itemType)
		itemName = clean(itemName)

		Logger.info("Searching inventory:", itemType, itemName)

		if itemType == "" or itemName == "" then
			Logger.warn("Missing itemType/itemName.")
			return nil
		end

		local uuids = findUuidsWithKey(itemType, itemName)

		Logger.info("FindItemsWithKey UUID matches:", #uuids)

		if #uuids == 0 then
			uuids = findUuidsFallback(itemType, itemName)
			Logger.info("Fallback UUID matches:", #uuids)
		end

		for _, uuid in ipairs(uuids) do
			local rawItem = getInventoryItem(itemType, uuid)

			if isTradable(rawItem) then
				Logger.info("Selected inventory UUID:", uuid)

				return {
					UUID = uuid,
					ItemType = itemType,
					ItemName = itemName,
					RawItem = rawItem,
				}
			else
				Logger.warn("Skipping locked/untradable UUID:", uuid)
			end
		end

		debugInventory(itemType)

		return nil
	end

	return InventoryUtil
end
