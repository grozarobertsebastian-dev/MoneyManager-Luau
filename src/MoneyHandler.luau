-- MoneyManager (ServerScriptService)
-- Handles economy, passive income, rebirths, spawner assignment,
-- steal system, base themes and server luck calculation.

local PhysicsService    = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local GD = require(ReplicatedStorage.Shared.GameData)

-- Physics collision groups
local GROUP_BANDA   = "Banda"
local GROUP_PLAYERS = "Players"
local GROUP_CUBURI  = "Cuburi"

local function setupPhysics()
	pcall(function() PhysicsService:RegisterCollisionGroup(GROUP_BANDA)   end)
	pcall(function() PhysicsService:RegisterCollisionGroup(GROUP_PLAYERS) end)
	pcall(function() PhysicsService:RegisterCollisionGroup(GROUP_CUBURI)  end)
	PhysicsService:CollisionGroupSetCollidable(GROUP_BANDA,   GROUP_PLAYERS, false)
	PhysicsService:CollisionGroupSetCollidable(GROUP_CUBURI,  GROUP_PLAYERS, false)
	PhysicsService:CollisionGroupSetCollidable(GROUP_BANDA,   GROUP_CUBURI,  true)
end
setupPhysics()

-- Aliases to shared game data (all balance constants live in GameData.luau)
local formatNumber         = GD.formatNumber
local ANIME_BASE_COLORS    = GD.ANIME_BASE_COLORS
local STORAGE_PER_REBIRTH  = GD.STORAGE_PER_REBIRTH
local REBIRTH_COINS_COST   = GD.REBIRTH_COINS_COST
local REBIRTH_BONUS_COINS  = GD.REBIRTH_BONUS_COINS
local REBIRTH_REQUIREMENTS = GD.REBIRTH_REQUIREMENTS

local function getRebirthLuck(rebirthLevel)
	return GD.getRebirthLuck(rebirthLevel)
end

local function getCashMultiplier(rebirthLevel)
	return GD.getCashMultiplier(rebirthLevel)
end

local function getTotalSlots(player, rebirthLevel)
	return GD.getTotalSlots(rebirthLevel, player:GetAttribute("HasBP_ExtraSlots"))
end

-- Remote events

local function createEvent(name, className)
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then return existing end
	local event    = Instance.new(className or "RemoteEvent")
	event.Name     = name
	event.Parent   = ReplicatedStorage
	return event
end

createEvent("MoveToSlotEvent")
createEvent("MoveToStorageEvent")
createEvent("SellFromInventoryEvent")

local notifyEvent      = createEvent("NotifyEvent")
local rebirthEvent     = createEvent("RebirthEvent")
local changeThemeEvent = createEvent("ChangeBaseThemeEvent")
local purchaseEvent    = createEvent("PurchaseEvent")
createEvent("CharacterSeenEvent")

local rebirthInfoEvent = ReplicatedStorage:FindFirstChild("RebirthInfoEvent")
if not rebirthInfoEvent then
	rebirthInfoEvent        = Instance.new("RemoteFunction")
	rebirthInfoEvent.Name   = "RebirthInfoEvent"
	rebirthInfoEvent.Parent = ReplicatedStorage
end

print("[MoneyManager] Remote events ready")

-- Spawner assignment

local assignedSpawners = {}
local MAX_SPAWNERS     = 6

local function assignSpawnerToPlayer(player)
	for i = 1, MAX_SPAWNERS do
		local taken = false
		for _, num in pairs(assignedSpawners) do
			if num == i then taken = true; break end
		end
		if not taken then
			assignedSpawners[player.UserId] = i
			player:SetAttribute("SpawnerNumber", i)
			print("[MoneyManager] " .. player.Name .. " -> SpawnerPlayer" .. i)
			return i
		end
	end
	warn("[MoneyManager] No spawner available for " .. player.Name)
	return nil
end

-- Player helpers

local function getPlayerBasePlateau(player)
	local pNum          = player:GetAttribute("SpawnerNumber") or 1
	local spawnerFolder = workspace:FindFirstChild("SpawnerPlayer" .. pNum)
	if not spawnerFolder then return nil end
	return spawnerFolder:FindFirstChild("BasePlateau" .. pNum)
end

local function applyBaseColor(player)
	local rebirthLvl = 0
	if player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Rebirths") then
		rebirthLvl = player.leaderstats.Rebirths.Value
	end
	local colorLevel = player:GetAttribute("SelectedBaseTheme") or rebirthLvl
	local bp = getPlayerBasePlateau(player)
	if bp then
		bp.Color    = ANIME_BASE_COLORS[colorLevel] or Color3.fromRGB(108, 59, 245)
		bp.Material = Enum.Material.SmoothPlastic
	end
end

-- Server luck
-- Uses sqrt dampening so one maxed-out player doesn't trivialize the whole server.
-- All luck changes go through recalculatePersonalLuck -> updateServerLuck,
-- so there is only one place where ServerLuck is written.
local function updateServerLuck()
	local players = Players:GetPlayers()
	if #players == 0 then
		workspace:SetAttribute("ServerLuck", 1)
		return
	end
	local total = 0
	for _, p in ipairs(players) do
		total = total + (p:GetAttribute("PersonalLuck") or 1)
	end
	local avg = total / #players
	workspace:SetAttribute("ServerLuck", math.max(1, math.sqrt(avg)))
end

