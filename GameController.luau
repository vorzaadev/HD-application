--[[
	GameController

	Client-side controller for game logic and server communication.

	Responsibilities:
		- Request level data from server
		- Submit words to server for validation
		- Manage tool usage and selection
		- Track player money and bonus words
		- Provide state for UI components
]]

--// Most of the logic is repeated so the first half has 90% of the logic explanation

--// Require our dependencies
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")

--// Knit is our framework for networking through controllers/services
local Knit = require(Packages.knit)
--// Fusion is the framework for state management to make the UI reactive
local Fusion = require(Packages.fusion)

--// Create the controller that will manage game logic
local GameController = Knit.CreateController({
	Name = "GameController",
})

--// Set up our board states which are defined in KnitInit
--// Setting everything to nil initially means that everything
--// is clean for when we need to set everything up
--// Also helps with tracking what we have available easily
GameController.Grid = nil
GameController.GridWidth = nil
GameController.GridHeight = nil
GameController.Letters = nil
GameController.CurrentLevel = nil
GameController.IsLoading = nil

--// Set up the tool states, same logic applies here
GameController.Money = nil
GameController.ToolCosts = nil
GameController.SelectedTool = nil
GameController.BonusWordsCount = nil
GameController.BonusWords = nil
GameController.IsBonusWordsCardVisible = nil

--// Setting the scope here so we can have the values created by Fusion
--// Setting the Fusion scope to itself allows us to create
--// new allowed Fusion values but in our own space (GameController)
local scope = Fusion.scoped(Fusion)

--// Initialize everything
function GameController:KnitInit()
	--// Set our grid states with values that aren't nil
	self.Grid = scope:Value({})
	self.GridWidth = scope:Value(1)
	self.GridHeight = scope:Value(1)
	self.Letters = scope:Value({})
	self.CurrentLevel = scope:Value(0)
	self.IsLoading = scope:Value(false)
	self.AnimatedCells = scope:Value({})

	--// Same here, but with tools
	self.Money = scope:Value(0)
	self.ToolCosts = scope:Value({ Bullseye = 10, Hint = 15, Barrage = 40 })
	self.SelectedTool = scope:Value(nil)
	self.BonusWordsCount = scope:Value(0)
	self.BonusWords = scope:Value({})
	self.IsBonusWordsCardVisible = scope:Value(false)

	self.LevelService = Knit.GetService("LevelService")
	self.ToolService = Knit.GetService("ToolService")
	self.DataService = Knit.GetService("DataService")
end

--// This one function should hold everything that GameController
--// needs to listen to
function GameController:SetupEvents()
	--// In this case, we want to listen for the change in player data
	--// which is fired from the server when a change is authorized and completed
	self.DataService.ValueChanged:Connect(function(key, value)
		--// The key describes what changed in the data
		--// (like {["Money"] = 100})
		if key == "Money" then
			--// Set the value on the client so we can quickly check
			--// if the client wants to buy something without
			--// calling the server
			self.Money:set(value)
		end
	end)
end

--// KnitStart is called when all the controllers are required and the other
--// controllers/services are reachable.
function GameController:KnitStart()
	--// call ToolService to get the full list of tool costs
	--// "andThen()" means that the function will indefinitely yield until the
	--// promise resolves/rejects on the server and it is returned
	--// it works kinda like the :Once() RbxScriptSignal
	self.ToolService:GetToolCosts():andThen(function(costs)
		--// Set the table we receive from the server on the client
		--// :set() method updates the value without defining the entire thing again
		--// for resource efficiency
		self.ToolCosts:set(costs)
		print("[GameController] Tool costs loaded:", costs)
	end)

	--// ReloadLevel fires from LevelService when we request a new level
	--// The results/answers aren't exposed to the client so it
	--// only sends the raw data we need to build the board
	self.LevelService.ReloadLevel:Connect(function(levelNumber)
		--// We only pass the number to LoadLevel so it makes a new request to LevelService
		--// Sounds inefficient to only pass the number but I'll explain my reasoning later
		self:LoadLevel(levelNumber)
	end)

	--// Set up the listener for data changes
	self:SetupEvents()

	print("[GameController] Started")
