-- AutoTrade/Loader.lua

local HttpService = game:GetService("HttpService")

-- Multi-game place-scoped loading (2026-07-16).
-- One shared Loader.lua, injected into any game's client, picks which
-- game's module folder + file list to fetch based on game.PlaceId. This
-- mirrors the Python side's existing blade_ball/ + core/ + BLADESPINS_GAME
-- selector pattern -- one loading mechanism, per-game module sets.
--
-- Each game's Lua files live in their OWN subfolder under AutoTrade/ in
-- this same repo (AutoTrade/BB/ for Blade Ball, AutoTrade/GAG2/ for Grow
-- a Garden 2 once it exists) so a bug fix to one game's modules can never
-- accidentally affect another's, same reasoning as the Python side having
-- a separate config.py per game folder.
--
-- To add a new game: add its real PlaceId + file list below. Until a
-- game's PlaceId is set (left nil), the loader will not run for it.
local BLADE_BALL_PLACE_ID = 13772394625
local GAG2_PLACE_ID = 97598239454123

local GAME_FOLDERS = {
	[BLADE_BALL_PLACE_ID] = {
		name = "Blade Ball",
		folder = "BB",
		files = {
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
		},
	},
}

if GAG2_PLACE_ID then
	GAME_FOLDERS[GAG2_PLACE_ID] = {
		name = "Grow a Garden 2",
		folder = "GAG2",
		-- Order matters: loadRemote() calls each module's factory
		-- function(ctx) immediately as it's fetched, and later modules
		-- read earlier ones off ctx.Modules (e.g. PlayersUtil/ItemResolver/
		-- MailboxGiftActions all read ctx.Modules.Logger; MailboxGiftMain
		-- reads Logger+Heartbeat+PlayersUtil+ItemResolver+MailboxGiftActions;
		-- Main reads Logger+Heartbeat+Config+MailboxGiftMain). This is the
		-- same dependency-ordering convention BB's file list already uses.
		files = {
			"Logger",
			"Config",
			"Heartbeat",
			"PlayersUtil",
			"ItemResolver",
			"MailboxGiftActions",
			"MailboxGiftMain",
			"Main",
		},
	}
end

-- getgenv().AutoTradeExpectedPlaceId still works as a full override for
-- local testing (forces which game's module set loads, regardless of the
-- place you're actually standing in).
local CURRENT_PLACE_ID = game.PlaceId
local EFFECTIVE_PLACE_ID = getgenv().AutoTradeExpectedPlaceId or CURRENT_PLACE_ID
local GAME = GAME_FOLDERS[EFFECTIVE_PLACE_ID]

if not GAME then
	warn(
		"[AutoTradeLoader] Refusing to load: current PlaceId "
			.. tostring(CURRENT_PLACE_ID)
			.. " has no registered AutoTrade module set. "
			.. "(Set getgenv().AutoTradeExpectedPlaceId to override for local testing.)"
	)
	return
end

print("[AutoTradeLoader] Detected game: " .. GAME.name .. " (PlaceId " .. tostring(EFFECTIVE_PLACE_ID) .. ")")

local REPO_BASE = getgenv().AutoTradeRepoBase or "https://raw.githubusercontent.com/loadstr0/AutoTrade/main/AutoTrade/"
local BASE = getgenv().AutoTradeBase or (REPO_BASE .. GAME.folder .. "/")
local FILES = GAME.files
local BRIDGE_FILE = getgenv().AutoTradeBridgeFile or "autotrade_bridge.json"

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
