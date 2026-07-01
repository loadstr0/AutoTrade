-- AutoTrade/SupplyState.lua
-- Max-safety persistent state for Trading Plaza auto-supply.
-- Never hides an unknown/dangerous purchase state. If the script crashes after a buy is sent,
-- the next run must verify/manual-check; it must not blindly buy again.

return function(ctx)
	local SupplyState = {}

	local HttpService = ctx.Services.HttpService
	local Logger = ctx.Modules.Logger

	local DEFAULT_STATE_FILE = "autosupply_state.json"
	local DEFAULT_VISITED_FILE = "autosupply_visited.json"
	local DEFAULT_LEDGER_FILE = "autosupply_spend_ledger.json"

	local DANGEROUS_STAGES = {
		supply_buy_invoking = true,
		supply_buy_sent = true,
		supply_buy_sent_waiting_result = true,
		supply_waiting_purchase_result = true,
		supply_purchase_unconfirmed = true,
		supply_tokens_decreased_item_missing = true,
		supply_manual_check_required = true,
	}

	local function now()
		return os.time()
	end

	local function str(value)
		return tostring(value or "")
	end

	local function hasText(value)
		return type(value) == "string" and value:gsub("%s+", "") ~= ""
	end

	local function getStateFile(config)
		return str((config and config.SupplyStateFile) or DEFAULT_STATE_FILE)
	end

	local function getVisitedFile(config)
		return str((config and config.SupplyVisitedFile) or DEFAULT_VISITED_FILE)
	end

	local function getLedgerFile(config)
		return str((config and config.SupplySpendLedgerFile) or DEFAULT_LEDGER_FILE)
	end

	local function canRead()
		return typeof(readfile) == "function"
	end

	local function canWrite()
		return typeof(writefile) == "function"
	end

	local function hasFile(path)
		if typeof(isfile) == "function" then
			local ok, exists = pcall(function()
				return isfile(path)
			end)
			return ok and exists == true
		end
		return true
	end

	local function readText(path)
		if not canRead() then
			return nil, "readfile_unavailable"
		end

		if not hasFile(path) then
			return nil, "missing"
		end

		local ok, raw = pcall(function()
			return readfile(path)
		end)

		if not ok then
			return nil, "read_failed:" .. str(raw)
		end

		raw = str(raw)
		if not hasText(raw) then
			return nil, "empty"
		end

		return raw, nil
	end

	local function readJson(path)
		local raw, err = readText(path)
		if not raw then
			return nil, err
		end

		local ok, data = pcall(function()
			return HttpService:JSONDecode(raw)
		end)

		if not ok or type(data) ~= "table" then
			return nil, "bad_json"
		end

		return data, nil
	end

	local function writeJson(path, data)
		if not canWrite() then
			return false, "writefile_unavailable"
		end

		local okEncode, encoded = pcall(function()
			return HttpService:JSONEncode(data or {})
		end)

		if not okEncode then
			return false, "json_encode_failed:" .. str(encoded)
		end

		-- Two-step write helps avoid half-written JSON if executor/file system hiccups.
		local tmp = path .. ".tmp"
		local okTmp, tmpErr = pcall(function()
			writefile(tmp, encoded)
		end)

		if not okTmp then
			return false, "tmp_write_failed:" .. str(tmpErr)
		end

		local okFinal, finalErr = pcall(function()
			writefile(path, encoded)
		end)

		if not okFinal then
			return false, "final_write_failed:" .. str(finalErr)
		end

		return true
	end

	local function bridgeIdOf(config)
		return str((config and config.BridgeId) or "")
	end

	function SupplyState.IsDangerous(state)
		if type(state) ~= "table" then
			return false
		end

		if state.Dangerous == true or state.safeToRetry == false or state.SafeToRetry == false then
			return true
		end

		return DANGEROUS_STAGES[str(state.Stage)] == true
	end

	function SupplyState.LoadRaw(config)
		local data = readJson(getStateFile(config))
		if type(data) ~= "table" then
			return nil
		end
		return data
	end

	function SupplyState.Load(config)
		local data = SupplyState.LoadRaw(config)
		if type(data) ~= "table" then
			return nil
		end

		local currentBridgeId = bridgeIdOf(config)
		local stateBridgeId = str(data.BridgeId)

		if currentBridgeId ~= "" and stateBridgeId ~= "" and currentBridgeId ~= stateBridgeId then
			if SupplyState.IsDangerous(data) and (not config or config.SupplyDangerousStateBlocksNewOrders ~= false) then
				Logger.error("Blocking new supply job because stale dangerous supply state exists:", stateBridgeId, "current", currentBridgeId)
				return {
					Stage = "stale_dangerous_block",
					Dangerous = true,
					SafeToRetry = false,
					BridgeId = currentBridgeId,
					StaleBridgeId = stateBridgeId,
					StaleStage = data.Stage,
					StaleState = data,
				}
			end

			Logger.warn("Ignoring stale non-dangerous supply state:", stateBridgeId, "current", currentBridgeId)
			return nil
		end

		return data
	end

	function SupplyState.Save(config, state)
		state = state or {}
		state.BridgeId = state.BridgeId or bridgeIdOf(config)
		state.UpdatedAt = now()
		state.PlaceId = game.PlaceId
		state.JobId = game.JobId
		state.Dangerous = SupplyState.IsDangerous(state)
		state.SafeToRetry = not state.Dangerous

		local ok, err = writeJson(getStateFile(config), state)
		if ok then
			Logger.info("Supply state saved:", str(state.Stage), "dangerous=", str(state.Dangerous))
		else
			Logger.warn("Supply state save failed:", str(err))
		end
		return ok, err
	end

	function SupplyState.MarkManualCheck(config, state, reason)
		state = state or {}
		state.Stage = "supply_manual_check_required"
		state.Reason = str(reason or state.Reason or "manual_check_required")
		state.Dangerous = true
		state.SafeToRetry = false
		SupplyState.Save(config, state)
		return state
	end

	function SupplyState.Clear(config)
		if canWrite() then
			pcall(function()
				writefile(getStateFile(config), "")
			end)
		end
		Logger.info("Supply state cleared.")
	end

	local function pruneMap(map, ttlSeconds)
		local cutoff = now() - math.max(60, tonumber(ttlSeconds or 3600) or 3600)
		local out = {}
		for k, v in pairs(map or {}) do
			local ts = tonumber(v)
			if ts and ts >= cutoff then
				out[k] = ts
			end
		end
		return out
	end

	function SupplyState.ReadVisited(config)
		local data = readJson(getVisitedFile(config))
		if type(data) ~= "table" then
			return {}
		end
		return pruneMap(data, (config and config.SupplyVisitedTtlSeconds) or 3600)
	end

	function SupplyState.MarkVisited(config, guid)
		guid = str(guid)
		if guid == "" then
			return
		end

		local visited = SupplyState.ReadVisited(config)
		visited[guid] = now()
		writeJson(getVisitedFile(config), visited)
	end

	function SupplyState.ClearVisited(config)
		writeJson(getVisitedFile(config), {})
		Logger.info("Supply visited cache cleared.")
	end

	function SupplyState.ReadLedger(config)
		local data = readJson(getLedgerFile(config))
		if type(data) ~= "table" then
			return {}
		end

		local cutoff = now() - math.max(3600, tonumber((config and config.SupplySpendLedgerTtlSeconds) or 86400) or 86400)
		local out = {}
		for _, row in ipairs(data) do
			if type(row) == "table" and tonumber(row.Time or 0) and tonumber(row.Time or 0) >= cutoff then
				table.insert(out, row)
			end
		end
		return out
	end

	function SupplyState.GetSpentInLastHour(config)
		local rows = SupplyState.ReadLedger(config)
		local cutoff = now() - 3600
		local total = 0
		for _, row in ipairs(rows) do
			if tonumber(row.Time or 0) and tonumber(row.Time or 0) >= cutoff then
				total += tonumber(row.Price or 0) or 0
			end
		end
		return total
	end

	function SupplyState.AppendSpend(config, spend)
		local rows = SupplyState.ReadLedger(config)
		spend = spend or {}
		spend.Time = spend.Time or now()
		spend.BridgeId = spend.BridgeId or bridgeIdOf(config)
		table.insert(rows, spend)
		local ok, err = writeJson(getLedgerFile(config), rows)
		if not ok then
			Logger.warn("Could not append supply spend ledger:", str(err))
		end
		return ok, err
	end

	return SupplyState
end
