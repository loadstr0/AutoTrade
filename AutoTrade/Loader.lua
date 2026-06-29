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
		warn("[AutoTradeLoader] File content was:", source)
		return {}
	end

	print("[AutoTradeLoader] Loaded bridge from workspace:", BRIDGE_FILE)
	getgenv().AutoTradeBridge = data

	return data
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

ctx.Bridge = loadBridgeFromWorkspace()

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

	-- Our files return function(ctx) ... return Module end
	-- So if result is a function, call it with ctx to get the actual module table.
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

if type(ctx.Modules.Main) ~= "table" then
	error("[AutoTradeLoader] Main module is not a table. Got: " .. typeof(ctx.Modules.Main))
end

if type(ctx.Modules.Main.Start) ~= "function" then
	error("[AutoTradeLoader] Main.Start is missing.")
end

ctx.Modules.Main.Start(ctx)
