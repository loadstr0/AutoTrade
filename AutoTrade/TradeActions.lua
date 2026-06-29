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

		local ok, result = pcall(function()
			if remote:IsA("RemoteFunction") then
				return remote:InvokeServer(table.unpack(args))
			else
				remote:FireServer(table.unpack(args))
				return true
			end
		end)

		if not ok then
			Logger.warn(label, "error:", result)
			return false, result
		end

		Logger.info(label, "=>", tostring(result))

		if result == false then
			return false, result
		end

		return true, result
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

	function TradeActions.sendTradeRequest(buyer)
		if not buyer then
			return false, "missing_buyer"
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

		Logger.info("Adding item to trade:")
		Logger.info("  UUID =", uuid)
		Logger.info("  Type =", tostring(itemType))

		local attempts = {}

		if itemType then
			table.insert(attempts, {
				name = "AddItemToTrade itemType/uuid",
				fn = function()
					return invoke("AddItemToTrade itemType/uuid", Remotes.AddItemToTrade, itemType, uuid)
				end,
			})

			table.insert(attempts, {
				name = "AddItemToTrade uuid/itemType",
				fn = function()
					return invoke("AddItemToTrade uuid/itemType", Remotes.AddItemToTrade, uuid, itemType)
				end,
			})
		end

		table.insert(attempts, {
			name = "AddItemToTrade uuid",
			fn = function()
				return invoke("AddItemToTrade uuid", Remotes.AddItemToTrade, uuid)
			end,
		})

		table.insert(attempts, {
			name = "AddItemToTrade table",
			fn = function()
				return invoke("AddItemToTrade table", Remotes.AddItemToTrade, {
					UUID = uuid,
					ItemType = itemType,
				})
			end,
		})

		for _, attempt in ipairs(attempts) do
			Logger.info("Trying", attempt.name)

			local ok, result = attempt.fn()

			if ok then
				Logger.info("AddItemToTrade worked with:", attempt.name)
				return true, result
			end

			task.wait(0.5)
		end

		return false, "add_item_failed"
	end

	function TradeActions.readyUp()
		return invoke("ReadyUp", Remotes.ReadyUp)
	end

	function TradeActions.confirmTrade()
		return invoke("ConfirmTrade", Remotes.ConfirmTrade)
	end

	function TradeActions.cancelTrade()
		return invoke("CancelTrade", Remotes.CancelTrade)
	end

	-- Aliases for older TradeMain versions.
	TradeActions.sendRequest = TradeActions.sendTradeRequest
	TradeActions.addItem = TradeActions.addItemToTrade
	TradeActions.ready = TradeActions.readyUp
	TradeActions.confirm = TradeActions.confirmTrade
	TradeActions.cancel = TradeActions.cancelTrade

	return TradeActions
end
