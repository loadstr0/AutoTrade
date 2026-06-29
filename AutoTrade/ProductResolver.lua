-- AutoTrade/ProductResolver.lua

return function(ctx)
	local ProductResolver = {}

	local ReplicatedStorage = ctx.Services.ReplicatedStorage
	local Logger = ctx.Modules.Logger

	local GiftProductsId = require(ReplicatedStorage.Shared.GiftProductsId)

	local function normalize(text)
		text = tostring(text or ""):lower()

		text = text:gsub("|.*$", "")
		text = text:gsub("blade ball", "")
		text = text:gsub("fast delivery", "")
		text = text:gsub("limited", "")
		text = text:gsub("(%d+)%s*x%s+", "%1 ")
		text = text:gsub("(%d+)x%s+", "%1 ")
		text = text:gsub("ten%s+", "10 ")
		text = text:gsub("fifty%s+", "50 ")
		text = text:gsub("two%s+hundred%s+fifty%s+", "250 ")
		text = text:gsub("one%s+", "1 ")
		text = text:gsub("[^%w%s]", " ")
		text = text:gsub("%s+", " ")
		text = text:gsub("^%s+", ""):gsub("%s+$", "")

		return text
	end

	local function getDisplay(entry, key)
		return tostring(entry.DisplayName or entry.name or entry.Name or key or "")
	end

	local function getProductId(entry)
		return tonumber(entry.productId or entry.ProductId or entry.id or entry.Id)
	end

	function ProductResolver.normalize(text)
		return normalize(text)
	end

	function ProductResolver.listMatches(query)
		local q = normalize(query)
		local matches = {}

		for key, entry in pairs(GiftProductsId) do
			if type(entry) == "table" then
				local display = getDisplay(entry, key)
				local productId = getProductId(entry)

				if productId then
					local nKey = normalize(key)
					local nDisplay = normalize(display)

					local score = 0

					if nDisplay == q then
						score = 100
					elseif nKey == q then
						score = 95
					elseif nDisplay:find(q, 1, true) then
						score = 70
					elseif q:find(nDisplay, 1, true) then
						score = 60
					elseif nKey:find(q, 1, true) then
						score = 50
					end

					if score > 0 then
						table.insert(matches, {
							key = key,
							entry = entry,
							displayName = display,
							productId = productId,
							score = score,
						})
					end
				end
			end
		end

		table.sort(matches, function(a, b)
			if a.score == b.score then
				return a.displayName < b.displayName
			end

			return a.score > b.score
		end)

		return matches
	end

	function ProductResolver.resolve(config)
		if config.ProductId then
			for key, entry in pairs(GiftProductsId) do
				if type(entry) == "table" and getProductId(entry) == config.ProductId then
					return {
						key = key,
						entry = entry,
						displayName = getDisplay(entry, key),
						productId = config.ProductId,
						score = 999,
					}
				end
			end

			return {
				key = "ManualProductId",
				entry = {
					productId = config.ProductId,
					DisplayName = config.ProductName or tostring(config.ProductId),
				},
				displayName = config.ProductName or tostring(config.ProductId),
				productId = config.ProductId,
				score = 900,
			}
		end

		local query = config.ProductName or config.OrderTitle or config.ItemName or ""
		local matches = ProductResolver.listMatches(query)

		Logger.info("Product query:", query)
		Logger.info("Normalized query:", normalize(query))
		Logger.info("Product matches:", #matches)

		for i = 1, math.min(#matches, 5) do
			local m = matches[i]
			Logger.info(("Match #%d score=%d id=%s name=%s key=%s"):format(
				i,
				m.score,
				tostring(m.productId),
				tostring(m.displayName),
				tostring(m.key)
			))
		end

		return matches[1]
	end

	return ProductResolver
end
