-- AutoTrade/OfferRAPDump.lua
-- Run in Blade Ball / Trading Plaza to create autosupply_rap_cache.json for Python offer_budget_check.py.
-- If autosupply_offer_names.json exists, only those names are dumped and recent sales are loaded.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Net = require(ReplicatedStorage.Packages.Net)
local Replion = require(ReplicatedStorage.Packages.Replion)
local Inventory = require(ReplicatedStorage.Shared.Inventory).Client
local RequestRAPHistory = Net:RemoteFunction("RequestRAPHistory")

local OUTPUT_FILE = "autosupply_rap_cache.json"
local WANTED_FILE = "autosupply_offer_names.json"
local DAYS_BACK = 5
local MAX_RETRIES = 3
local RETRY_DELAY = 0.75
local INCLUDE_HISTORY_FOR_WANTED = true
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

local function dayTimestamp(dt)
	local u = dt:ToUniversalTime()
	return DateTime.fromUniversalTime(u.Year, u.Month, u.Day).UnixTimestamp
end

local function getHistory(itemType, itemKey)
	local nowDt = DateTime.now()
	local startDt = DateTime.fromUnixTimestamp(nowDt.UnixTimestamp - DAYS_BACK * 86400)
	for attempt = 1, MAX_RETRIES do
		local ok, success, history = pcall(function()
			local s, h = RequestRAPHistory:InvokeServer(itemType, itemKey, startDt, nowDt)
			return s, h
		end)
		if ok and success and type(history) == "table" then
			local grouped = {}
			local totalSales, rapTotal, rapPoints = 0, 0, 0
			for _, row in ipairs(history) do
				if type(row) == "table" and row.Date and row.RAP ~= nil and row.Count ~= nil then
					local ts = row.Date.UnixTimestamp
					if ts >= startDt.UnixTimestamp and ts <= nowDt.UnixTimestamp then
						local day = dayTimestamp(row.Date)
						grouped[day] = grouped[day] or { totalRap = 0, points = 0, totalSales = 0 }
						grouped[day].totalRap += tonumber(row.RAP) or 0
						grouped[day].points += 1
						grouped[day].totalSales += tonumber(row.Count) or 0
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
				Days = days,
				DaysBack = DAYS_BACK,
				TotalSales = totalSales,
				AvgSalesPerDay = totalSales / math.max(DAYS_BACK, 1),
				AvgRAP = rapPoints > 0 and math.round(rapTotal / rapPoints) or nil,
			}
		end
		if attempt < MAX_RETRIES then
			task.wait(RETRY_DELAY * attempt)
		end
	end
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
