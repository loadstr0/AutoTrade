-- AutoTrade/GAG2/Main.lua
--
-- Entry point Loader.lua calls once it has required every GAG2 module
-- into ctx.Modules and set ctx.Bridge to the current job's payload
-- (mirrors AutoTrade/BB/Main.lua's shape: ctx.Modules.Main.Start(ctx)).
--
-- GAG2 only has one delivery mode implemented so far (MailboxGift) --
-- unlike BB's Main.lua, which dispatches across Gift/TokenTrade/Trade/
-- SupplyThenTrade, this dispatcher intentionally has a single branch and
-- fails loudly on anything else, since there is no other GAG2 delivery
-- path built yet.
--
-- Supports the same GroupJobs batching convention as BB (multiple orders
-- for the same buyer bundled into ctx.Bridge.GroupJobs so they can be
-- sent as fewer, larger SendBatch calls instead of one-by-one) -- each
-- job in the group is resolved and sent independently through
-- MailboxGiftMain, in order, since SendBatch itself has no native
-- "merge multiple orders" concept.

return function(ctx)
	local Main = {}

	local Logger = ctx.Modules.Logger
	local Heartbeat = ctx.Modules.Heartbeat
	local Config = ctx.Modules.Config
	local MailboxGiftMain = ctx.Modules.MailboxGiftMain

	local function runOne(bridge)
		local resolved = Config.Resolve({ Bridge = bridge })
		local valid, reason = Config.Validate(resolved)

		if not valid then
			Logger.error("[Main] Config validation failed:", reason)
			Logger.writeResultForBridge(bridge, false, reason)
			return false, reason
		end

		if resolved.DeliveryMode ~= "MailboxGift" then
			local err = "unsupported_delivery_mode:" .. tostring(resolved.DeliveryMode)
			Logger.error("[Main]", err)
			Logger.writeResultForBridge(bridge, false, err)
			return false, err
		end

		return MailboxGiftMain.Start(resolved)
	end

	function Main.Start(runtimeCtx)
		runtimeCtx = runtimeCtx or ctx
		local bridge = runtimeCtx.Bridge or {}

		Logger.info("[Main] GAG2 AutoTrade starting. PlaceId=", game.PlaceId, "JobId=", game.JobId)

		if Heartbeat then
			Heartbeat.Start()
		end

		if type(bridge.GroupJobs) == "table" and #bridge.GroupJobs > 0 then
			Logger.info("[Main] Processing", #bridge.GroupJobs, "grouped job(s).")

			local anyFailed = false

			for i, job in ipairs(bridge.GroupJobs) do
				Logger.info("[Main] Group job", i, "of", #bridge.GroupJobs)

				local ok, reason = runOne(job)

				if not ok then
					anyFailed = true
					Logger.warn("[Main] Group job", i, "failed:", reason)
				end
			end

			return not anyFailed
		end

		local ok, reason = runOne(bridge)
		return ok, reason
	end

	return Main
end
