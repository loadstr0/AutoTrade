-- AutoTrade/ChatActions.lua
--
-- Real in-game chat sending. Confirmed live via Tests/InGameChatTest.lua:
-- general chat works through TextChatService.TextChannels.RBXGeneral;
-- a private whisper did NOT resolve in that same test (the
-- "RBXWhisper:<lowId>_<highId>" channel-name guess wasn't found), so this
-- only supports general chat for now -- whisper support can be added once
-- the real channel-creation mechanism is confirmed.
--
-- Used for things like telling a buyer their trade privacy setting looks
-- off and asking them to send the trade to us instead, when the retry
-- flow in TokenTradeMain.lua switches TradeDirection to "incoming".

return function(ctx)
	local ChatActions = {}

	local Services = ctx.Services
	local TextChatService = Services.TextChatService or game:GetService("TextChatService")
	local Logger = ctx.Modules.Logger

	local lastSendTimes = {}

	local function getGeneralChannel()
		local folder = TextChatService:FindFirstChild("TextChannels")

		if not folder then
			return nil, "no_text_channels_folder"
		end

		local channel = folder:FindFirstChild("RBXGeneral")

		if not channel then
			return nil, "rbxgeneral_not_found"
		end

		return channel
	end

	-- Simple per-message cooldown so a retry loop can't spam the exact
	-- same text into a public channel repeatedly if something misfires.
	function ChatActions.sendGeneralMessage(text, cooldownSeconds)
		text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")

		if text == "" then
			return false, "empty_message"
		end

		cooldownSeconds = tonumber(cooldownSeconds or 30) or 30

		local now = os.clock()
		local lastSent = lastSendTimes[text]

		if lastSent and (now - lastSent) < cooldownSeconds then
			if Logger then
				Logger.info("ChatActions.sendGeneralMessage: skipped, same message sent recently:", text)
			end
			return false, "cooldown_active"
		end

		local channel, err = getGeneralChannel()

		if not channel then
			if Logger then
				Logger.warn("ChatActions.sendGeneralMessage: channel unavailable:", err)
			end
			return false, err
		end

		local ok, result = pcall(function()
			return channel:SendAsync(text)
		end)

		if not ok then
			if Logger then
				Logger.warn("ChatActions.sendGeneralMessage: SendAsync failed:", result)
			end
			return false, "send_failed:" .. tostring(result)
		end

		lastSendTimes[text] = now

		if Logger then
			Logger.info("Sent general chat message:", text)
		end

		return true, "sent"
	end

	-- Convenience wrapper that prefixes an @mention, since general chat is
	-- visible to everyone in the server -- this makes clear who the
	-- message is directed at, same as a normal player would type it.
	function ChatActions.sendMessageToBuyer(buyerName, text, cooldownSeconds)
		buyerName = tostring(buyerName or ""):gsub("^%s+", ""):gsub("%s+$", "")
		text = tostring(text or "")

		if buyerName == "" then
			return ChatActions.sendGeneralMessage(text, cooldownSeconds)
		end

		local mentioned = ("@%s %s"):format(buyerName, text)
		return ChatActions.sendGeneralMessage(mentioned, cooldownSeconds)
	end

	return ChatActions
end
