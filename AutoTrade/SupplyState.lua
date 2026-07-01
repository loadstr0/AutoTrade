-- AutoTrade/SupplyState.lua

return function(ctx)
	local SupplyState = {}

	local HttpService = ctx.Services.HttpService
	local Logger = ctx.Modules.Logger

	local DEFAULT_FILE = "autosupply_state.json"
	local VISITED_FILE = "autosupply_visited.json"

	local function getStateFile(config)
		return tostring((config and config.SupplyStateFile) or DEFAULT_FILE)
	end

	local function hasFile(path)
		return typeof(isfile) == "function" and isfile(path)
	end

	local function readJson(path)
		if typeof(readfile) ~= "function" then
			return nil, "readfile_unavailable"
		end

		if hasFile(path) == false then
			return nil, "missing"
		end

		local okRead, raw = pcall(function()
			return readfile(path)
		end)

		if not okRead or not raw or tostring(raw):gsub("%s+", "") == "" then
			return nil, "empty"
		end

		local okDecode, data = pcall(function()
			return HttpService:JSONDecode(raw)
		end)

		if not okDecode or type(data) ~= "table" then
			return nil, "bad_json"
		end

		return data, nil
	end

	local function writeJson(path, data)
		if typeof(writefile) ~= "function" then
			return false, "writefile_unavailable"
		end

		local okEncode, encoded = pcall(function()
			return HttpService:JSONEncode(data)
		end)

		if not okEncode then
			return false, "json_encode_failed:" .. tostring(encoded)
		end

		local okWrite, err = pcall(function()
			writefile(path, encoded)
		end)

		if not okWrite then
			return false, tostring(err)
		end

		return true
	end

	local function bridgeIdOf(config)
		return tostring((config and config.BridgeId) or "")
	end

	function SupplyState.Load(config)
		local data = readJson(getStateFile(config))
		if type(data) ~= "table" then
			return nil
		end

		local currentBridgeId = bridgeIdOf(config)
		local stateBridgeId = tostring(data.BridgeId or "")

		if currentBridgeId ~= "" and stateBridgeId ~= "" and currentBridgeId ~= stateBridgeId then
			Logger.warn("Ignoring stale supply state for different BridgeId:", stateBridgeId, "current", currentBridgeId)
			return nil
		end

		return data
	end

	function SupplyState.Save(config, state)
		state = state or {}
		state.BridgeId = state.BridgeId or bridgeIdOf(config)
		state.UpdatedAt = os.time()
		state.PlaceId = game.PlaceId
		state.JobId = game.JobId

		local ok, err = writeJson(getStateFile(config), state)
		if ok then
			Logger.info("Supply state saved:", tostring(state.Stage or "?"))
		else
			Logger.warn("Supply state save failed:", tostring(err))
		end
		return ok, err
	end

	function SupplyState.Clear(config)
		if typeof(writefile) == "function" then
			pcall(function()
				writefile(getStateFile(config), "")
			end)
		end
		Logger.info("Supply state cleared.")
	end

	function SupplyState.ReadVisited()
		local data = readJson(VISITED_FILE)
		if type(data) ~= "table" then
			return {}
		end
		return data
	end

	function SupplyState.MarkVisited(guid)
		guid = tostring(guid or "")
		if guid == "" then
			return
		end

		local visited = SupplyState.ReadVisited()
		visited[guid] = os.time()
		writeJson(VISITED_FILE, visited)
	end

	function SupplyState.ClearVisited()
		writeJson(VISITED_FILE, {})
		Logger.info("Supply visited cache cleared.")
	end

	return SupplyState
end