-- Personal luck
-- Called whenever anything that affects luck changes (rebirth, BP, VIP, potions, index).
local function recalculatePersonalLuck(player)
	local rebirthLevel = 0
	if player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Rebirths") then
		rebirthLevel = player.leaderstats.Rebirths.Value
	end

	local rebirthLuck  = getRebirthLuck(rebirthLevel)
	local indexLuck    = player:GetAttribute("IndexLuck")    or 0
	local premiumLuck  = player:GetAttribute("PremiumLuck")  or 0

	-- Potion luck with diminishing returns above the soft cap.
	-- Players below SOFT_CAP get the full bonus; above it, each doubling of
	-- base luck halves the effective potion gain to keep things balanced.
	local potionLuck    = 0
	local potionLuckExp = player:GetAttribute("PotionLuckExpire") or 0
	if os.time() < potionLuckExp then
		local rawPotionLuck    = player:GetAttribute("PotionLuck") or 0
		local baseLuckNoPot    = 1 + rebirthLuck + indexLuck + premiumLuck
		local SOFT_CAP         = 8
		local diminish         = math.min(1, SOFT_CAP / math.max(SOFT_CAP, baseLuckNoPot))
		potionLuck             = rawPotionLuck * diminish
	end

	local baseLuck = 1 + rebirthLuck + indexLuck + premiumLuck + potionLuck

	if player:GetAttribute("HasBP_x2Luck") then baseLuck = baseLuck * 2   end
	if player:GetAttribute("IsVIP")        then baseLuck = baseLuck * 1.1 end

	player:SetAttribute("PersonalLuck",  baseLuck)
	player:SetAttribute("RebirthLuck",   rebirthLuck)
	updateServerLuck()
	return baseLuck
end

-- Character counting (used by rebirth requirement checks)
local function countAllCharactersForRebirth(player)
	local counts      = {}
	local basePlateau = getPlayerBasePlateau(player)

	if basePlateau then
		for _, slot in pairs(basePlateau:GetChildren()) do
			if slot.Name:match("^Slot%d+$") then
				for _, child in pairs(slot:GetChildren()) do
					if child:IsA("BasePart") and child.Name == "PlacedCharacter" then
						local cName = child:GetAttribute("CharacterName") or ""
						counts[cName] = (counts[cName] or 0) + 1
					end
				end
			end
		end
	end

	local inventory = player:FindFirstChild("Inventory")
	if inventory then
		local storageFolder = inventory:FindFirstChild("Storage")
		if storageFolder then
			for _, child in pairs(storageFolder:GetChildren()) do
				if child:IsA("BasePart") then
					local cName = child:GetAttribute("CharacterName") or ""
					counts[cName] = (counts[cName] or 0) + 1
				end
			end
		end
	end

	return counts
end

-- Character serialization (used by rebirth SaveAll perk)
local function saveCharacterData(child)
	local data = {
		CharacterName = child:GetAttribute("CharacterName"),
		Rarity        = child:GetAttribute("Rarity"),
		PassiveIncome = child:GetAttribute("BasePassiveIncome") or child:GetAttribute("PassiveIncome") or 0,
		Price         = child:GetAttribute("Price"),
		Anime         = child:GetAttribute("Anime"),
		Stars         = child:GetAttribute("Stars") or 1,
		IsLocked      = child:GetAttribute("IsLocked")    == true,
		IsProtected   = child:GetAttribute("IsProtected") == true,
		Size          = {child.Size.X,  child.Size.Y,  child.Size.Z},
		Color         = {child.Color.R, child.Color.G, child.Color.B},
		Material      = child.Material.Name,
		Transparency  = child.Transparency,
		Shape         = child.Shape.Name,
	}

	local mesh = child:FindFirstChildOfClass("SpecialMesh")
	if mesh then
		data.MeshId    = mesh.MeshId
		data.TextureId = mesh.TextureId
		data.MeshScale = {mesh.Scale.X, mesh.Scale.Y, mesh.Scale.Z}
		data.MeshType  = mesh.MeshType.Name
	end

	local decals = {}
	for _, d in pairs(child:GetChildren()) do
		if d:IsA("Decal") or d:IsA("Texture") then
			table.insert(decals, {ClassName=d.ClassName, Face=d.Face.Name, Texture=d.Texture})
		end
	end
	if #decals > 0 then data.Decals = decals end

	return data
end

local function restoreCharacterToStorage(stor, charData)
	local char      = Instance.new("Part")
	char.Name       = "PlacedCharacter"
	char.Anchored   = true
	char.CanCollide = false

	char.Size = charData.Size
		and Vector3.new(charData.Size[1], charData.Size[2], charData.Size[3])
		or  Vector3.new(3, 3, 3)

	if charData.Color then
		char.Color = Color3.new(charData.Color[1], charData.Color[2], charData.Color[3])
	end
	if charData.Material    then pcall(function() char.Material = Enum.Material[charData.Material]   end) end
	if charData.Transparency then char.Transparency = charData.Transparency end
	if charData.Shape       then pcall(function() char.Shape    = Enum.PartType[charData.Shape]       end) end

	if charData.MeshId and charData.MeshId ~= "" then
		local mesh  = Instance.new("SpecialMesh")
		mesh.MeshId = charData.MeshId
		if charData.TextureId then mesh.TextureId = charData.TextureId end
		if charData.MeshScale then
			mesh.Scale = Vector3.new(charData.MeshScale[1], charData.MeshScale[2], charData.MeshScale[3])
		end
		if charData.MeshType then pcall(function() mesh.MeshType = Enum.MeshType[charData.MeshType] end) end
		mesh.Parent = char
	end

	if charData.Decals then
		for _, d in pairs(charData.Decals) do
			local decal   = Instance.new(d.ClassName)
			pcall(function() decal.Face = Enum.NormalId[d.Face] end)
			decal.Texture = d.Texture
			decal.Parent  = char
		end
	end

	local stars       = charData.Stars or 1
	local starMult    = stars > 1 and (1.75 ^ (stars - 1)) or 1
	local baseIncome  = charData.PassiveIncome or 0
	local actualIncome = baseIncome * starMult

	char:SetAttribute("CharacterName",     charData.CharacterName)
	char:SetAttribute("Rarity",            charData.Rarity)
	char:SetAttribute("BasePassiveIncome", baseIncome)
	char:SetAttribute("PassiveIncome",     actualIncome)
	char:SetAttribute("Price",             charData.Price)
	char:SetAttribute("Anime",             charData.Anime or "Unknown")
	char:SetAttribute("Stars",             stars)
	char:SetAttribute("IsLocked",          charData.IsLocked)
	char:SetAttribute("IsProtected",       charData.IsProtected)
	char:SetAttribute("InInventory",       true)
	char.Position = Vector3.new(0, -200, 0)
	char.Parent   = stor
	return char
