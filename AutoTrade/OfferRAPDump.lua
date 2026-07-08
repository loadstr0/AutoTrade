-- AutoTrade/OfferRAPDump.lua
-- Run in Blade Ball / Trading Plaza to create autosupply_rap_cache.json for Python offer_budget_check.py.
-- If autosupply_offer_names.json exists, only those names are dumped and recent sales are loaded.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Replion = require(ReplicatedStorage.Packages.Replion)
local Inventory = require(ReplicatedStorage.Shared.Inventory).Client

local OUTPUT_FILE = "autosupply_rap_cache.json"
local WANTED_FILE = "autosupply_offer_names.json"
local DAYS_BACK = 5
local MAX_RETRIES = 3
local RETRY_DELAY = 0.75
local INCLUDE_HISTORY_FOR_WANTED = false -- direct RequestRAPHistory is intentionally not used
local ITEM_TYPES = { "Sword", "Explosion", "Emote", "Ability" }

local function normalize(s)
	return tostring(s or ""):lower():gsub("[^a-z0-9]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function readWanted()
	if not isfile or not isfile(WANTED_FILE) then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(readfile(WANTED_FILE))
	end)
	if not ok or type(decoded) ~= "table" then
		return nil
	end
	local list = decoded.Items or decoded
	if type(list) ~= "table" then
		return nil
	end
	local wanted = {}
	for _, row in ipairs(list) do
		if type(row) == "table" then
			local itemType = row.ItemType or row.Type or "Sword"
			local name = row.ItemName or row.Name
			if name then
				wanted[normalize(itemType) .. "|" .. normalize(name)] = true
			end
		end
	end
	return wanted
end

local function getHistory(itemType, itemKey)
	-- Disabled on purpose. Direct RequestRAPHistory was confirmed delayed-kick prone.
	-- Use SupplyRAP/RAPChartController in live supply, or provide sales overrides from Python cache.
	return nil
end

local client = Replion.Client or Replion
local rapReplion = client:WaitReplion("ItemRAP")
local wanted = readWanted()
local items = {}
local seen = {}

print("[OfferRAPDump] Starting. Wanted filter:", wanted and "yes" or "no")

for _, itemType in ipairs(ITEM_TYPES) do
	local rapItems = rapReplion:Get({ "Items", itemType }) or {}
	for key, rap in pairs(rapItems) do
		local item = nil
		pcall(function()
			item = Inventory:KeyToItem(key)
		end)
		local name = item and item.Name
		if name then
			local wantedKey = normalize(itemType) .. "|" .. normalize(name)
			if not wanted or wanted[wantedKey] then
				local id = itemType .. "|" .. tostring(key)
				if not seen[id] then
					seen[id] = true
					local stats = nil
					if wanted and INCLUDE_HISTORY_FOR_WANTED then
						stats = getHistory(itemType, key)
					end
					table.insert(items, {
						ItemType = itemType,
						ItemName = name,
						ItemKey = tostring(key),
						RAP = tonumber(rap) or 0,
						AvgSalesPerDay = stats and stats.AvgSalesPerDay or 0,
						TotalSales = stats and stats.TotalSales or 0,
						DaysBack = stats and stats.DaysBack or DAYS_BACK,
						HistoryLoaded = stats ~= nil,
					})
					if #items % 25 == 0 then
						print("[OfferRAPDump] Dumped", #items, "items...")
					end
				end
			end
		end
	end
end

table.sort(items, function(a, b)
	if a.ItemType == b.ItemType then
		return a.ItemName < b.ItemName
	end
	return a.ItemType < b.ItemType
end)

local out = {
	GeneratedAt = DateTime.now().UnixTimestamp,
	WantedOnly = wanted ~= nil,
	Items = items,
}

local encoded = HttpService:JSONEncode(out)
if writefile then
	writefile(OUTPUT_FILE, encoded)
	print("[OfferRAPDump] Saved", OUTPUT_FILE, "items", #items)
else
	print(encoded)
end
