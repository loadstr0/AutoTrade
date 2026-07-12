-- AutoTrade/Heartbeat.lua

return function(ctx)
	local Heartbeat = {}

	local Players = ctx.Services.Players
	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local HttpService = ctx.Services.HttpService

	local HEARTBEAT_FILE = getgenv().AutoTradeHeartbeatFile or "autotrade_heartbeat.json"
	local INTERVAL = tonumber(getgenv().AutoTradeHeartbeatSeconds or 3) or 3

	Heartbeat.State = {
		alive = true,
		phase = "booting",
		safeToRetry = true,
		dangerous = false,
		deliveryReady = false,
		readyReason = "booting",
		dataLoaded = false,
		inventoryReady = false,
		tradeReady = false,
		kickDetected = false,
		message = "",
		time = os.time(),
		placeId = game.PlaceId,
		jobStartedAt = nil,
		BridgeId = nil,
		ResultFile = nil,
		DeliveryMode = nil,
		BuyerName = nil,
		BuyerUserId = nil,
	}

	local started = false
	local lastReadyCheck = 0
	local cachedReady = false
	local cachedReadyInfo = {
		reason = "not_checked_yet",
		dataLoaded = false,
		inventoryReady = false,
		tradeReady = false,
		kickDetected = false,
		connectionAlive = true,
	}

	-- [AUTOTRADE HEARTBEAT CONNECTION-LIVENESS PATCH -- 2026-07-13]
	-- None of the checks below this originally caught a real disconnect:
	-- game:IsLoaded(), Players.LocalPlayer.Parent, and the inventory/trade
	-- module presence checks all stay true forever once satisfied once,
	-- even after the live server connection dies (client shows the
	-- built-in "disconnected" overlay while the injected script keeps
	-- running). getLiveTokenBalance() reads Replion's last cached value,
	-- which doesn't error on disconnect either. Result: the write loop
	-- kept stamping a fresh os.time() onto an otherwise-frozen snapshot
	-- forever, so Python's recovery.py always saw a "healthy, fresh"
	-- heartbeat no matter how long the real connection had been dead --
	-- confirmed from a real production heartbeat file that stayed
	-- deliveryReady=true throughout a disconnect with no [Recovery] log
	-- lines at all.
	--
	-- workspace:GetServerTimeNow() is synced from the server over the
	-- network -- it FREEZES on a real disconnect, while os.clock() (a
	-- pure local clock) keeps advancing normally. Comparing the two over
	-- a real-time window is a reliable, UI-text-independent way to detect
	-- "still connected" that doesn't depend on the exact wording of
	-- whatever disconnect overlay Roblox happens to show.
	local lastServerTimeSample = nil
	local lastServerTimeSampleClock = nil
	local connectionStalled = false

	local function checkServerConnectionAlive()
		local ok, serverTime = pcall(function()
			return workspace:GetServerTimeNow()
		end)

		if not ok or type(serverTime) ~= "number" then
			-- Can't read it at all -- don't flip everything red on this
			-- alone, that's a different kind of unknown than a confirmed
			-- disconnect. Keep whatever the last known state was.
			return not connectionStalled
		end

		local nowClock = os.clock()

		if lastServerTimeSample == nil then
			lastServerTimeSample = serverTime
			lastServerTimeSampleClock = nowClock
			return true
		end

		local realElapsed = nowClock - lastServerTimeSampleClock

		-- Only judge over a big enough real-time window so normal jitter
		-- (frame hitches, GC pauses) can't false-positive this.
		if realElapsed >= 5 then
			local serverElapsed = serverTime - lastServerTimeSample
			-- Server clock advancing less than half of real elapsed time
			-- means we're not actually receiving live updates anymore.
			connectionStalled = serverElapsed < (realElapsed * 0.5)

			lastServerTimeSample = serverTime
			lastServerTimeSampleClock = nowClock
		end

		return not connectionStalled
	end
	-- [/AUTOTRADE HEARTBEAT CONNECTION-LIVENESS PATCH]

	local DANGEROUS_PHASES = {
		confirm_sent = true,
		local_confirmed = true,
		waiting_buyer_confirm = true,
		buyer_confirmed = true,
		processing = true,
		gift_remote_sent = true,
		gift_remote_fired = true,
		gift_waiting_token_decrease = true,
		gift_unconfirmed = true,
		supply_buy_invoking = true,
		supply_buy_sent = true,
		supply_buy_sent_waiting_result = true,
		supply_waiting_purchase_result = true,
		supply_purchase_unconfirmed = true,
		supply_tokens_decreased_item_missing = true,
		supply_manual_check_required = true,
		supply_dangerous_resume_check = true,
		supply_stale_dangerous_block = true,
	}

	local function shallowCopy(source)
		local out = {}

		for k, v in pairs(source) do
			out[k] = v
		end

		return out
	end

	local function getPlayerInfo()
		local player = Players.LocalPlayer

		if not player then
			return nil, nil
		end

		return player.Name, player.UserId
	end

	-- [AUTOTRADE HEARTBEAT TOKEN PATCH]
	local function getLiveTokenBalance()
		local ok, result = pcall(function()
			local Replion = require(ReplicatedStorage.Packages.Replion)
			local inventory = Replion.Client:WaitReplion("Inventory")
			if inventory and type(inventory.Get) == "function" then
				return inventory:Get("Tokens")
			end
			return nil
		end)

		if ok and type(result) == "number" then
			return math.floor(result), "roblox_live_replion", ""
		end

		return nil, "unavailable", tostring(result or "could_not_read_tokens")
	end
	-- [/AUTOTRADE HEARTBEAT TOKEN PATCH]

	local function encode(data)
		local ok, encoded = pcall(function()
			return HttpService:JSONEncode(data)
		end)

		if ok then
			return encoded
		end

		return nil
	end

	local function textLooksLikeKick(text)
		text = string.lower(tostring(text or ""))

		return text:find("data", 1, true) and text:find("could", 1, true) and text:find("load", 1, true)
	end

	local function scanForKickMessage()
		local containers = {}

		pcall(function()
			table.insert(containers, game:GetService("CoreGui"))
		end)

		pcall(function()
			local player = Players.LocalPlayer
			if player then
				table.insert(containers, player:FindFirstChildOfClass("PlayerGui"))
			end
		end)

		for _, container in ipairs(containers) do
			if container then
				local ok, descendants = pcall(function()
					return container:GetDescendants()
				end)

				if ok then
					for _, obj in ipairs(descendants) do
						if obj:IsA("TextLabel") or obj:IsA("TextButton") then
							local okText, text = pcall(function()
								return obj.Text
							end)

							if okText and textLooksLikeKick(text) then
								return true, tostring(text)
							end
						end
					end
				end
			end
		end

		return false, ""
	end

	local function checkInventoryReady(player)
		local okClient, InventoryClient = pcall(function()
			return require(ReplicatedStorage.Shared.Inventory.Client)
		end)

		if not okClient or type(InventoryClient) ~= "table" then
			return false, "inventory_client_unavailable"
		end

		local okGet, data = pcall(function()
			if type(InventoryClient.Get) == "function" then
				return InventoryClient.Get(player)
			end
		end)

		if okGet and data ~= nil then
			return true, "inventory_get_ready"
		end

		local okGetInventory, inv = pcall(function()
			if type(InventoryClient.GetInventory) == "function" then
				return InventoryClient.GetInventory(player)
			end
		end)

		if okGetInventory and inv ~= nil then
			return true, "inventory_getinventory_ready"
		end

		return false, "inventory_not_loaded"
	end

	local function checkTradeReady()
		local okInfo, TradeInfo = pcall(function()
			return require(ReplicatedStorage.Shared.Trading.TradeInfo)
		end)

		if not okInfo or type(TradeInfo) ~= "table" then
			return false, "tradeinfo_unavailable"
		end

		if type(TradeInfo.Remotes) ~= "table" then
			return false, "trade_remotes_unavailable"
		end

		if not TradeInfo.Remotes.SendTradeRequest or not TradeInfo.Remotes.AddItemToTrade then
			return false, "trade_required_remotes_missing"
		end

		return true, "trade_ready"
	end

	local function checkDeliveryReady()
		local now = os.clock()

		if now - lastReadyCheck < 1.5 then
			return cachedReady, cachedReadyInfo
		end

		lastReadyCheck = now

		local info = {
			reason = "unknown",
			dataLoaded = false,
			inventoryReady = false,
			tradeReady = false,
			kickDetected = false,
			connectionAlive = true,
		}

		local connectionAlive = checkServerConnectionAlive()
		info.connectionAlive = connectionAlive
		if not connectionAlive then
			info.reason = "server_connection_stalled"
			cachedReady = false
			cachedReadyInfo = info
			return false, info
		end

		local kicked, kickText = scanForKickMessage()
		if kicked then
			info.kickDetected = true
			info.reason = "kick_message_detected:" .. string.sub(kickText, 1, 120)
			cachedReady = false
			cachedReadyInfo = info
			return false, info
		end

		local player = Players.LocalPlayer
		if not player or not player.Parent then
			info.reason = "localplayer_missing"
			cachedReady = false
			cachedReadyInfo = info
			return false, info
		end

		local okLoaded, loaded = pcall(function()
			return game:IsLoaded()
		end)

		if not okLoaded or not loaded then
			info.reason = "game_not_loaded"
			cachedReady = false
			cachedReadyInfo = info
			return false, info
		end

		info.dataLoaded = true

		local invReady, invReason = checkInventoryReady(player)
		info.inventoryReady = invReady
		if not invReady then
			info.reason = invReason
			cachedReady = false
			cachedReadyInfo = info
			return false, info
		end

		local tradeReady, tradeReason = checkTradeReady()
		info.tradeReady = tradeReady
		if not tradeReady then
			info.reason = tradeReason
			cachedReady = false
			cachedReadyInfo = info
			return false, info
		end

		info.reason = "ready"
		cachedReady = true
		cachedReadyInfo = info
		return true, info
	end

	function Heartbeat.Write()
		if typeof(writefile) ~= "function" then
			return false, "writefile_unavailable"
		end

		local data = shallowCopy(Heartbeat.State)
		local playerName, playerUserId = getPlayerInfo()
		local liveTokens, tokenSource, tokenError = getLiveTokenBalance()
		local deliveryReady, readyInfo = checkDeliveryReady()

		data.alive = true
		data.time = os.time()
		data.osClock = os.clock()
		data.placeId = game.PlaceId
		data.jobId = game.JobId
		data.playerName = playerName
		data.playerUserId = playerUserId
		data.currentTokens = liveTokens
		data.tokenBalanceSource = tokenSource
		data.tokenBalanceError = tokenError
		data.deliveryReady = deliveryReady == true
		data.readyReason = readyInfo.reason
		data.dataLoaded = readyInfo.dataLoaded == true
		data.inventoryReady = readyInfo.inventoryReady == true
		data.tradeReady = readyInfo.tradeReady == true
		data.kickDetected = readyInfo.kickDetected == true
		data.connectionAlive = readyInfo.connectionAlive ~= false
		data.safeToRetry = data.safeToRetry ~= false
		data.dangerous = data.dangerous == true

		if DANGEROUS_PHASES[tostring(data.phase)] then
			data.dangerous = true
			data.safeToRetry = false
		end

		local encoded = encode(data)

		if not encoded then
			return false, "json_encode_failed"
		end

		local ok, err = pcall(function()
			writefile(HEARTBEAT_FILE, encoded)
		end)

		if not ok then
			return false, tostring(err)
		end

		return true
	end

	function Heartbeat.SetPhase(phase, info)
		info = info or {}

		Heartbeat.State.phase = tostring(phase or "unknown")
		Heartbeat.State.time = os.time()
		Heartbeat.State.message = tostring(info.message or info.reason or Heartbeat.State.message or "")

		if info.safeToRetry ~= nil then
			Heartbeat.State.safeToRetry = info.safeToRetry == true
		end

		if info.dangerous ~= nil then
			Heartbeat.State.dangerous = info.dangerous == true
		elseif DANGEROUS_PHASES[tostring(phase)] then
			Heartbeat.State.dangerous = true
			Heartbeat.State.safeToRetry = false
		end

		for _, key in ipairs({
			"BridgeId",
			"ResultFile",
			"DeliveryMode",
			"BuyerName",
			"BuyerUserId",
			"ItemName",
			"ItemType",
			"ProductName",
			"ProductId",
			"Quantity",
			"OrderQuantity",
			"attempt",
			"GroupId",
			"GroupSize",
		}) do
			if info[key] ~= nil then
				Heartbeat.State[key] = info[key]
			end
		end

		Heartbeat.Write()
	end

	function Heartbeat.SetJob(bridge)
		bridge = bridge or {}

		Heartbeat.State.jobStartedAt = os.time()
		Heartbeat.State.BridgeId = bridge.BridgeId
		Heartbeat.State.ResultFile = bridge.ResultFile
		Heartbeat.State.DeliveryMode = bridge.DeliveryMode
		Heartbeat.State.BuyerName = bridge.BuyerName
		Heartbeat.State.BuyerUserId = bridge.BuyerUserId
		Heartbeat.State.ItemName = bridge.ItemName
		Heartbeat.State.ItemType = bridge.ItemType
		Heartbeat.State.ProductName = bridge.ProductName
		Heartbeat.State.ProductId = bridge.ProductId
		Heartbeat.State.Quantity = bridge.Quantity
		Heartbeat.State.OrderQuantity = bridge.OrderQuantity
		Heartbeat.State.Grouped = bridge.Grouped == true
		Heartbeat.State.GroupSize = type(bridge.GroupJobs) == "table" and #bridge.GroupJobs or 1
		Heartbeat.State.safeToRetry = true
		Heartbeat.State.dangerous = false
		Heartbeat.State.phase = "job_loaded"
		Heartbeat.State.message = ""

		Heartbeat.Write()
	end

	function Heartbeat.ClearJob()
		Heartbeat.State.jobStartedAt = nil
		Heartbeat.State.BridgeId = nil
		Heartbeat.State.ResultFile = nil
		Heartbeat.State.DeliveryMode = nil
		Heartbeat.State.BuyerName = nil
		Heartbeat.State.BuyerUserId = nil
		Heartbeat.State.ItemName = nil
		Heartbeat.State.ItemType = nil
		Heartbeat.State.ProductName = nil
		Heartbeat.State.ProductId = nil
		Heartbeat.State.Quantity = nil
		Heartbeat.State.OrderQuantity = nil
		Heartbeat.State.Grouped = false
		Heartbeat.State.GroupSize = nil
		Heartbeat.State.safeToRetry = true
		Heartbeat.State.dangerous = false
		Heartbeat.State.phase = "idle"
		Heartbeat.State.message = ""

		Heartbeat.Write()
	end

	function Heartbeat.Start()
		if started then
			return
		end

		started = true
		Heartbeat.SetPhase("idle", { safeToRetry = true, dangerous = false })

		task.spawn(function()
			while getgenv().AutoTradeStop ~= true do
				-- A single bad Write() (e.g. a transient nil somewhere not
				-- already caught inside it) must never kill this whole loop
				-- permanently -- that would freeze the heartbeat forever even
				-- though the bot is still fully alive in-game, which is
				-- exactly the "stale heartbeat but actually fine" case the
				-- Python-side presence check exists to catch. Guard every
				-- tick so one bad write just gets logged and retried next
				-- cycle instead of ending the loop.
				local ok, err = pcall(Heartbeat.Write)
				if not ok then
					warn("[Heartbeat] Write() errored, will retry next tick: " .. tostring(err))
				end
				task.wait(INTERVAL)
			end

			Heartbeat.State.alive = false
			Heartbeat.State.phase = "stopped"
			Heartbeat.State.time = os.time()
			Heartbeat.Write()
		end)
	end

	return Heartbeat
end