end

--// LoadLevel() builds our board here
function GameController:LoadLevel(levelNumber)
	--// Set our IsLoading guard so that we don't try to load something else
	--// on top of this and get some weird results
	self.IsLoading:set(true)

	--// Clear the selected tool when loading a new level
	--// Because other games do this to refresh the player's mind
	--// On what they currently have going on
	self.SelectedTool:set(nil)

	--// We make a new GetLevelData request to LevelService
	--// Because this can also be called on the client when they want to progress
	--// And we can't cache the 1000+ levels if the player progressed a ton
	return self
		.LevelService
		:GetLevelData(levelNumber)
		--// Another :andThen() to make our script yield until we get an answer
		:andThen(function(data)
			if data then
				--// The grid itself is built like:
				--// grid[x][y] = {
				--//	 Letter = "A",
				--//	 Filled = false,
				--//	 Revealed = false,
				--//	 Empty = false
				--// }
				--// GridWidth is the max X value
				--// GridHeight is the max Y value
				self.Grid:set(data.Grid or {})
				self.GridWidth:set(data.GridWidth or 1)
				self.GridHeight:set(data.GridHeight or 1)
				--// data.Letters is the table of allowed letters to form words for this level
				self.Letters:set(data.Letters or {})
				--// Set our current level so the level display gets updated
				self.CurrentLevel:set(levelNumber)
				--// Set the current money for the player so they can check
				self.Money:set(data.Money or 0)
				--// BonusWords will either be an empty table or list the bonus words the player found
				self.BonusWordsCount:set(data.BonusWordsCount or 0)
				--// AnimatedCells is used for procedural animations on the grid, used
				--// in a different Fusion UI component
				self.AnimatedCells:set({})
				print("[GameController] Level", levelNumber, "loaded successfully")
				print("[GameController] Grid dimensions:", data.GridWidth, "x", data.GridHeight)
			else
				--// Output that the level failed to load if something
				--// goes wrong on the server but it didn't tell us
				--// or the player who cant access the server logs
				warn("[GameController] Failed to load level", levelNumber, "- data is nil")
			end
			--// Put the guard back to false so we can load something else
			--// quickly again
			self.IsLoading:set(false)
			return data
		end)
		--// :catch() is like :andThen() but it's meant to handle errors only
		--// so if our Promise returned a reject() instead of a resolve()
		--// this function will be called instead of :andThen()
		:catch(
			function(err)
				--// the passed "err" argument is an entirely different object type
				--// so we need to use tostring() in case it didn't return a raw string
				warn("[GameController] Error loading level:", tostring(err))
				--// Set the guard back again so we can load something else
				self.IsLoading:set(false)
			end
		)
end

--// Submit a word to the server and get validation on it
--// Again, the answers aren't revealed for exploit protection
--// so we need to do this for every word
function GameController:SubmitWord(word)
	return self
		.LevelService
		--// "word" in this case is just a string that is all the player's selected letters concatenated
		:SubmitWord(
			word
		)
		:andThen(function(result)
			print("[GameController] Word submission result:", result.Status)

			--// If we get a bonus word and it returned the money earned with it
			--// then update it accordingly
			if result.Status == "bonus" and result.MoneyEarned then
				--// Set the new money value
				--// Fusion.peek() is used to get the current value of a Fusion state
				--// without needing to wrap it in a Fusion computation
				local currentMoney = Fusion.peek(self.Money)
				self.Money:set(currentMoney + result.MoneyEarned)

				--// Update bonus words count
				local currentCount = Fusion.peek(self.BonusWordsCount)
				self.BonusWordsCount:set(currentCount + 1)
			end

			return result
		end)
		:catch(function(err)
			--// Again, the "err" argument is a different object type
			warn("[GameController] Error submitting word:", tostring(err))
			return { Status = "invalid" }
		end)
end

