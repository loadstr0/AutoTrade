-- AutoTrade/TradeState.lua

return function(ctx)
	local TradeState = {}

	local Players = ctx.Services.Players
	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger

	local LocalPlayer = Players.LocalPlayer

	local TradeInfo = require(ReplicatedStorage.Shared.Trading.TradeInfo)
	local TradeTabController = require(ReplicatedStorage.Controllers.Trading.TradeTabController)

	local lastStatus = nil
	local lastStatusRaw = nil

	local function safeGet(obj, path)
		if not obj then
			return nil
		end

		local ok, result = pcall(function()
			return obj:Get(path)
		end)

		if ok then
			return result
		end

		return nil
	end

	local function getTrade()
		local state = TradeTabController.TradeReplionState

		if not state then
			return nil
		end

		local ok, trade = pcall(function()
			return state:Get()
		end)

		if ok then
			return trade
		end

		return nil
	end

	local function getTradeId(trade)
		return safeGet(trade, "TradeId")
	end

	local function serializeSmall(value, depth)
		depth = depth or 0

		if depth > 2 then
			return "..."
		end

		if type(value) ~= "table" then
			return tostring(value)
		end

		local parts = {}
		local count = 0

		for k, v in pairs(value) do
			count += 1
			table.insert(parts, tostring(k) .. "=" .. serializeSmall(v, depth + 1))

			if count >= 12 then
				table.insert(parts, "...")
				break
			end
		end

		return "{" .. table.concat(parts, ", ") .. "}"
	end

	local function parseStatus(...)
		local args = { ... }
		lastStatusRaw = args

		for _, value in ipairs(args) do
			if type(value) == "number" then
				local name = TradeInfo.TradeIdToStatus[value]

				if name then
					return name
				end
			elseif type(value) == "string" then
				local lowered = value:lower()

				if lowered:find("completed", 1, true) then
					return "Completed"
				end

				if lowered:find("canceled", 1, true) or lowered:find("cancelled", 1, true) then
					return "Canceled"
				end

				if lowered:find("reverted", 1, true) then
					return "Reverted"
				end

				if lowered:find("processing", 1, true) then
					return "Processing"
				end
			elseif type(value) == "table" then
				local status = value.Status or value.status or value.TradeStatus or value.tradeStatus

				if type(status) == "number" then
					return TradeInfo.TradeIdToStatus[status]
				end

				if type(status) == "string" then
					return status
				end
			end
		end

		return nil
	end

	if TradeInfo.Remotes.TradeStatus and not getgenv().AutoTradeTradeStatusHooked then
		getgenv().AutoTradeTradeStatusHooked = true

		TradeInfo.Remotes.TradeStatus.OnClientEvent:Connect(function(...)
			local status = parseStatus(...)

			if status then
				lastStatus = status
				Logger.info("TradeStatus event:", status)
			else
				Logger.warn("TradeStatus event unknown args:", serializeSmall(lastStatusRaw))
			end
		end)
	end

	-- Buyer-initiates-trade support ("TradeDirection" = "incoming"): Blade
	-- Ball fires ReceivedTradeRequest to the client when someone sends US a
	-- trade request -- the mirror image of our own SendTradeRequest flow.
	-- Confirmed from a real dump of ReplicatedStorage.Shared.Trading.TradeInfo
	-- and TradeRequestController:
	--   Remotes.ReceivedTradeRequest  -- RemoteEvent, fires with { From = Player, Time = number }
	--   Remotes.RespondToTradeRequest -- RemoteFunction, InvokeServer(fromPlayer, true/false)
	-- TradeInfo.TradeRequestExpiration is only 10 seconds, so this hook is
	-- installed once at bot startup (TradeState.lua only ever runs its module
	-- body once, per Loader.lua) rather than per-job -- otherwise a buyer who
	-- sends a request right as they join could expire before any bridge job
	-- even starts watching for them.
	getgenv().AutoTradeIncomingRequests = getgenv().AutoTradeIncomingRequests or {}
	local incomingRequests = getgenv().AutoTradeIncomingRequests

	if TradeInfo.Remotes.ReceivedTradeRequest and not getgenv().AutoTradeReceivedRequestHooked then
		getgenv().AutoTradeReceivedRequestHooked = true

		TradeInfo.Remotes.ReceivedTradeRequest.OnClientEvent:Connect(function(payload)
			local ok, err = pcall(function()
				local from = payload and payload.From

				if not from then
					return
				end

				local fromUserId = (typeof(from) == "Instance" and from.UserId)
					or (type(from) == "table" and from.UserId)

				if not fromUserId then
					return
				end

				incomingRequests[tostring(fromUserId)] = {
					player = from,
					time = tonumber(payload.Time) or workspace:GetServerTimeNow(),
				}

				local fromName = (typeof(from) == "Instance" and from.Name) or tostring(from)
				Logger.info("Incoming trade request captured from:", fromName, fromUserId)
			end)

			if not ok then
				Logger.warn("ReceivedTradeRequest handler error:", err)
			end
		end)
	end

	local function getPlayers(trade)
		local players = safeGet(trade, "Players")

		if type(players) == "table" then
			return players
		end

		if type(trade) == "table" and type(trade.Data) == "table" then
			return trade.Data.Players
		end

		return nil
	end

	local function findOtherPlayer(trade)
		local players = getPlayers(trade)

		if type(players) ~= "table" then
			return nil
		end

		for _, plr in pairs(players) do
			if typeof(plr) == "Instance" and plr:IsA("Player") and plr ~= LocalPlayer then
				return plr
			end

			if type(plr) == "table" and plr.UserId and tonumber(plr.UserId) ~= LocalPlayer.UserId then
				return plr
			end
		end

		return nil
	end

	local function userIdOf(plr)
		if typeof(plr) == "Instance" and plr:IsA("Player") then
			return plr.UserId
		end

		if type(plr) == "table" then
			return tonumber(plr.UserId)
		end

		return nil
	end

	local function deepContains(value, needle)
		needle = tostring(needle)

		if value == nil then
			return false
		end

		if type(value) == "string" or type(value) == "number" then
			return tostring(value) == needle or tostring(value):find(needle, 1, true) ~= nil
		end

		if type(value) == "table" then
			for k, v in pairs(value) do
				if deepContains(k, needle) or deepContains(v, needle) then
					return true
				end
			end
		end

		return false
	end

	local function clickGuiButton(button)
		if not button then
			return false
		end

		if typeof(firesignal) == "function" then
			local ok = pcall(function()
				firesignal(button.Activated)
			end)

			if ok then
				return true
			end
		end

		if typeof(getconnections) == "function" then
			local ok = pcall(function()
				for _, connection in ipairs(getconnections(button.Activated)) do
					connection:Fire()
				end
			end)

			if ok then
				return true
			end
		end

		local ok = pcall(function()
			local VirtualInputManager = game:GetService("VirtualInputManager")
			local pos = button.AbsolutePosition + (button.AbsoluteSize / 2)

			VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, game, 1)
			task.wait(0.05)
			VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, game, 1)
		end)

		return ok
	end

	function TradeState.getTrade()
		return getTrade()
	end

	function TradeState.getLastStatus()
		return lastStatus
	end

	function TradeState.getLocalUserIdString()
		return tostring(LocalPlayer.UserId)
	end

	function TradeState.getBuyerUserIdString(buyer)
		return tostring(userIdOf(buyer))
	end

	function TradeState.isTradeOpenForBuyer(buyer)
		local trade = getTrade()

		if not trade then
			return false, "no_trade_replion"
		end

		local other = findOtherPlayer(trade)

		if not other then
			return false, "no_other_player"
		end

		local otherUserId = userIdOf(other)
		local buyerUserId = userIdOf(buyer)

		if tonumber(otherUserId) ~= tonumber(buyerUserId) then
			return false, "wrong_buyer_in_trade:" .. tostring(otherUserId)
		end

		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local tradeGui = playerGui and playerGui:FindFirstChild("Trade")

		if not tradeGui or tradeGui.Enabled ~= true then
			return false, "trade_replion_exists_but_gui_disabled"
		end

		return true, "trade_open:" .. tostring(getTradeId(trade))
	end

	function TradeState.waitForTradeOpen(buyer, timeout)
		timeout = tonumber(timeout or 12) or 12

		Logger.info("Waiting for REAL trade replion with timeout:", timeout)

		local start = os.clock()
		local lastLog = 0

		while os.clock() - start < timeout do
			local ok, reason = TradeState.isTradeOpenForBuyer(buyer)

			if ok then
				Logger.info("Real trade open:", reason)
				return true, reason
			end

			if os.clock() - lastLog >= 2 then
				Logger.info("Still waiting for real trade:", tostring(reason))
				lastLog = os.clock()
			end

			task.wait(0.25)
		end

		return false, "trade_open_timeout"
	end

	function TradeState.getIncomingRequest(buyerUserId)
		buyerUserId = tonumber(buyerUserId)

		if not buyerUserId then
			return nil
		end

		local entry = incomingRequests[tostring(buyerUserId)]

		if not entry then
			return nil
		end

		-- TradeInfo.TradeRequestExpiration is the server's own expiration
		-- window (10s) -- treat a stale captured entry as gone so we don't
		-- try to accept a request the server has already expired.
		local age = workspace:GetServerTimeNow() - entry.time

		if age > TradeInfo.TradeRequestExpiration then
			incomingRequests[tostring(buyerUserId)] = nil
			return nil
		end

		return entry
	end

	function TradeState.clearIncomingRequest(buyerUserId)
		buyerUserId = tonumber(buyerUserId)

		if buyerUserId then
			incomingRequests[tostring(buyerUserId)] = nil
		end
	end

	function TradeState.waitForIncomingTradeRequest(buyer, timeout)
		timeout = tonumber(timeout or 60) or 60

		local buyerUserId = userIdOf(buyer)

		if not buyerUserId then
			return false, "missing_buyer_user_id"
		end

		Logger.info("Waiting for buyer to send us a trade request. Timeout:", timeout)

		local start = os.clock()
		local lastLog = 0

		while os.clock() - start < timeout do
			local entry = TradeState.getIncomingRequest(buyerUserId)

			if entry then
				Logger.info("Incoming trade request confirmed from buyer.")
				return true, "incoming_request_seen", entry.player
			end

			if os.clock() - lastLog >= 5 then
				Logger.info("Still waiting for buyer's incoming trade request...")
				lastLog = os.clock()
			end

			task.wait(0.25)
		end

		return false, "incoming_trade_request_timeout"
	end

	function TradeState.getPlayerValue(userId, key)
		local trade = getTrade()

		if not trade then
			return nil
		end

		return safeGet(trade, {
			tostring(userId),
			key,
		})
	end

	function TradeState.isReady(userId)
		return TradeState.getPlayerValue(userId, "Ready") == true
	end

	function TradeState.isConfirmed(userId)
		return TradeState.getPlayerValue(userId, "Confirmed") == true
	end

	function TradeState.isProcessing()
		local trade = getTrade()

		if not trade then
			return false
		end

		return safeGet(trade, "Processing") == true
	end

	function TradeState.getLastChange()
		local trade = getTrade()

		if not trade then
			return 0
		end

		return tonumber(safeGet(trade, "LastChange") or 0) or 0
	end

	function TradeState.waitNoItemCountdown(timeout)
		timeout = tonumber(timeout or 8) or 8

		local start = os.clock()

		while os.clock() - start < timeout do
			local lastChange = TradeState.getLastChange()

			if lastChange <= 0 then
				return true
			end

			local elapsed = workspace:GetServerTimeNow() - lastChange
			local left = TradeInfo.ItemChangeCountdown + 0.2 - elapsed

			if left <= 0 then
				return true
			end

			Logger.info("Waiting item-change countdown:", math.ceil(left), "s")
			task.wait(math.min(1, left))
		end

		return false, "item_countdown_timeout"
	end

	function TradeState.offerContainsItem(localUserId, uuid)
		local trade = getTrade()

		if not trade then
			return false
		end

		local items = safeGet(trade, {
			tostring(localUserId),
			"Items",
		})

		return deepContains(items, uuid)
	end

	function TradeState.offerContainsAllItems(localUserId, uuids)
		if type(uuids) ~= "table" then
			return TradeState.offerContainsItem(localUserId, uuids)
		end

		for _, uuid in ipairs(uuids) do
			if not TradeState.offerContainsItem(localUserId, uuid) then
				return false, uuid
			end
		end

		return true
	end

	function TradeState.waitItemInOffer(localUserId, uuid, timeout)
		timeout = tonumber(timeout or 8) or 8

		local start = os.clock()

		while os.clock() - start < timeout do
			if not getTrade() then
				return false, "trade_closed"
			end

			if TradeState.offerContainsItem(localUserId, uuid) then
				Logger.info("Verified item is in our trade offer:", uuid)
				return true
			end

			task.wait(0.25)
		end

		return false, "item_not_seen_in_offer"
	end

	function TradeState.waitLocalReady(localUserId, timeout)
		timeout = tonumber(timeout or 8) or 8

		local start = os.clock()

		while os.clock() - start < timeout do
			if not getTrade() then
				return false, "trade_closed"
			end

			if TradeState.isReady(localUserId) then
				return true
			end

			task.wait(0.25)
		end

		return false, "local_ready_timeout"
	end

	function TradeState.waitBuyerReady(buyerUserId, localUserId, uuids, timeout)
		timeout = tonumber(timeout or 60) or 60

		local start = os.clock()
		local lastLog = 0

		while os.clock() - start < timeout do
			if not getTrade() then
				return false, "trade_closed"
			end

			local allPresent, missingUuid = TradeState.offerContainsAllItems(localUserId, uuids)

			if not allPresent then
				return false, "our_item_removed_or_missing:" .. tostring(missingUuid)
			end

			if TradeState.isReady(buyerUserId) then
				Logger.info("Buyer is ready.")
				return true
			end

			if os.clock() - lastLog >= 5 then
				Logger.info("Waiting for buyer to ready...")
				lastLog = os.clock()
			end

			task.wait(0.5)
		end

		return false, "buyer_ready_timeout"
	end

	function TradeState.waitLocalConfirmed(localUserId, timeout)
		timeout = tonumber(timeout or 8) or 8

		local start = os.clock()

		while os.clock() - start < timeout do
			if not getTrade() then
				if lastStatus == "Completed" then
					return true
				end

				return false, "trade_closed"
			end

			if TradeState.isConfirmed(localUserId) or TradeState.isProcessing() then
				return true
			end

			task.wait(0.25)
		end

		return false, "local_confirm_timeout"
	end

	function TradeState.waitBuyerConfirmedOrProcessing(buyerUserId, localUserId, uuids, timeout)
		timeout = tonumber(timeout or 60) or 60

		local start = os.clock()
		local lastLog = 0

		while os.clock() - start < timeout do
			if not getTrade() then
				if lastStatus == "Completed" then
					return true, "completed"
				end

				return false, "trade_closed_before_completed"
			end

			local allPresent, missingUuid = TradeState.offerContainsAllItems(localUserId, uuids)

			if not allPresent then
				return false, "our_item_removed_or_missing:" .. tostring(missingUuid)
			end

			if TradeState.isProcessing() then
				return true, "processing"
			end

			if TradeState.isConfirmed(buyerUserId) then
				return true, "buyer_confirmed"
			end

			if os.clock() - lastLog >= 5 then
				Logger.info("Waiting for buyer confirm/processing...")
				lastLog = os.clock()
			end

			task.wait(0.5)
		end

		return false, "buyer_confirm_timeout"
	end

	function TradeState.completedPopupVisible()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")

		if not playerGui then
			return false
		end

		for _, obj in ipairs(playerGui:GetDescendants()) do
			if obj:IsA("TextLabel") or obj:IsA("TextButton") then
				local text = tostring(obj.Text or ""):lower()

				if text:find("trade with", 1, true) and text:find("completed", 1, true) then
					return true
				end
			end
		end

		return false
	end

	function TradeState.closeCompletedPopup(timeout)
		timeout = tonumber(timeout or 8) or 8

		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")

		if not playerGui then
			return false, "no_player_gui"
		end

		local start = os.clock()

		while os.clock() - start < timeout do
			local foundCompletedText = false
			local okButton = nil

			for _, obj in ipairs(playerGui:GetDescendants()) do
				if obj:IsA("TextLabel") or obj:IsA("TextButton") then
					local text = tostring(obj.Text or ""):lower()

					if text:find("trade with", 1, true) and text:find("completed", 1, true) then
						foundCompletedText = true
					end

					if text == "ok!" or text == "ok" then
						if obj:IsA("GuiButton") then
							okButton = obj
						end
					end
				end
			end

			if foundCompletedText and okButton then
				Logger.info("Trade completed popup found. Pressing OK.")
				local clicked = clickGuiButton(okButton)

				if clicked then
					return true, "clicked_ok"
				end

				return false, "ok_click_failed"
			end

			task.wait(0.25)
		end

		return false, "completed_popup_not_found"
	end

	function TradeState.waitFinalResult(timeout)
		timeout = tonumber(timeout or 30) or 30

		local start = os.clock()
		local sawProcessing = false

		while os.clock() - start < timeout do
			if lastStatus == "Completed" then
				return true, "completed_status"
			end

			if lastStatus == "Canceled" or lastStatus == "Reverted" then
				return false, "trade_" .. string.lower(lastStatus)
			end

			if TradeState.completedPopupVisible() then
				return true, "completed_popup"
			end

			if TradeState.isProcessing() then
				sawProcessing = true
			end

			if sawProcessing and not getTrade() then
				if TradeState.completedPopupVisible() then
					return true, "closed_after_processing_with_popup"
				end

				-- Give popup/status a short moment to appear.
				local graceStart = os.clock()

				while os.clock() - graceStart < 5 do
					if lastStatus == "Completed" or TradeState.completedPopupVisible() then
						return true, "closed_after_processing_completed"
					end

					if lastStatus == "Canceled" or lastStatus == "Reverted" then
						return false, "trade_" .. string.lower(lastStatus)
					end

					task.wait(0.25)
				end

				return false, "trade_closed_after_processing_without_completion_signal"
			end

			task.wait(0.25)
		end

		return false, "final_result_timeout"
	end

	function TradeState.resetStatus()
		lastStatus = nil
		lastStatusRaw = nil
	end

	return TradeState
end
