-- AutoTrade/BridgeWatcher.lua

return function(ctx)
	local BridgeWatcher = {}

	local Players = ctx.Services.Players
	local HttpService = ctx.Services.HttpService
	local Logger = ctx.Modules.Logger
	local Config = ctx.Modules.Config
	local Heartbeat = ctx.Modules.Heartbeat

	local BRIDGE_FILE = getgenv().AutoTradeBridgeFile or "autotrade_bridge.json"
	local POLL_SECONDS = tonumber(getgenv().AutoTradePollSeconds or 5) or 5

	getgenv().AutoTradeProcessedBridgeIds = getgenv().AutoTradeProcessedBridgeIds or {}

	local processed = getgenv().AutoTradeProcessedBridgeIds
	local busy = false
	local lastIdleReason = nil

	local function hasText(s)
		return type(s) == "string" and s:gsub("%s+", "") ~= ""
	end

	local function nowUnix()
		return os.time()
	end

	local function readTextFile(path)
		if typeof(readfile) ~= "function" then
			return nil, "readfile_unavailable"
		end

		if typeof(isfile) == "function" and not isfile(path) then
			return nil, "missing"
		end

		local ok, raw = pcall(function()
			return readfile(path)
		end)

		if not ok then
			return nil, "read_failed:" .. tostring(raw)
		end

		return tostring(raw or ""), nil
	end

	local function readJsonFile(path)
		local raw, err = readTextFile(path)

		if not raw then
			return nil, err
		end

		if not hasText(raw) then
			return nil, "idle_empty"
		end

		local okDecode, data = pcall(function()
			return HttpService:JSONDecode(raw)
		end)

		if not okDecode then
			return nil, "idle_invalid_json"
		end

		if type(data) ~= "table" then
			return nil, "json_not_table"
		end

		if next(data) == nil then
			return nil, "idle_empty_object"
		end

		return data, nil
	end

	local function readBridgeFile()
		return readJsonFile(BRIDGE_FILE)
	end

	local function extractJobs(data)
		if type(data.Jobs) == "table" then
			return data.Jobs
		end

		return { data }
	end

	local function getBridgeId(bridge)
		local id = bridge.BridgeId
			or bridge.bridgeId
			or bridge.OrderId
			or bridge.orderId

		if id and tostring(id) ~= "" then
			return tostring(id)
		end

		return table.concat({
			tostring(bridge.BuyerName or ""),
			tostring(bridge.DeliveryMode or ""),
			tostring(bridge.ItemName or ""),
			tostring(bridge.ProductName or ""),
			tostring(bridge.OrderTitle or ""),
		}, "|")
	end

	local function getJobIds(bridge)
		local ids = {}

		if type(bridge) == "table" and type(bridge.GroupJobs) == "table" then
			for _, job in ipairs(bridge.GroupJobs) do
				table.insert(ids, getBridgeId(job))
			end
		else
			table.insert(ids, getBridgeId(bridge))
		end

		return ids
	end

	local function markProcessed(bridge)
		for _, id in ipairs(getJobIds(bridge)) do
			processed[id] = true
		end
	end

	local function resultFileAlreadyExists(bridge)
		local resultFile = tostring(bridge.ResultFile or "")

		if resultFile == "" then
			return false
		end

		local data = readJsonFile(resultFile)

		if type(data) ~= "table" then
			return false
		end

		local resultBridgeId = tostring(data.BridgeId or data.bridgeId or "")
		local bridgeId = getBridgeId(bridge)

		if resultBridgeId ~= "" and resultBridgeId ~= bridgeId then
			return false
		end

		return data.success ~= nil or data.Success ~= nil or data.status ~= nil or data.reason ~= nil
	end

	local function isExpired(bridge)
		local deadline = tonumber(bridge.DeadlineUnix or 0) or 0

		if deadline <= 0 then
			return false
		end

		return nowUnix() >= deadline
	end

	local function isValidBridge(bridge)
		if type(bridge) ~= "table" then
			return false, "bridge_not_table"
		end

		if not bridge.BuyerName or bridge.BuyerName == "" then
			return false, "missing BuyerName"
		end

		if not bridge.DeliveryMode or bridge.DeliveryMode == "" then
			return false, "missing DeliveryMode"
		end

		if bridge.DeliveryMode == "Trade" or bridge.DeliveryMode == "Supply" or bridge.DeliveryMode == "SupplyThenTrade" then
			if not bridge.ItemName or bridge.ItemName == "" then
				return false, "missing ItemName"
			end

			if not bridge.ItemType or bridge.ItemType == "" then
				return false, "missing ItemType"
			end
		elseif bridge.DeliveryMode == "Gift" then
			if not bridge.ProductName and not bridge.ProductId then
				return false, "missing ProductName/ProductId"
			end
		elseif bridge.DeliveryMode == "TokenTrade" then
			if not bridge.TokenAmount or tonumber(bridge.TokenAmount) == nil or tonumber(bridge.TokenAmount) <= 0 then
				return false, "missing or invalid TokenAmount"
			end
		else
			return false, "bad DeliveryMode: " .. tostring(bridge.DeliveryMode)
		end

		return true
	end

	local function findPlayer(name, userId)
		userId = tonumber(userId)

		if userId then
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr.UserId == userId then
					return plr
				end
			end
		end

		name = tostring(name or ""):lower()

		if name == "" then
			return nil
		end

		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Name:lower() == name or plr.DisplayName:lower() == name then
				if userId and plr.UserId ~= userId then
					return nil
				end

				return plr
			end
		end

		-- No fuzzy/partial matching here. A valid-but-wrong buyer username must not
		-- accidentally select a similarly named account.
		return nil
	end

	local function sortJobs(jobs)
		table.sort(jobs, function(a, b)
			local ac = tonumber(a.CreatedAt or 0) or 0
			local bc = tonumber(b.CreatedAt or 0) or 0

			if ac == bc then
				return getBridgeId(a) < getBridgeId(b)
			end

			return ac < bc
		end)
	end

	local function failBridge(bridge, reason, extra)
		extra = extra or {}
		extra.BridgeId = getBridgeId(bridge)

		if Logger.writeResultForBridge then
			Logger.writeResultForBridge(bridge, false, reason, extra)
		elseif Logger.writeResult then
			local previousBridge = ctx.Bridge
			ctx.Bridge = bridge
			Logger.writeResult(false, reason, extra)
			ctx.Bridge = previousBridge
		end
	end

	local function cleanJobs(jobs)
		local pending = {}
		local expiredCount = 0

		for _, bridge in ipairs(jobs) do
			local bridgeId = getBridgeId(bridge)

			if processed[bridgeId] then
				continue
			end

			if resultFileAlreadyExists(bridge) then
				processed[bridgeId] = true
				continue
			end

			local valid, reason = isValidBridge(bridge)

			if not valid then
				Logger.warn("Bridge ignored:", reason)
				processed[bridgeId] = true
				failBridge(bridge, reason, { invalid = true })
				continue
			end

			if isExpired(bridge) then
				expiredCount += 1
				processed[bridgeId] = true
				Logger.warn("Bridge expired before buyer was ready:", bridgeId)
				failBridge(bridge, "deadline_expired", { expired = true })
				continue
			end

			table.insert(pending, bridge)
		end

		return pending, expiredCount
	end

	local function sameBuyer(a, b)
		local au = tonumber(a.BuyerUserId or 0) or 0
		local bu = tonumber(b.BuyerUserId or 0) or 0

		if au > 0 and bu > 0 then
			return au == bu
		end

		return tostring(a.BuyerName or ""):lower() == tostring(b.BuyerName or ""):lower()
	end

	local function minDeadline(jobs)
		local best = nil

		for _, job in ipairs(jobs) do
			local d = tonumber(job.DeadlineUnix or 0) or 0

			if d > 0 and (best == nil or d < best) then
				best = d
			end
		end

		return best or 0
	end

	local function makeTradeGroup(firstJob, pending)
		if Config.QueueGroupSameBuyerTrades ~= true then
			return firstJob
		end

		if firstJob.DeliveryMode ~= "Trade" then
			return firstJob
		end

		local group = {}

		for _, job in ipairs(pending) do
			if job.DeliveryMode == "Trade" and sameBuyer(firstJob, job) and findPlayer(job.BuyerName, job.BuyerUserId) then
				table.insert(group, job)
			end
		end

		sortJobs(group)

		if #group <= 1 then
			return firstJob
		end

		local groupId = "group-" .. getBridgeId(group[1]) .. "-x" .. tostring(#group)
		local combined = {}

		for k, v in pairs(group[1]) do
			combined[k] = v
		end

		combined.BridgeId = groupId
		combined.Grouped = true
		combined.GroupJobs = group
		combined.DeliveryMode = "Trade"
		combined.DeadlineUnix = minDeadline(group)

		Logger.info("Grouped same-buyer trade jobs:", tostring(combined.BuyerName), "jobs=", #group)

		return combined
	end

	local function chooseNextJob(jobs)
		local pending, expiredCount = cleanJobs(jobs)
		local ready = {}

		for _, bridge in ipairs(pending) do
			if bridge.DeliveryMode == "Supply" or bridge.DeliveryMode == "SupplyThenTrade" then
				table.insert(ready, bridge)
			elseif findPlayer(bridge.BuyerName, bridge.BuyerUserId) then
				table.insert(ready, bridge)
			end
		end

		sortJobs(ready)
		sortJobs(pending)

		if #ready > 0 then
			local selected = makeTradeGroup(ready[1], pending)
			return selected, "buyer_ready", #pending, #ready, expiredCount
		end

		if Config.QueueProcessOnlyReadyBuyers == false and #pending > 0 then
			return pending[1], "oldest_pending", #pending, #ready, expiredCount
		end

		return nil, "no_ready_buyers", #pending, #ready, expiredCount
	end

	local function runBridge(bridge)
		local bridgeId = getBridgeId(bridge)

		if processed[bridgeId] and not bridge.Grouped then
			return
		end

		if busy then
			Logger.warn("Bridge detected but already busy:", bridgeId)
			return
		end

		busy = true
		if Heartbeat and Heartbeat.SetJob then
			Heartbeat.SetJob(bridge)
			Heartbeat.SetPhase("job_started", { BridgeId = bridgeId, safeToRetry = true, dangerous = false })
		end
		markProcessed(bridge)

		if Logger.clear then
			Logger.clear()
		end

		Logger.info("New bridge detected:", bridgeId)

		ctx.Bridge = bridge
		getgenv().AutoTradeBridge = bridge

		local ok, result, reason = pcall(function()
			return ctx.Modules.Main.Start(ctx)
		end)

		if not ok then
			Logger.error("Bridge run crashed:", result)

			if Heartbeat and Heartbeat.SetPhase then
				Heartbeat.SetPhase("lua_error_failed", { reason = tostring(result), safeToRetry = true, dangerous = false })
			end

			if type(bridge.GroupJobs) == "table" and Logger.writeGroupResults then
				Logger.writeGroupResults(bridge.GroupJobs, false, tostring(result), {
					GroupId = bridgeId,
					crashed = true,
				})
			else
				failBridge(bridge, tostring(result), { crashed = true })
			end
		else
			Logger.info("Bridge run finished:", tostring(result), tostring(reason or ""))

			if Heartbeat and Heartbeat.SetPhase then
				Heartbeat.SetPhase(result == true and "completed" or "failed", { reason = tostring(reason or ""), safeToRetry = result ~= true, dangerous = false })
			end
		end

		busy = false

		if Heartbeat and Heartbeat.ClearJob then
			Heartbeat.ClearJob()
		end
	end

	function BridgeWatcher.Start()
		if Heartbeat and Heartbeat.Start then
			Heartbeat.Start()
			Heartbeat.SetPhase("waiting_queue", { safeToRetry = true, dangerous = false })
		end

		Logger.info("Bridge watcher started.")
		Logger.info("Watching file:", BRIDGE_FILE)
		Logger.info("Poll seconds:", POLL_SECONDS)

		while getgenv().AutoTradeStop ~= true do
			if not busy then
				local data, err = readBridgeFile()

				if data then
					lastIdleReason = nil

					local jobs = extractJobs(data)
					local job, reason, pendingCount, readyCount, expiredCount = chooseNextJob(jobs)

					if job then
						if Heartbeat and Heartbeat.SetPhase then
							Heartbeat.SetPhase("queue_job_ready", { safeToRetry = true, dangerous = false })
						end
						Logger.info("Queue state: pending=", pendingCount, "ready=", readyCount, "expired=", expiredCount)
						runBridge(job)
					else
						local message = reason .. " pending=" .. tostring(pendingCount) .. " ready=" .. tostring(readyCount) .. " expired=" .. tostring(expiredCount)

						if lastIdleReason ~= message then
							if Heartbeat and Heartbeat.SetPhase then
								Heartbeat.SetPhase("waiting_queue", { message = message, safeToRetry = true, dangerous = false })
							end
							Logger.info("Waiting for queue job:", message)
							lastIdleReason = message
						end
					end
				else
					if err == "missing" or err == "idle_empty" or err == "idle_empty_object" or err == "idle_invalid_json" then
						if lastIdleReason ~= err then
							Logger.info("Waiting for bridge file job:", err)
							lastIdleReason = err
						end
					else
						Logger.warn("Bridge read skipped:", err)
					end
				end
			end

			task.wait(POLL_SECONDS)
		end

		Logger.warn("Bridge watcher stopped.")
	end

	return BridgeWatcher
end
