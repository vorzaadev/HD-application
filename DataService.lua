--// Object-oriented data service module to handle player data and leaderboards

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

local Public = ReplicatedStorage:WaitForChild("Public")
local TrackableStats = require(Public:WaitForChild("TrackableStats"))

local MAX_ATTEMPTS = 5
local PLAYER_KEY_PREFIX = "player_"

local PlayerData = {}
PlayerData.__index = PlayerData

--// Create our new object to hold the data for a player
function PlayerData.new(player: Player)
	local self = setmetatable({}, PlayerData)

	self.player = player
	self.userId = player.UserId
	self.allTimeStats = {}
	self.dailyStats = {}
	self.isLoaded = false

	return self
end

--// Getters for daily/all-time stats, takes a name string and returns a number value
function PlayerData:GetAllTimeStat(statName: string): number
	return self.allTimeStats[statName] or 0
end

function PlayerData:GetDailyStat(statName: string): number
	return self.dailyStats[statName] or 0
end

--// Setters for daily/all-time stats, takes a name string and sets a number value
function PlayerData:SetAllTimeStat(statName: string, value: number)
	if type(statName) ~= "string" or type(value) ~= "number" then
		warn("PlayerData: Invalid stat name or value type")
		return
	end

	self.allTimeStats[statName] = value
	self:_updateLeaderstats(statName, value)
end

function PlayerData:SetDailyStat(statName: string, value: number)
	if type(statName) ~= "string" or type(value) ~= "number" then
		warn("PlayerData: Invalid stat name or value type")
		return
	end

	self.dailyStats[statName] = value
end

--// Incrementers for daily/all-time stats taking a name string and an increment amount
function PlayerData:IncrementAllTimeStat(statName: string, increment: number)
	local currentValue = self:GetAllTimeStat(statName)
	self:SetAllTimeStat(statName, currentValue + increment)
end

function PlayerData:IncrementDailyStat(statName: string, increment: number)
	local currentValue = self:GetDailyStat(statName)
	self:SetDailyStat(statName, currentValue + increment)
end

function PlayerData:IncrementBothStats(statName: string, increment: number)
	self:IncrementAllTimeStat(statName, increment)
	self:IncrementDailyStat(statName, increment)
end

--// Reset daily stats in case the player's in the server at the time of reset
function PlayerData:ResetDailyStats()
	print("Resetting daily stats for player:", self.player.Name)

	for statName, _ in pairs(TrackableStats) do
		self.dailyStats[statName] = 0
	end
end

--// Create a leaderstats folder for the Roblox leaderboard and populate it
function PlayerData:CreateLeaderstats()
	if not self.isLoaded then
		warn("PlayerData: Cannot create leaderstats - data not loaded for player:", self.player.Name)
		return
	end

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = self.player

	for statName, value in pairs(self.allTimeStats) do
		local stat = Instance.new("IntValue")
		stat.Name = self:_formatStatName(statName)
		stat.Value = value
		stat.Parent = leaderstats
	end
end

--// Update a leaderstat value from a name string and a number value
function PlayerData:_updateLeaderstats(statName: string, value: number)
	local leaderstats = self.player:FindFirstChild("leaderstats")
	if leaderstats then
		local stat = leaderstats:FindFirstChild(self:_formatStatName(statName))
		if stat then
			stat.Value = value
		end
	end
end

--// Format a stat name so it looks pretty (e.g., "StudsMoved" -> "Studs Moved")
function PlayerData:_formatStatName(statName: string): string
	return statName:gsub("(%u)", " %1"):gsub("^%s", "")
end

local DataService = {}
DataService.__index = DataService

--// Create a new DataService instance
function DataService.new()
	local self = setmetatable({}, DataService)

	self.playerDataObjects = {}
	self.dataStores = {}
	self.dailyDataStores = {}
	self.leaderboardCache = {}
	self.savingPlayers = {}
	self.isRefreshingLeaderboard = false

	self:_initializeDataStores()
	self:_startDailyResetTimer()

	return self
