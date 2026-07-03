-- AutoTrade/SupplyBuyer.lua
-- Max-safety booth purchase. Uses real structures confirmed from game scripts:
-- BoothListings entries: Type, ItemName, Item, Price. ListingId is table key.
-- Purchase path: BoothController:PurchaseListing(sellerPlayerInstance, listingId)
-- Tokens: Inventory replion path "Tokens".

return function(ctx)
	local SupplyBuyer = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger
	local Heartbeat = ctx.Modules.Heartbeat
	local SupplyState = ctx.Modules.SupplyState
	local SupplyRAP = ctx.Modules.SupplyRAP
	local SupplyPlanner = ctx.Modules.SupplyPlanner

	local Players = game:GetService("Players")
	local ReplionClient = require(ReplicatedStorage.Packages.Replion).Client
	local InventoryClient = require(ReplicatedStorage.Shared.Inventory).Client

	local function trim(s)
		return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
	end

	local function phase(name, info)
		if Heartbeat and Heartbeat.SetPhase then
			Heartbeat.SetPhase(name, info or {})
		end
	end

	local function waitReplion(name, timeout)
		local direct = nil
		pcall(function()
			direct = ReplionClient:GetReplion(name)
		end)
		if direct then
			return direct
		end

		local done = false
		local result = nil
		task.spawn(function()
			local ok, replion = pcall(function()
				return ReplionClient:WaitReplion(name)
			end)
			if ok then
				result = replion
			end
			done = true
		end)

		local started = os.clock()
		while not done and os.clock() - started < (tonumber(timeout or 10) or 10) do
			task.wait(0.1)
		end
		return result
	end

	local function isTradingPlaza()
		local ok, ServerInfo = pcall(function()
			return require(ReplicatedStorage.ServerInfo)
		end)
		if not ok or type(ServerInfo) ~= "table" or type(ServerInfo.isTradingPlazaServer) ~= "function" then
			return false, "serverinfo_missing"
		end
		local ok2, result = pcall(function()
			return ServerInfo.isTradingPlazaServer()
		end)
		if ok2 and result == true then
			return true
		end
		return false, "not_trading_plaza_server"
	end

	local function fireAfkPing()
		-- Intentionally no-op. The normal client handles AFK/teleport behavior.
	end

	local function getTokenBalance()
		local inv = waitReplion("Inventory", 10)
		if not inv then
			return nil, "inventory_replion_missing"
		end

		local ok, result = pcall(function()
			return inv:Get("Tokens")
		end)

		if ok and type(result) == "number" then
			return result, nil
		end

		return nil, "tokens_path_missing"
	end

	local function waitForTokenDecrease(before, price, config)
		if type(before) ~= "number" then
			return false, nil, "before_tokens_missing"
		end

		local timeout = tonumber(config.SupplyConfirmTokenDecreaseTimeout or 12) or 12
		local exact = config.SupplyRequireExactTokenDecrease == true
		local started = os.clock()
		local last = before

		while os.clock() - started < timeout do
			fireAfkPing()
			local current = getTokenBalance()
			if type(current) == "number" then
				last = current
				if exact then
					if current <= before - price then
						return true, current, "token_decrease_exact_or_more"
					end
				elseif current < before then
					return true, current, "token_decreased"
				end
			end
			task.wait(0.5)
		end

		return false, last, "token_decrease_timeout"
	end

	local function checkTradingFlags(config)
		if config.SupplyRequireTradingFlags == false then
			return true
		end

		local ok, FFlagClient = pcall(function()
			return require(ReplicatedStorage.ClientGameModules.FFlagClient)
		end)
		if not ok or type(FFlagClient) ~= "table" or type(FFlagClient.GetKey) ~= "function" then
			return false, "fflag_client_missing"
		end

		local tradingOk = false
		local tokensOk = false
		pcall(function()
			tradingOk = FFlagClient:GetKey("TradingEnabled") == true
			tokensOk = FFlagClient:GetKey("TradingTokensEnabled") == true
		end)

		if not tradingOk then
			return false, "trading_disabled"
		end
		if not tokensOk then
			return false, "trading_tokens_disabled"
		end
		return true
	end

	local function countOwned(config)
		local stock = SupplyPlanner.checkTradeStock(config)
		if type(stock) == "table" then
			return stock.Owned or 0, stock
		end
		return 0, nil
	end

	local function computeListingKey(entry)
		if type(entry) ~= "table" then
			return nil
		end
		if type(entry.Item) ~= "table" then
			return nil
		end
		local ok, key = pcall(function()
			return InventoryClient:ItemToKey(entry.Type, entry.Item, { "TradeLock" })
		end)
		if ok and key then
			return tostring(key)
		end
		return nil
	end

	local function getBoothListings()
		local boothListings = waitReplion("BoothListings", 12)
		if not boothListings then
			return nil, "boothlistings_missing"
		end
		return boothListings, nil
	end

	local function getSellerPlayer(ownerKey)
		local userId = tonumber(ownerKey)
		if not userId then
			return nil
		end
		return Players:GetPlayerByUserId(userId)
	end

	local function getAllBoothData()
		local boothListings, reason = getBoothListings()
		if not boothListings then
			return nil, reason
		end

		local data = nil
		pcall(function()
			data = boothListings:Get({})
		end)
		if type(data) ~= "table" then
			return nil, "booth_data_missing"
		end
		return data, nil
	end

	local function getSellerBoothData(sellerUserId)
		local allData, reason = getAllBoothData()
		if not allData then
			return nil, reason
		end

		local data = allData[tostring(sellerUserId)] or allData[tonumber(sellerUserId)] or allData[sellerUserId]
		if type(data) ~= "table" then
			return nil, "seller_booth_missing"
		end
		return data, nil
	end

	local function listingMatches(config, state, ownerUserId, listingId, entry, maxPrice)
		if type(entry) ~= "table" then
			return false, "listing_entry_not_table"
		end

		local expectedType = trim(state.ItemType or config.ItemType)
		local expectedName = trim(state.ItemName or config.ItemName)
		local expectedKey = trim(state.ItemKey or config.ItemKey or "")
		local entryType = trim(entry.Type)
		local entryName = trim(entry.ItemName or (type(entry.Item) == "table" and entry.Item.Name) or "")
		local price = tonumber(entry.Price)
		local key = computeListingKey(entry)

		if trim(listingId) == "" then
			return false, "listing_id_missing"
		end
		if entryType ~= expectedType then
			return false, "listing_type_mismatch:" .. entryType .. "~=" .. expectedType
		end
		if entryName ~= expectedName then
			return false, "listing_name_mismatch:" .. entryName .. "~=" .. expectedName
		end
		if config.SupplyRequireBoothItemKey ~= false then
			if key == nil or key == "" then
				return false, "listing_item_key_missing"
			end
			if expectedKey ~= "" and key ~= expectedKey then
				return false, "listing_key_mismatch"
			end
		end
		if not price then
			return false, "listing_price_missing"
		end
		if price <= 0 then
			return false, "listing_price_not_positive"
		end
		if maxPrice and price > maxPrice then
			return false, "listing_price_above_max"
		end

		local sellerPlayer = getSellerPlayer(ownerUserId)
		return true, "match", {
			OwnerUserId = tostring(ownerUserId),
			SellerName = sellerPlayer and sellerPlayer.Name or nil,
			ListingId = tostring(listingId),
			Entry = entry,
			Price = price,
			ItemKey = key,
			Type = entryType,
			ItemName = entryName,
		}
	end

	local function collectSafeListings(config, state, maxPrice)
		local sellerTables = {}
		local allReason = nil

		if state.SellerUserId then
			local data, dataReason = getSellerBoothData(state.SellerUserId)
			if not data then
				return nil, dataReason
			end
			sellerTables[tostring(state.SellerUserId)] = data
		else
			local allData, reason = getAllBoothData()
			if not allData then
				return nil, reason
			end
			allReason = reason
			for ownerKey, listings in pairs(allData) do
				if type(listings) == "table" and getSellerPlayer(ownerKey) then
					sellerTables[tostring(ownerKey)] = listings
				end
			end
		end

		local matches = {}
		local rejectCounts = {}
		for ownerUserId, data in pairs(sellerTables) do
			for listingId, entry in pairs(data) do
				local ok, reason, info = listingMatches(config, state, ownerUserId, listingId, entry, maxPrice)
				if ok then
					table.insert(matches, info)
				else
					rejectCounts[reason] = (rejectCounts[reason] or 0) + 1
				end
			end
		end

		table.sort(matches, function(a, b)
			return (a.Price or math.huge) < (b.Price or math.huge)
		end)

		if #matches <= 0 then
			local firstReason = allReason or "no_matching_safe_listing"
			for reason in pairs(rejectCounts) do
				firstReason = reason
				break
			end
			return {}, firstReason
		end

		return matches, nil
	end

	local function verifyListingStable(config, state, maxPrice)
		local matches, reason = collectSafeListings(config, state, maxPrice)
		if type(matches) ~= "table" or #matches == 0 then
			return nil, reason or "no_safe_listing_first_check"
		end

		local picked = matches[1]
		if config.SupplyDoubleCheckListing == false then
			return picked, nil
		end

		local delaySeconds = tonumber(config.SupplyDoubleCheckDelay or 0.75) or 0.75
		task.wait(delaySeconds)
		fireAfkPing()

		local secondMatches, secondReason = collectSafeListings(config, state, maxPrice)
		if type(secondMatches) ~= "table" or #secondMatches == 0 then
			return nil, secondReason or "no_safe_listing_second_check"
		end

		for _, second in ipairs(secondMatches) do
			if second.ListingId == picked.ListingId then
				if second.Price ~= picked.Price then
					return nil, "listing_price_changed"
				end
				if trim(second.ItemKey) ~= trim(picked.ItemKey) then
					return nil, "listing_item_key_changed"
				end
				return second, nil
			end
		end

		return nil, "listing_disappeared_between_checks"
	end

	local function checkBudget(config, price, beforeTokens)
		if type(beforeTokens) ~= "number" then
			return false, "token_balance_missing"
		end
		if beforeTokens < price then
			return false, "not_enough_tokens"
		end

		local reservePercent = tonumber(config.SupplyTokenReservePercent or 0) or 0
		local minReserve = tonumber(config.SupplyMinTokenReserve or 0) or 0
		local reserve = math.max(minReserve, math.floor(beforeTokens * reservePercent / 100))
		if beforeTokens - price < reserve then
			return false, "token_reserve_would_be_breached"
		end

		local itemCap = tonumber(config.SupplyMaxTokensPerItem or 0) or 0
		if itemCap > 0 and price > itemCap then
			return false, "item_token_cap_exceeded"
		end

		local orderCap = tonumber(config.SupplyMaxTokensPerOrder or 0) or 0
		if orderCap > 0 and price > orderCap then
			return false, "order_token_cap_exceeded"
		end

		local hourCap = tonumber(config.SupplyMaxTokensPerHour or 0) or 0
		if hourCap > 0 then
			local spent = SupplyState.GetSpentInLastHour(config)
			if spent + price > hourCap then
				return false, "hourly_token_cap_exceeded"
			end
		end

		return true
	end

	local function purchaseListing(ownerUserId, listingId)
		local sellerPlayer = getSellerPlayer(ownerUserId)
		if not sellerPlayer then
			return false, nil, "seller_player_missing_or_left_server"
		end

		local okController, BoothController = pcall(function()
			return require(ReplicatedStorage.Controllers.Booth.BoothController)
		end)
		if not okController or type(BoothController) ~= "table" or type(BoothController.PurchaseListing) ~= "function" then
			return false, nil, "booth_controller_purchase_missing"
		end

		local ok, success, message = pcall(function()
			return BoothController:PurchaseListing(sellerPlayer, listingId)
		end)

		if not ok then
			return false, nil, "booth_controller_purchase_error:" .. tostring(success)
		end

		return true, success, message
	end

	local function waitForInventoryGain(config, state)
		local timeout = tonumber(config.SupplyInventoryVerifyTimeout or 20) or 20
		local start = os.clock()
		local initialOwned = tonumber(state.InitialOwned or 0) or 0
		local expected = tonumber(state.ExpectedOwnedAfterPurchase or (initialOwned + 1)) or (initialOwned + 1)

		while os.clock() - start < timeout do
			fireAfkPing()
			local owned, stock = countOwned(config)
			if owned >= expected then
				return true, owned, stock
			end
			task.wait(1)
		end

		local owned, stock = countOwned(config)
		return false, owned, stock
	end

	local function handleDangerousResume(config, state)
		phase("supply_dangerous_resume_check", { safeToRetry = false, dangerous = true, reason = state.Stage })
		Logger.warn("Dangerous supply state found. Verifying only; not buying again:", tostring(state.Stage))

		local inventoryOk, owned = waitForInventoryGain(config, state)
		if inventoryOk then
			Logger.info("Dangerous resume verified item in inventory. Treating supply as completed.")
			SupplyState.AppendSpend(config, {
				BridgeId = config.BridgeId,
				ItemName = state.ItemName,
				ItemType = state.ItemType,
				Price = tonumber(state.Price or 0) or 0,
				ListingId = state.ListingId,
				Reason = "verified_after_dangerous_resume",
			})
			return true, "supply_verified_after_dangerous_resume"
		end

		local before = tonumber(state.BeforeTokens)
		if before then
			local current = getTokenBalance()
			if type(current) == "number" and current < before then
				state.AfterTokens = current
				state.CurrentOwned = owned
				SupplyState.MarkManualCheck(config, state, "tokens_decreased_but_item_missing_after_resume")
				return false, "manual_check_tokens_decreased_but_item_missing_after_resume"
			end
		end

		SupplyState.MarkManualCheck(config, state, "ambiguous_previous_purchase_state_no_rebuy")
		return false, "manual_check_ambiguous_previous_purchase_state_no_rebuy"
	end

	function SupplyBuyer.resumeAtBooth(config, state)
		state = state or {}

		if SupplyState.IsDangerous(state) then
			return handleDangerousResume(config, state)
		end

		if config.SupplyRequireTradingPlazaServer ~= false then
			local inPlaza, plazaReason = isTradingPlaza()
			if not inPlaza then
				return false, plazaReason or "not_trading_plaza_server"
			end
		end

		local flagsOk, flagsReason = checkTradingFlags(config)
		if not flagsOk then
			SupplyState.Clear(config)
			return false, flagsReason or "trading_flags_not_ready"
		end

		phase("supply_checking_booth", { safeToRetry = true, dangerous = false })
		Logger.info("Resuming supply at seller booth:", tostring(state.SellerName), tostring(state.SellerUserId))
		task.wait(tonumber(config.SupplyPostTeleportWait or 6) or 6)
		fireAfkPing()

		local maxPrice = tonumber(state.MaxBuyPrice)
		if not maxPrice then
			local calcMax, calcReason = ctx.Modules.SupplyRAP.calculateMaxBuyPrice(config, state.ItemType or config.ItemType, state.ItemName or config.ItemName)
			if not calcMax then
				SupplyState.Clear(config)
				return false, calcReason or "max_price_recalc_failed"
			end
			maxPrice = calcMax
		end

		local listing, listingReason = verifyListingStable(config, state, maxPrice)
		if not listing then
			SupplyState.Clear(config)
			return false, listingReason or "listing_not_found_or_unsafe"
		end

		Logger.info("Stable safe booth listing found:", tostring(listing.ListingId), "price", tostring(listing.Price), "key", tostring(listing.ItemKey), "seller", tostring(listing.OwnerUserId))
		state.SellerUserId = listing.OwnerUserId or state.SellerUserId
		state.SellerName = listing.SellerName or state.SellerName

		local beforeTokens, tokenReason = getTokenBalance()
		if beforeTokens == nil and config.SupplyRequireTokenBalanceRead ~= false then
			SupplyState.Clear(config)
			return false, tokenReason or "could_not_read_token_balance_before_supply_buy"
		end

		local budgetOk, budgetReason = checkBudget(config, listing.Price, beforeTokens)
		if not budgetOk then
			SupplyState.Clear(config)
			return false, budgetReason or "budget_check_failed"
		end

		local beforeOwned = countOwned(config)
		state.ListingId = listing.ListingId
		state.Price = listing.Price
		state.ListingItemKey = listing.ItemKey
		state.BeforeTokens = beforeTokens
		state.InitialOwned = tonumber(state.InitialOwned or beforeOwned or 0) or 0
		state.OwnedBeforePurchase = beforeOwned
		state.ExpectedOwnedAfterPurchase = math.max((tonumber(beforeOwned) or 0) + 1, (tonumber(state.InitialOwned or 0) or 0) + 1)
		state.MaxBuyPrice = maxPrice

		phase("supply_prebuy_verified", {
			safeToRetry = true,
			dangerous = false,
			Price = listing.Price,
			MaxPrice = maxPrice,
			ListingId = listing.ListingId,
			BeforeTokens = beforeTokens,
		})

		if config.SupplyDryRun == true or config.SupplyAutoBuy ~= true then
			SupplyState.Clear(config)
			Logger.warn("Supply auto-buy blocked by config. Would buy", tostring(state.ItemName or config.ItemName), "for", listing.Price)
			return false, "supply_dry_run_or_autobuy_disabled"
		end

		-- Dangerous begins BEFORE InvokeServer, so crash recovery never re-buys blindly.
		state.Stage = "supply_buy_invoking"
		state.Dangerous = true
		state.SafeToRetry = false
		SupplyState.Save(config, state)
		phase("supply_buy_invoking", {
			safeToRetry = false,
			dangerous = true,
			Price = listing.Price,
			MaxPrice = maxPrice,
			ListingId = listing.ListingId,
		})

		local callOk, remoteSuccess, remoteMessage = purchaseListing(state.SellerUserId, listing.ListingId)
		state.Stage = "supply_buy_sent_waiting_result"
		state.Dangerous = true
		state.SafeToRetry = false
		state.RemoteCallOk = callOk
		state.RemoteSuccess = remoteSuccess
		state.RemoteMessage = tostring(remoteMessage or "")
		SupplyState.Save(config, state)

		Logger.info("BoothController purchase returned:", tostring(callOk), tostring(remoteSuccess), tostring(remoteMessage))
		phase("supply_waiting_purchase_result", {
			safeToRetry = false,
			dangerous = true,
			Price = listing.Price,
			ListingId = listing.ListingId,
		})

		local tokenDecreased = true
		local afterTokens = nil
		if beforeTokens ~= nil and config.SupplyRequireTokenDecrease ~= false then
			tokenDecreased, afterTokens = waitForTokenDecrease(beforeTokens, listing.Price, config)
			state.AfterTokens = afterTokens
			SupplyState.Save(config, state)
		end

		local inventoryOk, ownedAfter = waitForInventoryGain(config, state)
		state.OwnedAfterPurchase = ownedAfter

		if inventoryOk and (tokenDecreased or config.SupplyRequireTokenDecrease == false) then
			Logger.info("Supply purchase verified. Owned:", tostring(ownedAfter), "tokens", tostring(beforeTokens), "->", tostring(afterTokens))
			phase("supply_completed", { safeToRetry = false, dangerous = false, Price = listing.Price, ListingId = listing.ListingId })
			SupplyState.AppendSpend(config, {
				BridgeId = config.BridgeId,
				ItemName = state.ItemName or config.ItemName,
				ItemType = state.ItemType or config.ItemType,
				Price = listing.Price,
				ListingId = listing.ListingId,
				SellerUserId = state.SellerUserId,
				BeforeTokens = beforeTokens,
				AfterTokens = afterTokens,
				Reason = "purchase_verified",
			})
			state.Stage = "supply_purchase_verified"
			state.Dangerous = false
			state.SafeToRetry = true
			SupplyState.Save(config, state)
			return true, "supply_purchase_verified"
		end

		if tokenDecreased and not inventoryOk then
			state.Stage = "supply_tokens_decreased_item_missing"
			SupplyState.MarkManualCheck(config, state, "tokens_decreased_but_item_missing")
			return false, "manual_check_tokens_decreased_but_item_missing"
		end

		if inventoryOk and not tokenDecreased then
			-- Item is present, so delivery can be safe; keep ledger note but do not fail just because token replion lagged.
			Logger.warn("Inventory gained item but token decrease was not verified. Continuing with caution.")
			SupplyState.AppendSpend(config, {
				BridgeId = config.BridgeId,
				ItemName = state.ItemName or config.ItemName,
				ItemType = state.ItemType or config.ItemType,
				Price = listing.Price,
				ListingId = listing.ListingId,
				SellerUserId = state.SellerUserId,
				BeforeTokens = beforeTokens,
				AfterTokens = afterTokens,
				Reason = "inventory_verified_token_unconfirmed",
			})
			state.Stage = "supply_purchase_verified_token_unconfirmed"
			state.Dangerous = false
			state.SafeToRetry = true
			SupplyState.Save(config, state)
			return true, "supply_purchase_verified_token_unconfirmed"
		end

		if callOk and remoteSuccess == false then
			SupplyState.Clear(config)
			return false, "purchase_rejected:" .. tostring(remoteMessage or "")
		end

		SupplyState.MarkManualCheck(config, state, "purchase_unconfirmed_no_inventory_no_token_decrease")
		return false, "manual_check_purchase_unconfirmed_no_inventory_no_token_decrease"
	end

	return SupplyBuyer
end
