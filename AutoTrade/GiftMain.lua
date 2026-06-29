-- AutoTrade/GiftMain.lua

return function(ctx)
	local GiftMain = {}

	local Logger = ctx.Modules.Logger
	local PlayersUtil = ctx.Modules.PlayersUtil
	local ProductResolver = ctx.Modules.ProductResolver
	local GiftActions = ctx.Modules.GiftActions

	function GiftMain.Start(config)
		Logger.info("Starting gift delivery.")

		local userId, player = PlayersUtil.getUserIdFromName(config.BuyerName)

		if not userId then
			PlayersUtil.logPlayers()
			return false, "buyer_userid_not_found"
		end

		if player then
			Logger.info("Buyer found in server:", player.Name, player.UserId)
		else
			Logger.warn("Buyer not found as Player instance, but userId resolved:", userId)
		end

		local product = ProductResolver.resolve(config)

		if not product then
			return false, "product_not_found"
		end

		Logger.info("Resolved product:", product.displayName, "id=" .. tostring(product.productId))

		local repeatCount = math.max(1, tonumber(config.OrderQuantity or 1) or 1)
		Logger.info("OrderQuantity/repeat count:", repeatCount)

		local lastReason = nil

		for i = 1, repeatCount do
			Logger.info(("Gift attempt %d/%d"):format(i, repeatCount))

			local ok, reason = GiftActions.sendGift(config, userId, product)

			if not ok then
				lastReason = reason
				return false, reason
			end

			task.wait(config.GiftRetryDelay or 1)
		end

		return true, "gift_sent"
	end

	return GiftMain
end