--// Fill a single cell with a letter result for procedural animation
function GameController:FillCell(x, y, letter)
	--// Get our current grid as it is right now
	local grid = Fusion.peek(self.Grid)
	--// Check if the target cell exists
	if grid[x] and grid[x][y] then
		--// Create a new grid with the updated cell
		local newGrid = {}
		--// Iterate through the existing grid and copy cells
		--// Update only the target cell passed as the arguments
		for gx, column in pairs(grid) do
			newGrid[gx] = {}
			for gy, cell in pairs(column) do
				if gx == x and gy == y then
					newGrid[gx][gy] = {
						--// Letter and Filled are the only things that change
						--// because that was our target cell to fill
						Letter = letter,
						Filled = true,
						Revealed = cell.Revealed,
						Empty = cell.Empty,
					}
				else
					--// Otherwise, copy it and move on
					newGrid[gx][gy] = {
						Letter = cell.Letter,
						Filled = cell.Filled,
						Revealed = cell.Revealed,
						Empty = cell.Empty,
					}
				end
			end
		end
		--// Set the new grid we have
		self.Grid:set(newGrid)
	end
end

--// We have a whole method for getting the current grid
--// Because the grid value itself isn't directly exposed to the
--// Fusion UI component
--// and it allows for easier management of the grid state if we only have
--// one copy here
function GameController:GetGrid()
	return Fusion.peek(self.Grid)
end

--// Same logic here
function GameController:GetLetters()
	return Fusion.peek(self.Letters)
end

--// Toggle a tool selection
function GameController:SelectTool(toolName)
	--// self.SelectedTool is just a Fusion string
	local currentTool = Fusion.peek(self.SelectedTool)

	--// Toggle off if already selected
	if currentTool == toolName then
		self.SelectedTool:set(nil)
		return
	end

	--// For non-selection tools (Hint, Barrage), use immediately
	if toolName == "Hint" then
		self:UseHint()
		return
	elseif toolName == "Barrage" then
		self:UseBarrage()
		return
	end
	--// For Bullseye, enter selection mode
	self.SelectedTool:set(toolName)
end

--// We have this Cancel method because
--// Bullseye has a selection mode and we need a way
--// to get out of it if the player changes
--// their mind
function GameController:CancelToolSelection()
	self.SelectedTool:set(nil)
end

--// Use Bullseye tool on a specific cell
function GameController:UseBullseye(cellX, cellY)
	--// Check if the currently selected tool is Bullseye
	--// otherwise, do nothing
	local currentTool = Fusion.peek(self.SelectedTool)
	if currentTool ~= "Bullseye" then
		return
	end

	--// Call ToolService on this cell because it isn't revealed
	--// on the client
	return self.ToolService
		:UseBullseye(cellX, cellY)
		:andThen(function(result)
			if result.Success and result.Cell then
				--// Update the grid with the revealed cell
				--// We have another method for this because it is meant to look differently
				--// when used on the accompanying UI component
				self:RevealCell(result.Cell.X, result.Cell.Y, result.Cell.Letter)

				--// Deduct money from the client state
				local costs = Fusion.peek(self.ToolCosts)
				local currentMoney = Fusion.peek(self.Money)
				self.Money:set(currentMoney - costs.Bullseye)

				print("[GameController] Bullseye used on cell:", result.Cell.X, result.Cell.Y)
			elseif result.Error then
				--// Warn if we have an error
				--// It can be something non-harmful like not enough money
				--// so it isn't used on a server reject()
				warn("[GameController] Bullseye error:", result.Error)
			end

			--// Clear selection after use
			self.SelectedTool:set(nil)
			return result
		end)
		:catch(function(err)
			--// If something more catastrophic happens
			--// we use this instead.
			warn("[GameController] Error using Bullseye:", tostring(err))
			self.SelectedTool:set(nil)
		end)
end

