-- AutoTrade/SupplyBuyer.lua

return function(ctx)
	local SupplyBuyer = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger
	local Heartbeat = ctx.Modules.Heartbeat
	local InventoryUtil = ctx.Modules.InventoryUtil
	local SupplyState = ctx.Modules.SupplyState
	local SupplyRAP = ctx.Modules.SupplyRAP

	local Net = require(ReplicatedStorage.Packages.Net)
	local ReplionClient = require(ReplicatedStorage.Packages.Replion).Client

	local function phase(name, info)
		if Heartbeat and Heartbeat.SetPhase then
			Heartbeat.SetPhase(name, info or {})
		end
	end

	local function getTokenBalance()
		local ok, result = pcall(function()
			local inv = ReplionClient:WaitReplion("Inventory", 10)
			return inv:Get("Tokens")
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

	local function findListingInBooth(config, state)
		local boothListings = ReplionClient:GetReplion("BoothListings") or ReplionClient:WaitReplion("BoothListings", 10)
		if not boothListings then
			return nil, nil, "boothlistings_missing"
		end

		local sellerUserId = state.SellerUserId
		local data = boothListings:Get({ sellerUserId }) or boothListings:Get({ tostring(sellerUserId) }) or {}
		local wantedName = tostring(state.ItemName or config.ItemName or "")

		for listingId, entry in pairs(data) do
			if type(entry) == "table" then
				local itemName = entry.ItemName or (entry.Item and entry.Item.Name) or ""
				local price = tonumber(entry.Price or entry.Cost or entry.Value)

				if itemName == wantedName and price then
					return listingId, price, nil, entry
				end
			end
		end

		return nil, nil, "listing_not_found_in_booth"
	end

	local function buyListing(ownerUserId, listingId)
		return pcall(function()
			return Net:Invoke("PurchaseBoothListing", {
				Owner = ownerUserId,
				ListingId = listingId,
			})
		end)
	end

	local function stockEnough(config)
		local items = InventoryUtil.findTradableItems(config.ItemType, config.ItemName, math.max(1, tonumber(config.Quantity or 1) or 1), {})
		return type(items) == "table" and #items >= (tonumber(config.Quantity or 1) or 1)
	end

	function SupplyBuyer.resumeAtBooth(config, state)
		phase("supply_checking_booth", { safeToRetry = true, dangerous = false })

		Logger.info("Resuming supply at seller booth:", tostring(state.SellerName), tostring(state.SellerUserId))
		task.wait(tonumber(config.SupplyPostTeleportWait or 6) or 6)

		local listingId, price, boothReason = findListingInBooth(config, state)
		if not listingId then
			SupplyState.Clear(config)
			return false, boothReason or "listing_missing_after_teleport"
		end

		Logger.info("Booth listing found:", tostring(listingId), "price", tostring(price))

		local safe, priceReason, priceInfo, maxPrice = SupplyRAP.isPriceSafe(config, state.ItemType or config.ItemType, state.ItemName or config.ItemName, price)
		if not safe then
			SupplyState.Clear(config)
			return false, "unsafe_listing_price:" .. tostring(priceReason) .. ":" .. tostring(price) .. ":max=" .. tostring(maxPrice)
		end

		phase("supply_prebuy_verified", {
			safeToRetry = true,
			dangerous = false,
			Price = price,
			MaxPrice = maxPrice,
			ListingId = listingId,
		})

		local beforeTokens = getTokenBalance()
		if beforeTokens == nil and config.SupplyRequireTokenBalanceRead ~= false then
			SupplyState.Clear(config)
			return false, "could_not_read_token_balance_before_supply_buy"
		end

		Logger.info("Token balance before supply buy:", tostring(beforeTokens))

		if config.SupplyDryRun == true or config.SupplyAutoBuy ~= true then
			SupplyState.Clear(config)
			Logger.warn("Supply auto-buy blocked by config. Would buy", config.ItemName, "for", price)
			return false, "supply_dry_run_or_autobuy_disabled"
		end

		phase("supply_buy_sent", {
			safeToRetry = false,
			dangerous = true,
			Price = price,
			MaxPrice = maxPrice,
			ListingId = listingId,
		})

		local ok, result = buyListing(state.SellerUserId, listingId)
		if not ok then
			return false, "purchase_booth_listing_error:" .. tostring(result)
		end

		Logger.info("PurchaseBoothListing result:", tostring(result))

		state.Stage = "buy_sent_waiting_result"
		state.ListingId = listingId
		state.Price = price
		SupplyState.Save(config, state)

		phase("supply_waiting_purchase_result", {
			safeToRetry = false,
			dangerous = true,
			Price = price,
			ListingId = listingId,
		})

		local decreased = true
		local afterTokens = nil
		if beforeTokens ~= nil and config.SupplyRequireTokenDecrease ~= false then
			decreased, afterTokens = waitForTokenDecrease(beforeTokens, tonumber(config.SupplyConfirmTokenDecreaseTimeout or 12) or 12)
			if not decreased then
				return false, "supply_token_balance_not_changed_manual_check"
			end
			Logger.info("Token balance decreased after supply buy:", beforeTokens, "->", tostring(afterTokens))
		end

		local verifyTimeout = tonumber(config.SupplyInventoryVerifyTimeout or 20) or 20
		local start = os.clock()
		while os.clock() - start < verifyTimeout do
			if stockEnough(config) then
				Logger.info("Supply purchase verified in inventory.")
				phase("supply_completed", { safeToRetry = false, dangerous = false, Price = price, ListingId = listingId })
				return true, "supply_purchase_verified"
			end
			task.wait(1)
		end

		if decreased then
			return false, "manual_check_tokens_decreased_but_item_missing"
		end

		return false, "supply_inventory_not_received"
	end

	return SupplyBuyer
end
