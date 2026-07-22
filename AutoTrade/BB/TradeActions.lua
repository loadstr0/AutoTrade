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

		Logger.info("Preparing trade request:")
		Logger.info("  Buyer.Name =", buyer.Name)
		Logger.info("  Buyer.DisplayName =", buyer.DisplayName)
		Logger.info("  Buyer.UserId =", buyer.UserId)

		-- CONFIRMED 2026-07-22 from the real client source
		-- (Controllers.Trading.TradeRequestController.lua's own SendTrade
		-- function): Remotes.SendTradeRequest:InvokeServer(p2), where p2 is
		-- the actual Player instance passed in from observePlayer() (which
		-- explicitly skips LocalPlayer, confirming p2 is a real other-player
		-- Player object -- not a UserId, username, or table). This used to
		-- brute-force 7 different argument shapes across up to 3 rounds
		-- because this signature wasn't confirmed; the other 6 never once
		-- succeeded in any real trace and don't exist anywhere in the real
		-- game code, so they're gone. Rounds are kept (transient hiccups are
		-- still real) but each round is now one real attempt instead of
		-- seven guesses.
		--
		-- Also explains why early rounds can still legitimately fail even
		-- with the right signature: the real SendTrade() gates on
		-- PlayerStates.options.CanInvite, itself driven by the buyer's real
		-- AllowRequests privacy setting ("Friends" vs "Everyone"). If
		-- they're not accepting requests from strangers, the server
		-- rejects this exact same call -- that's a privacy-setting failure,
		-- not a signature failure, and is already handled by watcher.py's
		-- trade-privacy retry (asking the buyer to send the request to us
		-- instead) rather than anything here.
		for round = 1, 3 do
			Logger.info("Trade request round:", round)

			openTradeUiState()

			Logger.info("Trying SendTradeRequest: buyer Player instance")

			local ok, result = invoke("SendTradeRequest buyer Player instance", Remotes.SendTradeRequest, buyer)

			if ok then
				Logger.info("SendTradeRequest worked.")
				return true, result
			end

			Logger.warn("Trade request round failed:", round, "reason:", tostring(result))
			task.wait(2)
		end

		return false, "send_trade_request_failed"
	end

	-- Buyer-initiates-trade support ("TradeDirection" = "incoming"). Real
	-- remote + call signature confirmed from a live dump of
	-- TradeRequestController.lua's own "Yes" button handler:
	--   TradeInfo.Remotes.RespondToTradeRequest:InvokeServer(fromPlayer, true)
	-- fromPlayer is the actual Player instance that sent the request (the
	-- same one captured off the ReceivedTradeRequest event in TradeState.lua),
	-- not a UserId/username -- unlike SendTradeRequest, which tries multiple
	-- shapes because we didn't have this confirmed, this one is verified so
	-- there's no need to guess argument shapes here.
	function TradeActions.respondToTradeRequest(buyer, accept)
		if not buyer then
			return false, "missing_buyer"
		end

		if not Remotes.RespondToTradeRequest then
			return false, "missing_RespondToTradeRequest_remote"
		end

		if accept == nil then
			accept = true
		end

		return invoke("RespondToTradeRequest", Remotes.RespondToTradeRequest, buyer, accept)
	end

	function TradeActions.acceptTradeRequest(buyer)
		return TradeActions.respondToTradeRequest(buyer, true)
	end

	function TradeActions.declineTradeRequest(buyer)
		return TradeActions.respondToTradeRequest(buyer, false)
	end

	function TradeActions.addTokensToTrade(amount)
		amount = tonumber(amount)
	
		if not amount or amount <= 0 then
			return false, "invalid_token_amount"
		end
	
		if not Remotes.AddTokensToTrade then
			return false, "missing_AddTokensToTrade_remote"
		end
	
		return invoke("AddTokensToTrade", Remotes.AddTokensToTrade, amount)
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