end

-- Slot visibility and layout
local function updateSlotsVisibility(player)
	if not player:FindFirstChild("leaderstats") then return end

	local rebirthLevel   = player.leaderstats.Rebirths.Value
	local unlockedSlots  = getTotalSlots(player, rebirthLevel)
	local storageCapacity = STORAGE_PER_REBIRTH[rebirthLevel] or 4

	player:SetAttribute("StorageCapacity", storageCapacity)
	player:SetAttribute("SlotCount",       unlockedSlots)

	local basePlateau = getPlayerBasePlateau(player)
	if not basePlateau then return end

	local templateSlot = nil
	for _, part in pairs(basePlateau:GetChildren()) do
		if part.Name:match("^Slot%d+$") and part:IsA("BasePart") then
			templateSlot = part
			break
		end
	end
	if not templateSlot then return end

	local slotShape       = templateSlot.Shape
	local slotSize        = templateSlot.Size
	local slotMaterial    = templateSlot.Material
	local slotColor       = templateSlot.Color
	local slotOrientation = templateSlot.Orientation

	local surfaceY      = basePlateau.Position.Y + basePlateau.Size.Y / 2
	local slotThickness = (slotShape == Enum.PartType.Cylinder) and slotSize.X or slotSize.Y
	local slotY         = surfaceY + slotThickness / 2

	local spacing   = 12
	local cols      = 5
	local centerX   = basePlateau.Position.X
	local centerZ   = basePlateau.Position.Z
	local totalRows = math.ceil(unlockedSlots / cols)
	local startX    = centerX - (cols - 1) * spacing / 2
	local startZ    = centerZ - (totalRows - 1) * spacing / 2

	for i = 0, unlockedSlots - 1 do
		local slotName    = "Slot" .. i
		local existingSlot = basePlateau:FindFirstChild(slotName)

		local row       = math.floor(i / cols)
		local col       = i % cols
		local correctPos = Vector3.new(startX + col * spacing, slotY, startZ + row * spacing)

		if existingSlot then
			local yDiff = math.abs(existingSlot.Position.Y - slotY)
			if yDiff > 0.5 then
				local charPart = nil
				for _, child in pairs(existingSlot:GetChildren()) do
					if child.Name == "PlacedCharacter" then charPart = child; break end
				end
				local fixedPos = Vector3.new(existingSlot.Position.X, slotY, existingSlot.Position.Z)
				existingSlot.Position    = fixedPos
				existingSlot.Orientation = slotOrientation
				existingSlot.Shape       = slotShape
				existingSlot.Size        = slotSize
				if charPart then
					charPart.Position = fixedPos + Vector3.new(0, 2, 0)
					local nameTag = charPart:FindFirstChild("NameTag")
					if nameTag then nameTag.Adornee = charPart end
				end
			end
		else
			local newSlot             = Instance.new("Part")
			newSlot.Name              = slotName
			newSlot.Shape             = slotShape
			newSlot.Size              = slotSize
			newSlot.Material          = slotMaterial
			newSlot.Color             = slotColor
			newSlot.Transparency      = 0.5
			newSlot.Anchored          = true
			newSlot.CanCollide        = true
			newSlot.Orientation       = slotOrientation
			newSlot.Position          = correctPos
			newSlot:SetAttribute("Occupied", false)
			newSlot.Parent            = basePlateau
		end
	end

	for _, part in pairs(basePlateau:GetChildren()) do
		if part.Name:match("^Slot%d+$") then
			local slotNumber = tonumber(part.Name:match("%d+"))
			if slotNumber ~= nil then
				if slotNumber < unlockedSlots then
					part.Transparency = part:GetAttribute("Occupied") and 0.7 or 0.5
					part.CanCollide   = true
				else
					part.Transparency = 1
					part.CanCollide   = false
				end
			end
		end
	end
end

-- Spawn player at their assigned base location
local function spawnPlayerAtBase(player, character, playerNumber)
	local spawnerFolder = workspace:FindFirstChild("SpawnerPlayer" .. playerNumber)
	if not spawnerFolder then return end
	local spawnLocation = spawnerFolder:FindFirstChild("SpawnLocation" .. playerNumber)
	if not spawnLocation then return end
	local rootPart = character:WaitForChild("HumanoidRootPart", 5)
	if not rootPart then return end
	rootPart.CFrame = spawnLocation.CFrame + Vector3.new(0, 3, 0)
end

