-- AutoTrade/RestockWatcher.lua
-- Watches autotrade_restock_request.json and runs RestockAnalyzer automatically.
--
-- This does not touch trades/gifts. It only creates:
--   autotrade_restock_report.json
--   autotrade_restock_debug_log.txt
--   autotrade_restock_status.json

return function(ctx)
	local RestockWatcher = {}

	local HttpService = ctx.Services.HttpService
	local Logger = ctx.Modules.Logger
	local RestockAnalyzer = ctx.Modules.RestockAnalyzer

	local REQUEST_FILE = getgenv().AutoTradeRestockRequestFile or "autotrade_restock_request.json"
	local STATUS_FILE_DEFAULT = getgenv().AutoTradeRestockStatusFile or "autotrade_restock_status.json"
	local POLL_SECONDS = tonumber(getgenv().AutoTradeRestockPollSeconds or 5) or 5

	getgenv().AutoTradeProcessedRestockRequestIds = getgenv().AutoTradeProcessedRestockRequestIds or {}
	local processed = getgenv().AutoTradeProcessedRestockRequestIds

	local function now()
		return os.date("!%Y-%m-%dT%H:%M:%SZ")
	end

	local function hasText(s)
		return type(s) == "string" and s:gsub("%s+", "") ~= ""
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
			return nil, "idle_invalid_json:" .. tostring(data)
		end

		if type(data) ~= "table" then
			return nil, "json_not_table"
		end

		return data, nil
	end

	local function writeJsonFile(path, data)
		if typeof(writefile) ~= "function" then
			if Logger and Logger.warn then
				Logger.warn("RestockWatcher writefile unavailable:", path)
			end
			return false
		end

		local okEncode, encoded = pcall(function()
			return HttpService:JSONEncode(data)
		end)

		if not okEncode then
			if Logger and Logger.warn then
				Logger.warn("RestockWatcher JSON encode failed:", encoded)
			end
			return false
		end

		local okWrite, err = pcall(function()
			writefile(path, encoded)
		end)

		if not okWrite and Logger and Logger.warn then
			Logger.warn("RestockWatcher write failed:", path, err)
		end

		return okWrite
	end

	local function getRequestId(req)
		local id = req.request_id or req.RequestId or req.id or req.created_at
		if id and tostring(id) ~= "" then
			return tostring(id)
		end
		return tostring(req.input_file or "no_input") .. "|" .. tostring(req.output_file or "no_output")
	end

	local function numberOrNil(v)
		local n = tonumber(v)
		if n == nil then
			return nil
		end
		return n
	end

	local function buildOverrides(req)
		local overrides = {}

		overrides.InputFile = tostring(req.input_file or req.InputFile or "autotrade_offers_all.json")
		overrides.OutputFile = tostring(req.output_file or req.OutputFile or "autotrade_restock_report.json")
		overrides.LogFile = tostring(req.log_file or req.LogFile or "autotrade_restock_debug_log.txt")

		if numberOrNil(req.current_tokens) then
			overrides.CurrentTokens = numberOrNil(req.current_tokens)
		end

		if numberOrNil(req.token_rate_per_k_usd) then
			overrides.TokenRatePerKUsd = numberOrNil(req.token_rate_per_k_usd)
		end

		if numberOrNil(req.seller_fee_percent) then
			overrides.SellerFeePercent = numberOrNil(req.seller_fee_percent)
		end

		if numberOrNil(req.token_reserve) then
			overrides.TokenReserve = numberOrNil(req.token_reserve)
		end

		return overrides
	end

	local function writeStatus(req, state, reason, extra)
		extra = extra or {}
		local statusFile = tostring(req.status_file or req.StatusFile or STATUS_FILE_DEFAULT)

		local data = {
			request_id = getRequestId(req),
			state = state,
			reason = tostring(reason or ""),
			time = now(),
			input_file = tostring(req.input_file or "autotrade_offers_all.json"),
			output_file = tostring(req.output_file or "autotrade_restock_report.json"),
			log_file = tostring(req.log_file or "autotrade_restock_debug_log.txt"),
			placeId = game.PlaceId,
			jobId = game.JobId,
		}

		for k, v in pairs(extra) do
			data[k] = v
		end

		writeJsonFile(statusFile, data)
	end

	local function process(req)
		local requestId = getRequestId(req)

		if req.enabled == false then
			return false, "request_disabled"
		end

		if processed[requestId] then
			return false, "already_processed"
		end

		processed[requestId] = true

		if not RestockAnalyzer or type(RestockAnalyzer.Run) ~= "function" then
			writeStatus(req, "failed", "restock_analyzer_missing")
			return false, "restock_analyzer_missing"
		end

		local overrides = buildOverrides(req)

		if Logger and Logger.info then
			Logger.info("Restock request starting:", requestId, "input=", overrides.InputFile, "output=", overrides.OutputFile)
		end

		writeStatus(req, "running", "started", {
			overrides = overrides,
		})

		local ok, reason = RestockAnalyzer.Run(overrides)

		if ok then
			writeStatus(req, "completed", reason or "ok")
			if Logger and Logger.info then
				Logger.info("Restock request completed:", requestId)
			end
			return true, "completed"
		end

		writeStatus(req, "failed", reason or "failed")
		if Logger and Logger.warn then
			Logger.warn("Restock request failed:", requestId, reason)
		end
		return false, reason
	end

	function RestockWatcher.Start()
		if Logger and Logger.info then
			Logger.info("Restock watcher started.")
			Logger.info("Watching file:", REQUEST_FILE)
			Logger.info("Poll seconds:", POLL_SECONDS)
		end

		while getgenv().AutoTradeStop ~= true do
			local req, err = readJsonFile(REQUEST_FILE)

			if req then
				process(req)
			else
				if err ~= "missing" and err ~= "idle_empty" then
					if Logger and Logger.warn then
						Logger.warn("Restock request read skipped:", err)
					end
				end
			end

			task.wait(POLL_SECONDS)
		end

		if Logger and Logger.warn then
			Logger.warn("Restock watcher stopped.")
		end
	end

	return RestockWatcher
end
