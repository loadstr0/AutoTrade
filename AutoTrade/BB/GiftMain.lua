-- AutoTrade/GiftMain.lua

return function(ctx)
	local GiftMain = {}

	local Logger = ctx.Modules.Logger
	local Heartbeat = ctx.Modules.Heartbeat
	local PlayersUtil = ctx.Modules.PlayersUtil
	local ProductResolver = ctx.Modules.ProductResolver
	local GiftActions = ctx.Modules.GiftActions

	local function phase(name, info)
		if Heartbeat and Heartbeat.SetPhase then
			Heartbeat.SetPhase(name, info or {})
		end
	end

	local function resolveBuyer(config)
		local userId = tonumber(config.BuyerUserId)
		local player = nil

		if userId then
			player = PlayersUtil.findPlayerByUserId(userId)
			return userId, player
		end

		return PlayersUtil.getUserIdFromName(config.BuyerName)
	end

	local function describePlan(plan)
		local counts = {}

		for _, product in ipairs(plan.steps or {}) do
			local key = tostring(product.amount or product.displayName or product.productId)
			counts[key] = (counts[key] or 0) + 1
		end

		local parts = {}

		for key, count in pairs(counts) do
			table.insert(parts, tostring(key) .. "x" .. tostring(count))
		end

		table.sort(parts)

		return table.concat(parts, ", ")
	end

	function GiftMain.Start(config)
		phase("gift_start", { safeToRetry = true, dangerous = false })

		Logger.info("Starting gift delivery.")

		local userId, player = resolveBuyer(config)

		if not userId then
			PlayersUtil.logPlayers()
			return false, "buyer_userid_not_found"
		end

		if player then
			Logger.info("Buyer found in server:", player.Name, player.UserId)
		else
			Logger.warn("Buyer not found as Player instance, but userId resolved:", userId)
		end

		local plan, planReason = ProductResolver.buildGiftPlan(config)

		if not plan or type(plan.steps) ~= "table" or #plan.steps == 0 then
			Logger.warn("Could not build gift plan:", tostring(planReason))
			return false, tostring(planReason or "gift_plan_failed")
		end

		local maxSends = tonumber(config.GiftMaxSendsPerOrder or config.MaxGiftSendsPerOrder or 50) or 50

		if #plan.steps > maxSends then
			Logger.warn("Gift plan has too many sends:", #plan.steps, "max=", maxSends)
			return false, "gift_plan_too_many_sends"
		end

		Logger.info("Gift plan mode:", tostring(plan.mode))
		Logger.info("Gift plan display:", tostring(plan.display))
		Logger.info("Gift plan steps:", tostring(#plan.steps), describePlan(plan))

		local lastReason = nil
		local delayBetween = tonumber(config.GiftSendDelay or config.GiftRetryDelay or 2.5) or 2.5

		for i, product in ipairs(plan.steps) do
			phase("gift_attempt", {
				attempt = i,
				total = #plan.steps,
				ProductId = product.productId,
				PackAmount = product.amount,
				safeToRetry = true,
				dangerous = false,
			})

			Logger.info(("Gift step %d/%d: %s id=%s amount=%s"):format(
				i,
				#plan.steps,
				tostring(product.displayName or product.key or "?"),
				tostring(product.productId),
				tostring(product.amount or "?")
			))

			local ok, reason = GiftActions.sendGift(config, userId, product)

			if not ok then
				lastReason = reason
				Logger.warn("Gift step failed:", tostring(reason))
				return false, reason
			end

			if i < #plan.steps then
				phase("gift_wait_between_sends", {
					attempt = i,
					nextAttempt = i + 1,
					total = #plan.steps,
					delay = delayBetween,
					safeToRetry = false,
					dangerous = false,
				})

				Logger.info("Waiting before next gift send:", delayBetween, "seconds")
				task.wait(delayBetween)
			end
		end

		phase("completed", { safeToRetry = false, dangerous = false, giftsSent = #plan.steps })

		return true, "gift_plan_sent"
	end

	return GiftMain
end
