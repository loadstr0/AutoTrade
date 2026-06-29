-- AutoTrade/TradeActions.lua

return function(ctx)
	local TradeActions = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger

	local TradeInfo = require(ReplicatedStorage.Shared.Trading.TradeInfo)
	local Remotes = TradeInfo.Remotes

	local function invoke(name, ...)
		local remote = Remotes[name]

		if not remote then
			Logger.error("Missing trade remote:", name)
			return false, "missing_remote"
		end

		local ok, result = pcall(function(...)
			return remote:InvokeServer(...)
		end, ...)

		if not ok then
			Logger.error(name, "failed:", result)
			return false, result
		end

		Logger.info(name, "=>", tostring(result))
		return result, nil
	end

	function TradeActions.sendRequest(player)
		return invoke("SendTradeRequest", player)
	end

	function TradeActions.addItem(itemType, item)
		return invoke("AddItemToTrade", itemType, item)
	end

	function TradeActions.ready()
		return invoke("ReadyUp")
	end

	function TradeActions.confirm()
		return invoke("ConfirmTrade")
	end

	function TradeActions.cancel()
		return invoke("CancelTrade")
	end

	return TradeActions
end