--// Use Hint tool to reveal a random cell
function GameController:UseHint()
	--// The ToolService call does the logic for us on the server
	--// because again the client doesn't have the full board
	return self
		.ToolService
		:UseHint()
		:andThen(function(result)
			if result.Success and result.Cell then
				--// Update the grid with the revealed cell
				self:RevealCell(result.Cell.X, result.Cell.Y, result.Cell.Letter)

				--// Deduct money from the client state
				local costs = Fusion.peek(self.ToolCosts)
				local currentMoney = Fusion.peek(self.Money)
				self.Money:set(currentMoney - costs.Hint)

				print("[GameController] Hint used, revealed cell:", result.Cell.X, result.Cell.Y)
			elseif result.Error then
				--// Same logic for a non-server error here
				warn("[GameController] Hint error:", result.Error)
			end
			return result
		end)
		--// Catch the server errors and display them on the output
		:catch(function(err)
			warn("[GameController] Error using Hint:", tostring(err))
		end)
end

--// Use Barrage tool to reveal multiple random cells
function GameController:UseBarrage()
	--// The logic is done on the server
	return self
		.ToolService
		:UseBarrage()
		:andThen(function(result)
			if result.Success and result.Cells then
				--// Update the grid with all revealed cells
				--// The incoming data looks like:
				--// Cells = {
				--//	{ X = 1, Y = 2, Letter = "A" },
				--//	{ X = 3, Y = 4, Letter = "B" },
				--// }
				for _, cell in ipairs(result.Cells) do
					self:RevealCell(cell.X, cell.Y, cell.Letter)
				end

				--// Deduct money from the client state
				local costs = Fusion.peek(self.ToolCosts)
				local currentMoney = Fusion.peek(self.Money)
				self.Money:set(currentMoney - costs.Barrage)

				print("[GameController] Barrage used, revealed", #result.Cells, "cells")
			elseif result.Error then
				--// Same logic for a non-server error here
				warn("[GameController] Barrage error:", result.Error)
			end
			return result
		end)
		--// Same logic for catching server errors
		:catch(function(err)
			warn("[GameController] Error using Barrage:", tostring(err))
		end)
end

--// Reveal a cell, shows the letter but with a different visual effect
function GameController:RevealCell(x, y, letter)
	local grid = Fusion.peek(self.Grid)
	if grid[x] and grid[x][y] then
		local newGrid = {}
		for gx, column in pairs(grid) do
			newGrid[gx] = {}
			for gy, cell in pairs(column) do
				if gx == x and gy == y then
					newGrid[gx][gy] = {
						--// It's the exact same logic as a filled cell
						--// except it sets Revealed to true instead of Filled
						Letter = letter,
						Filled = cell.Filled,
						Revealed = true,
						Empty = cell.Empty,
					}
				else
					newGrid[gx][gy] = {
						Letter = cell.Letter,
						Filled = cell.Filled,
						Revealed = cell.Revealed,
						Empty = cell.Empty,
					}
				end
			end
		end
		self.Grid:set(newGrid)
	end
end

--// Handle cell click for Bullseye tool
function GameController:OnCellClick(x, y)
	--// Check if we're even using Bullseye right now
	local currentTool = Fusion.peek(self.SelectedTool)
	if currentTool == "Bullseye" then
		--// Call the appropriate method
		self:UseBullseye(x, y)
	end
end

--// Load bonus words from server
--// Bonus words get their own method because its handled
--// by a different UI component
function GameController:LoadBonusWords()
	return self.LevelService
		:GetBonusWords()
		:andThen(function(result)
		--// If we have a valid result and a words list
		--// Then we simply set all the necessary values as such
		if result and result.Words then
			self.BonusWords:set(result.Words)
			self.BonusWordsCount:set(#result.Words)
		end
		return result
		end)
		--// Catch server errors
		:catch(function(err)
		warn("[GameController] Error loading bonus words:", tostring(err))
		end)
end

--// Toggle bonus words card
function GameController:ToggleBonusWordsCard()
	--// Load bonus words when showing the card
	--// in case it changes on the server
	self:LoadBonusWords()
	--// Set the bonus words card to the opposite state
	--// Again, :set is used here because it is a fusion value and not a regular
	--// variable
	self.IsBonusWordsCardVisible:set(not Fusion.peek(self.IsBonusWordsCardVisible))
end

--// Return GameController so Knit can pick it up
--// and other UI components can use the Knit feature to get a controller
--// and use its methods
return GameController