-- Player setup
Players.PlayerAdded:Connect(function(player)
	local playerNumber = assignSpawnerToPlayer(player)

	local stats        = Instance.new("Folder")
	stats.Name         = "leaderstats"
	stats.Parent       = player

	local coins        = Instance.new("NumberValue")
	coins.Name         = "Coins"
	coins.Value        = 10000
	coins.Parent       = stats

	local rebirths     = Instance.new("IntValue")
	rebirths.Name      = "Rebirths"
	rebirths.Value     = 0
	rebirths.Parent    = stats

	local inventory    = Instance.new("Folder")
	inventory.Name     = "Inventory"
	inventory.Parent   = player

	local invCount     = Instance.new("IntValue")
	invCount.Name      = "InventoryCount"
	invCount.Value     = 0
	invCount.Parent    = inventory

	Instance.new("Folder", inventory).Name = "Storage"
	Instance.new("Folder", player).Name    = "DiscoveredCharacters"
	Instance.new("Folder", player).Name    = "SeenCharacters"

	player:SetAttribute("CashMultiplier",  getCashMultiplier(0))
	player:SetAttribute("StorageCapacity", STORAGE_PER_REBIRTH[0])
	player:SetAttribute("SlotCount",       getTotalSlots(player, 0))
	player:SetAttribute("MaxRebirth",      9)
	player:SetAttribute("RebirthLuck",     0)
	player:SetAttribute("IndexLuck",       0)
	player:SetAttribute("PremiumLuck",     0)
	player:SetAttribute("PersonalLuck",    1)
	player:SetAttribute("LuckBoostExpire", 0)

	recalculatePersonalLuck(player)

	player.CharacterAdded:Connect(function(character)
		task.wait(0.2)
		if playerNumber then spawnPlayerAtBase(player, character, playerNumber) end
		task.wait(0.2)
		updateSlotsVisibility(player)
		applyBaseColor(player)

		if player:GetAttribute("HasBP_x2Speed") then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then humanoid.WalkSpeed = humanoid.WalkSpeed * 2 end
		end

		for _, part in pairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				pcall(function() part.CollisionGroup = GROUP_PLAYERS end)
			end
		end
	end)

	rebirths.Changed:Connect(function()
		updateSlotsVisibility(player)
		player:SetAttribute("CashMultiplier", getCashMultiplier(rebirths.Value))
		recalculatePersonalLuck(player)
	end)

	-- Reconnect luck when relevant attributes change
	player:GetAttributeChangedSignal("HasBP_x2Luck"):Connect(function()  recalculatePersonalLuck(player) end)
	player:GetAttributeChangedSignal("IndexLuck"):Connect(function()      recalculatePersonalLuck(player) end)
	player:GetAttributeChangedSignal("PremiumLuck"):Connect(function()    recalculatePersonalLuck(player) end)
	player:GetAttributeChangedSignal("IsVIP"):Connect(function()          recalculatePersonalLuck(player) end)
	player:GetAttributeChangedSignal("PotionLuck"):Connect(function()     recalculatePersonalLuck(player) end)

	player:GetAttributeChangedSignal("HasBP_ExtraSlots"):Connect(function()
		updateSlotsVisibility(player)
	end)

	player:GetAttributeChangedSignal("HasBP_x2Speed"):Connect(function()
		if player:GetAttribute("HasBP_x2Speed") and player.Character then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then humanoid.WalkSpeed = humanoid.WalkSpeed * 2 end
		end
	end)

	task.delay(6, function()
		if player and player.Parent then updateSlotsVisibility(player) end
	end)

	-- Passive income loop: runs every second and adds income from all placed characters
	task.spawn(function()
		while player and player.Parent do
			task.wait(1)

			local totalIncome = 0
			local multiplier  = player:GetAttribute("CashMultiplier") or 1

			local basePlateau = getPlayerBasePlateau(player)
			if basePlateau then
				for _, slot in pairs(basePlateau:GetChildren()) do
					if slot.Name:match("^Slot%d+$") then
						for _, child in pairs(slot:GetChildren()) do
							if child.Name == "PlacedCharacter" then
								totalIncome = totalIncome + (child:GetAttribute("PassiveIncome") or 0)
							end
						end
					end
				end
			end

			local finalIncome = math.floor(totalIncome * multiplier)

			if workspace:GetAttribute("GlobalMoneyActive")    then finalIncome = finalIncome * 2 end
			if player:GetAttribute("HasBP_x2Coins")           then finalIncome = finalIncome * 2 end

			local potionMoneyExp = player:GetAttribute("PotionMoneyExpire") or 0
			if os.time() < potionMoneyExp then
				local pm = player:GetAttribute("PotionMoneyMult") or 1
				if pm > 1 then finalIncome = math.floor(finalIncome * pm) end
			end

			if finalIncome > 0 then
				player.leaderstats.Coins.Value = player.leaderstats.Coins.Value + finalIncome
			end
		end
	end)
end)

-- Player cleanup
Players.PlayerRemoving:Connect(function(player)
	assignedSpawners[player.UserId] = nil
	task.defer(updateServerLuck)
end)

