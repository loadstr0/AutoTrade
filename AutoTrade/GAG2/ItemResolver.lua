-- AutoTrade/GAG2/ItemResolver.lua
--
-- Turns the Python-resolved MailboxItemsSpec (grow_a_garden/product_resolver.py's
-- resolve_mailbox_items() output -- a list of
-- {category, item_key, display, count, unique_instance} dicts) into the
-- exact {Category, ItemKey, Count} table that
-- Networking.Mailbox.SendBatch:Fire() expects.
--
-- Two very different resolution paths, matching the two inventory shapes
-- confirmed from the decompiled game scripts:
--
--   STACKABLE categories (Seeds, Trowels, EmptyPots, SeedPacks, Props,
--   Mushrooms, Gnomes, Raccoons, Crates, Sprinklers, WateringCans) --
--   MailboxItemCatalog keys these by the plain item name, and Python
--   already resolved the correct item_key string
--   (product_resolver.ITEM_CATALOG's "item_key" field, e.g. "Moon Bloom").
--   These pass through basically unchanged: {Category=cat, ItemKey=key,
--   Count=n}.
--
--   UNIQUE-INSTANCE categories (Pets, HarvestedFruits) -- Python can only
--   tell us *which species* to sell ("Bear"), never *which specific
--   inventory entry*, because that's an id assigned per-instance at
--   hatch/grow time and isn't knowable outside the live client. This
--   module is what actually walks the live inventory
--   (PlayerStateClient:GetLocalReplica().Data.Inventory[Category]) to
--   find `count` real entries matching that species and not currently
--   Equipped, and emits their real unique ids as ItemKey.
--
-- CONFIRMED 2026-07-17 (from the real MailboxController.lua source,
-- rebuildInventory() + isGiftableInventoryEntry()): Inventory.Pets is a
-- dictionary keyed DIRECTLY by the pet's unique instance id (a string --
-- same ids used in Networking.Pets.PetEquipped/PetUnequipped events),
-- with the VALUE being a table containing at least .Id (redundant with
-- the key) and .Equipped (boolean). This is the exact same shape as
-- Inventory.HarvestedFruits, which IS iterated directly in
-- rebuildInventory() (`for k, n in Data.HarvestedFruits do ... end`,
-- k=unique id, n=entry table) -- so "Shape B" below is the confirmed
-- real shape, not a guess. (Interesting side note: rebuildInventory()'s
-- own tile-grid loop structure -- `if category == "HarvestedFruits" then
-- ... elseif category ~= "Pets" then ...` -- never actually builds
-- clickable tiles for the Pets category at all, meaning the stock
-- MailboxController UI has no picker for gifting a pet this way; pets
-- must be sent through some other in-game flow. That's irrelevant to us
-- since we call Networking.Mailbox.SendBatch directly via script
-- injection rather than clicking through this UI -- we just needed to
-- confirm Data.Inventory.Pets's shape, which isGiftableInventoryEntry()
-- still describes precisely even though this particular UI never reads
-- it.) "Shape A" (array-of-entries) is kept as a defensive fallback only
-- in case a future game update changes this -- it should never actually
-- trigger given the above.
--
-- CONFIRMED 2026-07-17 (from the real MailboxItemCatalog.lua source,
-- Resolve()'s "Pets" branch): a pet's entry table's species field is
-- `.Name` -- exactly the field entryMatchesSpeciesName() below already
-- checks first. Verbatim from that function: `v1 = p3.Name or p2`, with
-- `.Mutation`, `.Size`, and `.Type` also read off the same entry table
-- (Type feeds pet-rainbow visual styling elsewhere, not gifting logic --
-- see PetTypes.Rainbow in MailboxController.lua). No longer a guess.

return function(ctx)
	local ItemResolver = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger

	local UNIQUE_INSTANCE_CATEGORIES = {
		Pets = true,
		HarvestedFruits = true,
	}

	local function getLocalReplicaData()
		local okRequire, PlayerStateClient = pcall(function()
			return require(ReplicatedStorage.ClientModules.PlayerStateClient)
		end)

		if not okRequire or type(PlayerStateClient) ~= "table" then
			return nil, "player_state_client_unavailable"
		end

		local okReplica, replica = pcall(function()
			return PlayerStateClient:GetLocalReplica()
		end)

		if not okReplica or not replica then
			return nil, "local_replica_not_ready"
		end

		local okData, data = pcall(function()
			return replica.Data
		end)

		if not okData or type(data) ~= "table" then
			return nil, "replica_data_missing"
		end

		return data, nil
	end

	-- Normalizes either inventory shape into a flat array of
	-- {id = <key or entry.Id>, entry = <the entry table>} so the rest of
	-- this module doesn't need to care which one the live game actually
	-- uses.
	local function flattenInventoryCategory(container)
		local out = {}

		if type(container) ~= "table" then
			return out
		end

		-- Shape A: array of entries, each carrying its own id field.
		local looksLikeArray = container[1] ~= nil

		if looksLikeArray then
			for _, entry in ipairs(container) do
				if type(entry) == "table" then
					local id = entry.Id or entry.UniqueId or entry.InstanceId or entry.Uuid
					table.insert(out, { id = id, entry = entry })
				end
			end

			return out
		end

		-- Shape B: dictionary keyed directly by the unique id.
		for key, entry in pairs(container) do
			if type(entry) == "table" then
				table.insert(out, { id = entry.Id or entry.UniqueId or key, entry = entry })
			end
		end

		return out
	end

	-- entry.Name is the confirmed real field (MailboxItemCatalog.lua's
	-- Resolve(): `v1 = p3.Name or p2`) -- the other fallbacks are just
	-- cheap insurance against a future rename, not guesses anymore.
	local function entryMatchesSpeciesName(entry, speciesName)
		local name = entry.Name or entry.Species or entry.ItemKey or entry.PetName

		if type(name) ~= "string" then
			return false
		end

		return name:lower() == tostring(speciesName or ""):lower()
	end

	local function entryIsEquipped(entry)
		return entry.Equipped == true or entry.IsEquipped == true
	end

	-- Finds up to `count` non-equipped inventory entries in `category`
	-- matching `speciesName`. Returns a list of real unique ids (strings
	-- or numbers, whatever the live game uses) or nil + reason on failure.
	local function findUniqueInstanceMatches(category, speciesName, count)
		local data, reason = getLocalReplicaData()

		if not data then
			return nil, reason
		end

		local inventory = data.Inventory

		if type(inventory) ~= "table" then
			return nil, "inventory_missing"
		end

		local container = inventory[category]

		if container == nil then
			return nil, "category_missing_in_inventory:" .. tostring(category)
		end

		local flat = flattenInventoryCategory(container)
		local matches = {}

		for _, item in ipairs(flat) do
			if item.id ~= nil and not entryIsEquipped(item.entry) and entryMatchesSpeciesName(item.entry, speciesName) then
				table.insert(matches, item.id)

				if #matches >= count then
					break
				end
			end
		end

		if #matches == 0 then
			return nil, "no_matching_" .. tostring(category) .. "_found_for:" .. tostring(speciesName)
		end

		return matches, nil
	end

	-- spec entries: {category, item_key, display, count, unique_instance}
	-- (field names as emitted by grow_a_garden/product_resolver.py's
	-- resolve_mailbox_items() -> payload_to_dict() -> JSON -> Lua decode,
	-- so they arrive with these exact lowercase/snake_case keys).
	function ItemResolver.Resolve(itemsSpec)
		if type(itemsSpec) ~= "table" or #itemsSpec == 0 then
			return nil, "no_items_spec"
		end

		local resolved = {}

		for _, spec in ipairs(itemsSpec) do
			local category = spec.category or spec.Category
			local itemKey = spec.item_key or spec.ItemKey
			local display = spec.display or spec.Display or spec.DisplayName or spec.display_name or itemKey
			local count = tonumber(spec.count or spec.Count or 1) or 1
			local uniqueInstance = spec.unique_instance or spec.UniqueInstance

			if not category or not itemKey then
				return nil, "malformed_spec_entry_missing_category_or_item_key"
			end

			if uniqueInstance or UNIQUE_INSTANCE_CATEGORIES[category] then
				local ids, reason = findUniqueInstanceMatches(category, itemKey, count)

				if not ids then
					Logger.warn("[ItemResolver] Could not resolve unique-instance item:", display, "reason:", reason)
					return nil, reason
				end

				for _, id in ipairs(ids) do
					table.insert(resolved, { Category = category, ItemKey = id, Count = 1 })
				end

				if #ids < count then
					Logger.warn(
						"[ItemResolver] Only found",
						#ids,
						"of",
						count,
						"requested",
						display,
						"in live inventory -- sending partial amount."
					)
				end
			else
				table.insert(resolved, { Category = category, ItemKey = itemKey, Count = count })
			end
		end

		if #resolved == 0 then
			return nil, "nothing_resolved"
		end

		return resolved, nil
	end

	return ItemResolver
end
