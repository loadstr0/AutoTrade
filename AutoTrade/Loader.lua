-- AutoTrade/Loader.lua

local HttpService = game:GetService("HttpService")

-- Place-scoped loading.
-- This bridge/module set (Heartbeat, Gift/Trade/Supply mains, RestockWatcher,
-- etc.) is Blade Ball-specific. As more games (starting with Grow a Garden 2)
-- get their own trading mechanics, this same Loader.lua may end up injected
-- into any game's client, so it must refuse to run the Blade Ball module set
-- anywhere except the actual Blade Ball place. Override via
-- getgenv().AutoTradeExpectedPlaceId if you ever need to bypass this for
-- local testing.
local BLADE_BALL_PLACE_ID = 13772394625
local EXPECTED_PLACE_ID = getgenv().AutoTradeExpectedPlaceId or BLADE_BALL_PLACE_ID
local CURRENT_PLACE_ID = game.PlaceId

if CURRENT_PLACE_ID ~= EXPECTED_PLACE_ID then
	warn(
		"[AutoTradeLoader] Refusing to load Blade Ball AutoTrade modules: current PlaceId "
			.. tostring(CURRENT_PLACE_ID)
			.. " does not match expected Blade Ball PlaceId "
			.. tostring(EXPECTED_PLACE_ID)
			.. ". (Set getgenv().AutoTradeExpectedPlaceId to override.)"
	)
	return
end

local BASE = getgenv().AutoTradeBase or "https://raw.githubusercontent.com/loadstr0/AutoTrade/main/AutoTrade/"
local BRIDGE_FILE = getgenv().AutoTradeBridgeFile or "autotrade_bridge.json"

local FILES = {
	"Logger",
	"Config",
	"Heartbeat",
	"PlayersUtil",
	"ProductResolver",
	"InventoryUtil",
	"SupplyState",
	"SupplyRAP",
	"SupplyPlanner",
	"SupplyScanner",
	"SupplyBuyer",
	"SupplyMain",
	"GiftActions",
	"GiftMain",
	"ChatActions",
	"TradeState",
	"TradeActions",
	"TradeMain",
	"TokenTradeMain",
	"Main",
	"RestockAnalyzer",
	"RestockWatcher",
	"BridgeWatcher",
}

local function getRequest()
	if typeof(request) == "function" then
		return request
	end

	if typeof(http_request) == "function" then
		return http_request
	end

	if syn and typeof(syn.request) == "function" then
		return syn.request
	end

	if http and typeof(http.request) == "function" then
		return http.request
	end

	return nil
end

local function addCacheBust(url)
	local sep = string.find(url, "?", 1, true) and "&" or "?"
	return url .. sep .. "cache=" .. tostring(os.time()) .. tostring(math.random(1000, 9999))
end

local function httpGet(url)
	url = addCacheBust(url)

	print("[AutoTradeLoader] GET:", url)

	local req = getRequest()

	if req then
		local ok, res = pcall(function()
			return req({
				Url = url,
				Method = "GET",
				Headers = {
					["Cache-Control"] = "no-cache",
					["Pragma"] = "no-cache",
				},
			})
		end)

		if not ok then
			error("[AutoTradeLoader] request() failed: " .. tostring(res), 2)
		end

		if type(res) == "table" then
			local status = tonumber(res.StatusCode or res.Status or 200)
			local body = res.Body or res.body

			if status and (status < 200 or status >= 300) then
				error("[AutoTradeLoader] HTTP " .. tostring(status) .. " for " .. url, 2)
			end

			if type(body) ~= "string" or body == "" then
				error("[AutoTradeLoader] Empty response for " .. url, 2)
			end

			return body
		end

		if type(res) == "string" and res ~= "" then
			return res
		end

		error("[AutoTradeLoader] Bad request() response for " .. url .. ": " .. typeof(res), 2)
	end

	local ok, body = pcall(function()
		return game:HttpGet(url)
	end)

	if not ok then
		error("[AutoTradeLoader] game:HttpGet failed: " .. tostring(body), 2)
	end

	if type(body) ~= "string" or body == "" then
		error("[AutoTradeLoader] Empty game:HttpGet response for " .. url, 2)
	end

	return body
end

local ctx = {
	Base = BASE,
	Bridge = nil,
	Modules = {},
	Services = {
		Players = game:GetService("Players"),
		ReplicatedStorage = game:GetService("ReplicatedStorage"),
		HttpService = HttpService,
		TextChatService = game:GetService("TextChatService"),
	},
}

local function loadBridgeOnce()
	if getgenv().AutoTradeBridge then
		print("[AutoTradeLoader] Using existing getgenv().AutoTradeBridge")
		return getgenv().AutoTradeBridge
	end

	if typeof(readfile) ~= "function" then
		warn("[AutoTradeLoader] readfile is not available.")
		return {}
	end

	if typeof(isfile) == "function" and not isfile(BRIDGE_FILE) then
		warn("[AutoTradeLoader] Bridge file not found:", BRIDGE_FILE)
		return {}
	end

	local okRead, source = pcall(function()
		return readfile(BRIDGE_FILE)
	end)

	if not okRead then
		warn("[AutoTradeLoader] Failed to read bridge file:", source)
		return {}
	end

	local okDecode, data = pcall(function()
		return HttpService:JSONDecode(source)
	end)

	if not okDecode then
		warn("[AutoTradeLoader] Failed to JSONDecode bridge file:", data)
		return {}
	end

	print("[AutoTradeLoader] Loaded bridge from workspace:", BRIDGE_FILE)

	getgenv().AutoTradeBridge = data
	return data
end

local function loadRemote(name)
	local url = BASE .. name .. ".lua"

	print("[AutoTradeLoader] Loading module:", name)

	task.wait(0.15)

	local source = httpGet(url)

	if not string.find(source, "return", 1, true) then
		warn("[AutoTradeLoader] Source preview for", name, string.sub(source, 1, 200))
	end

	local chunk, compileErr = loadstring(source)

	if not chunk then
		error("[AutoTradeLoader] Failed to compile " .. name .. ": " .. tostring(compileErr))
	end

	local okRun, result = pcall(chunk)

	if not okRun then
		error("[AutoTradeLoader] Failed to run chunk " .. name .. ": " .. tostring(result))
	end

	if type(result) == "function" then
		local okFactory, module = pcall(result, ctx)

		if not okFactory then
			error("[AutoTradeLoader] Failed to initialize module " .. name .. ": " .. tostring(module))
		end

		result = module
	end

	if result == nil then
		error("[AutoTradeLoader] Module returned nil: " .. name)
	end

	print("[AutoTradeLoader] Loaded", name, "as", typeof(result))

	return result
end

for _, name in ipairs(FILES) do
	ctx.Modules[name] = loadRemote(name)
end

if getgenv().AutoTradeRestockWatch == true and ctx.Modules.RestockWatcher then
	task.spawn(function()
		local ok, err = pcall(function()
			ctx.Modules.RestockWatcher.Start()
		end)

		if not ok then
			warn("[AutoTradeLoader] RestockWatcher crashed:", err)
		end
	end)
end

if getgenv().AutoTradeWatch == true then
	ctx.Modules.BridgeWatcher.Start()
elseif getgenv().AutoTradeRestockWatch == true then
	print("[AutoTradeLoader] AutoTradeWatch=false but RestockWatch=true; keeping loader alive for restock requests.")

	while getgenv().AutoTradeStop ~= true do
		task.wait(1)
	end
else
	ctx.Bridge = loadBridgeOnce()
	ctx.Modules.Main.Start(ctx)
end