-- Steal system
local function stealTravelingCharacter(stealer, travelChar, prompt)
	if not travelChar or not travelChar.Parent then return end
	if travelChar.Name ~= "TravelingCharacter"  then return end

	local stealPrice  = travelChar:GetAttribute("StealPrice")  or 0
	local ownerUserId = travelChar:GetAttribute("OwnerUserId") or 0
	local paidPrice   = travelChar:GetAttribute("PaidPrice")   or 0
	local charName    = travelChar:GetAttribute("CharacterName") or "?"

	if stealer.UserId == ownerUserId then
		notifyEvent:FireClient(stealer, "That's your own character!", "error")
		return
	end

	local stealerStats = stealer:FindFirstChild("leaderstats")
	if not stealerStats then return end
	local stealerCoins = stealerStats:FindFirstChild("Coins")
	if not stealerCoins or stealerCoins.Value < stealPrice then
		notifyEvent:FireClient(stealer, "Not enough coins! Need " .. formatNumber(stealPrice), "error")
		return
	end

	local stealerBase = getPlayerBasePlateau(stealer)
	if not stealerBase then
		notifyEvent:FireClient(stealer, "Cannot find your base!", "error")
		return
	end

	local rebirthLevel  = stealerStats:FindFirstChild("Rebirths") and stealerStats.Rebirths.Value or 0
	local unlockedSlots = getTotalSlots(stealer, rebirthLevel)
	local freeSlot      = nil

	for i = 0, unlockedSlots - 1 do
		local slot = stealerBase:FindFirstChild("Slot" .. i)
		if slot then
			local occupied = false
			for _, child in pairs(slot:GetChildren()) do
				if child.Name == "PlacedCharacter" then occupied = true; break end
			end
			if not occupied and slot:GetAttribute("Occupied") ~= true then
				freeSlot = slot
				break
			end
		end
	end

	if not freeSlot then
		notifyEvent:FireClient(stealer, "All slots full! Can't steal.", "error")
		return
	end

	-- Release the old owner's reserved slot
	local oldPlayerNumber   = travelChar:GetAttribute("PlayerNumber")   or 1
	local oldTargetSlotName = travelChar:GetAttribute("TargetSlotName")
	local oldSpawnerFolder  = workspace:FindFirstChild("SpawnerPlayer" .. oldPlayerNumber)
	if oldSpawnerFolder then
		local oldBase = oldSpawnerFolder:FindFirstChild("BasePlateau" .. oldPlayerNumber)
		if oldBase and oldTargetSlotName then
			local oldSlot = oldBase:FindFirstChild(oldTargetSlotName)
			if oldSlot then oldSlot:SetAttribute("Occupied", false) end
		end
	end

	-- Refund the original owner
	local originalOwner = Players:GetPlayerByUserId(ownerUserId)
	if originalOwner then
		local ownerStats = originalOwner:FindFirstChild("leaderstats")
		if ownerStats and ownerStats:FindFirstChild("Coins") then
			ownerStats.Coins.Value = ownerStats.Coins.Value + paidPrice
			notifyEvent:FireClient(originalOwner,
				charName .. " was stolen! +" .. formatNumber(paidPrice) .. " refunded", "warning")
		end
	end

	stealerCoins.Value = stealerCoins.Value - stealPrice

	local newStealPrice = math.ceil(stealPrice * 1.03)
	travelChar:SetAttribute("OwnerUserId",    stealer.UserId)
	travelChar:SetAttribute("OwnerName",      stealer.Name)
	travelChar:SetAttribute("PaidPrice",      stealPrice)
	travelChar:SetAttribute("StealPrice",     newStealPrice)
	freeSlot:SetAttribute("Occupied", true)

	local stealerNumber = stealer:GetAttribute("SpawnerNumber") or 1
	travelChar:SetAttribute("PlayerNumber",   stealerNumber)
	travelChar:SetAttribute("TargetSlotName", freeSlot.Name)
	travelChar:SetAttribute("IsRerouted",     true)

	if prompt and prompt.Parent then
		prompt.ObjectText = charName .. " - " .. formatNumber(newStealPrice) .. " coins"
	end

	notifyEvent:FireClient(stealer, "Stole " .. charName .. " for " .. formatNumber(stealPrice) .. "!", "success")
	print("[MoneyManager] " .. stealer.Name .. " stole " .. charName .. " (paid " .. formatNumber(stealPrice) .. ")")
end

-- Purchase event
purchaseEvent.OnServerEvent:Connect(function(player, cube)
	if not cube or not cube.Parent then return end
	if not cube:IsA("BasePart")    then return end
	if cube.Name ~= "BandaCube"    then return end
	if cube:GetAttribute("Purchased") == true then return end

	local charName = cube:GetAttribute("CharacterName")
	local price    = cube:GetAttribute("Price")
	if not charName or not price then return end
	cube:SetAttribute("Purchased", true)

	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then cube:SetAttribute("Purchased", false); return end
	local coins = leaderstats:FindFirstChild("Coins")
	if not coins then cube:SetAttribute("Purchased", false); return end

	local rebirthLevel = leaderstats:FindFirstChild("Rebirths") and leaderstats.Rebirths.Value or 0
	local reqRebirth   = cube:GetAttribute("RequiredRebirth") or 0
	if rebirthLevel < reqRebirth then
		cube:SetAttribute("Purchased", false)
		local animeName = cube:GetAttribute("Anime") or "this island"
		notifyEvent:FireClient(player,
			"Locked! Requires Rebirth " .. reqRebirth .. " to collect " .. animeName ..
			" characters. (You are R" .. rebirthLevel .. ")", "error")
		return
	end

	if coins.Value < price then
		cube:SetAttribute("Purchased", false)
		notifyEvent:FireClient(player, "Not enough coins! Need " .. formatNumber(price), "error")
		return
	end

	local basePlateau = getPlayerBasePlateau(player)
	if not basePlateau then cube:SetAttribute("Purchased", false); return end

	local unlockedSlots = getTotalSlots(player, rebirthLevel)
	local freeSlot      = nil

	for i = 0, unlockedSlots - 1 do
		local slot = basePlateau:FindFirstChild("Slot" .. i)
		if slot then
			local hasChar = false
			for _, child in pairs(slot:GetChildren()) do
				if child.Name == "PlacedCharacter" then hasChar = true; break end
			end
			if not hasChar and slot:GetAttribute("Occupied") ~= true then
				freeSlot = slot
				break
			end
		end
	end

	if not freeSlot then
		cube:SetAttribute("Purchased", false)
		notifyEvent:FireClient(player, "All slots full! Move characters to storage first.", "error")
		return
	end

	coins.Value = coins.Value - price

	local newChar     = cube:Clone()
	newChar.Name      = "TravelingCharacter"
	newChar.Anchored  = true
	newChar.CanCollide = false
	newChar:SetAttribute("Purchased", nil)

	local playerNumber = player:GetAttribute("SpawnerNumber") or 1
	newChar:SetAttribute("TargetSlotName", freeSlot.Name)
	newChar:SetAttribute("PlayerNumber",   playerNumber)
	newChar:SetAttribute("Processing",     false)
	freeSlot:SetAttribute("Occupied", true)

	local stealPrice = math.ceil(price * 1.03)
	newChar:SetAttribute("OwnerUserId", player.UserId)
	newChar:SetAttribute("OwnerName",   player.Name)
	newChar:SetAttribute("PaidPrice",   price)
	newChar:SetAttribute("StealPrice",  stealPrice)

	local stealPrompt                    = Instance.new("ProximityPrompt")
	stealPrompt.Name                     = "StealPrompt"
	stealPrompt.ActionText               = "Steal"
	stealPrompt.ObjectText               = charName .. " - " .. formatNumber(stealPrice) .. " coins"
	stealPrompt.MaxActivationDistance    = 8
	stealPrompt.HoldDuration             = 1
	stealPrompt.Parent                   = newChar
	stealPrompt.Triggered:Connect(function(stealingPlayer)
		stealTravelingCharacter(stealingPlayer, newChar, stealPrompt)
	end)

	newChar.Parent = workspace
	cube:Destroy()

	local discoveredFolder = player:FindFirstChild("DiscoveredCharacters")
	if discoveredFolder and not discoveredFolder:FindFirstChild(charName) then
		local tag     = Instance.new("BoolValue")
		tag.Name      = charName
		tag.Value     = true
		tag.Parent    = discoveredFolder
	end

	notifyEvent:FireClient(player, charName .. " purchased for " .. formatNumber(price) .. "!", "success")
end)

