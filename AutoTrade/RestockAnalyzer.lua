-- AutoTrade/RestockAnalyzer.lua
-- Module version of RestockRAPAnalyzer_v6 for automated RestockWatcher use.

return function(ctx)
	local RestockAnalyzer = {}

-- RestockAnalyzer.lua
--
-- Input:
--   autotrade_offers_all.json
--
-- Output:
--   autotrade_restock_report.json
--   autotrade_restock_debug_log.txt
--
-- Main behavior:
--   - Reads all Eldorado offers from the Python scraper.
--   - Resolves Eldorado names against ItemInfo.
--   - Uses RAPChartController safe path.
--   - Parses RAP strings with commas, e.g. "12,218".
--   - Prioritizes smaller spin offers before high spin offers.
--   - Outputs pythonAction fields for apply_restock_plan.py.
--
-- No direct RequestRAPHistory.
-- No direct GetItemListings.

local CONFIG = {
	InputFile = "autotrade_offers_all.json",
	OutputFile = "autotrade_restock_report.json",
	LogFile = "autotrade_restock_debug_log.txt",

	CurrentTokens = 23916,
	TokenRatePerKUsd = 3.78672,
	SellerFeePercent = 5,

	TokenReserve = 1000,

	PrioritizeLowSpinOffers = true,
	SmallSpinMax = 100,
	SmallSpinCoverageFirst = true,
	FillSmallSpinsBeforeItems = true,
	LargeSpinsAfterItems = true,
	AllowPartialQuantity = true,

	RapCostMultiplier = 1.10,
	MinProfitUsdPerUnit = 0.50,
	MinMarginPercent = 10,

	IncludePausedOffers = true,
	IgnoreStatuses = {
		Closed = true,
		Expired = true,
	},

	RapRenderWait = 2.25,
	DelayBetweenRapChecks = 1.25,
	MaxRapChecks = 30,
	MaxOfferRows = 200,
	MaxResolverSuggestions = 8,

	SpinPacks = {
		{ spins = 250, tokens = 10785 },
		{ spins = 50, tokens = 2400 },
		{ spins = 10, tokens = 480 },
		{ spins = 1, tokens = 60 },
	},
}

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local LOG_LINES = {}
local WARN_COUNT = 0
local ERROR_COUNT = 0

local function now()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function log(level, ...)
	local parts = {}

	for i = 1, select("#", ...) do
		table.insert(parts, tostring(select(i, ...)))
	end

	local line = ("[%s] [%s] %s"):format(now(), level, table.concat(parts, " "))
	table.insert(LOG_LINES, line)

	if level == "WARN" then
		WARN_COUNT += 1
		warn("[RESTOCK_AUTO]", table.concat(parts, " "))
	elseif level == "ERROR" then
		ERROR_COUNT += 1
		warn("[RESTOCK_AUTO_ERROR]", table.concat(parts, " "))
	else
		print("[RESTOCK_AUTO]", table.concat(parts, " "))
	end
end

local function saveLog()
	if not writefile then
		return
	end

	local header = {
		"========== RESTOCK AUTO DEBUG LOG ==========",
		"saved_at=" .. now(),
		"warn_count=" .. tostring(WARN_COUNT),
		"error_count=" .. tostring(ERROR_COUNT),
		"==========================================",
		"",
	}

	pcall(function()
		writefile(CONFIG.LogFile, table.concat(header, "\n") .. table.concat(LOG_LINES, "\n"))
	end)
end

local function writeJson(path, data)
	if not writefile then
		log("WARN", "writefile unavailable:", path)
		return
	end

	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(data)
	end)

	if not ok then
		log("ERROR", "JSON encode failed:", path, encoded)
		return
	end

	local okWrite, err = pcall(function()
		writefile(path, encoded)
	end)

	if okWrite then
		log("INFO", "wrote", path)
	else
		log("ERROR", "write failed:", path, err)
	end
end

local function readJson(path)
	if not readfile then
		return nil, "readfile_unavailable"
	end

	if isfile and not isfile(path) then
		return nil, "missing_file"
	end

	local okRead, raw = pcall(function()
		return readfile(path)
	end)

	if not okRead then
		return nil, "read_failed: " .. tostring(raw)
	end

	local okJson, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)

	if not okJson then
		return nil, "json_decode_failed: " .. tostring(decoded)
	end

	return decoded, nil
end

local function trim(s)
	s = tostring(s or "")
	s = s:gsub("^%s+", "")
	s = s:gsub("%s+$", "")
	s = s:gsub("%s+", " ")
	return s
end

local function lower(s)
	return string.lower(tostring(s or ""))
end

local function toNumber(v, fallback)
	if v == nil or v == "" then
		return fallback
	end

	if type(v) == "number" then
		return v
	end

	local s = tostring(v)
	s = s:gsub(",", "")
	s = s:gsub("%$", "")
	s = s:gsub("/unit", "")
	s = s:gsub("%s+", "")

	local n = tonumber(s)
	if n == nil then
		return fallback
	end

	return n
end

local function parseRapNumber(v)
	if v == nil then
		return nil
	end

	if type(v) == "number" then
		return v
	end

	local s = tostring(v)
	s = s:gsub(",", "")
	s = s:gsub("%s+", "")

	local suffix = string.sub(s, -1)
	local mult = 1

	if suffix == "K" or suffix == "k" then
		mult = 1000
		s = string.sub(s, 1, -2)
	elseif suffix == "M" or suffix == "m" then
		mult = 1000000
		s = string.sub(s, 1, -2)
	elseif suffix == "B" or suffix == "b" then
		mult = 1000000000
		s = string.sub(s, 1, -2)
	end

	local n = tonumber(s)
	if not n then
		return nil
	end

	return n * mult
end

local function round(n, places)
	if n == nil then
		return nil
	end

	local mult = 10 ^ (places or 2)
	return math.floor(n * mult + 0.5) / mult
