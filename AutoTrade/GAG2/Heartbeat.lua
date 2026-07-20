-- AutoTrade/GAG2/Heartbeat.lua
--
-- Adapted from AutoTrade/BB/Heartbeat.lua's shape (same State table,
-- phase/dangerous-phase tracking, connection-liveness detection via
-- workspace:GetServerTimeNow() drift, kick-message scan) but the
-- "is the game actually ready for delivery" checks are GAG2-specific:
--
--   - BB checks ReplicatedStorage.Packages.Replion for a live token
--     balance, and ReplicatedStorage.Shared.Trading.TradeInfo for trade
--     remotes -- neither of those modules exist in GAG2's real script
--     tree (confirmed from the decompiled MailboxController.lua /
--     Networking.lua dump). Its actual live-state source is
--     PlayerStateClient:GetLocalReplica() (same module
--     MailboxController.lua itself reads for inventory), and its actual
--     delivery remote is ReplicatedStorage.SharedModules.Networking's
--     Mailbox table.
--
-- Dangerous phases are the mailbox-send equivalents of BB's
-- gift_remote_sent/gift_remote_fired/gift_waiting_token_decrease --
-- once SendBatch has actually been fired, a crash/disconnect before we
-- get its response is a genuinely ambiguous state (did the buyer
-- receive it or not?), same reasoning as BB's gift flow.

return function(ctx)
	local Heartbeat = {}

	local Players = ctx.Services.Players
	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local HttpService = ctx.Services.HttpService

	local HEARTBEAT_FILE = getgenv().Gag2AutoTradeHeartbeatFile or "gag2_autotrade_heartbeat.json"
	local INTERVAL = tonumber(getgenv().Gag2AutoTradeHeartbeatSeconds or 3) or 3

	Heartbeat.State = {
		alive = true,
		phase = "booting",
		safeToRetry = true,
		dangerous = false,
		deliveryReady = false,
		readyReason = "booting",
		dataLoaded = false,
		inventoryReady = false,
		mailboxNetworkingReady = false,
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
		mailboxNetworkingReady = false,
		kickDetected = false,
		connectionAlive = true,
	}

	-- Same connection-liveness technique as BB's Heartbeat.lua: real-time
	-- (os.clock()) vs server-synced time (workspace:GetServerTimeNow())
	-- drifting apart over a real window means the live connection died
	-- even though the injected script keeps running -- confirmed useful
	-- there against a real production disconnect that every other check
	-- missed. Game-agnostic, reused as-is.
	local lastServerTimeSample = nil
	local lastServerTimeSampleClock = nil
	local connectionStalled = false

	local function checkServerConnectionAlive()
		local ok, serverTime = pcall(function()
			return workspace:GetServerTimeNow()
		end)

		if not ok or type(serverTime) ~= "number" then
			return not connectionStalled
		end

		local nowClock = os.clock()

		if lastServerTimeSample == nil then
			lastServerTimeSample = serverTime
			lastServerTimeSampleClock = nowClock
			return true
		end

		local realElapsed = nowClock - lastServerTimeSampleClock

		if realElapsed >= 5 then
			local serverElapsed = serverTime - lastServerTimeSample
			connectionStalled = serverElapsed < (realElapsed * 0.5)

			lastServerTimeSample = serverTime
			lastServerTimeSampleClock = nowClock
		end

		return not connectionStalled
	end

	-- CONFIRMED 2026-07-17 (see MailboxGiftActions.lua's module docstring):
	-- SendBatch:Fire() is actually a blocking request/response call that
	-- returns a real (success, message) pair, not a fire-and-forget event.
	-- So the only genuinely dangerous window is between firing it and the
	-- pcall returning -- once we have an answer (accepted OR rejected),
	-- that's a known, clean state, not an ambiguous one. mailbox_remote_fired
	-- and mailbox_waiting_response are no longer set by MailboxGiftActions.lua
	-- (left here harmlessly in case a future phase reuses those names).
	local DANGEROUS_PHASES = {
		mailbox_send_precheck = false,
		mailbox_remote_sent = true,
		mailbox_remote_fired = true,
		mailbox_waiting_response = true,
		mailbox_unconfirmed = true,
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

	local function getLivePlayers()
		local ok, list = pcall(function()
			local out = {}
			for _, p in ipairs(Players:GetPlayers()) do
				table.insert(out, {
					name = p.Name,
					displayName = p.DisplayName,
					userId = p.UserId,
				})
			end
			return out
		end)

		if ok then
			return list
		end

		return {}
	end

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

	-- GAG2-specific: inventory readiness comes from PlayerStateClient's
	-- local replica (confirmed from MailboxController.lua's
	-- rebuildInventory(), which reads
	-- PlayerStateClient:GetLocalReplica().Data.Inventory) -- not Replion,
	-- not a "Shared.Inventory.Client" module like BB.
	local function checkInventoryReady()
		local okRequire, PlayerStateClient = pcall(function()
			return require(ReplicatedStorage.ClientModules.PlayerStateClient)
		end)

		if not okRequire or type(PlayerStateClient) ~= "table" then
			return false, "player_state_client_unavailable"
		end

		local okReplica, replica = pcall(function()
			return PlayerStateClient:GetLocalReplica()
		end)

		if not okReplica or not replica then
			return false, "local_replica_not_ready"
		end

		local okData, inventory = pcall(function()
			return replica.Data and replica.Data.Inventory
		end)

		if okData and type(inventory) == "table" then
			return true, "inventory_ready"
		end

		return false, "inventory_data_missing"
	end

	-- GAG2-specific: the actual delivery remote is
	-- ReplicatedStorage.SharedModules.Networking.Mailbox.SendBatch
	-- (confirmed from the decompiled Networking.lua dump). Check the
	-- module and the specific fields exist before ever claiming ready,
	-- so a Roblox-side rename/update to this module surfaces as a clear
	-- "not ready" instead of a confusing failure deep in MailboxGiftActions.
	local function checkMailboxNetworkingReady()
		local okRequire, Networking = pcall(function()
			return require(ReplicatedStorage.SharedModules.Networking)
		end)

		if not okRequire or type(Networking) ~= "table" then
			return false, "networking_module_unavailable"
		end

		if type(Networking.Mailbox) ~= "table" then
			return false, "networking_mailbox_table_missing"
		end

		if not Networking.Mailbox.SendBatch or not Networking.Mailbox.LookupPlayer then
			return false, "networking_mailbox_remotes_missing"
		end

		return true, "mailbox_networking_ready"
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
			mailboxNetworkingReady = false,
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

		local invReady, invReason = checkInventoryReady()
		info.inventoryReady = invReady
		if not invReady then
			info.reason = invReason
			cachedReady = false
			cachedReadyInfo = info
			return false, info
		end

		local netReady, netReason = checkMailboxNetworkingReady()
		info.mailboxNetworkingReady = netReady
		if not netReady then
			info.reason = netReason
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
		local deliveryReady, readyInfo = checkDeliveryReady()

		data.alive = true
		data.time = os.time()
		data.osClock = os.clock()
		data.placeId = game.PlaceId
		data.jobId = game.JobId
		data.playerName = playerName
		data.playerUserId = playerUserId
		data.players = getLivePlayers()
		data.playersUpdatedAt = os.time()
		data.deliveryReady = deliveryReady == true
		data.readyReason = readyInfo.reason
		data.dataLoaded = readyInfo.dataLoaded == true
		data.inventoryReady = readyInfo.inventoryReady == true
		data.mailboxNetworkingReady = readyInfo.mailboxNetworkingReady == true
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
