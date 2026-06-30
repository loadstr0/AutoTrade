-- AutoTrade/Main.lua

return function(ctx)
	local Main = {}

	local function copyTable(source)
		local out = {}

		if type(source) ~= "table" then
			return out
		end

		for k, v in pairs(source) do
			out[k] = v
		end

		return out
	end

	local function getBridgeJobs(bridge)
		if type(bridge) == "table" and type(bridge.GroupJobs) == "table" and #bridge.GroupJobs > 0 then
			return bridge.GroupJobs
		end

		if type(bridge) == "table" then
			return { bridge }
		end

		return {}
	end

	function Main.Start()
		local Logger = ctx.Modules.Logger
		local Config = ctx.Modules.Config

		ctx.Config = Config.Resolve and Config.Resolve(ctx) or Config.Get(ctx)
		local resolved = ctx.Config

		Logger.dumpTable("Bridge payload:", ctx.Bridge)
		Logger.dumpTable("Resolved Config:", {
			BuyerName = resolved.BuyerName,
			BuyerUserId = resolved.BuyerUserId,
			DeliveryMode = resolved.DeliveryMode,
			ItemName = resolved.ItemName,
			ItemType = resolved.ItemType,
			ProductName = resolved.ProductName,
			ProductId = resolved.ProductId,
			Quantity = resolved.Quantity,
			OrderQuantity = resolved.OrderQuantity,
			BridgeId = resolved.BridgeId,
			DeadlineUnix = resolved.DeadlineUnix,
			Grouped = resolved.Grouped,
			GroupJobs = resolved.GroupJobs,
			GiftWithTokens = resolved.GiftWithTokens,
			GiftDryRun = resolved.GiftDryRun,
			AllowTokenSpend = resolved.AllowTokenSpend,
			RequireTokenBalanceDecrease = resolved.RequireTokenBalanceDecrease,
		})

		local valid = true
		local err = nil

		if Config.Validate then
			valid, err = Config.Validate(resolved)
		end

		if not valid then
			Logger.error(err)

			if type(resolved.GroupJobs) == "table" then
				Logger.writeGroupResults(resolved.GroupJobs, false, err, {
					GroupId = resolved.BridgeId,
					DeliveryMode = resolved.DeliveryMode,
				})
			else
				Logger.writeResult(false, err)
			end

			return false, err
		end

		local ok = false
		local reason = "unknown"

		if resolved.DeliveryMode == "Gift" then
			ok, reason = ctx.Modules.GiftMain.Start(resolved)
		elseif resolved.DeliveryMode == "Trade" then
			ok, reason = ctx.Modules.TradeMain.Start(resolved)
		else
			ok = false
			reason = "unknown_delivery_mode"
		end

		Logger.info("Finished:", tostring(ok), tostring(reason))

		local extra = {
			BridgeId = resolved.BridgeId,
			GroupId = resolved.Grouped and resolved.BridgeId or nil,
			Grouped = resolved.Grouped == true,
			GroupSize = type(resolved.GroupJobs) == "table" and #resolved.GroupJobs or 1,
			DeliveryMode = resolved.DeliveryMode,
			BuyerName = resolved.BuyerName,
			BuyerUserId = resolved.BuyerUserId,
			ItemName = resolved.ItemName,
			ItemType = resolved.ItemType,
			ProductName = resolved.ProductName,
			ProductId = resolved.ProductId,
		}

		local jobs = getBridgeJobs(ctx.Bridge)

		if resolved.Grouped == true and #jobs > 0 then
			Logger.writeGroupResults(jobs, ok, reason, extra)
		else
			Logger.writeResult(ok, reason, extra)
		end

		return ok, reason
	end

	return Main
end