end

local function safeCategories(offer)
	if type(offer.categories) == "table" then
		return offer.categories
	end

	return {}
end

local function hasCategory(offer, wanted)
	wanted = lower(wanted)

	for _, c in ipairs(safeCategories(offer)) do
		if lower(c) == wanted then
			return true
		end
	end

	return false
end

local function getOfferKind(offer)
	if hasCategory(offer, "Spins") then
		return "spin", nil
	end

	if hasCategory(offer, "Swords") or hasCategory(offer, "Sword") then
		return "item", "Sword"
	end

	if hasCategory(offer, "Explosions") or hasCategory(offer, "Explosion") then
		return "item", "Explosion"
	end

	if hasCategory(offer, "Emotes") or hasCategory(offer, "Emote") then
		return "item", "Emote"
	end

	local name = lower((offer.name or "") .. " " .. (offer.title or ""))

	if name:find("spin", 1, true) then
		return "spin", nil
	end

	if name:find("emote", 1, true) then
		return "item", "Emote"
	end

	if name:find("explosion", 1, true) then
		return "item", "Explosion"
	end

	if name:find("sword", 1, true) or name:find("blade", 1, true) or name:find("katana", 1, true) then
		return "item", "Sword"
	end

	return "unknown", nil
end

local function shouldIgnoreOffer(offer)
	local status = tostring(offer.status or "")

	if CONFIG.IgnoreStatuses[status] then
		return true, "ignored_status_" .. status
	end

	if not CONFIG.IncludePausedOffers then
		local s = lower(status)
		if s == "paused" or s == "offline" then
			return true, "paused_or_offline"
		end
	end

	return false, nil
end

local function usdCost(tokens, ratePerK)
	return (tonumber(tokens) or 0) / 1000 * (tonumber(ratePerK) or 0)
end

local function netUsd(priceUsd)
	priceUsd = tonumber(priceUsd)
	if not priceUsd then
		return nil
	end

	return priceUsd * (1 - (CONFIG.SellerFeePercent / 100))
end

local function parseSpinCount(offer)
	local s = lower((offer.name or "") .. " " .. (offer.title or ""))

	local n = s:match("(%d+)%s*x")
	if n then
		return tonumber(n)
	end

	n = s:match("(%d+)%s*spin")
	if n then
		return tonumber(n)
	end

	n = s:match("(%d+)")
	if n then
		return tonumber(n)
	end

	return nil
end

local function cheapestSpinTokenCost(spins)
	spins = tonumber(spins) or 0

	if spins <= 0 then
		return nil, { error = "invalid_spin_count", spins = spins }
	end

	local max = spins + 250
	local inf = 10 ^ 12
	local dp = {}
	local prev = {}

	for i = 0, max do
		dp[i] = inf
	end

	dp[0] = 0

	for i = 1, max do
		for _, pack in ipairs(CONFIG.SpinPacks) do
			if i - pack.spins >= 0 then
				local cand = dp[i - pack.spins] + pack.tokens
				if cand < dp[i] then
					dp[i] = cand
					prev[i] = pack
				end
			end
		end
	end

	local bestSpins = nil
	local bestCost = inf

	for i = spins, max do
		if dp[i] < bestCost then
			bestCost = dp[i]
			bestSpins = i
		end
	end

	if bestCost == inf then
		return nil, { error = "spin_pack_optimizer_failed", spins = spins }
	end

	local packs = {}
	local cur = bestSpins

	while cur and cur > 0 and prev[cur] do
		local p = prev[cur]
		packs[tostring(p.spins)] = (packs[tostring(p.spins)] or 0) + 1
		cur -= p.spins
	end

	return bestCost, {
		requestedSpins = spins,
		purchasedSpins = bestSpins,
		packs = packs,
	}
end

local ItemInfo = nil
local InventoryClient = nil
local RAPChartController = nil

local function loadGameModules()
	local okItem, itemModule = pcall(function()
		return require(ReplicatedStorage.Shared.ItemInfo)
	end)

	if okItem then
		ItemInfo = itemModule
		log("INFO", "loaded ItemInfo")
	else
		log("ERROR", "failed loading ItemInfo:", itemModule)
	end

	local okInv, inv = pcall(function()
		return require(ReplicatedStorage.Shared.Inventory).Client
	end)

	if okInv then
		InventoryClient = inv
		log("INFO", "loaded Inventory.Client")
	else
		log("ERROR", "failed loading Inventory.Client:", inv)
	end

	local okRap, rap = pcall(function()
		return require(ReplicatedStorage.Controllers.Trading.RAPChartController)
	end)

	if okRap then
		RAPChartController = rap
		log("INFO", "loaded RAPChartController")
	else
		log("ERROR", "failed loading RAPChartController:", rap)
	end
end

local function normalizeNameStrict(s)
	s = tostring(s or "")
	s = s:gsub("%|%s*Blade%s*Ball.*$", " ")
	s = s:gsub("Blade%s*Ball", " ")
	s = s:gsub("Fast%s*Delivery", " ")
	s = s:gsub("Guaranteed.*$", " ")
	s = s:gsub("Instant.*$", " ")
	s = s:gsub("Roblox", " ")
	s = s:gsub("[%[%]%(%)|•·%-_]+", " ")
	s = s:gsub("%s+", " ")
	s = trim(s)
	return lower(s)
end

local function normalizeNameLoose(s, itemType)
	s = normalizeNameStrict(s)

	local removeWords = {
		"limited",
		"unique",
		"legendary",
		"rare",
		"common",
		"mythic",
		"exclusive",
	}

	if itemType == "Sword" then
		table.insert(removeWords, "sword")
	elseif itemType == "Explosion" then
		table.insert(removeWords, "explosion")
	elseif itemType == "Emote" then
		table.insert(removeWords, "emote")
	end

	for _, word in ipairs(removeWords) do
		s = s:gsub("%f[%w]" .. word .. "%f[%W]", " ")
	end

	s = s:gsub("%s+", " ")
	s = trim(s)

	return s
