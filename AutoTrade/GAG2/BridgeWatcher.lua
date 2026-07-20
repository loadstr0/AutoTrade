-- AutoTrade/GAG2/BridgeWatcher.lua
--
-- Watches the shared Python bridge queue and dispatches MailboxGift jobs
-- immediately. GAG2 recipients never need to be present in this server;
-- a resolved BuyerUserId and a non-empty MailboxItemsSpec are sufficient.

return function(ctx)
	local BridgeWatcher = {}

	local HttpService = ctx.Services.HttpService
	local Logger = ctx.Modules.Logger
	local Heartbeat = ctx.Modules.Heartbeat

	local BRIDGE_FILE = getgenv().AutoTradeBridgeFile or "autotrade_bridge.json"
	local POLL_SECONDS = tonumber(getgenv().AutoTradePollSeconds or 5) or 5
	local processed = getgenv().AutoTradeProcessedBridgeIds or {}

	getgenv().AutoTradeProcessedBridgeIds = processed

	local busy = false
	local lastIdleReason = nil

	local function bridgeId(bridge)
		local id = bridge.BridgeId or bridge.bridgeId or bridge.OrderId or bridge.orderId

		if id and tostring(id) ~= "" then
			return tostring(id)
		end

		return table.concat({
			tostring(bridge.BuyerUserId or ""),
			tostring(bridge.OrderTitle or ""),
			tostring(bridge.CreatedAt or ""),
		}, "|")
	end

	local function writeFailure(bridge, reason, extra)
		extra = extra or {}
		extra.BridgeId = bridgeId(bridge)
		Logger.writeResultForBridge(bridge, false, reason, extra)
	end

	local function readQueue()
		if typeof(readfile) ~= "function" then
			return nil, "readfile_unavailable"
		end

		if typeof(isfile) == "function" and not isfile(BRIDGE_FILE) then
			return nil, "missing"
		end

		local okRead, raw = pcall(function()
			return readfile(BRIDGE_FILE)
		end)

		if not okRead then
			return nil, "read_failed:" .. tostring(raw)
		end

		raw = tostring(raw or "")

		if raw:gsub("%s+", "") == "" then
			return nil, "empty"
		end

		local okDecode, data = pcall(function()
			return HttpService:JSONDecode(raw)
		end)

		if not okDecode or type(data) ~= "table" or next(data) == nil then
			return nil, "invalid_json"
		end

		if type(data.Jobs) == "table" then
			return data.Jobs, nil
		end

		return { data }, nil
	end

	local function validate(bridge)
		if type(bridge) ~= "table" then
			return false, "bridge_not_table"
		end

		if bridge.DeliveryMode ~= "MailboxGift" then
			return false, "unsupported_delivery_mode:" .. tostring(bridge.DeliveryMode)
		end

		if not tonumber(bridge.BuyerUserId) then
			return false, "missing_buyer_user_id"
		end

		if type(bridge.MailboxItemsSpec) ~= "table" or #bridge.MailboxItemsSpec == 0 then
			return false, "no_items_resolved"
		end

		local deadline = tonumber(bridge.DeadlineUnix or 0) or 0

		if deadline > 0 and os.time() >= deadline then
			return false, "deadline_expired"
		end

		return true, nil
	end

	local function chooseJob(jobs)
		local ready = {}

		for _, bridge in ipairs(jobs) do
			local id = bridgeId(bridge)

			if not processed[id] then
				local valid, reason = validate(bridge)

				if valid then
					table.insert(ready, bridge)
				else
					processed[id] = true
					Logger.warn("Bridge ignored:", reason)
					writeFailure(bridge, reason, { invalid = reason ~= "deadline_expired", expired = reason == "deadline_expired" })
				end
			end
		end

		table.sort(ready, function(a, b)
			local ac = tonumber(a.CreatedAt or 0) or 0
			local bc = tonumber(b.CreatedAt or 0) or 0

			if ac == bc then
				return bridgeId(a) < bridgeId(b)
			end

			return ac < bc
		end)

		return ready[1], #ready
	end

	local function runJob(bridge)
		local id = bridgeId(bridge)
		busy = true
		processed[id] = true
		ctx.Bridge = bridge
		getgenv().AutoTradeBridge = bridge

		if Logger.clear then
			Logger.clear()
		end

		if Heartbeat and Heartbeat.SetJob then
			Heartbeat.SetJob(bridge)
			Heartbeat.SetPhase("job_started", { BridgeId = id, safeToRetry = true, dangerous = false })
		end

		Logger.info("New MailboxGift bridge detected:", id)

		local ok, result, reason = pcall(function()
			return ctx.Modules.Main.Start(ctx)
		end)

		if not ok then
			Logger.error("MailboxGift bridge crashed:", result)
			writeFailure(bridge, tostring(result), { crashed = true })
		elseif Heartbeat and Heartbeat.SetPhase then
			Heartbeat.SetPhase(result == true and "completed" or "failed", {
				reason = tostring(reason or ""),
				safeToRetry = result ~= true,
				dangerous = false,
			})
		end

		if Heartbeat and Heartbeat.ClearJob then
			Heartbeat.ClearJob()
		end

		busy = false
	end

	function BridgeWatcher.Start()
		if Heartbeat and Heartbeat.Start then
			Heartbeat.Start()
			Heartbeat.SetPhase("waiting_queue", { safeToRetry = true, dangerous = false })
		end

		Logger.info("GAG2 mailbox bridge watcher started. File:", BRIDGE_FILE, "Poll seconds:", POLL_SECONDS)

		while getgenv().AutoTradeStop ~= true do
			if not busy then
				local jobs, reason = readQueue()

				if jobs then
					local bridge, readyCount = chooseJob(jobs)

					if bridge then
						lastIdleReason = nil
						Logger.info("Mailbox queue ready jobs:", readyCount)
						runJob(bridge)
					elseif lastIdleReason ~= "no_ready_jobs" then
						Logger.info("Waiting for mailbox queue job: no_ready_jobs")
						lastIdleReason = "no_ready_jobs"
					end
				elseif reason ~= lastIdleReason then
					Logger.info("Waiting for bridge file job:", reason)
					lastIdleReason = reason
				end
			end

			task.wait(POLL_SECONDS)
		end

		Logger.warn("GAG2 mailbox bridge watcher stopped.")
	end

	return BridgeWatcher
end
