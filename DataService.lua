--// Object-oriented data service module to handle player data and leaderboards
--// Two classes are defined here: PlayerData (per-player state) and DataService (the singleton manager).
--// DataService is returned already instantiated at the bottom so anything that needs it just require() and use it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")

--// Public is a shared folder accessible by both server and client scripts
local Public = ReplicatedStorage:WaitForChild("Public")

--// TrackableStats is a dictionary which keys are the stat names we care about (e.g. { StudsMoved = true })
--// It acts as the source for which stats exist, so adding a new stat only requires editing that module
local TrackableStats = require(Public:WaitForChild("TrackableStats"))

--// Maximum number of retries for any DataStore operation before we give up and warn
local MAX_ATTEMPTS = 5

--// All DataStore keys are prefixed so they're namespaced and won't mix with other data in the same store
local PLAYER_KEY_PREFIX = "player_"

--// PlayerData class
--// Holds the in-memory state for a single player.
--// One instance is created per player on join and cleaned up on leave.

local PlayerData = {}
PlayerData.__index = PlayerData

--// Create our new object to hold the data for a player.
--// setmetatable links the new table to PlayerData so method calls like self:GetAllTimeStat() resolve correctly.
function PlayerData.new(player: Player)
	local self = setmetatable({}, PlayerData)

	self.player = player
	self.userId = player.UserId

	--// Separate tables for all-time vs daily stats so resets only touch the daily table,
	--// leaving lifetime progress untouched
	self.allTimeStats = {}
	self.dailyStats = {}

	--// isLoaded is a guard flag, leaderstats and saving are blocked until data has
	--// been fetched from the DataStore, preventing partial or zero-value writes
	self.isLoaded = false

	return self
end

--// Getters for daily/all-time stats, takes a name string and returns a number value.
--// Defaulting to 0 with `or 0` means callers never have to nil-check, a missing stat is treated as zero.
function PlayerData:GetAllTimeStat(statName: string): number
	return self.allTimeStats[statName] or 0
end

function PlayerData:GetDailyStat(statName: string): number
	return self.dailyStats[statName] or 0
end

--// Setters for daily/all-time stats, takes a name string and sets a number value.
--// Type validation at the top catches accidental string-number mix-ups early and surfaces them as warnings
--// rather than silently corrupting the DataStore with the wrong type.
function PlayerData:SetAllTimeStat(statName: string, value: number)
	if type(statName) ~= "string" or type(value) ~= "number" then
		warn("PlayerData: Invalid stat name or value type")
		return
	end

	self.allTimeStats[statName] = value

	--// Mirror the change to the live leaderstats folder so the Roblox leaderboard updates immediately,
	--// without needing to recreate or re-read the whole folder
	self:_updateLeaderstats(statName, value)
end

function PlayerData:SetDailyStat(statName: string, value: number)
	if type(statName) ~= "string" or type(value) ~= "number" then
		warn("PlayerData: Invalid stat name or value type")
		return
	end

	--// Daily stats are purely in-memory between resets and don't drive the Roblox leaderboard,
	--// so no _updateLeaderstats call is needed here
	self.dailyStats[statName] = value
end

--// Incrementers for daily/all-time stats taking a name string and an increment amount.
--// Delegating to the getters/setters means validation and leaderstat sync happen automatically
function PlayerData:IncrementAllTimeStat(statName: string, increment: number)
	local currentValue = self:GetAllTimeStat(statName)
	self:SetAllTimeStat(statName, currentValue + increment)
end

function PlayerData:IncrementDailyStat(statName: string, increment: number)
	local currentValue = self:GetDailyStat(statName)
	self:SetDailyStat(statName, currentValue + increment)
end

--// Convenience wrapper that increments both tables in one call.
--// Used when an event (e.g. a player moving studs) should count toward both lifetime and daily totals.
function PlayerData:IncrementBothStats(statName: string, increment: number)
	self:IncrementAllTimeStat(statName, increment)
	self:IncrementDailyStat(statName, increment)
