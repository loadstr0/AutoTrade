-- AutoTrade/SupplyScanner.lua
-- Trading Plaza listing search/teleport with state persistence.

return function(ctx)
	local SupplyScanner = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger
	local SupplyState = ctx.Modules.SupplyState
	local SupplyRAP = ctx.Modules.SupplyRAP

	local Net = require(ReplicatedStorage.Packages.Net)
	local TeleportService = game:GetService("TeleportService")
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer

	local function trim(s)
		return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
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

	local function remoteFunction(name)
		local ok, remote = pcall(function()
			return Net:RemoteFunction(name)
		end)
		if ok and remote then
			return remote
		end
		return nil
	end

	function SupplyScanner.getListingCandidates(config, itemType, itemName)
		if config.SupplyRequireTradingPlazaServer ~= false then
			local inPlaza, plazaReason = isTradingPlaza()
			if not inPlaza then
				return nil, plazaReason or "not_trading_plaza_server"
			end
		end

		local itemKey, keyReason = SupplyRAP.getItemKey(itemType, itemName)
		if not itemKey then
			return nil, keyReason or "item_key_failed"
		end

		local GetItemListings = remoteFunction("TradePlaza/GetItemListings")
		if not GetItemListings then
			return nil, "get_item_listings_remote_missing"
		end

		local ok, a, b = pcall(function()
			return GetItemListings:InvokeServer("Teleport", itemType, itemKey)
		end)

		if not ok then
			return nil, "get_item_listings_error:" .. tostring(a)
		end

		if not a or type(b) ~= "table" or #b == 0 then
			return {}, "no_listings"
		end

		Logger.info("Supply scanner found listing candidates:", #b)
		return b, nil, itemKey
	end

	function SupplyScanner.chooseUnvisited(config, listings)
		local visited = SupplyState.ReadVisited(config)
		for _, listing in ipairs(listings or {}) do
			if type(listing) == "table" then
				local guid = trim(listing.GUID or listing.Guid or listing.guid)
				local sellerUserId = listing.Seller and listing.Seller.UserId or listing.UserId or listing.SellerId
				if guid ~= "" and sellerUserId and not visited[guid] then
					return listing, guid, sellerUserId
				end
			end
		end
		return nil, "no_unvisited_listings"
	end

	local function getReturnTarget(config)
		local placeId = tonumber(config.SupplyReturnPlaceId or config.ReturnPlaceId or config.PrivateServerPlaceId or config.DeliveryPlaceId)
		local jobId = trim(config.SupplyReturnJobId or config.ReturnJobId or config.PrivateServerJobId or config.DeliveryJobId)

		if placeId and jobId ~= "" then
			return placeId, jobId, "config"
		end

		-- Fallback is current server. Safe only if caller intentionally started supply from the delivery server.
		return game.PlaceId, game.JobId, "current_server_fallback"
	end

	function SupplyScanner.teleportToListing(config, listing, itemType, itemName, plan)
		if config.SupplyRequireTradingPlazaServer ~= false then
			local inPlaza, plazaReason = isTradingPlaza()
			if not inPlaza then
				return false, plazaReason or "not_trading_plaza_server"
			end
		end

		local itemKey, keyReason = SupplyRAP.getItemKey(itemType, itemName)
		if not itemKey then
			return false, keyReason or "item_key_failed"
		end

		local guid = trim(listing.GUID or listing.Guid or listing.guid)
		local sellerUserId = listing.Seller and listing.Seller.UserId or listing.UserId or listing.SellerId
		local sellerName = listing.Seller and (listing.Seller.Name or listing.Seller.Username) or tostring(sellerUserId)

		if guid == "" or not sellerUserId then
			return false, "bad_listing_candidate"
		end

		local returnPlaceId, returnJobId, returnSource = getReturnTarget(config)
		if config.DeliveryMode == "SupplyThenTrade" and returnJobId == game.JobId and config.SupplyAllowCurrentServerReturn ~= true then
			Logger.warn("Supply return target is current server fallback. Set SupplyReturnPlaceId/SupplyReturnJobId if delivery must return elsewhere.")
		end

		local TeleportToListing = remoteFunction("TradePlaza/TeleportToListing")
		if not TeleportToListing then
			return false, "teleport_to_listing_remote_missing"
		end

		Logger.info("Teleporting to supply listing:", guid, "seller", sellerName, sellerUserId)
		SupplyState.MarkVisited(config, guid)
		SupplyState.Save(config, {
			Stage = "teleported_to_listing",
			BridgeId = config.BridgeId,
			Dangerous = false,
			SafeToRetry = true,
			ItemType = itemType,
			ItemName = itemName,
			ItemKey = itemKey,
			MaxBuyPrice = plan and plan.MaxBuyPrice or config.MaxBuyPrice,
			InitialOwned = plan and plan.Owned or nil,
			Needed = plan and plan.Needed or tonumber(config.Quantity or 1),
			MissingAtStart = plan and plan.Missing or nil,
			SellerUserId = sellerUserId,
			SellerName = sellerName,
			ListingGUID = guid,
			ReturnPlaceId = returnPlaceId,
			ReturnJobId = returnJobId,
			ReturnSource = returnSource,
			SourcePlaceId = game.PlaceId,
			SourceJobId = game.JobId,
		})

		local ok, result, msg = pcall(function()
			return TeleportToListing:InvokeServer("Teleport", itemType, itemKey, guid)
		end)

		if not ok then
			SupplyState.Clear(config)
			return false, "teleport_to_listing_error:" .. tostring(result)
		end

		if not result then
			SupplyState.Clear(config)
			return false, "teleport_to_listing_rejected:" .. tostring(msg)
		end

		local oldJob = game.JobId
		task.wait(tonumber(config.SupplyTeleportConfirmWait or 8) or 8)

		if game.JobId == oldJob then
			SupplyState.Clear(config)
			return false, "teleport_to_listing_no_server_change"
		end

		return true, "teleporting"
	end

	function SupplyScanner.returnToPrivateServer(config, state)
		state = state or {}
		local returnPlaceId = tonumber(state.ReturnPlaceId or config.SupplyReturnPlaceId or config.ReturnPlaceId)
		local returnJobId = trim(state.ReturnJobId or config.SupplyReturnJobId or config.ReturnJobId)

		if not returnPlaceId or returnJobId == "" then
			return false, "missing_return_server"
		end

		SupplyState.Save(config, {
			Stage = "purchased_returning",
			BridgeId = config.BridgeId,
			Dangerous = false,
			SafeToRetry = true,
			ItemType = state.ItemType,
			ItemName = state.ItemName,
			ItemKey = state.ItemKey,
			InitialOwned = state.InitialOwned,
			ExpectedOwnedAfterPurchase = state.ExpectedOwnedAfterPurchase,
			Needed = state.Needed,
			SellerUserId = state.SellerUserId,
			ListingId = state.ListingId,
			Price = state.Price,
			ReturnPlaceId = returnPlaceId,
			ReturnJobId = returnJobId,
		})

		Logger.info("Returning to delivery private server:", returnPlaceId, returnJobId)
		local ok, err = pcall(function()
			TeleportService:TeleportToPlaceInstance(returnPlaceId, returnJobId, LocalPlayer)
		end)

		if not ok then
			return false, "return_teleport_error:" .. tostring(err)
		end

		task.wait(tonumber(config.SupplyReturnTeleportWait or 8) or 8)
		return false, "return_teleport_pending_or_no_server_change"
	end

	return SupplyScanner
end
