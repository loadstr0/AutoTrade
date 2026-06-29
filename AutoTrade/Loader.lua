-- AutoTrade/Loader.lua

local BASE = getgenv().AutoTradeBase or "https://raw.githubusercontent.com/loadstr0/AutoTrade/main/AutoTrade/"
local BRIDGE_FILE = getgenv().AutoTradeBridgeFile or "autotrade_bridge.json"

local FILES = {
	"Logger",
	"Config",
	"PlayersUtil",
	"ProductResolver",
	"GiftActions",
	"GiftMain",
	"InventoryUtil",
	"TradeState",
	"TradeActions",
	"TradeMain",
	"Main",
}

local HttpService = game:GetService("HttpService")

local function httpGet(url)
	if game.HttpGet then
		return game:HttpGet(url)
	end

	return HttpService:GetAsync(url)
end

local function loadBridgeFromWorkspace()
	if getgenv().AutoTradeBridge then
		print("[AutoTradeLoader] Using existing getgenv().AutoTradeBridge")
		return getgenv().AutoTradeBridge
	end

	if typeof(readfile) ~= "function" then
		warn("[AutoTradeLoader] readfile is not available.")
		return {}
	end

	local exists = true

	if typeof(isfile) == "function" then
		exists = isfile(BRIDGE_FILE)
	end

	if not exists then
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
		warn("[AutoTradeLoader] File content was:", source)
		return {}
	end

	print("[AutoTradeLoader] Loaded bridge from workspace:", BRIDGE_FILE)
	getgenv().AutoTradeBridge = data

	return data
end

local function loadRemote(name, ctx)
	local url = BASE .. name .. ".lua"
	print("[AutoTradeLoader] Loading", name, url)

	local source = httpGet(url)
	local chunk, err = loadstring(source)

	if not chunk then
		error("[AutoTradeLoader] Failed to compile " .. name .. ": " .. tostring(err))
	end

	local ok, result = pcall(chunk, ctx)

	if not ok then
		error("[AutoTradeLoader] Failed to run " .. name .. ": " .. tostring(result))
	end

	print("[AutoTradeLoader] Loaded", name)
	return result
end

local ctx = {
	Base = BASE,
	Bridge = loadBridgeFromWorkspace(),
	Modules = {},
	Services = {
		Players = game:GetService("Players"),
		ReplicatedStorage = game:GetService("ReplicatedStorage"),
		HttpService = HttpService,
	},
}

for _, name in ipairs(FILES) do
	ctx.Modules[name] = loadRemote(name, ctx)
end

ctx.Modules.Main.Start(ctx)
