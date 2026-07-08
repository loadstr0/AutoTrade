-- AutoTrade/Logger.lua

return function(ctx)
	local Logger = {}

	Logger.Buffer = {}
	Logger.Prefix = "[AutoTrade]"

	local function stringify(...)
		local parts = {}

		for i = 1, select("#", ...) do
			local v = select(i, ...)
			table.insert(parts, tostring(v))
		end

		return table.concat(parts, " ")
	end

	function Logger.line(level, ...)
		local msg = stringify(...)
		local line = string.format("%s [%s] %s", Logger.Prefix, level, msg)

		table.insert(Logger.Buffer, line)
		print(line)

		return line
	end

	function Logger.info(...)
		return Logger.line("INFO", ...)
	end

	function Logger.warn(...)
		return Logger.line("WARN", ...)
	end

	function Logger.error(...)
		return Logger.line("ERROR", ...)
	end

	function Logger.dumpTable(title, t)
		Logger.info(title)

		if type(t) ~= "table" then
			Logger.info("  ", tostring(t))
			return
		end

		for k, v in pairs(t) do
			if type(v) ~= "table" then
				Logger.info("  ", tostring(k), "=", tostring(v))
			elseif k == "GroupJobs" then
				Logger.info("  ", tostring(k), "=", "table length", tostring(#v))
			else
				Logger.info("  ", tostring(k), "=", "table")
			end
		end
	end

	function Logger.clear()
		table.clear(Logger.Buffer)

		if getgenv().AutoTradeClearConsole == true and typeof(rconsoleclear) == "function" then
			pcall(rconsoleclear)
		end
	end

	local function encodeResult(result)
		local okJson, encoded = pcall(function()
			return ctx.Services.HttpService:JSONEncode(result)
		end)

		if not okJson then
			Logger.warn("Could not encode result JSON:", encoded)
			return nil
		end

		return encoded
	end

	local function writeResultFile(resultFile, result)
		local encoded = encodeResult(result)

		if not encoded then
			return false
		end

		if typeof(writefile) == "function" then
			local okWrite, err = pcall(function()
				writefile(resultFile, encoded)
			end)

			if okWrite then
				Logger.info("Wrote result file:", resultFile)
				return true
			end

			Logger.warn("writefile failed:", err)
			return false
		end

		Logger.warn("writefile is not available, cannot write result file.")
		return false
	end

	function Logger.makeResult(success, reason, extra)
		extra = extra or {}

		return {
			success = success == true,
			status = success and "success" or "failed",
			reason = reason or "",
			time = os.time(),
			logs = Logger.Buffer,
			extra = extra,
			BridgeId = extra.BridgeId,
			GroupId = extra.GroupId,
		}
	end

	function Logger.writeResultForBridge(bridge, success, reason, extra)
		extra = extra or {}
		bridge = bridge or {}

		local bridgeId = tostring(bridge.BridgeId or extra.BridgeId or "")
		local resultFile = tostring(bridge.ResultFile or extra.ResultFile or "")

		if resultFile == "" then
			resultFile = "autotrade_result" .. (bridgeId ~= "" and ("_" .. bridgeId) or "") .. ".json"
		end

		extra.BridgeId = bridgeId
		extra.BuyerName = bridge.BuyerName or extra.BuyerName
		extra.DeliveryMode = bridge.DeliveryMode or extra.DeliveryMode
		extra.ItemName = bridge.ItemName or extra.ItemName
		extra.ItemType = bridge.ItemType or extra.ItemType
		extra.ProductName = bridge.ProductName or extra.ProductName
		extra.ProductId = bridge.ProductId or extra.ProductId
		extra.Quantity = bridge.Quantity or extra.Quantity
		extra.OrderQuantity = bridge.OrderQuantity or extra.OrderQuantity

		local result = Logger.makeResult(success, reason, extra)
		return writeResultFile(resultFile, result)
	end

	function Logger.writeResult(success, reason, extra)
		extra = extra or {}

		local resultFile =
			(ctx.Config and ctx.Config.ResultFile)
			or (ctx.Bridge and ctx.Bridge.ResultFile)
			or "autotrade_result.json"

		local result = Logger.makeResult(success, reason, extra)
		return writeResultFile(resultFile, result)
	end

	function Logger.writeGroupResults(groupJobs, success, reason, extra)
		if type(groupJobs) ~= "table" then
			return false
		end

		local any = false

		for _, bridge in ipairs(groupJobs) do
			local e = {}

			for k, v in pairs(extra or {}) do
				e[k] = v
			end

			e.Grouped = #groupJobs > 1
			e.GroupSize = #groupJobs

			if Logger.writeResultForBridge(bridge, success, reason, e) then
				any = true
			end
		end

		return any
	end

	return Logger
end
