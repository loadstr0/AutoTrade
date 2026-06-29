-- AutoTrade/TradeState.lua

return function(ctx)
	local TradeState = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger

	local Replion = require(ReplicatedStorage.Packages.Replion)

	function TradeState.getTradeReplion()
		local ok, replion = pcall(function()
			return Replion.Client:GetReplion("Trade")
		end)

		if ok and replion then
			return replion
		end

		ok, replion = pcall(function()
			return Replion.Client:WaitReplion("Trade")
		end)

		if ok and replion then
			return replion
		end

		return nil
	end

	function TradeState.waitForTrade(timeout)
		timeout = timeout or 15
		local start = os.clock()

		while os.clock() - start < timeout do
			local replion = TradeState.getTradeReplion()

			if replion then
				Logger.info("Trade replion found.")
				return replion
			end

			task.wait(0.25)
		end

		return nil
	end

	function TradeState.get(replion, path)
		local ok, result = pcall(function()
			return replion:Get(path)
		end)

		if ok then
			return result
		end

		return nil
	end

	return TradeState
end
