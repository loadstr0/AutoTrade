-- AutoTrade/SupplyScanner.lua
-- Trading Plaza seller search/teleport using the normal Index UI/controller path.
-- IMPORTANT: direct TradePlaza/GetItemListings and TradePlaza/TeleportToListing calls are intentionally not used here.

return function(ctx)
	local SupplyScanner = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger
	local SupplyState = ctx.Modules.SupplyState
	local SupplyRAP = ctx.Modules.SupplyRAP

	local TeleportService = game:GetService("TeleportService")
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer
	local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

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

	local function getReturnTarget(config)
		local placeId = tonumber(config.SupplyReturnPlaceId or config.ReturnPlaceId or config.PrivateServerPlaceId or config.DeliveryPlaceId)
		local jobId = trim(config.SupplyReturnJobId or config.ReturnJobId or config.PrivateServerJobId or config.DeliveryJobId)

		if placeId and jobId ~= "" then
			return placeId, jobId, "config"
		end

		return game.PlaceId, game.JobId, "current_server_fallback"
	end

	local function phase(config, name, info)
		local Heartbeat = ctx.Modules.Heartbeat
		if Heartbeat and Heartbeat.SetPhase then
			Heartbeat.SetPhase(name, info or {})
		end
	end

	local function getTextBlob(inst)
		local out = {}
		if typeof(inst) ~= "Instance" then
			return ""
		end
		if inst:IsA("TextLabel") or inst:IsA("TextButton") then
			table.insert(out, tostring(inst.Text or ""))
		end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("TextLabel") or d:IsA("TextButton") then
				table.insert(out, tostring(d.Text or ""))
			end
		end
		return table.concat(out, " ")
	end

	local function isVisibleGuiObject(gui)
		if typeof(gui) ~= "Instance" or not gui:IsA("GuiObject") then
			return false
		end
		if gui.Visible ~= true then
			return false
		end
		local cur = gui.Parent
		while cur and cur ~= PlayerGui do
			if cur:IsA("GuiObject") and cur.Visible ~= true then
				return false
			end
			cur = cur.Parent
		end
		return true
	end

	local function fireActivated(button)
		if typeof(button) ~= "Instance" or not button:IsA("GuiButton") then
			return false, "button_missing_or_not_guibutton"
		end

		local fired = false
		local method = "none"

		if type(getconnections) == "function" then
			local ok, connections = pcall(function()
				return getconnections(button.Activated)
			end)
			if ok and type(connections) == "table" then
				for _, connection in ipairs(connections) do
					if connection.Enabled ~= false then
						local okFire = pcall(function()
							connection:Fire()
						end)
						if okFire then
							fired = true
							method = "getconnections.Activated"
						end
					end
				end
			end
		end

		if not fired and type(firesignal) == "function" then
			local okFire = pcall(function()
				firesignal(button.Activated)
			end)
			if okFire then
				fired = true
				method = "firesignal.Activated"
			end
		end

		return fired, method
	end

	local function getShowSellersButton()
		local index = PlayerGui:FindFirstChild("Index")
		local main = index and index:FindFirstChild("Main")
		local right = main and main:FindFirstChild("Right")
		return right and right:FindFirstChild("ShowSellers") or nil
	end

	local function getPromptsGui()
		return PlayerGui:FindFirstChild("Prompts")
	end

	local function findCurrentPrompt()
		local prompts = getPromptsGui()
		if not prompts then
			return nil
		end

		for _, child in ipairs(prompts:GetChildren()) do
			if child:IsA("GuiObject") and child.Visible and child:FindFirstChild("Yes") and child:FindFirstChild("No") then
				return child
			end
		end

		for _, child in ipairs(prompts:GetChildren()) do
			if child:IsA("GuiObject") and child.Visible then
				return child
			end
		end

		return nil
	end

	local function classifyPrompt(prompt)
		if not prompt then
			return nil, "prompt_missing"
		end
		local text = string.lower(getTextBlob(prompt))
		if text:find("seller has been found", 1, true) or text:find("teleport to their server", 1, true) then
			return "seller_found", text
		end
		if text:find("no users selling", 1, true) or text:find("no users", 1, true) then
			return "no_sellers", text
		end
		if text:find("internal server error", 1, true) then
			return "error", text
		end
		if text:find("another prompt", 1, true) then
			return "blocked", text
		end
		return "unknown", text
	end

	local function waitForSellerPrompt(timeout)
		local started = os.clock()
		local lastClass = nil
		local lastText = nil
		while os.clock() - started < (tonumber(timeout or 12) or 12) do
			local prompt = findCurrentPrompt()
			local cls, text = classifyPrompt(prompt)
			lastClass = cls or lastClass
			lastText = text or lastText
			if cls == "seller_found" or cls == "no_sellers" or cls == "error" or cls == "blocked" then
				return prompt, cls, text
			end
			task.wait(0.2)
		end
		return nil, lastClass or "timeout", lastText or ""
	end

	local function activateShowSellers(config)
		local button = getShowSellersButton()
		if not button then
			return false, "show_sellers_button_missing"
		end
		if not isVisibleGuiObject(button) then
			Logger.warn("ShowSellers button exists but is not visibly open; trying activation anyway.")
		end
		local fired, method = fireActivated(button)
		if not fired then
			return false, "show_sellers_activate_failed:" .. tostring(method)
		end
		return true, method
	end

	local function acceptSellerPrompt(prompt)
		if typeof(prompt) ~= "Instance" then
			return false, "prompt_missing"
		end
		local yes = prompt:FindFirstChild("Yes")
		if not yes then
			return false, "prompt_yes_missing"
		end
		local fired, method = fireActivated(yes)
		if not fired then
			return false, "prompt_yes_activate_failed:" .. tostring(method)
		end
		return true, method
	end

	-- Old direct listing search is disabled on purpose. Direct calls were confirmed as delayed-kick prone.
	function SupplyScanner.getListingCandidates(config, itemType, itemName)
		return nil, "direct_get_item_listings_disabled_use_index_ui_path"
	end

	function SupplyScanner.chooseUnvisited(config, listings)
		return nil, "direct_listing_candidates_disabled_use_index_ui_path"
	end

	-- Old direct teleport is disabled on purpose. Use searchAndTeleportToListing.
	function SupplyScanner.teleportToListing(config, listing, itemType, itemName, plan)
		return false, "direct_teleport_to_listing_disabled_use_index_ui_path"
	end

	function SupplyScanner.searchAndTeleportToListing(config, itemType, itemName, plan)
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

		local okIndex, IndexController = pcall(function()
			return require(ReplicatedStorage.Controllers.Trading.IndexController)
		end)
		if not okIndex or type(IndexController) ~= "table" or type(IndexController.Preview) ~= "function" then
			return false, "index_controller_preview_missing"
		end

		local returnPlaceId, returnJobId, returnSource = getReturnTarget(config)
		if config.DeliveryMode == "SupplyThenTrade" and returnJobId == game.JobId and config.SupplyAllowCurrentServerReturn ~= true then
			Logger.warn("Supply return target is current server fallback. Set SupplyReturnPlaceId/SupplyReturnJobId if delivery must return elsewhere.")
		end

		phase(config, "supply_index_preview", { safeToRetry = true, dangerous = false, ItemType = itemType, ItemName = itemName })
		Logger.info("Opening Index seller search for:", tostring(itemType), tostring(itemName))

		local okPreview, previewErr = pcall(function()
			IndexController:Preview(itemType, { Name = itemName })
		end)
		if not okPreview then
			return false, "index_preview_error:" .. tostring(previewErr)
		end

		task.wait(tonumber(config.SupplyIndexPreviewWait or 1.5) or 1.5)

		phase(config, "supply_index_show_sellers", { safeToRetry = true, dangerous = false })
		local clicked, clickReason = activateShowSellers(config)
		if not clicked then
			return false, clickReason
		end

		local prompt, promptClass, promptText = waitForSellerPrompt(tonumber(config.SupplyIndexPromptWait or 12) or 12)
		phase(config, "supply_index_prompt", { safeToRetry = true, dangerous = false, PromptClass = promptClass })

		if promptClass == "no_sellers" then
			return false, "no_listings"
		end
		if promptClass ~= "seller_found" then
			return false, "seller_prompt_not_found:" .. tostring(promptClass) .. ":" .. tostring(promptText):sub(1, 160)
		end

		SupplyState.Save(config, {
			Stage = "teleported_to_listing",
			BridgeId = config.BridgeId,
			Dangerous = false,
			SafeToRetry = true,
			SearchMode = "IndexPrompt",
			ItemType = itemType,
			ItemName = itemName,
			ItemKey = itemKey,
			MaxBuyPrice = plan and plan.MaxBuyPrice or config.MaxBuyPrice,
			InitialOwned = plan and plan.Owned or nil,
			Needed = plan and plan.Needed or tonumber(config.Quantity or 1),
			MissingAtStart = plan and plan.Missing or nil,
			SellerUserId = nil,
			SellerName = nil,
			ListingGUID = nil,
			ReturnPlaceId = returnPlaceId,
			ReturnJobId = returnJobId,
			ReturnSource = returnSource,
			SourcePlaceId = game.PlaceId,
			SourceJobId = game.JobId,
		})

		phase(config, "supply_index_accept_teleport", { safeToRetry = true, dangerous = false })
		local accepted, acceptReason = acceptSellerPrompt(prompt)
		if not accepted then
			SupplyState.Clear(config)
			return false, acceptReason
		end

		local oldJob = game.JobId
		task.wait(tonumber(config.SupplyTeleportConfirmWait or 8) or 8)
		if game.JobId == oldJob then
			-- In many executors the current script dies during teleport before this line.
			-- If it reaches this line unchanged, clear the state so it does not resume as if it landed.
			SupplyState.Clear(config)
			return false, "index_teleport_no_server_change"
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
			SellerName = state.SellerName,
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
