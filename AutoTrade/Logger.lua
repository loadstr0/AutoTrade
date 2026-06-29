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
			Logger.info("  ", tostring(k), "=", tostring(v))
		end
	end

	function Logger.clear()
		table.clear(Logger.Buffer)
	
		if getgenv().AutoTradeClearConsole == true and typeof(rconsoleclear) == "function" then
			pcall(rconsoleclear)
		end
	end

	function Logger.writeResult(success, reason, extra)
		extra = extra or {}

		local result = {
			success = success == true,
			status = success and "success" or "failed",
			reason = reason or "",
			time = os.time(),
			logs = Logger.Buffer,
			extra = extra,
		}

		local okJson, encoded = pcall(function()
			return ctx.Services.HttpService:JSONEncode(result)
		end)

		if not okJson then
			Logger.warn("Could not encode result JSON:", encoded)
			return false
		end

		local resultFile =
			(ctx.Config and ctx.Config.ResultFile)
			or (ctx.Bridge and ctx.Bridge.ResultFile)
			or "autotrade_result.json"

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

	return Logger
end