end

local function titleCandidates(offer)
	local out = {}

	local function add(v)
		v = tostring(v or "")
		v = v:gsub("%|%s*Blade%s*Ball.*$", " ")
		v = v:gsub("Blade%s*Ball", " ")
		v = v:gsub("Fast%s*Delivery", " ")
		v = v:gsub("Guaranteed.*$", " ")
		v = v:gsub("Instant.*$", " ")
		v = v:gsub("Roblox", " ")
		v = v:gsub("[%[%]%(%)|•·]+", " ")
		v = v:gsub("%s+", " ")
		v = trim(v)

		if v ~= "" then
			table.insert(out, v)
		end
	end

	add(offer.name)
	add(offer.title)

	for _, base in ipairs({ offer.name, offer.title }) do
		base = tostring(base or "")

		local variants = {
			base:gsub("%s+Limited%s+Sword$", ""),
			base:gsub("%s+Unique%s+Sword$", ""),
			base:gsub("%s+Legendary%s+Sword$", ""),
			base:gsub("%s+Sword%s+Limited$", ""),
			base:gsub("%s+Sword%s+Unique$", ""),
			base:gsub("%s+Sword$", ""),

			base:gsub("%s+Limited%s+Explosion$", ""),
			base:gsub("%s+Unique%s+Explosion$", ""),
			base:gsub("%s+Legendary%s+Explosion$", ""),
			base:gsub("%s+Explosion%s+Limited$", ""),
			base:gsub("%s+Explosion%s+Unique$", ""),
			base:gsub("%s+Explosion$", ""),

			base:gsub("%s+Limited%s+Emote$", ""),
			base:gsub("%s+Unique%s+Emote$", ""),
			base:gsub("%s+Legendary%s+Emote$", ""),
			base:gsub("%s+Emote%s+Limited$", ""),
			base:gsub("%s+Emote%s+Unique$", ""),
			base:gsub("%s+Emote$", ""),

			base:gsub("%s+Limited$", ""),
			base:gsub("%s+Unique$", ""),
			base:gsub("%s+Legendary$", ""),
		}

		for _, v in ipairs(variants) do
			add(v)
		end
	end

	local seen = {}
	local clean = {}

	for _, v in ipairs(out) do
		local key = lower(v)
		if not seen[key] then
			seen[key] = true
			table.insert(clean, v)
		end
	end

	return clean
end

local function getItemInfoNameAndDisplay(key, info)
	if type(info) ~= "table" then
		return tostring(key), ""
	end

	return tostring(info.Name or key), tostring(info.DisplayName or "")
end

local function collectResolverSuggestions(itemType, offer)
	local suggestions = {}

	if not ItemInfo or type(ItemInfo[itemType]) ~= "table" then
		return suggestions
	end

	local collection = ItemInfo[itemType]
	local candidates = titleCandidates(offer)
	local candidateLooseJoined = ""

	for _, c in ipairs(candidates) do
		candidateLooseJoined ..= " " .. normalizeNameLoose(c, itemType)
	end

	for key, info in pairs(collection) do
		local itemName, displayName = getItemInfoNameAndDisplay(key, info)
		local itemLoose = normalizeNameLoose(itemName, itemType)
		local displayLoose = normalizeNameLoose(displayName, itemType)
		local keyLoose = normalizeNameLoose(key, itemType)

		local score = 0

		if itemLoose ~= "" and candidateLooseJoined:find(itemLoose, 1, true) then
			score += 10 + #itemLoose
		end

		if displayLoose ~= "" and candidateLooseJoined:find(displayLoose, 1, true) then
			score += 10 + #displayLoose
		end

		if keyLoose ~= "" and candidateLooseJoined:find(keyLoose, 1, true) then
			score += 10 + #keyLoose
		end

		for word in candidateLooseJoined:gmatch("%S+") do
			if #word >= 4 and (itemLoose:find(word, 1, true) or displayLoose:find(word, 1, true) or keyLoose:find(word, 1, true)) then
				score += 2
			end
		end

		if score > 0 then
			table.insert(suggestions, {
				key = tostring(key),
				name = itemName,
				displayName = displayName,
				score = score,
			})
		end
	end

	table.sort(suggestions, function(a, b)
		return a.score > b.score
	end)

	local out = {}

	for i, s in ipairs(suggestions) do
		if i > CONFIG.MaxResolverSuggestions then
			break
		end

		table.insert(out, s)
	end

	return out
end

