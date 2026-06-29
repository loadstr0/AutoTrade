-- AutoTrade/BridgeWatcher.lua

return function(ctx)
	local BridgeWatcher = {}

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

	local function readBridgeFile()
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
			return nil, "read_failed: " .. tostring(raw)
		end

		raw = tostring(raw or "")

		-- Empty file = no job yet.
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

		-- Empty JSON object {} = no job yet.
		if next(data) == nil then
			return nil, "idle_empty_object"
		end

		return data, nil
	end

	local function getBridgeId(bridge)
		local id =
			bridge.BridgeId
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

	local function isValidBridge(bridge)
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

	local function runBridge(bridge)
		local valid, reason = isValidBridge(bridge)

		if not valid then
			Logger.warn("Bridge ignored:", reason)
			return
		end

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
			local bridge, err = readBridgeFile()

			if bridge then
				lastIdleReason = nil
				runBridge(bridge)
			else
				-- These are normal idle states. Do not spam warnings.
				if err == "missing" or err == "idle_empty" or err == "idle_empty_object" or err == "idle_invalid_json" then
					if lastIdleReason ~= err then
						Logger.info("Waiting for bridge file job:", err)
						lastIdleReason = err
					end
				else
					Logger.warn("Bridge read skipped:", err)
				end
			end

			task.wait(POLL_SECONDS)
		end

		Logger.warn("Bridge watcher stopped.")
	end

	return BridgeWatcher
end
