-- ExampleBridge.lua
-- Paste this into your executor/command bar after uploading AutoTrade/*.lua to GitHub.

getgenv().AutoTradeBase = "https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/AutoTrade/"

getgenv().AutoTradeBridge = {
	BuyerName = "ioadstr0",
	DeliveryMode = "Gift",
	ProductName = "10 Soccer Spins",
	Quantity = 10,
	OrderQuantity = 1,

	-- SAFE DEFAULT: no token spend.
	GiftDryRun = true,
	AllowTokenSpend = false,
	GiftWithTokens = true,
	RequireTokenBalanceDecrease = true,

	ResultFile = "autotrade_result.json",
}

loadstring(game:HttpGet(getgenv().AutoTradeBase .. "Loader.lua"))()
