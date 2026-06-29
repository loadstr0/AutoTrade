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

	local function getUuid(item)
		if type(item) == "string" then
			return item
		end

		if type(item) == "table" then
			return item.UUID or item.uuid or item.Id or item.id or item.ItemId or item.itemId
		end

		return nil
	end

	local function getItemType(item)
		if type(item) == "table" then
			return item.ItemType or item.itemType or item.Type or item.type
		end

		return nil
	end

	function TradeActions.sendTradeRequest(buyer)
		local userId = buyer.UserId

		local attempts = {
			function()
				return invoke("SendTradeRequest player", Remotes.SendTradeRequest, buyer)
			end,

			function()
				return invoke("SendTradeRequest userId", Remotes.SendTradeRequest, userId)
			end,
		}

		for _, fn in ipairs(attempts) do
			local ok, result = fn()

			if ok then
				return true, result
			end
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
			local ok, result = attempt.fn()

			if ok then
				Logger.info("AddItemToTrade worked with:", attempt.name)
				return true, result
			end
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

	-- Aliases in case TradeMain uses older names.
	TradeActions.sendRequest = TradeActions.sendTradeRequest
	TradeActions.addItem = TradeActions.addItemToTrade
	TradeActions.ready = TradeActions.readyUp
	TradeActions.confirm = TradeActions.confirmTrade
	TradeActions.cancel = TradeActions.cancelTrade

	return TradeActions
end