-- Rebirth event
rebirthEvent.OnServerEvent:Connect(function(player)
	if not player:FindFirstChild("leaderstats") then return end

	local currentRebirth = player.leaderstats.Rebirths.Value
	local nextRebirth    = currentRebirth + 1

	if nextRebirth > 9 then
		notifyEvent:FireClient(player, "Already at max rebirth (Level 9)!", "error")
		return
	end

	local coinsCost = REBIRTH_COINS_COST[nextRebirth] or 999999999
	if player.leaderstats.Coins.Value < coinsCost then
		notifyEvent:FireClient(player,
			"Need " .. formatNumber(coinsCost) .. " coins for Rebirth " .. nextRebirth ..
			". You have: " .. formatNumber(player.leaderstats.Coins.Value), "error")
		return
	end

	local requirements = REBIRTH_REQUIREMENTS[nextRebirth]
	if requirements then
		local charCounts = countAllCharactersForRebirth(player)
		local missing    = {}
		for charName, needed in pairs(requirements.Characters) do
			local have = charCounts[charName] or 0
			if have < needed then
				table.insert(missing, charName .. " (" .. have .. "/" .. needed .. ")")
			end
		end
		if #missing > 0 then
			notifyEvent:FireClient(player,
				"Rebirth " .. nextRebirth .. " needs: " .. table.concat(missing, ", "), "error")
			return
		end
	end

	local bonusCoins = REBIRTH_BONUS_COINS[nextRebirth] or 0
	local hasSaveAll = player:GetAttribute("HasBP_SaveAll") == true

	-- Save all characters before wiping if the player has SaveAll perk
	local allCharData = {}
	if hasSaveAll then
		local basePlateau = getPlayerBasePlateau(player)
		if basePlateau then
			for _, slot in pairs(basePlateau:GetChildren()) do
				if slot.Name:match("^Slot%d+$") then
					for _, child in pairs(slot:GetChildren()) do
						if child:IsA("BasePart") and child.Name == "PlacedCharacter" then
							table.insert(allCharData, saveCharacterData(child))
						end
					end
				end
			end
		end
		local inventory = player:FindFirstChild("Inventory")
		if inventory then
			local storageFolder = inventory:FindFirstChild("Storage")
			if storageFolder then
				for _, child in pairs(storageFolder:GetChildren()) do
					if child:IsA("BasePart") then
						table.insert(allCharData, saveCharacterData(child))
					end
				end
			end
		end
	end

	player.leaderstats.Rebirths.Value = nextRebirth
	player.leaderstats.Coins.Value    = bonusCoins

	player:SetAttribute("SelectedBaseTheme", nextRebirth)
	applyBaseColor(player)
	recalculatePersonalLuck(player)

	-- Clear all slots and storage
	local basePlateau = getPlayerBasePlateau(player)
	if basePlateau then
		for _, slot in pairs(basePlateau:GetChildren()) do
			if slot.Name:match("^Slot%d+$") then
				for _, child in pairs(slot:GetChildren()) do
					if child.Name == "PlacedCharacter" then child:Destroy() end
				end
				slot:SetAttribute("Occupied", false)
			end
		end
	end

	local inventory = player:FindFirstChild("Inventory")
	if inventory then
		local storageFolder = inventory:FindFirstChild("Storage")
		if storageFolder then
			for _, child in pairs(storageFolder:GetChildren()) do child:Destroy() end
		end
		local invCount = inventory:FindFirstChild("InventoryCount")
		if invCount then invCount.Value = 0 end
	end

	updateSlotsVisibility(player)

	-- Restore saved characters into storage after slots are ready
	if hasSaveAll and #allCharData > 0 then
		task.delay(1, function()
			local inv = player:FindFirstChild("Inventory")
			if not inv then return end
			local stor = inv:FindFirstChild("Storage")
			if not stor then return end

			local restoredCount = 0
			for _, charData in ipairs(allCharData) do
				restoreCharacterToStorage(stor, charData)
				restoredCount = restoredCount + 1
			end

			local invCount = inv:FindFirstChild("InventoryCount")
			if invCount then invCount.Value = invCount.Value + restoredCount end

			notifyEvent:FireClient(player,
				"Save All: " .. restoredCount .. " characters survived the rebirth! (In Storage)", "success")
		end)
	end

	local showcaseCount = 0
	if basePlateau then
		for _, child in pairs(basePlateau:GetChildren()) do
			if child.Name:match("^ShowcasePedestal") then
				for _, sc in pairs(child:GetChildren()) do
					if sc:IsA("BasePart") and sc.Name == "ShowcaseCharacter" then
						showcaseCount = showcaseCount + 1
					end
				end
			end
		end
	end

	local newMult    = getCashMultiplier(nextRebirth)
	local newSlots   = getTotalSlots(player, nextRebirth)
	local newStorage = STORAGE_PER_REBIRTH[nextRebirth] or 4
	local newLuck    = getRebirthLuck(nextRebirth)

	local savedMsg = ""
	if hasSaveAll then
		savedMsg = "\nAll characters saved!"
	elseif showcaseCount > 0 then
		savedMsg = "\n" .. showcaseCount .. " Trophy Stand character(s) survived!"
	end

	notifyEvent:FireClient(player,
		"REBIRTH " .. nextRebirth .. " SUCCESS!\n" ..
		"Multiplier: x" .. newMult .. "\n" ..
		"Slots: " .. newSlots .. " | Storage: " .. newStorage .. "\n" ..
		"Luck: +x" .. string.format("%.1f", newLuck) .. " from rebirth\n" ..
		"Bonus: " .. formatNumber(bonusCoins) .. " coins!" ..
		savedMsg,
		"success")

	for _, p in pairs(Players:GetPlayers()) do
		if p ~= player then
			notifyEvent:FireClient(p,
				player.Name .. " reached Rebirth " .. nextRebirth .. "! (x" .. newMult .. ")", "info")
		end
	end

	print("[MoneyManager] " .. player.Name .. " rebirth " .. nextRebirth ..
		" | mult: x" .. newMult ..
		" | luck: +" .. newLuck ..
		" | trophies: " .. showcaseCount ..
		" | saveAll: " .. tostring(hasSaveAll))
end)