end

--// Reset daily stats in case the player is still in the server at the time of the midnight reset.
--// Iterates TrackableStats (the authoritative list) rather than dailyStats itself,
--// so any stat that was never set still gets explicitly set to 0.
function PlayerData:ResetDailyStats()
	print("Resetting daily stats for player:", self.player.Name)

	for statName, _ in pairs(TrackableStats) do
		self.dailyStats[statName] = 0
	end
end

--// Create a leaderstats folder for the Roblox leaderboard and populate it.
--// The folder must be named "leaderstats" and parented directly to the Player instance for the UI
function PlayerData:CreateLeaderstats()
	--// Don't create the folder until data is confirmed loaded, otherwise every stat shows 0
	if not self.isLoaded then
		warn("PlayerData: Cannot create leaderstats - data not loaded for player:", self.player.Name)
		return
	end

	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = self.player

	--// Each stat gets its own IntValue child; Roblox reads these children to display columns on the leaderboard UI
	for statName, value in pairs(self.allTimeStats) do
		local stat = Instance.new("IntValue")

		--// Format the name for readability (e.g. "StudsMoved" → "Studs Moved") since
		--// the raw camelCase key would look weird to players on the leaderboard UI
		stat.Name = self:_formatStatName(statName)
		stat.Value = value
		stat.Parent = leaderstats
	end
end

--// Update a leaderstat value from a name string and a number value.
--// Called internally whenever an all-time stat changes so the leaderboard stays in sync live.
--// Silently skips if leaderstats hasn't been created yet (e.g. data still loading).
function PlayerData:_updateLeaderstats(statName: string, value: number)
	local leaderstats = self.player:FindFirstChild("leaderstats")
	if leaderstats then
		--// Look up the formatted name because the IntValue children use the display name, not the raw key
		local stat = leaderstats:FindFirstChild(self:_formatStatName(statName))
		if stat then
			stat.Value = value
		end
	end
end

--// Format a stat name so it looks pretty (e.g., "StudsMoved" -> "Studs Moved").
--// gsub("(%u)", " %1") inserts a space before every uppercase letter.
--// gsub("^%s", "") strips any leading space that appears if the name starts with a capital letter.
function PlayerData:_formatStatName(statName: string): string
	return statName:gsub("(%u)", " %1"):gsub("^%s", "")
end

--// DataService class
--// Singleton manager that owns all PlayerData objects and coordinates DataStore I/O.
--// Returned pre-instantiated at the bottom so other scripts just require() this module.

local DataService = {}
DataService.__index = DataService

--// Create a new DataService instance.
--// Called once at module load time, the result is what gets returned to the require.
function DataService.new()
	local self = setmetatable({}, DataService)

	--// playerDataObjects: userId -> PlayerData, it's a live in-memory store for all connected players
	self.playerDataObjects = {}

	--// dataStores / dailyDataStores: statName -> OrderedDataStore reference, cached so we don't call
	--// GetOrderedDataStore repeatedly (Roblox rate-limits them)
	self.dataStores = {}
	self.dailyDataStores = {}

	--// leaderboardCache holds the last fetched leaderboard payload so clients can read it without
	--// triggering a DataStore read every time
	self.leaderboardCache = {}

	--// savingPlayers tracks which userIds are mid-save to prevent concurrent saves for the same player,
	--// which could cause race conditions and corrupt DataStore entries
	self.savingPlayers = {}

	--// isRefreshingLeaderboard is a mutex flag that prevents multiple simultaneous leaderboard
	--// refreshes from piling up and exceeding the DataStore budget
	self.isRefreshingLeaderboard = false

	self:_initializeDataStores()
	self:_startDailyResetTimer()

	return self
end

