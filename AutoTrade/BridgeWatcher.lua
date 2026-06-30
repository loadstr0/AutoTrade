-- AutoTrade/BridgeWatcher.lua

return function(ctx)
	local BridgeWatcher = {}

	local Players = ctx.Services.Players
	local HttpService = ctx.Services.HttpService
	local Logger = ctx.Modules.Logger

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

		if bridge.DeliveryMode == "Trade" then
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
		else
			return false, "bad DeliveryMode: " .. tostring(bridge.DeliveryMode)
		end

		return true
	end

	local function findPlayer(name)
		name = tostring(name or ""):lower()

		if name == "" then
			return nil
		end

		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Name:lower() == name or plr.DisplayName:lower() == name then
				return plr
			end
		end

		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Name:lower():find(name, 1, true) or plr.DisplayName:lower():find(name, 1, true) then
				return plr
			end
		end

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

	local function chooseNextJob(jobs)
		local pending = {}
		local ready = {}
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
				continue
			end

			if isExpired(bridge) then
				expiredCount += 1
				processed[bridgeId] = true
				Logger.warn("Bridge expired before buyer was ready:", bridgeId)

				if Logger.writeResult then
					local previousBridge = ctx.Bridge
					ctx.Bridge = bridge
					pcall(function()
						Logger.writeResult(false, "deadline_expired", {
							BridgeId = bridgeId,
							expired = true,
						})
					end)
					ctx.Bridge = previousBridge
				end

				continue
			end

			table.insert(pending, bridge)

			if findPlayer(bridge.BuyerName) then
				table.insert(ready, bridge)
			end
		end

		sortJobs(ready)
		sortJobs(pending)

		if #ready > 0 then
			return ready[1], "buyer_ready", #pending, #ready, expiredCount
		end

		return nil, "no_ready_buyers", #pending, #ready, expiredCount
	end

	local function runBridge(bridge)
		local bridgeId = getBridgeId(bridge)

		if processed[bridgeId] then
			return
		end

		if busy then
			Logger.warn("Bridge detected but already busy:", bridgeId)
			return
		end

		busy = true
		processed[bridgeId] = true

		if Logger.clear then
			Logger.clear()
		end

		Logger.info("New bridge detected:", bridgeId)

		ctx.Bridge = bridge
		getgenv().AutoTradeBridge = bridge

		local ok, result = pcall(function()
			return ctx.Modules.Main.Start(ctx)
		end)

		if not ok then
			Logger.error("Bridge run crashed:", result)

			if Logger.writeResult then
				Logger.writeResult(false, tostring(result), {
					BridgeId = bridgeId,
					crashed = true,
				})
			end
		else
			Logger.info("Bridge run finished:", tostring(result))
		end

		busy = false
	end

	function BridgeWatcher.Start()
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
						Logger.info("Queue state: pending=", pendingCount, "ready=", readyCount, "expired=", expiredCount)
						runBridge(job)
					else
						local message = reason .. " pending=" .. tostring(pendingCount) .. " ready=" .. tostring(readyCount) .. " expired=" .. tostring(expiredCount)

						if lastIdleReason ~= message then
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