-- Rebirth info (called by client UI to populate the rebirth panel)
rebirthInfoEvent.OnServerInvoke = function(player)
	if not player:FindFirstChild("leaderstats") then return nil end

	local currentRebirth = player.leaderstats.Rebirths.Value
	local nextRebirth    = currentRebirth + 1

	if nextRebirth > 9 then
		return {
			MaxReached     = true,
			CurrentRebirth = currentRebirth,
			Multiplier     = getCashMultiplier(currentRebirth),
			Slots          = getTotalSlots(player, currentRebirth),
			Storage        = STORAGE_PER_REBIRTH[currentRebirth] or 55,
			RebirthLuck    = getRebirthLuck(currentRebirth),
		}
	end

	return {
		MaxReached          = false,
		CurrentRebirth      = currentRebirth,
		NextRebirth         = nextRebirth,
		CoinsCost           = REBIRTH_COINS_COST[nextRebirth]  or 0,
		BonusCoins          = REBIRTH_BONUS_COINS[nextRebirth] or 0,
		RequiredCharacters  = REBIRTH_REQUIREMENTS[nextRebirth] and REBIRTH_REQUIREMENTS[nextRebirth].Description or "None",
		CurrentCoins        = player.leaderstats.Coins.Value,
		Multiplier          = getCashMultiplier(currentRebirth),
		NextMultiplier      = getCashMultiplier(nextRebirth),
		CurrentSlots        = getTotalSlots(player, currentRebirth),
		NextSlots           = getTotalSlots(player, nextRebirth),
		CurrentStorage      = STORAGE_PER_REBIRTH[currentRebirth] or 4,
		NextStorage         = STORAGE_PER_REBIRTH[nextRebirth]    or 4,
		CurrentRebirthLuck  = getRebirthLuck(currentRebirth),
		NextRebirthLuck     = getRebirthLuck(nextRebirth),
	}
end

-- Base theme change
changeThemeEvent.OnServerEvent:Connect(function(player, themeIndex)
	if not player:FindFirstChild("leaderstats") then return end
	if type(themeIndex) ~= "number"            then return end
	if themeIndex < 0 or themeIndex > 8        then return end
	if player.leaderstats.Rebirths.Value < themeIndex then return end

	player:SetAttribute("SelectedBaseTheme", themeIndex)
	applyBaseColor(player)

	local themeNames = {
		"Solo Leveling","Black Clover","Hunter x Hunter","Bleach","My Hero Academia",
		"Attack on Titan","Dragon Ball","Naruto","One Piece",
	}
	notifyEvent:FireClient(player, "Base theme: " .. (themeNames[themeIndex + 1] or "Unknown"), "success")
end)

-- Character seen (marks a character as seen in the index even if not owned)
local seenEvent = ReplicatedStorage:FindFirstChild("CharacterSeenEvent")
if seenEvent then
	seenEvent.OnServerEvent:Connect(function(player, charName)
		if type(charName) ~= "string" or charName == "" then return end

		local seenFolder = player:FindFirstChild("SeenCharacters")
		if not seenFolder then
			seenFolder        = Instance.new("Folder")
			seenFolder.Name   = "SeenCharacters"
			seenFolder.Parent = player
		end

		if not seenFolder:FindFirstChild(charName) then
			local tag     = Instance.new("BoolValue")
			tag.Name      = charName
			tag.Value     = true
			tag.Parent    = seenFolder
		end
	end)
end

-- Protect character event (marks a character to survive rebirth without SaveAll)
local protectCharEvent = createEvent("ProtectCharacterEvent")

