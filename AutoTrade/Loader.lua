-- AutoTrade/Loader.lua

local BASE = getgenv().AutoTradeBase or "https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/AutoTrade/"

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

local function httpGet(url)
	if game.HttpGet then
		return game:HttpGet(url)
	end

	return game:GetService("HttpService"):GetAsync(url)
end

local function loadRemote(name, ctx)
	local url = BASE .. name .. ".lua"
	print("[AutoTradeLoader] Loading", name, url)

	local source = httpGet(url)
	local chunk, compileErr = loadstring(source)

	if not chunk then
		error("[AutoTradeLoader] Failed to compile " .. name .. ": " .. tostring(compileErr))
	end

	local ok, result = pcall(chunk)

	if not ok then
		error("[AutoTradeLoader] Failed to run chunk " .. name .. ": " .. tostring(result))
	end

	if type(result) == "function" then
		local okModule, moduleResult = pcall(result, ctx)

		if not okModule then
			error("[AutoTradeLoader] Failed to initialize module " .. name .. ": " .. tostring(moduleResult))
		end

		result = moduleResult
	end

	print("[AutoTradeLoader] Loaded", name)
	return result
end

local ctx = {
	Base = BASE,
	Bridge = getgenv().AutoTradeBridge or {},
	Modules = {},
	Services = {
		Players = game:GetService("Players"),
		ReplicatedStorage = game:GetService("ReplicatedStorage"),
		HttpService = game:GetService("HttpService"),
	},
}

for _, name in ipairs(FILES) do
	ctx.Modules[name] = loadRemote(name, ctx)
end

ctx.Modules.Main.Start()