local function resolveGameItemName(itemType, offer)
	if not ItemInfo then
		return nil, { ok = false, reason = "iteminfo_not_loaded" }
	end

	local collection = ItemInfo[itemType]
	if type(collection) ~= "table" then
		return nil, { ok = false, reason = "missing_iteminfo_type", itemType = itemType }
	end

	local candidates = titleCandidates(offer)
	log("INFO", "resolve start:", itemType, "| title=", offer.title or "", "| candidates=", table.concat(candidates, " || "))

	for _, candidate in ipairs(candidates) do
		for key, info in pairs(collection) do
			local itemName, displayName = getItemInfoNameAndDisplay(key, info)

			if candidate == tostring(key) or candidate == itemName or candidate == displayName then
				log("INFO", "resolved exact:", itemType, candidate, "=>", itemName)
				return itemName, {
					ok = true,
					method = "exact",
					candidate = candidate,
					key = tostring(key),
					displayName = displayName,
				}
			end
		end
	end

	for _, candidate in ipairs(candidates) do
		local cStrict = normalizeNameStrict(candidate)

		for key, info in pairs(collection) do
			local itemName, displayName = getItemInfoNameAndDisplay(key, info)

			if cStrict == normalizeNameStrict(key)
				or cStrict == normalizeNameStrict(itemName)
				or (displayName ~= "" and cStrict == normalizeNameStrict(displayName))
			then
				log("INFO", "resolved strict:", itemType, candidate, "=>", itemName)
				return itemName, {
					ok = true,
					method = "strict_normalized",
					candidate = candidate,
					key = tostring(key),
					displayName = displayName,
				}
			end
		end
	end

	for _, candidate in ipairs(candidates) do
		local cLoose = normalizeNameLoose(candidate, itemType)

		for key, info in pairs(collection) do
			local itemName, displayName = getItemInfoNameAndDisplay(key, info)
			local keyLoose = normalizeNameLoose(key, itemType)
			local itemLoose = normalizeNameLoose(itemName, itemType)
			local displayLoose = normalizeNameLoose(displayName, itemType)

			if cLoose ~= "" and (
				cLoose == keyLoose
				or cLoose == itemLoose
				or (displayLoose ~= "" and cLoose == displayLoose)
			) then
				log("INFO", "resolved loose:", itemType, candidate, "=>", itemName)
				return itemName, {
					ok = true,
					method = "loose_normalized",
					candidate = candidate,
					key = tostring(key),
					displayName = displayName,
					cLoose = cLoose,
				}
			end
		end
	end

	for _, candidate in ipairs(candidates) do
		local cLoose = normalizeNameLoose(candidate, itemType)

		if #cLoose >= 4 then
			for key, info in pairs(collection) do
				local itemName, displayName = getItemInfoNameAndDisplay(key, info)
				local itemLoose = normalizeNameLoose(itemName, itemType)
				local displayLoose = normalizeNameLoose(displayName, itemType)

				if itemLoose ~= "" and #itemLoose >= 4 and (cLoose:find(itemLoose, 1, true) or itemLoose:find(cLoose, 1, true)) then
					log("INFO", "resolved contains item:", itemType, candidate, "=>", itemName)
					return itemName, {
						ok = true,
						method = "contains_item_name",
						candidate = candidate,
						key = tostring(key),
						itemLoose = itemLoose,
						cLoose = cLoose,
					}
				end

				if displayLoose ~= "" and #displayLoose >= 4 and (cLoose:find(displayLoose, 1, true) or displayLoose:find(cLoose, 1, true)) then
					log("INFO", "resolved contains display:", itemType, candidate, "=>", itemName)
					return itemName, {
						ok = true,
						method = "contains_display_name",
						candidate = candidate,
						key = tostring(key),
						displayName = displayName,
						displayLoose = displayLoose,
						cLoose = cLoose,
					}
				end
			end
		end
	end

	local suggestions = collectResolverSuggestions(itemType, offer)
	log("WARN", "resolve failed:", itemType, "|", offer.title or offer.name or "", "| suggestions:", HttpService:JSONEncode(suggestions))

	return nil, {
		ok = false,
		reason = "could_not_resolve_item_name",
		itemType = itemType,
		candidates = candidates,
		suggestions = suggestions,
	}
end

local function parsePointSortKey(inst, date)
	local fromName = tonumber(inst.Name)
	if fromName then
		return fromName
	end

	local fromDate = tonumber(date)
	if fromDate then
		return fromDate
	end

	return nil
end

local function collectRapPoints()
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local points = {}

	for _, d in ipairs(pg:GetDescendants()) do
		local rapRaw = d:GetAttribute("RAP")
		local countRaw = d:GetAttribute("Count")
		local dateRaw = d:GetAttribute("Date")

		if rapRaw ~= nil and countRaw ~= nil and dateRaw ~= nil then
			local rap = parseRapNumber(rapRaw)
			local count = parseRapNumber(countRaw)

			if rap and count then
				table.insert(points, {
					RAP = rap,
					Count = count,
					Date = tostring(dateRaw),
					SortKey = parsePointSortKey(d, dateRaw),
					RawRAP = tostring(rapRaw),
					RawCount = tostring(countRaw),
				})
			end
		end
	end

	table.sort(points, function(a, b)
		if a.SortKey and b.SortKey then
			return a.SortKey < b.SortKey
		end

		return tostring(a.Date) < tostring(b.Date)
	end)

	return points
end

local rapCache = {}
local rapChecksDone = 0

