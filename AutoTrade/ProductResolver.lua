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
		text = text:gsub("two%s+hundred%s+fifty", "250")
		text = text:gsub("one%s+hundred", "100")
		text = text:gsub("hundred", "100")
		text = text:gsub("fifty", "50")
		text = text:gsub("ten", "10")
		text = text:gsub("one", "1")
		text = text:gsub("[^%w%s]", " ")
		text = text:gsub("%s+", " ")
		text = text:gsub("^%s+", ""):gsub("%s+$", "")

		return text
	end

	local function getDisplay(entry, key)
		return tostring(entry.DisplayName or entry.displayName or entry.name or entry.Name or key or "")
	end

	local function getProductId(entry)
		return tonumber(entry.productId or entry.ProductId or entry.id or entry.Id)
	end

	local function containsAny(text, words)
		text = normalize(text)

		for _, word in ipairs(words) do
			if text:find(word, 1, true) then
				return true
			end
		end

		return false
	end

	local function extractNumberNearSpin(text)
		local raw = tostring(text or "")
		local lowered = raw:lower()

		-- Most Eldorado titles look like: "50x Soccer Spins | Blade Ball | Fast Delivery"
		local amount = lowered:match("(%d+)%s*x%s*[%w%s%-_]*spin")
			or lowered:match("(%d+)x%s*[%w%s%-_]*spin")
			or lowered:match("(%d+)%s*[%w%s%-_]*spin")
			or lowered:match("(%d+)%s*x%s*[%w%s%-_]*gacha")
			or lowered:match("(%d+)x%s*[%w%s%-_]*gacha")
			or lowered:match("(%d+)%s*[%w%s%-_]*gacha")

		if amount then
			return tonumber(amount)
		end

		local n = normalize(lowered)

		amount = n:match("(%d+)%s+[%w%s]*spin")
			or n:match("(%d+)%s+[%w%s]*gacha")
			or n:match("(%d+)")

		return tonumber(amount)
	end

	local function isSpinGiftProduct(text)
		return containsAny(text, { "spin", "spins", "gacha" })
	end

	local function productMatchesOrderTopic(productText, orderText)
		local p = normalize(productText)
		local q = normalize(orderText)

		-- If the order says Soccer, only use Soccer products.
		if q:find("soccer", 1, true) then
			return p:find("soccer", 1, true) ~= nil
		end

		return true
	end

	local function getOrderQuery(config)
		return config.ProductName or config.ItemName or config.OrderTitle or ""
	end

	local function getOrderSpinAmount(config)
		local fields = {
			config.ProductName,
			config.ItemName,
			config.OrderTitle,
		}

		for _, field in ipairs(fields) do
			if field and field ~= "" then
				local amount = extractNumberNearSpin(field)

				if amount and amount > 0 then
					return amount
				end
			end
		end

		return nil
	end


	local function getAllowedSpinPacks(config)
		local raw = config and config.GiftAllowedSpinPacks
		local allowed = {}

		if type(raw) == "table" then
			for _, value in pairs(raw) do
				local n = tonumber(value)

				if n and n > 0 then
					allowed[n] = true
				end
			end
		end

		-- Blade Ball currently shows gift packs: 1, 10, 50, 250.
		-- If config did not provide a table, use this safe visible-pack default.
		if next(allowed) == nil then
			allowed[1] = true
			allowed[10] = true
			allowed[50] = true
			allowed[250] = true
		end

		return allowed
	end

	local function listSpinProductsForOrder(config)
		local query = getOrderQuery(config)
		local allowedPacks = getAllowedSpinPacks(config)
		local products = {}

		for key, entry in pairs(GiftProductsId) do
			if type(entry) == "table" then
				local display = getDisplay(entry, key)
				local productId = getProductId(entry)
				local combined = tostring(key) .. " " .. tostring(display)

				if productId and isSpinGiftProduct(combined) and productMatchesOrderTopic(combined, query) then
					local amount = extractNumberNearSpin(combined)

					if amount and amount > 0 and allowedPacks[amount] == true then
						table.insert(products, {
							key = key,
							entry = entry,
							displayName = display,
							productId = productId,
							amount = amount,
						})
					elseif amount and amount > 0 then
						Logger.warn("Ignoring spin gift pack not in GiftAllowedSpinPacks:", tostring(amount), tostring(display), tostring(key))
					end
				end
			end
		end

		table.sort(products, function(a, b)
			if a.amount == b.amount then
				return tostring(a.displayName) < tostring(b.displayName)
			end

			return a.amount > b.amount
		end)

		return products
	end

	local function buildExactPlan(targetAmount, products)
		targetAmount = tonumber(targetAmount)

		if not targetAmount or targetAmount <= 0 then
			return nil, "invalid_target_amount"
		end

		if targetAmount ~= math.floor(targetAmount) then
			return nil, "non_integer_target_amount"
		end

		local dp = {}
		dp[0] = { count = 0, steps = {} }

		for amount = 1, targetAmount do
			local best = nil

			for _, product in ipairs(products) do
				local pack = tonumber(product.amount)

				if pack and pack > 0 and amount >= pack and dp[amount - pack] then
					local prev = dp[amount - pack]
					local candidateCount = prev.count + 1

					if not best or candidateCount < best.count or (candidateCount == best.count and pack > best.lastPack) then
						local steps = {}

						for _, step in ipairs(prev.steps) do
							table.insert(steps, step)
						end

						table.insert(steps, product)

						best = {
							count = candidateCount,
							steps = steps,
							lastPack = pack,
						}
					end
				end
			end

			dp[amount] = best
		end

		if not dp[targetAmount] then
			return nil, "exact_gift_plan_not_possible"
		end

		table.sort(dp[targetAmount].steps, function(a, b)
			return tonumber(a.amount or 0) > tonumber(b.amount or 0)
		end)

		return dp[targetAmount].steps, "exact_plan"
	end

	function ProductResolver.normalize(text)
		return normalize(text)
	end

	function ProductResolver.getOrderSpinAmount(config)
		return getOrderSpinAmount(config)
	end

	function ProductResolver.listSpinProducts(config)
		return listSpinProductsForOrder(config)
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

		local query = getOrderQuery(config)
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

	function ProductResolver.buildGiftPlan(config)
		local query = getOrderQuery(config)
		local orderQuantity = math.max(1, tonumber(config.OrderQuantity or 1) or 1)

		-- Manual product id stays direct: send exactly OrderQuantity times.
		if config.ProductId then
			local product = ProductResolver.resolve(config)

			if not product then
				return nil, "manual_product_not_found"
			end

			local plan = {}

			for _ = 1, orderQuantity do
				table.insert(plan, product)
			end

			return {
				steps = plan,
				totalAmount = nil,
				mode = "manual_product_id",
				display = tostring(product.displayName),
			}, "manual_product_id"
		end

		-- Spin/gacha orders need an exact pack plan. Never overdeliver by choosing 100 for 50.
		if isSpinGiftProduct(query) then
			local perOrderAmount = getOrderSpinAmount(config)

			if not perOrderAmount then
				return nil, "could_not_parse_spin_amount"
			end

			local targetAmount = perOrderAmount * orderQuantity
			local products = listSpinProductsForOrder(config)

			Logger.info("Spin gift query:", query)
			Logger.info("Spin amount per order:", perOrderAmount)
			Logger.info("Eldorado order quantity:", orderQuantity)
			Logger.info("Total spins to gift:", targetAmount)
			Logger.info("Available matching spin gift packs:", #products)

			for i, product in ipairs(products) do
				Logger.info(("Spin pack #%d: amount=%s id=%s name=%s key=%s"):format(
					i,
					tostring(product.amount),
					tostring(product.productId),
					tostring(product.displayName),
					tostring(product.key)
				))
			end

			if #products == 0 then
				return nil, "no_matching_spin_gift_products"
			end

			local steps, reason = buildExactPlan(targetAmount, products)

			if not steps then
				if config.GiftAllowOverdelivery == true then
					return nil, "overdelivery_planning_not_implemented"
				end

				return nil, reason
			end

			return {
				steps = steps,
				totalAmount = targetAmount,
				mode = "exact_spin_plan",
				display = tostring(targetAmount) .. " Spins",
			}, "exact_spin_plan"
		end

		-- Non-spin gifts keep old one-product behavior.
		local product = ProductResolver.resolve(config)

		if not product then
			return nil, "product_not_found"
		end

		local plan = {}

		for _ = 1, orderQuantity do
			table.insert(plan, product)
		end

		return {
			steps = plan,
			totalAmount = nil,
			mode = "single_product_repeat",
			display = tostring(product.displayName),
		}, "single_product_repeat"
	end

	return ProductResolver
end