end

--// Initialize and cache our DataStore references to avoid repeat calls
function DataService:_initializeDataStores()
	local currentDate = self:_getCurrentDateString()

	for statName, _ in pairs(TrackableStats) do
		self.dataStores[statName] = DataStoreService:GetOrderedDataStore(statName)
		self.dailyDataStores[statName] = DataStoreService:GetOrderedDataStore("Daily_" .. statName .. currentDate)
	end
end

--// Get the current date string in "YYYY-MM-DD" format for DataStore naming
function DataService:_getCurrentDateString(): string
	local utcTime = os.time(os.date("!*t"))
	local utcDate = os.date("!*t", utcTime)
	return string.format("%04d-%02d-%02d", utcDate.year, utcDate.month, utcDate.day)
end

--// Calculate seconds until the next midnight UTC for daily resets and refreshing
function DataService:_getSecondsUntilMidnight(): number
	local now = os.time(os.date("!*t"))
	local tomorrow = os.time(os.date("!*t", now + 86400))
	local tomorrowMidnight = os.time({
		year = os.date("!*t", tomorrow).year,
		month = os.date("!*t", tomorrow).month,
		day = os.date("!*t", tomorrow).day,
		hour = 0,
		min = 0,
		sec = 0,
	})
	return tomorrowMidnight - now
end

--// Safe retry attempt-based system for sensitive data operations, takes a function, context string, and max attempts
function DataService:_retryOperation(operation: any, context: string, maxAttempts: number)
	for attempt = 1, maxAttempts do
		local success, result = pcall(operation)

		if success then
			return true, result
		end

		if attempt == maxAttempts then
			warn(string.format("DataService: %s failed after %d attempts: %s", context, maxAttempts, tostring(result)))
			return false, result
		end

		task.wait(0.1 * attempt)
	end

	return false, nil
end

--// Generate the player key from a userId for our DataStore keys
function DataService:_getPlayerKey(userId: number): string
	return PLAYER_KEY_PREFIX .. tostring(userId)
end

--// Start a timer that resets daily stats at midnight UTC
function DataService:_startDailyResetTimer()
	task.spawn(function()
		while true do
			task.wait(self:_getSecondsUntilMidnight())

			print("Performing daily stats reset...")

			self:_initializeDataStores() --// Re-initialize daily DataStores with new suffix

			for _, playerData in pairs(self.playerDataObjects) do
				playerData:ResetDailyStats()
			end

			print("Daily stats reset completed")
		end
	end)
end

--// Get the PlayerData object for a given player
function DataService:GetPlayerData(player: Player): PlayerData?
	return self.playerDataObjects[player.UserId]
end

--// Retrieve player data from DataStores and create a PlayerData object
function DataService:RetrieveData(player: Player): PlayerData
	local userId = player.UserId

	local playerData = self.playerDataObjects[userId] or PlayerData.new(player)
	self.playerDataObjects[userId] = playerData

	--// All-time stats
	for statName, store in pairs(self.dataStores) do
		local success, value = self:_retryOperation(function()
			return store:GetAsync(self:_getPlayerKey(userId))
		end, string.format("retrieving all-time data for player %s, stat %s", tostring(userId), statName), MAX_ATTEMPTS)

		playerData.allTimeStats[statName] = success and (value or 0) or 0
	end

	--// Daily stats
	for statName, store in pairs(self.dailyDataStores) do
		local success, value = self:_retryOperation(function()
			return store:GetAsync(self:_getPlayerKey(userId))
		end, string.format("retrieving daily data for player %s, stat %s", tostring(userId), statName), MAX_ATTEMPTS)

		playerData.dailyStats[statName] = success and (value or 0) or 0
	end

	playerData.isLoaded = true
	return playerData
end