--// Initialize and cache our DataStore references to avoid repeat calls.
--// Daily stores include today's date in their name so they're automatically scoped to the current day
--// yesterday's daily store becomes unreachable without any explicit deletion or migration needed.
function DataService:_initializeDataStores()
	local currentDate = self:_getCurrentDateString()

	for statName, _ in pairs(TrackableStats) do
		--// All-time store: just the stat name — data accumulates indefinitely
		self.dataStores[statName] = DataStoreService:GetOrderedDataStore(statName)

		--// Daily store: name includes the date suffix so each day gets a fresh, isolated store automatically
		self.dailyDataStores[statName] = DataStoreService:GetOrderedDataStore("Daily_" .. statName .. currentDate)
	end
end

--// Get the current date string in "YYYY-MM-DD" format for DataStore naming.
--// os.date("!*t") returns UTC time as a table, passing it back through os.time() normalises it to a Unix timestamp.
--// We then format it as an ISO date string so daily store names are human-readable and sortable.
function DataService:_getCurrentDateString(): string
	local utcTime = os.time(os.date("!*t"))
	local utcDate = os.date("!*t", utcTime)
	return string.format("%04d-%02d-%02d", utcDate.year, utcDate.month, utcDate.day)
end

--// Calculate seconds until the next midnight UTC for daily resets and refreshing.
--// We advance `now` by 86400 seconds (one full day) to land somewhere in tomorrow, then rebuild a
--// midnight timestamp from just the date components (hour/min/sec all zero). Subtracting `now` gives
--// the exact wait duration so the reset fires at 00:00:00 UTC regardless of when the server started.
function DataService:_getSecondsUntilMidnight(): number
	local now = os.time(os.date("!*t"))

	--// Adding 86400s guarantees we're in tomorrow even late at night when seconds remain until midnight
	local tomorrow = os.time(os.date("!*t", now + 86400))

	--// Reconstruct the timestamp with time components zeroed out to get exactly 00:00:00 of that day
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

--// Safe retry attempt-based system for sensitive data operations, takes a function, context string, and max attempts.
--// pcall catches any DataStore errors (network failures, budget exceeded, etc.) without crashing the script.
--// Back-off between attempts (0.1s * attempt number) gives the DataStore service time to recover
--// and avoids hammering it with rapid retries when it's under load.
function DataService:_retryOperation(operation: any, context: string, maxAttempts: number)
	for attempt = 1, maxAttempts do
		local success, result = pcall(operation)

		if success then
			--// Return immediately on the first success, no need to exhaust all attempts
			return true, result
		end

		if attempt == maxAttempts then
			--// Only warn on the final failure so we don't spam the output on transient errors
			warn(string.format("DataService: %s failed after %d attempts: %s", context, maxAttempts, tostring(result)))
			return false, result
		end

		--// Exponential-ish back-off: 0.1s, 0.2s, 0.3s … giving the service time to stabilize
		task.wait(0.1 * attempt)
	end

	return false, nil
end

--// Generate the player key from a userId for our DataStore keys.
--// Prefixing with "player_" namespaces the key and makes it clear in the DataStore dashboard what the entry is.
function DataService:_getPlayerKey(userId: number): string
	return PLAYER_KEY_PREFIX .. tostring(userId)
end

--// Start a timer that resets daily stats at midnight UTC.
--// task.spawn runs this in a background coroutine so it doesn't block the server's main thread.
--// The infinite loop is intentional, it fires once per day for the lifetime of the server.
function DataService:_startDailyResetTimer()
	task.spawn(function()
		while true do
			--// Sleep until exactly midnight; _getSecondsUntilMidnight recalculates each iteration
			--// so clock drift over long server uptimes doesn't cause the reset to drift off midnight
			task.wait(self:_getSecondsUntilMidnight())

			print("Performing daily stats reset...")

			--// Re-initialize daily DataStores first so the new date suffix is in place before any
			--// stats are written, otherwise stats would flow into the previous day's store briefly
			self:_initializeDataStores() --// Re-initialize daily DataStores with new suffix

			--// Reset in-memory daily stats for every player currently online;
			--// players who join after midnight will load from the new (empty) store naturally
			for _, playerData in pairs(self.playerDataObjects) do
				playerData:ResetDailyStats()
			end

			print("Daily stats reset completed")
		end
	end)
