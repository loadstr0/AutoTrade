-- AutoTrade/PlayersUtil.lua

return function(ctx)
	local PlayersUtil = {}

	local Players = ctx.Services.Players
	local Logger = ctx.Modules.Logger

	local function cleanName(name)
		return tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
	end

	function PlayersUtil.findPlayer(name)
		name = cleanName(name)

		if name == "" then
			return nil
		end

		local lower = name:lower()

		for _, player in ipairs(Players:GetPlayers()) do
			if player.Name:lower() == lower then
				return player
			end
		end

		for _, player in ipairs(Players:GetPlayers()) do
			if player.DisplayName:lower() == lower then
				return player
			end
		end

		return nil
	end


	function PlayersUtil.findPlayerByUserId(userId)
		userId = tonumber(userId)

		if not userId then
			return nil
		end

		for _, player in ipairs(Players:GetPlayers()) do
			if player.UserId == userId then
				return player
			end
		end

		return nil
	end

	function PlayersUtil.findPlayerExact(name, userId)
		local byId = PlayersUtil.findPlayerByUserId(userId)

		if byId then
			return byId
		end

		return PlayersUtil.findPlayer(name)
	end

	function PlayersUtil.waitForPlayer(name, timeout)
		timeout = timeout or math.huge
		local start = os.clock()

		while os.clock() - start < timeout do
			local player = PlayersUtil.findPlayer(name)

			if player then
				return player
			end

			task.wait(0.25)
		end

		return nil
	end

	function PlayersUtil.getUserIdFromName(name)
		local player = PlayersUtil.findPlayer(name)

		if player then
			return player.UserId, player
		end

		local ok, result = pcall(function()
			return Players:GetUserIdFromNameAsync(name)
		end)

		if ok and result then
			return result, nil
		end

		Logger.warn("Could not resolve Roblox user id for:", name, result)
		return nil, nil
	end

	function PlayersUtil.logPlayers()
		Logger.info("Players currently in server:")

		for _, player in ipairs(Players:GetPlayers()) do
			Logger.info(" -", player.Name, "DisplayName=", player.DisplayName, "UserId=", player.UserId)
		end
	end

	return PlayersUtil
end
