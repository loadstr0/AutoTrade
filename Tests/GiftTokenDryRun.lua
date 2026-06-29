-- Tests/GiftTokenDryRun.lua
-- Safe single-file dry run. Does NOT spend tokens.

local TEST = {
	BuyerName = "ioadstr0",
	ProductName = "10 Soccer Spins",
	ExpectedProductId = 3606732999,
	REAL_SPEND = false,
	GiftWithTokens = true,
	GiftMessage = "",
}

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function log(...)
	print("[GiftDryRun]", ...)
end

local function warnLog(...)
	warn("[GiftDryRun]", ...)
end

local function normalize(text)
	text = tostring(text or ""):lower()
	text = text:gsub("|.*$", "")
	text = text:gsub("blade ball", "")
	text = text:gsub("fast delivery", "")
	text = text:gsub("limited", "")
	text = text:gsub("(%d+)%s*x%s+", "%1 ")
	text = text:gsub("(%d+)x%s+", "%1 ")
	text = text:gsub("[^%w%s]", " ")
	text = text:gsub("%s+", " ")
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	return text
end

local function getDisplay(entry, key)
	return tostring(entry.DisplayName or entry.name or entry.Name or key or "")
end

local function getProductId(entry)
	return tonumber(entry.productId or entry.ProductId or entry.id or entry.Id)
end

local function resolveProduct(query)
	local GiftProductsId = require(ReplicatedStorage.Shared.GiftProductsId)
	local q = normalize(query)
	local matches = {}

	for key, entry in pairs(GiftProductsId) do
		if type(entry) == "table" then
			local display = getDisplay(entry, key)
			local productId = getProductId(entry)
			if productId then
				local nKey = normalize(key)
				local nDisplay = normalize(display)
				local score = 0
				if nDisplay == q then score = 100
				elseif nKey == q then score = 95
				elseif nDisplay:find(q, 1, true) then score = 70
				elseif q:find(nDisplay, 1, true) then score = 60
				elseif nKey:find(q, 1, true) then score = 50 end
				if score > 0 then
					table.insert(matches, { key = key, displayName = display, productId = productId, score = score })
				end
			end
		end
	end

	table.sort(matches, function(a, b)
		if a.score == b.score then return a.displayName < b.displayName end
		return a.score > b.score
	end)

	return matches
end

local function findPlayer(name)
	local lower = tostring(name or ""):lower()
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Name:lower() == lower or player.DisplayName:lower() == lower then
			return player
		end
	end
	return nil
end

local function resolveUserId(name)
	local player = findPlayer(name)
	if player then return player.UserId, player end
	local ok, userId = pcall(function()
		return Players:GetUserIdFromNameAsync(name)
	end)
	if ok and userId then return userId, nil end
	return nil, nil
end

log("Starting gift token dry run")
log("BuyerName:", TEST.BuyerName)
log("ProductName:", TEST.ProductName)

local remotes = ReplicatedStorage:FindFirstChild("Remotes")
if not remotes then warnLog("FAILED: Remotes missing") return end
local setGiftTo = remotes:FindFirstChild("SetGiftTo")
if not setGiftTo then warnLog("FAILED: SetGiftTo missing") return end
log("SetGiftTo found:", setGiftTo:GetFullName(), setGiftTo.ClassName)

local matches = resolveProduct(TEST.ProductName)
if #matches == 0 then warnLog("FAILED: No product match") return end

for i = 1, math.min(#matches, 5) do
	local m = matches[i]
	log(("#%d score=%d id=%s name=%s key=%s"):format(i, m.score, tostring(m.productId), tostring(m.displayName), tostring(m.key)))
end

local product = matches[1]
if product.productId ~= TEST.ExpectedProductId then
	warnLog("BLOCKED: expected product", TEST.ExpectedProductId, "got", product.productId)
	return
end

local buyerUserId, buyerPlayer = resolveUserId(TEST.BuyerName)
if not buyerUserId then warnLog("FAILED: could not resolve buyer") return end
if buyerPlayer then log("Buyer in server:", buyerPlayer.Name, buyerPlayer.UserId) else log("Buyer userId resolved:", buyerUserId) end

log("Would call:")
log(("SetGiftTo:FireServer(%d, %d, %q, true, nil)"):format(buyerUserId, product.productId, TEST.GiftMessage))

if TEST.REAL_SPEND ~= true then
	warnLog("DRY RUN BLOCKED TOKEN SPEND. No tokens were spent.")
	return
end

warnLog("REAL_SPEND = true; firing in 5 seconds")
for i = 5, 1, -1 do warnLog("Firing in", i) task.wait(1) end
setGiftTo:FireServer(buyerUserId, product.productId, TEST.GiftMessage, true, nil)
log("SetGiftTo fired.")