end

--// Get the PlayerData object for a given player.
--// Returns nil if the player hasn't been loaded yet (e.g. called before RetrieveData completes).
function DataService:GetPlayerData(player: Player): PlayerData?
	return self.playerDataObjects[player.UserId]
end

--// Retrieve player data from DataStores and create a PlayerData object.
--// If an object already exists (e.g. from a previous partial load), it is reused rather than overwritten,
--// preserving any in-memory state that was set before the full load completed.
function DataService:RetrieveData(player: Player): PlayerData
	local userId = player.UserId

	local playerData = self.playerDataObjects[userId] or PlayerData.new(player)
	self.playerDataObjects[userId] = playerData

	--// All-time stats: fetched from the permanent ordered DataStore for each tracked stat
	for statName, store in pairs(self.dataStores) do
		local success, value = self:_retryOperation(function()
			return store:GetAsync(self:_getPlayerKey(userId))
		end, string.format("retrieving all-time data for player %s, stat %s", tostring(userId), statName), MAX_ATTEMPTS)

		--// If the fetch succeeded, use the stored value (which may itself be nil for a new player).
		--// If the fetch failed after all retries, default to 0 so the player can still play rather than being blocked.
		playerData.allTimeStats[statName] = success and (value or 0) or 0
	end

	--// Daily stats: same pattern but reading from the date-scoped daily DataStore
	for statName, store in pairs(self.dailyDataStores) do
		local success, value = self:_retryOperation(function()
			return store:GetAsync(self:_getPlayerKey(userId))
		end, string.format("retrieving daily data for player %s, stat %s", tostring(userId), statName), MAX_ATTEMPTS)

		playerData.dailyStats[statName] = success and (value or 0) or 0
	end

	--// Mark as loaded only after ALL stats have been fetched, so the isLoaded guard in CreateLeaderstats
	--// and SaveData won't pass prematurely with incomplete data
	playerData.isLoaded = true
	return playerData
end

--// Save player data back to DataStores so their data persists across sessions.
--// Uses OrderedDataStore:SetAsync() because leaderboard ordering needs the value stored directly.
function DataService:SaveData(player: Player)
	local userId = player.UserId
	local playerData = self.playerDataObjects[userId]

	--// Guard: skip the save entirely if data was never loaded, writing zeros would wipe real data
	if not playerData or not playerData.isLoaded then
		warn(string.format("DataService: No data found for player %s when saving", player.Name))
		return
	end

	--// Prevent a second save from starting while one is already in progress for the same player,
	--// which could cause two concurrent writes to race and produce inconsistent DataStore state
	if self.savingPlayers[userId] then
		return
	end

	self.savingPlayers[userId] = true

	print(string.format("Saving data for player %s", player.Name))

	--// All-time stats
	for statName, store in pairs(self.dataStores) do
		local statValue = playerData.allTimeStats[statName]

		local success = self:_retryOperation(function()
			--// SetAsync on an OrderedDataStore stores the numeric value under the player's key,
			--// which GetSortedAsync can later read back in ranked order for leaderboards
			store:SetAsync(self:_getPlayerKey(userId), statValue)
		end, string.format("saving all-time data for player %s, stat %s", tostring(userId), statName), MAX_ATTEMPTS)

		if success then
			print(
				string.format("DataService: Successfully saved all-time %s for player %s", statName, tostring(userId))
			)
		end
	end

	--// Daily stats: saved to the date-scoped store so the leaderboard can separately rank daily performance
	for statName, store in pairs(self.dailyDataStores) do
		local statValue = playerData.dailyStats[statName]

		local success = self:_retryOperation(function()
			store:SetAsync(self:_getPlayerKey(userId), statValue)
		end, string.format("saving daily data for player %s, stat %s", tostring(userId), statName), MAX_ATTEMPTS)

		if success then
			print(string.format("DataService: Successfully saved daily %s for player %s", statName, tostring(userId)))
		end
	end

	--// Release the lock so future saves (e.g. periodic autosave) can proceed for this player
	self.savingPlayers[userId] = nil
