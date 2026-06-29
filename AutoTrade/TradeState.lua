-- AutoTrade/TradeState.lua

return function(ctx)
	local TradeState = {}

	local Players = ctx.Services.Players
	local Logger = ctx.Modules.Logger

	local LocalPlayer = Players.LocalPlayer

	local BLOCKED_GUI_PATH_WORDS = {
		"duelframes",
		"duel",
		"abilities",
		"ability",
		"spectate",
	}

	local REQUIRED_TRADE_WORDS = {
		"ready",
		"confirm",
		"cancel",
		"your",
		"offer",
		"their",
	}

	local function lower(text)
		return tostring(text or ""):lower()
	end

	local function isVisible(obj)
		if obj:IsA("ScreenGui") then
			return obj.Enabled
		end

		if obj:IsA("GuiObject") then
			return obj.Visible
		end

		return false
	end

	local function pathBlocked(obj)
		local path = lower(obj:GetFullName())

		for _, word in ipairs(BLOCKED_GUI_PATH_WORDS) do
			if path:find(word, 1, true) then
				return true, word
			end
		end

		return false
	end

	local function countTradeWords(root)
		local found = {}

		for _, obj in ipairs(root:GetDescendants()) do
			if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
				local text = lower(obj.Text)

				for _, word in ipairs(REQUIRED_TRADE_WORDS) do
					if text:find(word, 1, true) then
						found[word] = true
					end
				end
			end
		end

		local count = 0

		for _ in pairs(found) do
			count += 1
		end

		return count
	end

	local function findRealTradeGui()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")

		if not playerGui then
			return nil, "no_player_gui"
		end

		local bestObj = nil
		local bestScore = 0

		for _, obj in ipairs(playerGui:GetDescendants()) do
			local name = lower(obj.Name)
			local path = lower(obj:GetFullName())

			if isVisible(obj) then
				local blocked = pathBlocked(obj)

				if not blocked then
					local nameLooksTrade =
						name:find("trade", 1, true)
						or path:find("trading", 1, true)
						or path:find("tradeframe", 1, true)
						or path:find("tradeview", 1, true)

					if nameLooksTrade then
						local score = countTradeWords(obj)

						if score > bestScore then
							bestScore = score
							bestObj = obj
						end
					end
				end
			end
		end

		if bestObj and bestScore >= 3 then
			return bestObj, "score_" .. tostring(bestScore)
		end

		return nil, "no_real_trade_gui"
	end

	function TradeState.isTradeOpen()
		local gui, reason = findRealTradeGui()

		if gui then
			return true, gui:GetFullName() .. " " .. reason
		end

		return false, reason
	end

	function TradeState.waitForTradeOpen(timeout)
		timeout = tonumber(timeout or 12) or 12

		Logger.info("Waiting for REAL trade open with timeout:", timeout)

		local start = os.clock()
		local lastLog = 0

		while os.clock() - start < timeout do
			local open, reason = TradeState.isTradeOpen()

			if open then
				Logger.info("Real trade open detected:", reason)
				return true, reason
			end

			if os.clock() - lastLog >= 2 then
				Logger.info("Still waiting for real trade open:", tostring(reason))
				lastLog = os.clock()
			end

			task.wait(0.25)
		end

		Logger.warn("Real trade open timeout. Buyer probably declined or ignored.")
		return false, "trade_open_timeout"
	end

	TradeState.waitOpen = TradeState.waitForTradeOpen
	TradeState.waitForTrade = TradeState.waitForTradeOpen

	return TradeState
end
