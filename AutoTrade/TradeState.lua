-- AutoTrade/TradeState.lua

return function(ctx)
	local TradeState = {}

	local Players = ctx.Services.Players
	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger

	local LocalPlayer = Players.LocalPlayer

	local function lower(text)
		return tostring(text or ""):lower()
	end

	local function isGuiVisible(obj)
		if obj:IsA("ScreenGui") then
			return obj.Enabled
		end

		if obj:IsA("GuiObject") then
			return obj.Visible
		end

		return false
	end

	local function hasTradeWords(root)
		local tradeWords = {
			"ready",
			"confirm",
			"cancel",
			"trade",
			"your offer",
			"their offer",
			"accept",
		}

		local foundWords = 0

		for _, obj in ipairs(root:GetDescendants()) do
			if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
				local text = lower(obj.Text)

				for _, word in ipairs(tradeWords) do
					if text:find(word, 1, true) then
						foundWords += 1
						break
					end
				end
			end
		end

		return foundWords >= 2
	end

	local function isTradeGuiOpen()
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")

		if not playerGui then
			return false
		end

		for _, obj in ipairs(playerGui:GetDescendants()) do
			local name = lower(obj.Name)
			local fullName = lower(obj:GetFullName())

			if name:find("trade", 1, true) or fullName:find("trading", 1, true) then
				if isGuiVisible(obj) then
					if hasTradeWords(obj) then
						return true, obj:GetFullName()
					end
				end
			end
		end

		return false
	end

	local function tryRequire(pathParts)
		local current = game

		for _, part in ipairs(pathParts) do
			current = current:FindFirstChild(part)

			if not current then
				return nil
			end
		end

		local ok, result = pcall(require, current)

		if ok then
			return result
		end

		return nil
	end

	local function tryGetReplionClient()
		local paths = {
			{ "ReplicatedStorage", "Packages", "Replion", "Client" },
			{ "ReplicatedStorage", "Packages", "Replion" },
			{ "ReplicatedStorage", "Packages", "_Index", "yetanotherclown_replion@1.0.0", "replion", "Client" },
			{ "ReplicatedStorage", "Packages", "_Index", "yetanotherclown_replion@1.0.0", "replion" },
		}

		for _, path in ipairs(paths) do
			local mod = tryRequire(path)

			if type(mod) == "table" then
				return mod
			end
		end

		return nil
	end

	local function hasTradeReplion()
		local replion = tryGetReplionClient()

		if type(replion) ~= "table" then
			return false
		end

		local names = {
			"Trade",
			"Trading",
			"TradeSession",
			"CurrentTrade",
			"TradeState",
		}

		for _, name in ipairs(names) do
			local ok, result = pcall(function()
				if type(replion.Get) == "function" then
					return replion.Get(name)
				end

				if type(replion.GetReplion) == "function" then
					return replion.GetReplion(name)
				end

				if type(replion.WaitReplion) == "function" then
					return replion.WaitReplion(name, 0.1)
				end

				return nil
			end)

			if ok and result ~= nil then
				return true, name
			end
		end

		return false
	end

	function TradeState.isTradeOpen()
		local guiOpen, guiName = isTradeGuiOpen()

		if guiOpen then
			return true, "gui_open:" .. tostring(guiName)
		end

		local replionOpen, replionName = hasTradeReplion()

		if replionOpen then
			return true, "replion_open:" .. tostring(replionName)
		end

		return false, "not_open"
	end

	function TradeState.waitForTradeOpen(timeout)
		timeout = tonumber(timeout or 12) or 12

		Logger.info("Waiting for trade open with timeout:", timeout)

		local start = os.clock()
		local lastLog = 0

		while os.clock() - start < timeout do
			local open, reason = TradeState.isTradeOpen()

			if open then
				Logger.info("Trade open detected:", reason)
				return true, reason
			end

			if os.clock() - lastLog >= 2 then
				Logger.info("Still waiting for trade open...")
				lastLog = os.clock()
			end

			task.wait(0.25)
		end

		Logger.warn("Trade open timeout. Buyer probably declined or ignored the request.")
		return false, "trade_open_timeout"
	end

	TradeState.waitOpen = TradeState.waitForTradeOpen
	TradeState.waitForTrade = TradeState.waitForTradeOpen

	return TradeState
end