--// Save player data back to DataStores so their data persists
function DataService:SaveData(player: Player)
	local userId = player.UserId
	local playerData = self.playerDataObjects[userId]

	if not playerData or not playerData.isLoaded then
		warn(string.format("DataService: No data found for player %s when saving", player.Name))
		return
	end

	if self.savingPlayers[userId] then
		return
	end

	self.savingPlayers[userId] = true

	print(string.format("Saving data for player %s", player.Name))

	--// All-time stats
	for statName, store in pairs(self.dataStores) do
		local statValue = playerData.allTimeStats[statName]

		local success = self:_retryOperation(function()
			store:SetAsync(self:_getPlayerKey(userId), statValue)
		end, string.format("saving all-time data for player %s, stat %s", tostring(userId), statName), MAX_ATTEMPTS)

		if success then
			print(
				string.format("DataService: Successfully saved all-time %s for player %s", statName, tostring(userId))
			)
		end
	end

	--// Daily stats
	for statName, store in pairs(self.dailyDataStores) do
		local statValue = playerData.dailyStats[statName]

		local success = self:_retryOperation(function()
			store:SetAsync(self:_getPlayerKey(userId), statValue)
		end, string.format("saving daily data for player %s, stat %s", tostring(userId), statName), MAX_ATTEMPTS)

		if success then
			print(string.format("DataService: Successfully saved daily %s for player %s", statName, tostring(userId)))
		end
	end

	self.savingPlayers[userId] = nil
end

--// Set a specific stat value for a player from a key name, number value, and a boolean for daily values
function DataService:SetData(player: Player, key: string, value: number, isDaily: boolean)
	local playerData = self:GetPlayerData(player)
	if not playerData then
		warn(string.format("DataService: No data initialized for player %s", player.Name))
		return
	end

	if isDaily then
		playerData:SetDailyStat(key, value)
	else
		playerData:SetAllTimeStat(key, value)
	end
end

--// Increment a specific stat value for a player from a key name and increment amount
function DataService:IncrementData(player: Player, key: string, increment: number)
	local playerData = self:GetPlayerData(player)
	if not playerData then
		warn(string.format("DataService: No data initialized for player %s", player.Name))
		return
	end

	playerData:IncrementBothStats(key, increment)
end

--// Create leaderstats for a player
function DataService:CreateLeaderstats(player: Player)
	local playerData = self:GetPlayerData(player)
	if not playerData then
		warn(string.format("DataService: No data found for player %s when creating leaderstats", player.Name))
		return
	end

	playerData:CreateLeaderstats()
end

--// Get leaderboard data with an option to refresh from DataStores
function DataService:GetLeaderboardData(isRefresh: boolean)
	if isRefresh then
		if self.isRefreshingLeaderboard then
			return self.leaderboardCache
		end

		self.isRefreshingLeaderboard = true
		self.leaderboardCache = {}

		local success, result = self:_retryOperation(function()
			local data = {
				AllTime = {},
				Daily = {},
				SecondsRemaining = self:_getSecondsUntilMidnight(),
			}

			--// All-time data
			for statName, store in pairs(self.dataStores) do
				local pages = store:GetSortedAsync(false, 50)
				data.AllTime[statName] = pages:GetCurrentPage()
			end

			--// Daily data
			for statName, store in pairs(self.dailyDataStores) do
				local pages = store:GetSortedAsync(false, 50)
				data.Daily[statName] = pages:GetCurrentPage()
			end

			return data
		end, "refreshing leaderboard data", MAX_ATTEMPTS)

		if success then
			self.leaderboardCache = result
		else
			warn("DataService: Failed to refresh leaderboard data")
		end

		self.isRefreshingLeaderboard = false
		return self.leaderboardCache
	else
		return self.leaderboardCache
	end
end

--// Cleanup player data when a player leaves
function DataService:CleanupPlayer(player: Player)
	self.playerDataObjects[player.UserId] = nil
	self.savingPlayers[player.UserId] = nil
end

return DataService.new()
