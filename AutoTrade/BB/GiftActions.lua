-- AutoTrade/GiftActions.lua

return function(ctx)
	local GiftActions = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger
	local Heartbeat = ctx.Modules.Heartbeat

	local Remotes = ReplicatedStorage:WaitForChild("Remotes")
	local SetGiftTo = Remotes:WaitForChild("SetGiftTo")

	local function getTokenBalance()
		local ok, result = pcall(function()
			local Replion = require(ReplicatedStorage.Packages.Replion)
			local inventory = Replion.Client:WaitReplion("Inventory")
			return inventory:Get("Tokens")
		end)

		if ok and type(result) == "number" then
			return result
		end

		return nil
	end

	local function waitForTokenDecrease(before, timeout)
		if type(before) ~= "number" then
			return false, nil
		end

		local start = os.clock()
		local last = before

		while os.clock() - start < timeout do
			local current = getTokenBalance()

			if type(current) == "number" then
				last = current

				if current < before then
					return true, current
				end
			end

			task.wait(0.5)
		end

		return false, last
	end

	local function phase(name, info)
		if Heartbeat and Heartbeat.SetPhase then
			Heartbeat.SetPhase(name, info or {})
		end
	end

	function GiftActions.sendGift(config, targetUserId, product)
		local productId = tonumber(product.productId)
		local giftMessage = config.GiftMessage or ""

		phase("gift_precheck", { BuyerUserId = targetUserId, ProductId = productId, safeToRetry = true, dangerous = false })

		Logger.info("Gift target userId:", targetUserId)
		Logger.info("Gift productId:", productId)
		Logger.info("Gift product:", product.displayName or product.key or "?")
		Logger.info("GiftWithTokens:", tostring(config.GiftWithTokens))
		Logger.info("GiftDryRun:", tostring(config.GiftDryRun))
		Logger.info("AllowTokenSpend:", tostring(config.AllowTokenSpend))
		Logger.info("RequireTokenBalanceDecrease:", tostring(config.RequireTokenBalanceDecrease))

		if not productId then
			return false, "missing_product_id"
		end

		if config.GiftWithTokens ~= true then
			return false, "gift_with_tokens_disabled"
		end

		local beforeTokens = getTokenBalance()

		if beforeTokens ~= nil then
			Logger.info("Token balance before gift:", beforeTokens)
		else
			Logger.warn("Could not read token balance before gift.")
		end

		if config.GiftDryRun or not config.AllowTokenSpend then
			Logger.warn("DRY RUN BLOCKED token spend.")
			Logger.warn("No tokens were spent.")
			Logger.warn(("Would call SetGiftTo:FireServer(%s, %s, %q, true, nil)"):format(
				tostring(targetUserId),
				tostring(productId),
				tostring(giftMessage)
			))
			return false, "dry_run_blocked"
		end

		if beforeTokens == nil and config.AssumeGiftSuccessWithoutTokenRead ~= true then
			return false, "could_not_read_token_balance"
		end

		phase("gift_remote_sent", { BuyerUserId = targetUserId, ProductId = productId, safeToRetry = false, dangerous = true })

		local ok, err = pcall(function()
			-- This mirrors GiftingController's token path:
			-- purchaseGift(true) -> SetGiftTo:FireServer(targetUserId, productId, giftMessage, true, nil)
			SetGiftTo:FireServer(targetUserId, productId, giftMessage, true, nil)
		end)

		if not ok then
			Logger.error("SetGiftTo failed:", err)
			return false, tostring(err)
		end

		phase("gift_remote_fired", { BuyerUserId = targetUserId, ProductId = productId, safeToRetry = false, dangerous = true })

		Logger.info("SetGiftTo fired successfully.")

		if config.RequireTokenBalanceDecrease == true and beforeTokens ~= nil then
			phase("gift_waiting_token_decrease", { BuyerUserId = targetUserId, ProductId = productId, safeToRetry = false, dangerous = true })

			Logger.info("Waiting for token balance decrease...")
			local decreased, afterTokens = waitForTokenDecrease(beforeTokens, config.ConfirmTokenSpendTimeout or 12)

			if decreased then
				phase("completed", { BuyerUserId = targetUserId, ProductId = productId, safeToRetry = false, dangerous = false })

				Logger.info("Token balance decreased:", beforeTokens, "->", afterTokens)
				return true, "gift_sent_token_decreased"
			end

			Logger.warn("Token balance did not decrease within timeout. Last balance:", tostring(afterTokens))
			return false, "token_balance_not_changed"
		end

		phase("gift_unconfirmed", { BuyerUserId = targetUserId, ProductId = productId, safeToRetry = false, dangerous = true })

		Logger.warn("Gift fired, but token decrease confirmation was skipped.")
		return true, "gift_fired_unconfirmed"
	end

	return GiftActions
end
