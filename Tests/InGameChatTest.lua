-- Tests/InGameChatTest.lua
-- Safe standalone test for writing real messages into Roblox's live
-- in-game chat. Does NOT touch trades, tokens, or Eldorado -- this only
-- answers one question: can the bot account actually write into chat
-- from this exploit client, and what channel name does Blade Ball
-- actually use?
--
-- Modern Roblox games (this one included, confirmed via TradeTabController
-- hooking TextChatService.ChildAdded for its own trade-chat channels) use
-- TextChatService's TextChannels system, not the old legacy Chat service.
-- "RBXGeneral" is Roblox's usual default name for the main public channel,
-- but that's an assumption until this test prints the real channel list
-- from a live server.
--
-- Run this standalone in the exploit client while actually in a Blade
-- Ball server (private server or public, doesn't matter for this test).

local TEST = {
	-- Change to a real player's username currently in the server if you
	-- want to test whisper/mention behavior too.
	BuyerName = "ioadstr0",

	-- Kept obviously a test message and short, in case REAL_SEND is on
	-- and this lands in a real player-visible chat.
	Message = "[BladeSpins test] please ignore -- verifying chat automation",

	-- Must flip to true to actually send anything. False = just lists
	-- the real channels that exist and stops there.
	REAL_SEND = false,

	-- If true (and REAL_SEND is true), also attempts a private whisper
	-- to BuyerName instead of/in addition to the general channel.
	TryWhisper = false,
}

local TextChatService = game:GetService("TextChatService")
local Players = game:GetService("Players")

local function log(...)
	print("[ChatTest]", ...)
end

local function warnLog(...)
	warn("[ChatTest]", ...)
end

local function findPlayer(name)
	local lower = tostring(name or ""):lower()

	for _, player in ipairs(Players:GetPlayers()) do
		if player.Name:lower() == lower or player.DisplayName:lower() == lower then
			return player
		end
	end

	return nil
end

log("Starting in-game chat test.")
log("REAL_SEND =", TEST.REAL_SEND)

local channelsFolder = TextChatService:FindFirstChild("TextChannels")

if not channelsFolder then
	warnLog("FAILED: TextChatService.TextChannels not found.")
	warnLog("This game may not use the modern TextChatService system the way expected. Stopping.")
	return
end

log("Found TextChannels. Existing channels right now:")

local channelNames = {}

for _, channel in ipairs(channelsFolder:GetChildren()) do
	log("  -", channel.Name, "(" .. channel.ClassName .. ")")
	channelNames[channel.Name] = channel
end

local generalChannel = channelsFolder:FindFirstChild("RBXGeneral")

if generalChannel then
	log("RBXGeneral found:", generalChannel:GetFullName())
else
	warnLog("RBXGeneral NOT found under TextChannels.")
	warnLog("Check the channel list printed above for the real name Blade Ball uses, then update this test.")
end

local buyer = findPlayer(TEST.BuyerName)

if buyer then
	log("Test buyer found in server:", buyer.Name, buyer.UserId)
else
	warnLog("Test buyer '" .. tostring(TEST.BuyerName) .. "' not found in this server right now.")
	warnLog("General-chat sending can still be tested below; whisper/mention just won't resolve to anyone.")
end

if not TEST.REAL_SEND then
	warnLog("REAL_SEND is false -- channel discovery only, nothing was sent.")
	warnLog("Set REAL_SEND = true (and optionally TryWhisper = true) and re-run to actually test writing.")
	return
end

if generalChannel then
	log("Sending a REAL test message to RBXGeneral in 3 seconds...")
	task.wait(3)

	local ok, result = pcall(function()
		return generalChannel:SendAsync(TEST.Message)
	end)

	if ok then
		log("SendAsync to RBXGeneral succeeded. Result:", result)
		log("Check the actual game chat window to confirm the message really appeared.")
	else
		warnLog("SendAsync to RBXGeneral FAILED:", result)
	end
else
	warnLog("Skipping general-channel send -- RBXGeneral was not found.")
end

if TEST.TryWhisper then
	if not buyer then
		warnLog("Skipping whisper test -- buyer not found in server.")
	else
		-- Roblox's own convention for whisper channel names is
		-- "RBXWhisper:<lowUserId>_<highUserId>", sorted so the smaller
		-- UserId comes first. This is Roblox's naming, not something
		-- Blade Ball chose -- if this doesn't find anything, check the
		-- channel list printed above; some games only create the whisper
		-- channel after one is opened once via the chat UI itself.
		local localId = Players.LocalPlayer.UserId
		local otherId = buyer.UserId
		local lowId, highId = math.min(localId, otherId), math.max(localId, otherId)
		local whisperName = ("RBXWhisper:%d_%d"):format(lowId, highId)

		local whisperChannel = channelsFolder:FindFirstChild(whisperName)

		if not whisperChannel then
			warnLog("Whisper channel not found as:", whisperName)
			warnLog("See the channel list printed above for what actually exists.")
		else
			log("Whisper channel found:", whisperName)
			log("Sending a REAL whisper test message in 3 seconds...")
			task.wait(3)

			local ok, result = pcall(function()
				return whisperChannel:SendAsync(TEST.Message)
			end)

			if ok then
				log("Whisper SendAsync succeeded. Result:", result)
			else
				warnLog("Whisper SendAsync FAILED:", result)
			end
		end
	end
end

log("Test complete.")
