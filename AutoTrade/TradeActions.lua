-- AutoTrade/TradeActions.lua

return function(ctx)
	local TradeActions = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger

	local TradeInfo = require(ReplicatedStorage.Shared.Trading.TradeInfo)
	local Remotes = TradeInfo.Remotes

	local function invoke(label, remote, ...)
		if not remote then
			Logger.warn(label, "remote missing")
			return false, "remote_missing"
		end

		local args = { ... }

		local ok, result1, result2, result3 = pcall(function()
			if remote:IsA("RemoteFunction") then
				return remote:InvokeServer(table.unpack(args))
			else
				remote:FireServer(table.unpack(args))
				return true
			end
		end)

		if not ok then
			Logger.warn(label, "error:", result1)
			return false, result1
		end

		Logger.info(label, "=>", tostring(result1), tostring(result2 or ""))

		if result1 == false then
			return false, result2 or result1
		end

		return true, result1, result2, result3
	end

	local function getUuid(item)
		if type(item) == "string" then
			return item
		end

		if type(item) == "table" then
			return item.UUID
				or item.uuid
				or item.Id
				or item.id
				or item.ItemId
				or item.itemId
		end

		return nil
	end

	local function getItemType(item)
		if type(item) == "table" then
			return item.ItemType
				or item.itemType
				or item.Type
				or item.type
		end

		return nil
	end

	local function openTradeUiState()
		if not Remotes.SetUIOpen then
			Logger.warn("SetUIOpen remote missing, skipping.")
			return
		end

		Logger.info("Opening trade UI state before request...")

		pcall(function()
			if Remotes.SetUIOpen:IsA("RemoteFunction") then
				Remotes.SetUIOpen:InvokeServer(true)
			else
				Remotes.SetUIOpen:FireServer(true)
			end
		end)

		task.wait(0.75)
	end

	function TradeActions.sendTradeRequest(buyer)
		if not buyer then
			return false, "missing_buyer"
		end

		if not Remotes.SendTradeRequest then
			return false, "missing_SendTradeRequest_remote"
		end

		local userId = buyer.UserId
		local username = buyer.Name
		local displayName = buyer.DisplayName

		Logger.info("Preparing trade request:")
		Logger.info("  Buyer.Name =", username)
		Logger.info("  Buyer.DisplayName =", displayName)
		Logger.info("  Buyer.UserId =", userId)

		local attempts = {
			{
				name = "buyer Player instance",
				fn = function()
					return invoke("SendTradeRequest buyer Player instance", Remotes.SendTradeRequest, buyer)
				end,
			},
			{
				name = "buyer UserId number",
				fn = function()
					return invoke("SendTradeRequest buyer UserId number", Remotes.SendTradeRequest, userId)
				end,
			},
			{
				name = "buyer UserId string",
				fn = function()
					return invoke("SendTradeRequest buyer UserId string", Remotes.SendTradeRequest, tostring(userId))
				end,
			},
			{
				name = "buyer username string",
				fn = function()
					return invoke("SendTradeRequest buyer username string", Remotes.SendTradeRequest, username)
				end,
			},
			{
				name = "buyer displayName string",
				fn = function()
					return invoke("SendTradeRequest buyer displayName string", Remotes.SendTradeRequest, displayName)
				end,
			},
			{
				name = "table {UserId}",
				fn = function()
					return invoke("SendTradeRequest table UserId", Remotes.SendTradeRequest, {
						UserId = userId,
					})
				end,
			},
			{
				name = "table {Player, UserId, Name}",
				fn = function()
					return invoke("SendTradeRequest table Player/UserId/Name", Remotes.SendTradeRequest, {
						Player = buyer,
						UserId = userId,
						Name = username,
					})
				end,
			},
		}

		for round = 1, 3 do
			Logger.info("Trade request round:", round)

			openTradeUiState()

			for _, attempt in ipairs(attempts) do
				Logger.info("Trying SendTradeRequest:", attempt.name)

				local ok, result = attempt.fn()

				if ok then
					Logger.info("SendTradeRequest worked with:", attempt.name)
					return true, result
				end

				task.wait(0.75)
			end

			Logger.warn("Trade request round failed:", round)
			task.wait(2)
		end

		return false, "send_trade_request_failed"
	end

	function TradeActions.addItemToTrade(item)
		local uuid = getUuid(item)
		local itemType = getItemType(item)

		if not uuid then
			return false, "missing_item_uuid"
		end

		if not itemType then
			return false, "missing_item_type"
		end

		if not Remotes.AddItemToTrade then
			return false, "missing_AddItemToTrade_remote"
		end

		Logger.info("Adding item to trade exactly like UI:")
		Logger.info("  Type =", itemType)
		Logger.info("  UUID =", uuid)

		return invoke("AddItemToTrade itemType/uuid", Remotes.AddItemToTrade, itemType, uuid)
	end

	function TradeActions.removeItemFromTrade(item)
		local uuid = getUuid(item)
		local itemType = getItemType(item)

		if not uuid then
			return false, "missing_item_uuid"
		end

		if not itemType then
			return false, "missing_item_type"
		end

		if not Remotes.RemoveItemFromTrade then
			return false, "missing_RemoveItemFromTrade_remote"
		end

		return invoke("RemoveItemFromTrade itemType/uuid", Remotes.RemoveItemFromTrade, itemType, uuid)
	end

	function TradeActions.clearItems()
		if Remotes.ClearItemsFromTrade then
			return invoke("ClearItemsFromTrade", Remotes.ClearItemsFromTrade)
		end

		return true, "no_clear_remote"
	end

	function TradeActions.clearTokens()
		if Remotes.AddTokensToTrade then
			return invoke("AddTokensToTrade 0", Remotes.AddTokensToTrade, 0)
		end

		return true, "no_tokens_remote"
	end

	function TradeActions.clearTradeContents()
		Logger.info("Clearing trade contents before adding item.")

		pcall(function()
			TradeActions.clearTokens()
		end)

		pcall(function()
			TradeActions.clearItems()
		end)

		task.wait(0.5)

		return true
	end

	function TradeActions.readyUp(value)
		if value == nil then
			value = true
		end

		if not Remotes.ReadyUp then
			return false, "missing_ReadyUp_remote"
		end

		return invoke("ReadyUp", Remotes.ReadyUp, value)
	end

	function TradeActions.unready()
		return TradeActions.readyUp(false)
	end

	function TradeActions.confirmTrade()
		if not Remotes.ConfirmTrade then
			return false, "missing_ConfirmTrade_remote"
		end

		return invoke("ConfirmTrade", Remotes.ConfirmTrade)
	end

	function TradeActions.cancelTrade()
		if not Remotes.CancelTrade then
			return false, "missing_CancelTrade_remote"
		end

		return invoke("CancelTrade", Remotes.CancelTrade)
	end

	TradeActions.sendRequest = TradeActions.sendTradeRequest
	TradeActions.addItem = TradeActions.addItemToTrade
	TradeActions.ready = TradeActions.readyUp
	TradeActions.confirm = TradeActions.confirmTrade
	TradeActions.cancel = TradeActions.cancelTrade

	return TradeActions
end