end

--// Set a specific stat value for a player from a key name, number value, and a boolean for daily values.
--// The isDaily flag lets callers target just the daily table without touching the all-time record,
--// which is useful for stats that reset but the lifetime total should be untouched.
function DataService:SetData(player: Player, key: string, value: number, isDaily: boolean)
	local playerData = self:GetPlayerData(player)
	if not playerData then
		warn(string.format("DataService: No data initialized for player %s", player.Name))
		return
	end

	if isDaily then
		playerData:SetDailyStat(key, value)
	else
		--// All-time setter also calls _updateLeaderstats internally, keeping the leaderboard in sync
		playerData:SetAllTimeStat(key, value)
	end
end

--// Increment a specific stat value for a player from a key name and increment amount.
--// Always increments both all-time and daily via IncrementBothStats, use SetData if you need
--// finer control over which table is affected.
function DataService:IncrementData(player: Player, key: string, increment: number)
	local playerData = self:GetPlayerData(player)
	if not playerData then
		warn(string.format("DataService: No data initialized for player %s", player.Name))
		return
	end

	playerData:IncrementBothStats(key, increment)
end

--// Create leaderstats for a player.
--// Thin wrapper that delegates to PlayerData:CreateLeaderstats, keeping the public API on DataService
--// so callers don't need to hold a direct reference to the PlayerData object.
function DataService:CreateLeaderstats(player: Player)
	local playerData = self:GetPlayerData(player)
	if not playerData then
		warn(string.format("DataService: No data found for player %s when creating leaderstats", player.Name))
		return
	end

	playerData:CreateLeaderstats()
end

--// Get leaderboard data with an option to refresh from DataStores.
--// When isRefresh is false the cached result is returned immediately with zero DataStore cost
--// useful for frequent UI polls that don't need real-time accuracy.
function DataService:GetLeaderboardData(isRefresh: boolean)
	if isRefresh then
		--// isRefreshingLeaderboard acts as a mutex: if a refresh is already running, return the
		--// stale cache rather than queuing up a second concurrent DataStore read
		if self.isRefreshingLeaderboard then
			return self.leaderboardCache
		end

		self.isRefreshingLeaderboard = true
		self.leaderboardCache = {} --// Clear the old cache so a partial failure leaves an empty table, not stale data

		local success, result = self:_retryOperation(function()
			local data = {
				AllTime = {},
				Daily = {},
				--// Include the countdown so clients can display a "resets in X" timer without their own clock logic
				SecondsRemaining = self:_getSecondsUntilMidnight(),
			}

			--// All-time data: GetSortedAsync(false, 50) returns the top 50 entries in descending order
			for statName, store in pairs(self.dataStores) do
				local pages = store:GetSortedAsync(false, 50)
				data.AllTime[statName] = pages:GetCurrentPage()
			end

			--// Daily data: same shape as all-time, but sourced from the date-scoped daily stores
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
			--// leaderboardCache remains {} on failure, safer than serving stale ranked data
		end

		--// Always release the mutex, even on failure, so future refreshes aren't permanently blocked
		self.isRefreshingLeaderboard = false
		return self.leaderboardCache
	else
		--// Fast path: return the last cached payload without touching the DataStore
		return self.leaderboardCache
	end
end

--// Cleanup player data when a player leaves.
--// Removing the entry from both maps frees memory and ensures stale data can't be accidentally
--// saved or served to a player who rejoins and gets a fresh data load.
function DataService:CleanupPlayer(player: Player)
	self.playerDataObjects[player.UserId] = nil
	self.savingPlayers[player.UserId] = nil
end

--// Return the singleton instance. Consumers require() this module and get a ready DataService
return DataService.new()