local function getRapViaChart(itemType, gameItemName)
	local cacheKey = itemType .. "::" .. gameItemName

	if rapCache[cacheKey] then
		return rapCache[cacheKey].rap, rapCache[cacheKey].info
	end

	if not InventoryClient then
		return nil, { error = "inventory_client_not_loaded" }
	end

	if not RAPChartController then
		return nil, { error = "rap_chart_controller_not_loaded" }
	end

	if rapChecksDone >= CONFIG.MaxRapChecks then
		return nil, { error = "max_rap_checks_reached", maxRapChecks = CONFIG.MaxRapChecks }
	end

	rapChecksDone += 1

	local item = { Name = gameItemName }

	log("INFO", "RAP check start:", itemType, gameItemName, "check", rapChecksDone .. "/" .. CONFIG.MaxRapChecks)

	local okKey, itemKey = pcall(function()
		return InventoryClient:ItemToKey(itemType, item)
	end)

	if not okKey or not itemKey then
		log("WARN", "ItemToKey failed:", itemType, gameItemName, tostring(itemKey))

		local info = {
			error = "item_key_failed",
			detail = tostring(itemKey),
		}

		rapCache[cacheKey] = { rap = nil, info = info }
		return nil, info
	end

	log("INFO", "ItemToKey ok:", itemType, gameItemName, "=>", itemKey)

	local okRender, renderErr = pcall(function()
		RAPChartController:Render("Index", itemType, itemKey)
	end)

	if not okRender then
		log("WARN", "RAP Render failed:", itemType, gameItemName, tostring(renderErr))

		local info = {
			error = "rap_render_failed",
			detail = tostring(renderErr),
			itemKey = itemKey,
		}

		rapCache[cacheKey] = { rap = nil, info = info }
		return nil, info
	end

	task.wait(CONFIG.RapRenderWait)

	local points = collectRapPoints()
	local latest = nil
	local totalCount = 0
	local weighted = 0

	for _, p in ipairs(points) do
		if p.RAP and p.Count and p.Count > 0 then
			latest = p.RAP
			totalCount += p.Count
			weighted += p.RAP * p.Count
		end
	end

	local avg = totalCount > 0 and (weighted / totalCount) or nil
	local rap = latest or avg

	local safePoints = {}

	for _, p in ipairs(points) do
		table.insert(safePoints, {
			RAP = p.RAP,
			Count = p.Count,
			Date = p.Date,
			RawRAP = p.RawRAP,
			RawCount = p.RawCount,
		})
	end

	local info = {
		itemKey = itemKey,
		points = safePoints,
		totalSales = totalCount,
		weightedRap = avg and round(avg, 4) or nil,
		latestRap = latest,
	}

	if rap then
		log("INFO", "RAP ok:", itemType, gameItemName, "rap=", rap, "sales=", totalCount)
	else
		log("WARN", "RAP missing/no points:", itemType, gameItemName, "points=", #points)
	end

	rapCache[cacheKey] = { rap = rap, info = info }

	task.wait(CONFIG.DelayBetweenRapChecks)

	return rap, info
end

local function buildOfferRows(snapshot)
	local rows = {}
	local offers = snapshot.offers or {}

	for idx, offer in ipairs(offers) do
		if idx > CONFIG.MaxOfferRows then
			log("WARN", "max offer rows reached; skipping remaining offers")
			break
		end

		local ignored, ignoreReason = shouldIgnoreOffer(offer)
		local kind, itemType = getOfferKind(offer)

		local quantity = math.max(0, toNumber(offer.quantity, 1) or 1)
		if quantity == 0 then
			quantity = 1
		end

		local priceUsd = toNumber(offer.price_per_unit, nil)
		local net = netUsd(priceUsd)

		local gameItemName = nil
		local resolveInfo = nil

		if itemType then
			gameItemName, resolveInfo = resolveGameItemName(itemType, offer)
		end

		if not gameItemName then
			gameItemName = tostring(offer.name or offer.title or "")
		end

		local tokensPerUnit = nil
		local tokenInfo = nil
		local rapInfo = nil
		local rap = nil
		local eligible = true
		local reason = nil
		local spinCount = nil

		log("INFO", "offer row:", idx, "| kind=", kind, "| type=", itemType or "nil", "| name=", offer.name or "", "| status=", offer.status or "", "| qty=", quantity, "| price=", tostring(priceUsd))

		if ignored then
			eligible = false
			reason = ignoreReason
		elseif kind == "spin" then
			spinCount = parseSpinCount(offer)

			if spinCount then
				tokensPerUnit, tokenInfo = cheapestSpinTokenCost(spinCount)
				reason = "spin_pack_optimizer"
				log("INFO", "spin cost:", offer.name or offer.title, "spins=", spinCount, "tokens=", tostring(tokensPerUnit))
			else
				eligible = false
				reason = "unknown_spin_count"
				log("WARN", "could not parse spin count:", offer.title or offer.name)
			end
		elseif kind == "item" and itemType then
			if not resolveInfo or not resolveInfo.ok then
				eligible = false
				reason = "could_not_resolve_item_name"
				rapInfo = resolveInfo
			else
				rap, rapInfo = getRapViaChart(itemType, gameItemName)

				if rap then
					tokensPerUnit = math.ceil(rap * CONFIG.RapCostMultiplier)
					reason = "rap_chart_safe_path"
				else
					eligible = false
					reason = "missing_rap_or_item_key"
				end
			end
		else
			eligible = false
			reason = "unknown_offer_kind"
		end

		local unitCostUsd = tokensPerUnit and usdCost(tokensPerUnit, CONFIG.TokenRatePerKUsd) or nil
		local profitPerUnit = net and unitCostUsd and (net - unitCostUsd) or nil
		local marginPercent = profitPerUnit and net and net > 0 and (profitPerUnit / net * 100) or nil

		if eligible and kind == "item" then
			if profitPerUnit and profitPerUnit < CONFIG.MinProfitUsdPerUnit then
				eligible = false
				reason = "profit_too_low"
			elseif marginPercent and marginPercent < CONFIG.MinMarginPercent then
				eligible = false
				reason = "margin_too_low"
			end
		end

		table.insert(rows, {
			offerIndex = idx,
			offerId = offer.offer_id,
			offerUrl = offer.offer_url,
			title = offer.title,
			name = offer.name,
			gameItemName = gameItemName,
			resolveInfo = resolveInfo,
			categories = offer.categories,
			status = offer.status,
			expiration = offer.expiration,
			deliveryTime = offer.delivery_time,

			kind = kind,
			itemType = itemType,
			spinCount = spinCount,
			quantityOnPage = quantity,
			minQuantity = toNumber(offer.min_quantity, nil),

			priceUsdPerUnit = priceUsd,
			netUsdPerUnit = net and round(net, 4) or nil,

			rap = rap and round(rap, 4) or nil,
			rapInfo = rapInfo,

			tokensPerUnit = tokensPerUnit,
			tokenInfo = tokenInfo,
			tokenCostUsdPerUnit = unitCostUsd and round(unitCostUsd, 4) or nil,
			profitUsdPerUnit = profitPerUnit and round(profitPerUnit, 4) or nil,
			marginPercent = marginPercent and round(marginPercent, 2) or nil,

			eligible = eligible,
			disableReason = eligible and nil or reason,

			recommendedQuantity = 0,
			recommendedEnabled = false,
			allocatedTokens = 0,

			desiredStatus = nil,
			desiredQuantity = nil,
			pythonAction = nil,
			pythonActionReason = nil,
			canPythonApply = false,

			priority = kind == "spin" and 1 or (kind == "item" and 2 or 3),
		})
	end

	return rows
end

local function rowEfficiency(row)
	local profit = row.profitUsdPerUnit or -999999
	local tokens = math.max(1, row.tokensPerUnit or 1)
	return profit / tokens
end

local function isSmallSpin(row)
	return row.kind == "spin" and (tonumber(row.spinCount) or 999999) <= CONFIG.SmallSpinMax
end

local function isLargeSpin(row)
	return row.kind == "spin" and not isSmallSpin(row)
end

local function markAllocationGroup(row)
	if isSmallSpin(row) then
		row.allocationGroup = "small_spin"
	elseif row.kind == "item" then
		row.allocationGroup = "item"
	elseif isLargeSpin(row) then
		row.allocationGroup = "large_spin"
	else
		row.allocationGroup = "other"
	end
end

local function sortSmallSpins(a, b)
	local aSpin = a.spinCount or 999999
	local bSpin = b.spinCount or 999999

	if aSpin ~= bSpin then
		return aSpin < bSpin
	end

	return (a.tokensPerUnit or 999999) < (b.tokensPerUnit or 999999)
end

local function sortItems(a, b)
	local aEff = rowEfficiency(a)
	local bEff = rowEfficiency(b)

	if aEff ~= bEff then
		return aEff > bEff
	end

	return (a.profitUsdPerUnit or -999999) > (b.profitUsdPerUnit or -999999)
end

local function allocList(rows, remaining, totals, phaseName, maxUnitsPerRow)
	for _, row in ipairs(rows) do
		if row.eligible and row.tokensPerUnit and row.tokensPerUnit > 0 then
			local already = row.recommendedQuantity or 0
			local maxQty = math.max(0, (row.quantityOnPage or 1) - already)

			if maxUnitsPerRow then
				maxQty = math.min(maxQty, maxUnitsPerRow)
			end

			local qty = math.min(maxQty, math.floor(remaining / row.tokensPerUnit))

			if qty > 0 then
				row.recommendedQuantity = already + qty
				row.recommendedEnabled = true
				row.allocatedTokens = (row.allocatedTokens or 0) + (qty * row.tokensPerUnit)
				row.allocationPhase = row.allocationPhase or phaseName
				remaining -= qty * row.tokensPerUnit

				if row.kind == "spin" then
					totals.spinReservedTokens += qty * row.tokensPerUnit
				elseif row.kind == "item" then
					totals.itemReservedTokens += qty * row.tokensPerUnit
				end

				log("INFO", "ALLOC ENABLE:", phaseName, "x" .. qty, row.kind, row.gameItemName or row.name, "tokens/unit=", row.tokensPerUnit, "allocated=", row.allocatedTokens, "remaining=", remaining)
			end
		end
	end

	return remaining
end

local function finalizePausedRows(rows, remaining)
	for _, row in ipairs(rows) do
		markAllocationGroup(row)

		if row.recommendedEnabled then
			-- already enabled
		elseif row.eligible and row.tokensPerUnit and row.tokensPerUnit > 0 then
			if row.kind == "item" then
				row.disableReason = "paused_to_keep_spins_priority_or_budget"
			elseif isSmallSpin(row) then
				row.disableReason = "not_enough_budget_for_small_spin"
			elseif row.kind == "spin" then
				row.disableReason = "large_spin_lower_priority_or_budget"
			else
				row.disableReason = "not_enough_budget"
			end

			log("INFO", "ALLOC PAUSE:", row.allocationGroup, row.kind, row.gameItemName or row.name, "reason=", row.disableReason, "tokens/unit=", tostring(row.tokensPerUnit), "remaining=", remaining)
		else
			log("INFO", "ALLOC SKIP:", row.kind, row.gameItemName or row.name, "eligible=", tostring(row.eligible), "reason=", tostring(row.disableReason))
		end
	end
end

local function allocateBudget(rows, currentTokens)
	local available = math.max(0, currentTokens - CONFIG.TokenReserve)

	local totals = {
		currentTokens = currentTokens,
		tokenRatePerKUsd = CONFIG.TokenRatePerKUsd,
		tokenReserve = CONFIG.TokenReserve,
		availableBudgetTokens = available,
		spinReservedTokens = 0,
		itemReservedTokens = 0,
		totalReservedTokens = 0,
		totalNetRevenueUsd = 0,
		totalTokenCostUsd = 0,
		totalProfitUsd = 0,
		remainingTokensAfterPlan = available,
		warnCount = WARN_COUNT,
		errorCount = ERROR_COUNT,
		allocationStrategy = "small_spin_coverage_then_extra_small_spins_then_items_then_large_spins",
	}

	local smallSpins = {}
	local items = {}
	local largeSpins = {}
	local others = {}

	for _, row in ipairs(rows) do
		markAllocationGroup(row)
		row.recommendedQuantity = 0
		row.recommendedEnabled = false
		row.allocatedTokens = 0
		row.allocationPhase = nil

		if isSmallSpin(row) then
			table.insert(smallSpins, row)
		elseif row.kind == "item" then
			table.insert(items, row)
		elseif isLargeSpin(row) then
			table.insert(largeSpins, row)
		else
			table.insert(others, row)
		end
	end

	table.sort(smallSpins, sortSmallSpins)
	table.sort(items, sortItems)
	table.sort(largeSpins, sortSmallSpins)

	local remaining = available

	log("INFO", "allocation start: currentTokens=", currentTokens, "reserve=", CONFIG.TokenReserve, "available=", available)

	-- Pass 1: make sure every important small spin size gets at least one unit before filling all quantities.
	if CONFIG.SmallSpinCoverageFirst then
		remaining = allocList(smallSpins, remaining, totals, "small_spin_coverage", 1)
	end

	-- Pass 2: fill extra 10x/50x/100x quantities.
	if CONFIG.FillSmallSpinsBeforeItems then
		remaining = allocList(smallSpins, remaining, totals, "small_spin_extra", nil)
	end

	-- Pass 3: items/swords/emotes/explosions by profit efficiency.
	remaining = allocList(items, remaining, totals, "items_after_small_spins", nil)

	-- Pass 4: big spin offers only after small spins + good items.
	if CONFIG.LargeSpinsAfterItems then
		remaining = allocList(largeSpins, remaining, totals, "large_spins_after_items", nil)
	else
		remaining = allocList(largeSpins, remaining, totals, "large_spins", nil)
	end

	-- Unknown/other only if they ever become eligible.
	remaining = allocList(others, remaining, totals, "other", nil)

	finalizePausedRows(rows, remaining)

	-- Keep report rows in the same order the allocator thinks about them.
	table.sort(rows, function(a, b)
		local groupOrder = {
			small_spin = 1,
			item = 2,
			large_spin = 3,
			other = 4,
		}

		local ag = groupOrder[a.allocationGroup or "other"] or 9
		local bg = groupOrder[b.allocationGroup or "other"] or 9

		if ag ~= bg then
			return ag < bg
		end

		if a.allocationGroup == "small_spin" or a.allocationGroup == "large_spin" then
			return sortSmallSpins(a, b)
		end

		if a.allocationGroup == "item" then
			return sortItems(a, b)
		end

		return (a.offerIndex or 999999) < (b.offerIndex or 999999)
	end)

	for _, row in ipairs(rows) do
		if row.recommendedEnabled then
			totals.totalReservedTokens += row.allocatedTokens
			totals.totalNetRevenueUsd += (row.netUsdPerUnit or 0) * row.recommendedQuantity
			totals.totalTokenCostUsd += usdCost(row.allocatedTokens, CONFIG.TokenRatePerKUsd)
		end
	end

	totals.remainingTokensAfterPlan = remaining
	totals.totalNetRevenueUsd = round(totals.totalNetRevenueUsd, 4)
	totals.totalTokenCostUsd = round(totals.totalTokenCostUsd, 4)
	totals.totalProfitUsd = round(totals.totalNetRevenueUsd - totals.totalTokenCostUsd, 4)
	totals.warnCount = WARN_COUNT
	totals.errorCount = ERROR_COUNT

	if totals.totalReservedTokens > 0 then
		local breakEven = totals.totalNetRevenueUsd / (totals.totalReservedTokens / 1000)
		totals.breakEvenTokenRatePerKUsd = round(breakEven, 4)
		totals.maxTokenRateFor10PercentMargin = round(breakEven * 0.90, 4)
		totals.maxTokenRateFor20PercentMargin = round(breakEven * 0.80, 4)
	end

	return totals
end

local function currentStatusNormalized(row)
	local s = lower(row.status or "")

	if s == "online" or s == "active" then
		return "active"
	end

	if s == "offline" or s == "paused" or s == "inactive" then
		return "paused"
	end

	if s == "closed" or s == "expired" then
		return "closed"
	end

	return s
end

local function addPythonActions(rows)
	for _, row in ipairs(rows) do
		local currentStatus = currentStatusNormalized(row)

		row.currentStatusNormalized = currentStatus
		row.desiredQuantity = row.recommendedQuantity or 0
		row.canPythonApply = false
		row.pythonAction = "none"
		row.pythonActionReason = "no_change"

		if currentStatus == "closed" then
			row.desiredStatus = "closed"
			row.pythonAction = "skip"
			row.pythonActionReason = "closed_or_expired_offer"
			row.canPythonApply = false

		elseif row.recommendedEnabled then
			row.desiredStatus = "active"
			row.canPythonApply = true

			if currentStatus ~= "active" then
				row.pythonAction = "enable"
				row.pythonActionReason = "recommended_and_not_active"
			elseif tonumber(row.quantityOnPage) ~= tonumber(row.recommendedQuantity) then
				row.pythonAction = "update_quantity"
				row.pythonActionReason = "active_but_quantity_mismatch"
			else
				row.pythonAction = "none"
				row.pythonActionReason = "already_active_correct_quantity"
				row.canPythonApply = false
			end

		else
			row.desiredStatus = "paused"
			row.desiredQuantity = 0

			if currentStatus == "active" then
				row.pythonAction = "pause"
				row.pythonActionReason = row.disableReason or "not_recommended"
				row.canPythonApply = true
			else
				row.pythonAction = "none"
				row.pythonActionReason = row.disableReason or "already_paused"
				row.canPythonApply = false
			end
		end

		if row.kind == "unknown" then
			row.canPythonApply = false
			row.pythonAction = "skip"
			row.pythonActionReason = "unknown_offer_kind"
		end

		if row.kind == "item" and not row.resolveInfo then
			row.canPythonApply = false
			row.pythonAction = "skip"
			row.pythonActionReason = "missing_resolve_info"
		end

		if row.kind == "item" and row.recommendedEnabled and not row.rap then
			row.canPythonApply = false
			row.pythonAction = "skip"
			row.pythonActionReason = "recommended_item_missing_rap"
		end

		if not row.offerId or row.offerId == "" then
			row.canPythonApply = false
			row.pythonAction = "skip"
			row.pythonActionReason = "missing_offer_id"
		end

		if not row.offerUrl or row.offerUrl == "" then
			row.canPythonApply = false
			row.pythonAction = "skip"
			row.pythonActionReason = "missing_offer_url"
		end
	end
end

local function countPythonActions(rows, totals)
	totals.pythonActions = {
		enable = 0,
		pause = 0,
		update_quantity = 0,
		skip = 0,
		none = 0,
	}

	for _, row in ipairs(rows) do
		local action = row.pythonAction or "none"
		totals.pythonActions[action] = (totals.pythonActions[action] or 0) + 1
	end
end

local function main()
	log("INFO", "script start")
	log("INFO", "input:", CONFIG.InputFile, "output:", CONFIG.OutputFile, "log:", CONFIG.LogFile)

	local snapshot, err = readJson(CONFIG.InputFile)
	if not snapshot then
		log("ERROR", "failed reading snapshot:", err)

		writeJson(CONFIG.OutputFile, {
			ok = false,
			error = err,
			message = "Put autotrade_offers_all.json in the executor workspace first.",
			config = CONFIG,
		})

		saveLog()
		return
	end

	log("INFO", "snapshot loaded. version=", tostring(snapshot.version), "count=", tostring(snapshot.count), "page=", tostring(snapshot.page_url))

	loadGameModules()

	local currentTokens = tonumber(snapshot.current_tokens) or CONFIG.CurrentTokens
	CONFIG.TokenRatePerKUsd = tonumber(snapshot.token_rate_per_k_usd) or CONFIG.TokenRatePerKUsd
	CONFIG.SellerFeePercent = tonumber(snapshot.seller_fee_percent) or CONFIG.SellerFeePercent
	CONFIG.TokenReserve = tonumber(snapshot.token_reserve) or CONFIG.TokenReserve
	log("INFO", "runtime config: tokens=", currentTokens, "rate=", CONFIG.TokenRatePerKUsd, "fee=", CONFIG.SellerFeePercent, "reserve=", CONFIG.TokenReserve)
	local rows = buildOfferRows(snapshot)
	local totals = allocateBudget(rows, currentTokens)

	addPythonActions(rows)
	countPythonActions(rows, totals)

	local report = {
		ok = true,
		version = 6,
		createdAtUnix = os.time(),
		inputFile = CONFIG.InputFile,
		config = CONFIG,
		snapshotMeta = {
			version = snapshot.version,
			createdAt = snapshot.created_at,
			pageUrl = snapshot.page_url,
			offerCount = snapshot.count or #(snapshot.offers or {}),
		},
		totals = totals,
		rows = rows,
		logFile = CONFIG.LogFile,
		notes = {
			"Small spin offers use coverage-first allocation: 10x/50x/100x get one slot before extra quantities.",
			"Extra 10x/50x/100x are filled before items; 200x/250x/500x are after items.",
			"Spins are allocated before swords/items.",
			"Swords/items are paused first when tokens are tight.",
			"Lua resolves Eldorado names against ItemInfo before ItemToKey/RAP.",
			"RAP parses comma strings like 12,218.",
			"RAP uses RAPChartController safe path.",
			"Direct RequestRAPHistory/GetItemListings are not used.",
			"Python actions are included for apply_restock_plan.py.",
		}
	}

	writeJson(CONFIG.OutputFile, report)

	print("========== RESTOCK AUTO REPORT ==========")
	print("Input offers:", #(snapshot.offers or {}))
	print("Current tokens:", totals.currentTokens)
	print("Available after reserve:", totals.availableBudgetTokens)
	print("Spin reserved:", totals.spinReservedTokens)
	print("Item reserved:", totals.itemReservedTokens)
	print("Total reserved:", totals.totalReservedTokens)
	print("Remaining:", totals.remainingTokensAfterPlan)
	print("Net revenue:", totals.totalNetRevenueUsd)
	print("Token cost:", totals.totalTokenCostUsd)
	print("Profit:", totals.totalProfitUsd)
	print("Break-even $/k:", totals.breakEvenTokenRatePerKUsd)
	print("Python actions:", HttpService:JSONEncode(totals.pythonActions))
	print("Warns:", WARN_COUNT, "Errors:", ERROR_COUNT)
	print("Saved:", CONFIG.OutputFile)
	print("Log:", CONFIG.LogFile)

	print("========== ENABLE ==========")
	for _, row in ipairs(rows) do
		if row.recommendedEnabled then
			print(("[ENABLE] x%s | %s | %s | %s | title=%s | %s tokens/unit | profit $%s/unit | action=%s"):format(
				tostring(row.recommendedQuantity),
				tostring(row.kind),
				tostring(row.itemType or "-"),
				tostring(row.gameItemName or row.name),
				tostring(row.title or row.name),
				tostring(row.tokensPerUnit),
				tostring(row.profitUsdPerUnit),
				tostring(row.pythonAction)
			))
		end
	end

	print("========== PAUSED / DISABLED ==========")
	for _, row in ipairs(rows) do
		if not row.recommendedEnabled then
			print(("[PAUSE] %s | %s | %s | title=%s | reason=%s | action=%s"):format(
				tostring(row.kind),
				tostring(row.itemType or "-"),
				tostring(row.gameItemName or row.name),
				tostring(row.title or row.name),
				tostring(row.disableReason),
				tostring(row.pythonAction)
			))
		end
	end

	print("=======================================")

	saveLog()
	log("INFO", "script done")
	saveLog()
end


local function resetRunState()
	LOG_LINES = {}
	WARN_COUNT = 0
	ERROR_COUNT = 0
	rapCache = {}
	rapChecksDone = 0
end

function RestockAnalyzer.Run(overrides)
	resetRunState()

	if type(overrides) == "table" then
		for k, v in pairs(overrides) do
			if CONFIG[k] ~= nil or k == "InputFile" or k == "OutputFile" or k == "LogFile" then
				CONFIG[k] = v
			end
		end
	end

	local ok, err = xpcall(main, function(e)
		return tostring(e) .. "\n" .. debug.traceback()
	end)

	if not ok then
		log("ERROR", "fatal error:", err)
		writeJson(CONFIG.OutputFile, {
			ok = false,
			fatalError = err,
			config = CONFIG,
			logFile = CONFIG.LogFile,
		})
		saveLog()
		return false, tostring(err)
	end

	return true, "ok"
end

function RestockAnalyzer.GetConfig()
	return CONFIG
end

return RestockAnalyzer
end
