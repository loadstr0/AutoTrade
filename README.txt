AutoTrade Lua Scripts

Folder to upload to GitHub:
  AutoTrade/

Required files:
  Loader.lua
  Config.lua
  Logger.lua
  PlayersUtil.lua
  ProductResolver.lua
  GiftActions.lua
  GiftMain.lua
  InventoryUtil.lua
  TradeState.lua
  TradeActions.lua
  TradeMain.lua
  Main.lua

Safe defaults:
  GiftDryRun = true
  AllowTokenSpend = false

That means gift orders resolve product + buyer and write/log results, but do NOT spend tokens.

For real token gift execution, the bridge must pass:
  GiftDryRun = false
  AllowTokenSpend = true
  GiftWithTokens = true

GiftActions also tries to confirm success by checking that the token balance decreased.
If it cannot read token balance or the token balance does not decrease, it returns failed so Python should NOT click Eldorado Order delivered.

Soccer products from GiftProductsId:
  10 Soccer Spins  -> 3606732999
  50 Soccer Spins  -> 3606733006
  250 Soccer Spins -> 3606733010

Use Tests/GiftTokenDryRun.lua for a local single-file dry run.
