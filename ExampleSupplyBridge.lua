-- ExampleSupplyBridge.lua
-- Put this into autotrade_bridge.json or set getgenv().AutoTradeBridge to this table for testing.

return {
	Jobs = {
		{
			BridgeId = "supply-test-dune-cleaver",
			DeliveryMode = "SupplyThenTrade",
			BuyerName = "ioadstr0",
			BuyerUserId = 7209122244,
			ItemType = "Sword",
			ItemName = "Dune Cleaver",
			Quantity = 1,
			OrderQuantity = 1,
			SupplyEnabled = true,
			SupplyAutoBuy = false,
			SupplyDryRun = true,
			ResultFile = "autotrade_result_supply-test-dune-cleaver.json",
		}
	}
}
