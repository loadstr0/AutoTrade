-- AutoTrade/Loader.lua

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
	"TradeState",
	"TradeActions",
	"TradeMain",
	"Main",
	"BridgeWatcher",
}

local HttpService = game:GetService("HttpService")

local function httpGet(url)
	if game.HttpGet then
		return game:HttpGet(url)
	end

	return HttpService:GetAsync(url)
end

local ctx = {
	Base = BASE,
	Bridge = nil,
	Modules = {},
	Services = {
		Players = game:GetService("Players"),
		ReplicatedStorage = game:GetService("ReplicatedStorage"),
		HttpService = HttpService,
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
	print("[AutoTradeLoader] Loading", name, url)

	local source = httpGet(url)
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

if getgenv().AutoTradeWatch == true then
	ctx.Modules.BridgeWatcher.Start()
else
	ctx.Bridge = loadBridgeOnce()
	ctx.Modules.Main.Start(ctx)
end
