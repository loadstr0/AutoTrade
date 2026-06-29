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

		if raw == "" then
			return nil, "empty"
		end

		local okDecode, data = pcall(function()
			return HttpService:JSONDecode(raw)
		end)

		if not okDecode then
			return nil, "json_decode_failed: " .. tostring(data)
		end

		if type(data) ~= "table" then
			return nil, "json_not_table"
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

		-- fallback if Python forgot BridgeId
		return table.concat({
			tostring(bridge.BuyerName or ""),
			tostring(bridge.DeliveryMode or ""),
			tostring(bridge.ItemName or ""),
			tostring(bridge.ProductName or ""),
			tostring(bridge.OrderTitle or ""),
		}, "|")
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
				runBridge(bridge)
			elseif err ~= "missing" then
				Logger.warn("Bridge read skipped:", err)
			end

			task.wait(POLL_SECONDS)
		end

		Logger.warn("Bridge watcher stopped.")
	end

	return BridgeWatcher
end