protectCharEvent.OnServerEvent:Connect(function(player, character, action)
	if not character or not character.Parent then return end
	if not character:IsA("BasePart") or character.Name ~= "PlacedCharacter" then return end

	local playerNumber = player:GetAttribute("SpawnerNumber") or 1
	local parent       = character.Parent
	local isOwned      = false

	if parent.Name:match("^Slot%d+$") then
		local bp = parent.Parent
		if bp and bp.Name == "BasePlateau" .. playerNumber then isOwned = true end
	end
	if parent.Name == "Storage" then
		local inv = parent.Parent
		if inv and inv.Name == "Inventory" and inv.Parent == player then isOwned = true end
	end

	if not isOwned then return end

	local charName = character:GetAttribute("CharacterName") or "Unknown"

	if action == "protect" then
		local alreadyProtected  = false
		local oldProtectedName  = nil

		local bp = getPlayerBasePlateau(player)
		if bp then
			for _, slot in pairs(bp:GetChildren()) do
				if slot.Name:match("^Slot%d+$") then
					for _, child in pairs(slot:GetChildren()) do
						if child.Name == "PlacedCharacter"
							and child:GetAttribute("IsProtected") == true
							and child ~= character then
							alreadyProtected = true
							oldProtectedName = child:GetAttribute("CharacterName")
						end
					end
				end
			end
		end

		local inv = player:FindFirstChild("Inventory")
		if inv then
			local stor = inv:FindFirstChild("Storage")
			if stor then
				for _, child in pairs(stor:GetChildren()) do
					if child:IsA("BasePart")
						and child:GetAttribute("IsProtected") == true
						and child ~= character then
						alreadyProtected = true
						oldProtectedName = child:GetAttribute("CharacterName")
					end
				end
			end
		end

		if alreadyProtected then
			notifyEvent:FireClient(player,
				"Already protecting: " .. (oldProtectedName or "Unknown") .. ". Unprotect it first!", "error")
			return
		end

		character:SetAttribute("IsProtected", true)
		notifyEvent:FireClient(player, charName .. " is now protected! It will survive rebirth.", "success")

	elseif action == "unprotect" then
		character:SetAttribute("IsProtected", false)
		notifyEvent:FireClient(player, charName .. " is no longer protected.", "info")
	end
end)

-- Index collect event
-- Rewards a luck bonus when a player discovers all characters from one anime series.
local indexCollectEvent = createEvent("IndexCollectEvent")

local INDEX_ANIME_DATA = {
	["Solo Leveling"]    = {luckBonus=0.3, chars={"Yoo Jin-Ho","Go Gun-Hee","Cha Hae-In","Woo Jin-Chul","Sung Jin-Woo","Beru","Igris","Tank","Architect"}},
	["Black Clover"]     = {luckBonus=0.3, chars={"Noelle Silva","Magna Swing","Luck Voltia","Finral Roulacase","Yami Sukehiro","Asta","Yuno","Julius Novachrono","William Vangeance"}},
	["Hunter x Hunter"]  = {luckBonus=0.3, chars={"Leorio Paradinight","Gon Freecss","Kurapika","Killua Zoldyck","Bisky","Hisoka","Chrollo Lucifer","Meruem","Adult Gon Freecss"}},
	["Bleach"]           = {luckBonus=0.3, chars={"Ichigo Kurosaki","Renji Abarai","Rukia Kuchiki","Grimmjow Jaegerjaquez","Ulquiorra Cifer","Yhwach","Kenpachi Zaraki","Sosuke Aizen"}},
	["My Hero Academia"] = {luckBonus=0.3, chars={"Izuku Midoriya","Katsuki Bakugo","Shoto Todoroki","Dabi","All Might","Tomura Shigaraki","Shota Aizawa","All For One"}},
	["Attack on Titan"]  = {luckBonus=0.4, chars={"Levi Ackerman","Eren Yeager","Armin Arlert","Female Titan","Armored Titan","Beast Titan","Attack Titan","Eren Founding Titan"}},
	["Dragon Ball"]      = {luckBonus=0.4, chars={"Goku","Vegeta","Gohan","Frieza","Cell","Broly","Piccolo","Goku SSJ GOD"}},
	["Naruto"]           = {luckBonus=0.5, chars={"Jiraiya","Kakashi Hatake","Minato Namikaze","Pain","Itachi Uchiha","Naruto Uzumaki","Sasuke Uchiha Akatsuki","Madara Uchiha"}},
	["One Piece"]        = {luckBonus=0.5, chars={"Roronoa Zoro","Monkey D. Luffy","Portgas D. Ace","Trafalgar D. Law","Donquixote Doflamingo","Whitebeard","Boa Hancock","Shanks","Enel","Kaido","Monkey D. Luffy Gear 5"}},
}

indexCollectEvent.OnServerEvent:Connect(function(player, animeName)
	if type(animeName) ~= "string" then return end
	local animeInfo = INDEX_ANIME_DATA[animeName]
	if not animeInfo then return end

	if player:GetAttribute("IndexCollected_" .. animeName) == true then
		notifyEvent:FireClient(player, "Already collected the " .. animeName .. " index reward!", "error")
		return
	end

	local discoveredFolder = player:FindFirstChild("DiscoveredCharacters")
	if not discoveredFolder then return end

	for _, charName in ipairs(animeInfo.chars) do
		if not discoveredFolder:FindFirstChild(charName) then
			notifyEvent:FireClient(player, "Haven't completed all " .. animeName .. " characters yet!", "error")
			return
		end
	end

	player:SetAttribute("IndexCollected_" .. animeName, true)
	local currentIndexLuck = player:GetAttribute("IndexLuck") or 0
	player:SetAttribute("IndexLuck", currentIndexLuck + animeInfo.luckBonus)

	for _, p in pairs(Players:GetPlayers()) do
		if p ~= player then
			notifyEvent:FireClient(p, player.Name .. " completed the " .. animeName .. " Index!", "info")
		end
	end

	notifyEvent:FireClient(player,
		animeName .. " INDEX COMPLETE! +x" .. string.format("%.1f", animeInfo.luckBonus) .. " Luck!", "success")

	print("[MoneyManager] " .. player.Name .. " completed " .. animeName
		.. " index | IndexLuck now: " .. (currentIndexLuck + animeInfo.luckBonus))
end)

-- ServerLuck is initialized here; all updates go through recalculatePersonalLuck -> updateServerLuck.
-- There is no separate polling loop to avoid two systems overwriting each other.
workspace:SetAttribute("ServerLuck", 1)

print("[MoneyManager] Loaded")