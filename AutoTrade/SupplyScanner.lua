-- AutoTrade/SupplyScanner.lua

return function(ctx)
	local SupplyScanner = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger
	local SupplyState = ctx.Modules.SupplyState
	local SupplyRAP = ctx.Modules.SupplyRAP

	local Net = require(ReplicatedStorage.Packages.Net)
	local GetItemListings = Net:RemoteFunction("TradePlaza/GetItemListings")
	local TeleportToListing = Net:RemoteFunction("TradePlaza/TeleportToListing")

	local TeleportService = game:GetService("TeleportService")
	local LocalPlayer = game:GetService("Players").LocalPlayer

	function SupplyScanner.getListingCandidates(config, itemType, itemName)
		local itemKey = SupplyRAP.getItemKey(itemType, itemName)
		if not itemKey then
			return nil, "item_key_failed"
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
		local visited = SupplyState.ReadVisited()
		for _, listing in ipairs(listings or {}) do
			local guid = tostring(listing.GUID or "")
			local sellerUserId = listing.Seller and listing.Seller.UserId or listing.UserId or listing.SellerId
			if guid ~= "" and sellerUserId and not visited[guid] then
				return listing, guid, sellerUserId
			end
		end
		return nil, "no_unvisited_listings"
	end

	function SupplyScanner.teleportToListing(config, listing, itemType, itemName)
		local itemKey = SupplyRAP.getItemKey(itemType, itemName)
		if not itemKey then
			return false, "item_key_failed"
		end

		local guid = tostring(listing.GUID or "")
		local sellerUserId = listing.Seller and listing.Seller.UserId or listing.UserId or listing.SellerId
		local sellerName = listing.Seller and (listing.Seller.Name or listing.Seller.Username) or tostring(sellerUserId)

		if guid == "" or not sellerUserId then
			return false, "bad_listing_candidate"
		end

		Logger.info("Teleporting to supply listing:", guid, "seller", sellerName, sellerUserId)
		SupplyState.MarkVisited(guid)
		SupplyState.Save(config, {
			Stage = "teleported_to_listing",
			BridgeId = config.BridgeId,
			ItemType = itemType,
			ItemName = itemName,
			ItemKey = itemKey,
			SellerUserId = sellerUserId,
			SellerName = sellerName,
			ListingGUID = guid,
			ReturnPlaceId = game.PlaceId,
			ReturnJobId = game.JobId,
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
		task.wait(8)

		if game.JobId == oldJob then
			SupplyState.Clear(config)
			return false, "teleport_to_listing_no_server_change"
		end

		return true, "teleporting"
	end

	function SupplyScanner.returnToPrivateServer(config, state)
		state = state or {}
		local returnPlaceId = tonumber(state.ReturnPlaceId)
		local returnJobId = tostring(state.ReturnJobId or "")

		if not returnPlaceId or returnJobId == "" then
			return false, "missing_return_server"
		end

		SupplyState.Save(config, {
			Stage = "purchased_returning",
			BridgeId = config.BridgeId,
			ItemType = state.ItemType,
			ItemName = state.ItemName,
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

		task.wait(8)
		return false, "return_teleport_no_server_change"
	end

	return SupplyScanner
end
