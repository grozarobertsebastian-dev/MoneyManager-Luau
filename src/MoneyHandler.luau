-- handles economy, passive income, rebirths, spawner assignment,
-- steal system, base themes and server luck calculation.

local PhysicsService    = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local GD = require(ReplicatedStorage.Shared.GameData)

-- physics collision groups

local GROUP_BAND    = "Band"
local GROUP_PLAYERS = "Players"
local GROUP_CUBES   = "Cubes"

local function setup_physics()
	pcall(function() PhysicsService:RegisterCollisionGroup(GROUP_BAND)    end)
	pcall(function() PhysicsService:RegisterCollisionGroup(GROUP_PLAYERS) end)
	pcall(function() PhysicsService:RegisterCollisionGroup(GROUP_CUBES)   end)
	PhysicsService:CollisionGroupSetCollidable(GROUP_BAND,   GROUP_PLAYERS, false)
	PhysicsService:CollisionGroupSetCollidable(GROUP_CUBES,  GROUP_PLAYERS, false)
	PhysicsService:CollisionGroupSetCollidable(GROUP_BAND,   GROUP_CUBES,  true)
end
setup_physics()

local formatNumber         = GD.formatNumber
local ANIME_BASE_COLORS    = GD.ANIME_BASE_COLORS
local STORAGE_PER_REBIRTH  = GD.STORAGE_PER_REBIRTH
local REBIRTH_COINS_COST   = GD.REBIRTH_COINS_COST
local REBIRTH_BONUS_COINS  = GD.REBIRTH_BONUS_COINS
local REBIRTH_REQUIREMENTS = GD.REBIRTH_REQUIREMENTS

local function get_rebirth_luck(level)    return GD.getRebirthLuck(level)              end
local function get_cash_multiplier(level) return GD.getCashMultiplier(level)            end
local function get_total_slots(player, level)
	return GD.getTotalSlots(level, player:GetAttribute("HasBP_ExtraSlots"))
end

-- remote events

local function create_event(name, class)
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then return existing end
	local event = Instance.new(class or "RemoteEvent")
	event.Name   = name
	event.Parent = ReplicatedStorage
	return event
end

create_event("MoveToSlotEvent")
create_event("MoveToStorageEvent")
create_event("SellFromInventoryEvent")
create_event("CharacterSeenEvent")

local notifyEvent      = create_event("NotifyEvent")
local rebirthEvent     = create_event("RebirthEvent")
local changeThemeEvent = create_event("ChangeBaseThemeEvent")
local purchaseEvent    = create_event("PurchaseEvent")
local protectCharEvent = create_event("ProtectCharacterEvent")
local indexCollectEvent = create_event("IndexCollectEvent")

local rebirthInfoEvent = ReplicatedStorage:FindFirstChild("RebirthInfoEvent")
if not rebirthInfoEvent then
	rebirthInfoEvent        = Instance.new("RemoteFunction")
	rebirthInfoEvent.Name   = "RebirthInfoEvent"
	rebirthInfoEvent.Parent = ReplicatedStorage
end

-- spawner assignment

local assigned_spawners = {}
local MAX_SPAWNERS = 6

local function assign_spawner(player)
	for i = 1, MAX_SPAWNERS do
		local taken = false
		for _, num in pairs(assigned_spawners) do
			if num == i then taken = true; break end
		end
		if not taken then
			assigned_spawners[player.UserId] = i
			player:SetAttribute("SpawnerNumber", i)
			print("[MoneyManager] " .. player.Name .. " -> SpawnerPlayer" .. i)
			return i
		end
	end
	warn("[MoneyManager] No spawner available for " .. player.Name)
	return nil
end

-- player helpers

local function get_base_plateau(player)
	local pn = player:GetAttribute("SpawnerNumber") or 1
	local folder = workspace:FindFirstChild("SpawnerPlayer" .. pn)
	if not folder then return nil end
	return folder:FindFirstChild("BasePlateau" .. pn)
end

local function apply_base_color(player)
	local level = 0
	if player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Rebirths") then
		level = player.leaderstats.Rebirths.Value
	end
	local color_level = player:GetAttribute("SelectedBaseTheme") or level
	local bp = get_base_plateau(player)
	if bp then
		bp.Color    = ANIME_BASE_COLORS[color_level] or Color3.fromRGB(108, 59, 245)
		bp.Material = Enum.Material.SmoothPlastic
	end
end

-- server luck

local function update_server_luck()
	local players = Players:GetPlayers()
	if #players == 0 then workspace:SetAttribute("ServerLuck", 1); return end
	local total = 0
	for _, p in ipairs(players) do
		total = total + (p:GetAttribute("PersonalLuck") or 1)
	end
	workspace:SetAttribute("ServerLuck", math.max(1, math.sqrt(total / #players)))
end

local function recalculate_personal_luck(player)
	local level = 0
	if player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Rebirths") then
		level = player.leaderstats.Rebirths.Value
	end
	local rebirth_luck = get_rebirth_luck(level)
	local index_luck   = player:GetAttribute("IndexLuck")   or 0
	local premium_luck = player:GetAttribute("PremiumLuck") or 0
	local potion_luck  = 0
	local potion_exp   = player:GetAttribute("PotionLuckExpire") or 0
	if os.time() < potion_exp then
		local raw        = player:GetAttribute("PotionLuck") or 0
		local base_no_pot = 1 + rebirth_luck + index_luck + premium_luck
		local SOFT_CAP   = 8
		local diminish   = math.min(1, SOFT_CAP / math.max(SOFT_CAP, base_no_pot))
		potion_luck      = raw * diminish
	end
	local luck = 1 + rebirth_luck + index_luck + premium_luck + potion_luck
	if player:GetAttribute("HasBP_x2Luck") then luck = luck * 2   end
	if player:GetAttribute("IsVIP")        then luck = luck * 1.1 end
	player:SetAttribute("PersonalLuck",  luck)
	player:SetAttribute("RebirthLuck",   rebirth_luck)
	update_server_luck()
	return luck
end

-- character counting

local function count_all_characters(player)
	local counts = {}
	local bp = get_base_plateau(player)
	if bp then
		for _, slot in pairs(bp:GetChildren()) do
			if slot.Name:match("^Slot%d+$") then
				for _, child in pairs(slot:GetChildren()) do
					if child:IsA("BasePart") and child.Name == "PlacedCharacter" then
						local n = child:GetAttribute("CharacterName") or ""
						counts[n] = (counts[n] or 0) + 1
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
				if child:IsA("BasePart") then
					local n = child:GetAttribute("CharacterName") or ""
					counts[n] = (counts[n] or 0) + 1
				end
			end
		end
	end
	return counts
end

-- character serialization

local function save_character_data(child)
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

local function restore_character_to_storage(stor, cd)
	local char      = Instance.new("Part")
	char.Name       = "PlacedCharacter"
	char.Anchored   = true
	char.CanCollide = false
	char.Size = cd.Size and Vector3.new(cd.Size[1], cd.Size[2], cd.Size[3]) or Vector3.new(3, 3, 3)
	if cd.Color       then char.Color = Color3.new(cd.Color[1], cd.Color[2], cd.Color[3]) end
	if cd.Material    then pcall(function() char.Material = Enum.Material[cd.Material]  end) end
	if cd.Transparency then char.Transparency = cd.Transparency end
	if cd.Shape       then pcall(function() char.Shape    = Enum.PartType[cd.Shape]      end) end
	if cd.MeshId and cd.MeshId ~= "" then
		local mesh  = Instance.new("SpecialMesh")
		mesh.MeshId = cd.MeshId
		if cd.TextureId then mesh.TextureId = cd.TextureId end
		if cd.MeshScale then mesh.Scale = Vector3.new(cd.MeshScale[1], cd.MeshScale[2], cd.MeshScale[3]) end
		if cd.MeshType  then pcall(function() mesh.MeshType = Enum.MeshType[cd.MeshType] end) end
		mesh.Parent = char
	end
	if cd.Decals then
		for _, d in pairs(cd.Decals) do
			local decal   = Instance.new(d.ClassName)
			pcall(function() decal.Face = Enum.NormalId[d.Face] end)
			decal.Texture = d.Texture
			decal.Parent  = char
		end
	end
	local stars        = cd.Stars or 1
	local star_mult    = stars > 1 and (1.75 ^ (stars - 1)) or 1
	local base_income  = cd.PassiveIncome or 0
	char:SetAttribute("CharacterName",     cd.CharacterName)
	char:SetAttribute("Rarity",            cd.Rarity)
	char:SetAttribute("BasePassiveIncome", base_income)
	char:SetAttribute("PassiveIncome",     base_income * star_mult)
	char:SetAttribute("Price",             cd.Price)
	char:SetAttribute("Anime",             cd.Anime or "Unknown")
	char:SetAttribute("Stars",             stars)
	char:SetAttribute("IsLocked",          cd.IsLocked)
	char:SetAttribute("IsProtected",       cd.IsProtected)
	char:SetAttribute("InInventory",       true)
	char.Position = Vector3.new(0, -200, 0)
	char.Parent   = stor
	return char
end

-- slot visibility and layout

local function update_slots_visibility(player)
	if not player:FindFirstChild("leaderstats") then return end
	local level    = player.leaderstats.Rebirths.Value
	local unlocked = get_total_slots(player, level)
	local capacity = STORAGE_PER_REBIRTH[level] or 4
	player:SetAttribute("StorageCapacity", capacity)
	player:SetAttribute("SlotCount",       unlocked)
	local bp = get_base_plateau(player)
	if not bp then return end
	local template = nil
	for _, part in pairs(bp:GetChildren()) do
		if part.Name:match("^Slot%d+$") and part:IsA("BasePart") then template = part; break end
	end
	if not template then return end
	local surface_y   = bp.Position.Y + bp.Size.Y / 2
	local slot_thick  = (template.Shape == Enum.PartType.Cylinder) and template.Size.X or template.Size.Y
	local slot_y      = surface_y + slot_thick / 2
	local spacing     = 12
	local cols        = 5
	local total_rows  = math.ceil(unlocked / cols)
	local start_x     = bp.Position.X - (cols - 1) * spacing / 2
	local start_z     = bp.Position.Z - (total_rows - 1) * spacing / 2
	for i = 0, unlocked - 1 do
		local slot_name = "Slot" .. i
		local existing  = bp:FindFirstChild(slot_name)
		local row       = math.floor(i / cols)
		local col       = i % cols
		local correct_pos = Vector3.new(start_x + col * spacing, slot_y, start_z + row * spacing)
		if existing then
			if math.abs(existing.Position.Y - slot_y) > 0.5 then
				local char_part = nil
				for _, child in pairs(existing:GetChildren()) do
					if child.Name == "PlacedCharacter" then char_part = child; break end
				end
				existing.Position    = Vector3.new(existing.Position.X, slot_y, existing.Position.Z)
				existing.Orientation = template.Orientation
				existing.Shape       = template.Shape
				existing.Size        = template.Size
				if char_part then
					char_part.Position = existing.Position + Vector3.new(0, 2, 0)
					local tag = char_part:FindFirstChild("NameTag")
					if tag then tag.Adornee = char_part end
				end
			end
		else
			local new_slot        = Instance.new("Part")
			new_slot.Name         = slot_name
			new_slot.Shape        = template.Shape
			new_slot.Size         = template.Size
			new_slot.Material     = template.Material
			new_slot.Color        = template.Color
			new_slot.Transparency = 0.5
			new_slot.Anchored     = true
			new_slot.CanCollide   = true
			new_slot.Orientation  = template.Orientation
			new_slot.Position     = correct_pos
			new_slot:SetAttribute("Occupied", false)
			new_slot.Parent       = bp
		end
	end
	for _, part in pairs(bp:GetChildren()) do
		if part.Name:match("^Slot%d+$") then
			local num = tonumber(part.Name:match("%d+"))
			if num ~= nil then
				if num < unlocked then
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

-- spawn player at base

local function spawn_at_base(player, character, pn)
	local folder = workspace:FindFirstChild("SpawnerPlayer" .. pn)
	if not folder then return end
	local spawn = folder:FindFirstChild("SpawnLocation" .. pn)
	if not spawn  then return end
	local root  = character:WaitForChild("HumanoidRootPart", 5)
	if not root  then return end
	root.CFrame = spawn.CFrame + Vector3.new(0, 3, 0)
end

-- player added

Players.PlayerAdded:Connect(function(player)
	local pn = assign_spawner(player)

	local stats    = Instance.new("Folder")
	stats.Name     = "leaderstats"
	stats.Parent   = player

	local coins    = Instance.new("NumberValue")
	coins.Name     = "Coins"
	coins.Value    = 10000
	coins.Parent   = stats

	local rebirths = Instance.new("IntValue")
	rebirths.Name  = "Rebirths"
	rebirths.Value = 0
	rebirths.Parent = stats

	local inv      = Instance.new("Folder")
	inv.Name       = "Inventory"
	inv.Parent     = player

	local inv_count      = Instance.new("IntValue")
	inv_count.Name       = "InventoryCount"
	inv_count.Value      = 0
	inv_count.Parent     = inv

	Instance.new("Folder", inv).Name    = "Storage"
	Instance.new("Folder", player).Name = "DiscoveredCharacters"
	Instance.new("Folder", player).Name = "SeenCharacters"

	player:SetAttribute("CashMultiplier",  get_cash_multiplier(0))
	player:SetAttribute("StorageCapacity", STORAGE_PER_REBIRTH[0])
	player:SetAttribute("SlotCount",       get_total_slots(player, 0))
	player:SetAttribute("MaxRebirth",      9)
	player:SetAttribute("RebirthLuck",     0)
	player:SetAttribute("IndexLuck",       0)
	player:SetAttribute("PremiumLuck",     0)
	player:SetAttribute("PersonalLuck",    1)
	player:SetAttribute("LuckBoostExpire", 0)

	recalculate_personal_luck(player)

	player.CharacterAdded:Connect(function(character)
		task.wait(0.2)
		if pn then spawn_at_base(player, character, pn) end
		task.wait(0.2)
		update_slots_visibility(player)
		apply_base_color(player)
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
		update_slots_visibility(player)
		player:SetAttribute("CashMultiplier", get_cash_multiplier(rebirths.Value))
		recalculate_personal_luck(player)
	end)

	player:GetAttributeChangedSignal("HasBP_x2Luck"):Connect(function()  recalculate_personal_luck(player) end)
	player:GetAttributeChangedSignal("IndexLuck"):Connect(function()      recalculate_personal_luck(player) end)
	player:GetAttributeChangedSignal("PremiumLuck"):Connect(function()    recalculate_personal_luck(player) end)
	player:GetAttributeChangedSignal("IsVIP"):Connect(function()          recalculate_personal_luck(player) end)
	player:GetAttributeChangedSignal("PotionLuck"):Connect(function()     recalculate_personal_luck(player) end)
	player:GetAttributeChangedSignal("HasBP_ExtraSlots"):Connect(function() update_slots_visibility(player) end)
	player:GetAttributeChangedSignal("HasBP_x2Speed"):Connect(function()
		if player:GetAttribute("HasBP_x2Speed") and player.Character then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then humanoid.WalkSpeed = humanoid.WalkSpeed * 2 end
		end
	end)

	task.delay(6, function()
		if player and player.Parent then update_slots_visibility(player) end
	end)

	-- passive income loop
	task.spawn(function()
		while player and player.Parent do
			task.wait(1)
			local total      = 0
			local multiplier = player:GetAttribute("CashMultiplier") or 1
			local bp = get_base_plateau(player)
			if bp then
				for _, slot in pairs(bp:GetChildren()) do
					if slot.Name:match("^Slot%d+$") then
						for _, child in pairs(slot:GetChildren()) do
							if child.Name == "PlacedCharacter" then
								total = total + (child:GetAttribute("PassiveIncome") or 0)
							end
						end
					end
				end
			end
			local income = math.floor(total * multiplier)
			if workspace:GetAttribute("GlobalMoneyActive") then income = income * 2 end
			if player:GetAttribute("HasBP_x2Coins")        then income = income * 2 end
			local potion_exp = player:GetAttribute("PotionMoneyExpire") or 0
			if os.time() < potion_exp then
				local pm = player:GetAttribute("PotionMoneyMult") or 1
				if pm > 1 then income = math.floor(income * pm) end
			end
			if income > 0 then
				player.leaderstats.Coins.Value = player.leaderstats.Coins.Value + income
			end
		end
	end)
end)

-- player cleanup

Players.PlayerRemoving:Connect(function(player)
	assigned_spawners[player.UserId] = nil
	task.defer(update_server_luck)
end)

-- steal system

local function steal_traveling_character(stealer, travel_char, prompt)
	if not travel_char or not travel_char.Parent then return end
	if travel_char.Name ~= "TravelingCharacter"  then return end
	local steal_price  = travel_char:GetAttribute("StealPrice")  or 0
	local owner_id     = travel_char:GetAttribute("OwnerUserId") or 0
	local paid_price   = travel_char:GetAttribute("PaidPrice")   or 0
	local char_name    = travel_char:GetAttribute("CharacterName") or "?"
	if stealer.UserId == owner_id then
		notifyEvent:FireClient(stealer, "That's your own character!", "error")
		return
	end
	local stealer_stats = stealer:FindFirstChild("leaderstats")
	if not stealer_stats then return end
	local stealer_coins = stealer_stats:FindFirstChild("Coins")
	if not stealer_coins or stealer_coins.Value < steal_price then
		notifyEvent:FireClient(stealer, "Not enough coins! Need " .. formatNumber(steal_price), "error")
		return
	end
	local stealer_base = get_base_plateau(stealer)
	if not stealer_base then
		notifyEvent:FireClient(stealer, "Cannot find your base!", "error")
		return
	end
	local level    = stealer_stats:FindFirstChild("Rebirths") and stealer_stats.Rebirths.Value or 0
	local unlocked = get_total_slots(stealer, level)
	local free_slot = nil
	for i = 0, unlocked - 1 do
		local slot = stealer_base:FindFirstChild("Slot" .. i)
		if slot then
			local occupied = false
			for _, child in pairs(slot:GetChildren()) do
				if child.Name == "PlacedCharacter" then occupied = true; break end
			end
			if not occupied and slot:GetAttribute("Occupied") ~= true then
				free_slot = slot; break
			end
		end
	end
	if not free_slot then
		notifyEvent:FireClient(stealer, "All slots full! Can't steal.", "error")
		return
	end
	local old_pn        = travel_char:GetAttribute("PlayerNumber")   or 1
	local old_slot_name = travel_char:GetAttribute("TargetSlotName")
	local old_folder    = workspace:FindFirstChild("SpawnerPlayer" .. old_pn)
	if old_folder then
		local old_base = old_folder:FindFirstChild("BasePlateau" .. old_pn)
		if old_base and old_slot_name then
			local old_slot = old_base:FindFirstChild(old_slot_name)
			if old_slot then old_slot:SetAttribute("Occupied", false) end
		end
	end
	local owner = Players:GetPlayerByUserId(owner_id)
	if owner then
		local owner_stats = owner:FindFirstChild("leaderstats")
		if owner_stats and owner_stats:FindFirstChild("Coins") then
			owner_stats.Coins.Value = owner_stats.Coins.Value + paid_price
			notifyEvent:FireClient(owner, char_name .. " was stolen! +" .. formatNumber(paid_price) .. " refunded", "warning")
		end
	end
	stealer_coins.Value = stealer_coins.Value - steal_price
	local new_steal_price = math.ceil(steal_price * 1.03)
	travel_char:SetAttribute("OwnerUserId",    stealer.UserId)
	travel_char:SetAttribute("OwnerName",      stealer.Name)
	travel_char:SetAttribute("PaidPrice",      steal_price)
	travel_char:SetAttribute("StealPrice",     new_steal_price)
	free_slot:SetAttribute("Occupied", true)
	travel_char:SetAttribute("PlayerNumber",   stealer:GetAttribute("SpawnerNumber") or 1)
	travel_char:SetAttribute("TargetSlotName", free_slot.Name)
	travel_char:SetAttribute("IsRerouted",     true)
	if prompt and prompt.Parent then
		prompt.ObjectText = char_name .. " - " .. formatNumber(new_steal_price) .. " coins"
	end
	notifyEvent:FireClient(stealer, "Stole " .. char_name .. " for " .. formatNumber(steal_price) .. "!", "success")
	print("[MoneyManager] " .. stealer.Name .. " stole " .. char_name .. " (paid " .. formatNumber(steal_price) .. ")")
end

-- purchase event

purchaseEvent.OnServerEvent:Connect(function(player, cube)
	if not cube or not cube.Parent    then return end
	if not cube:IsA("BasePart")       then return end
	if cube.Name ~= "BandaCube"       then return end
	if cube:GetAttribute("Purchased") == true then return end
	local char_name = cube:GetAttribute("CharacterName")
	local price     = cube:GetAttribute("Price")
	if not char_name or not price then return end
	cube:SetAttribute("Purchased", true)
	local ls = player:FindFirstChild("leaderstats")
	if not ls then cube:SetAttribute("Purchased", false); return end
	local coins = ls:FindFirstChild("Coins")
	if not coins then cube:SetAttribute("Purchased", false); return end
	local level       = ls:FindFirstChild("Rebirths") and ls.Rebirths.Value or 0
	local req_rebirth = cube:GetAttribute("RequiredRebirth") or 0
	if level < req_rebirth then
		cube:SetAttribute("Purchased", false)
		local anime = cube:GetAttribute("Anime") or "this island"
		notifyEvent:FireClient(player,
			"Locked! Requires Rebirth " .. req_rebirth .. " to collect " .. anime ..
			" characters. (You are R" .. level .. ")", "error")
		return
	end
	if coins.Value < price then
		cube:SetAttribute("Purchased", false)
		notifyEvent:FireClient(player, "Not enough coins! Need " .. formatNumber(price), "error")
		return
	end
	local bp = get_base_plateau(player)
	if not bp then cube:SetAttribute("Purchased", false); return end
	local unlocked  = get_total_slots(player, level)
	local free_slot = nil
	for i = 0, unlocked - 1 do
		local slot = bp:FindFirstChild("Slot" .. i)
		if slot then
			local has_char = false
			for _, child in pairs(slot:GetChildren()) do
				if child.Name == "PlacedCharacter" then has_char = true; break end
			end
			if not has_char and slot:GetAttribute("Occupied") ~= true then
				free_slot = slot; break
			end
		end
	end
	if not free_slot then
		cube:SetAttribute("Purchased", false)
		notifyEvent:FireClient(player, "All slots full! Move characters to storage first.", "error")
		return
	end
	coins.Value = coins.Value - price
	local new_char      = cube:Clone()
	new_char.Name       = "TravelingCharacter"
	new_char.Anchored   = true
	new_char.CanCollide = false
	new_char:SetAttribute("Purchased", nil)
	local pn = player:GetAttribute("SpawnerNumber") or 1
	new_char:SetAttribute("TargetSlotName", free_slot.Name)
	new_char:SetAttribute("PlayerNumber",   pn)
	new_char:SetAttribute("Processing",     false)
	free_slot:SetAttribute("Occupied", true)
	local steal_price = math.ceil(price * 1.03)
	new_char:SetAttribute("OwnerUserId", player.UserId)
	new_char:SetAttribute("OwnerName",   player.Name)
	new_char:SetAttribute("PaidPrice",   price)
	new_char:SetAttribute("StealPrice",  steal_price)
	local prompt                       = Instance.new("ProximityPrompt")
	prompt.Name                        = "StealPrompt"
	prompt.ActionText                  = "Steal"
	prompt.ObjectText                  = char_name .. " - " .. formatNumber(steal_price) .. " coins"
	prompt.MaxActivationDistance       = 8
	prompt.HoldDuration                = 1
	prompt.Parent                      = new_char
	prompt.Triggered:Connect(function(stealing_player)
		steal_traveling_character(stealing_player, new_char, prompt)
	end)
	new_char.Parent = workspace
	cube:Destroy()
	local discovered = player:FindFirstChild("DiscoveredCharacters")
	if discovered and not discovered:FindFirstChild(char_name) then
		local tag     = Instance.new("BoolValue")
		tag.Name      = char_name
		tag.Value     = true
		tag.Parent    = discovered
	end
	notifyEvent:FireClient(player, char_name .. " purchased for " .. formatNumber(price) .. "!", "success")
end)

-- rebirth event

rebirthEvent.OnServerEvent:Connect(function(player)
	if not player:FindFirstChild("leaderstats") then return end
	local current = player.leaderstats.Rebirths.Value
	local next_rb = current + 1
	if next_rb > 9 then
		notifyEvent:FireClient(player, "Already at max rebirth (Level 9)!", "error")
		return
	end
	local coins_cost = REBIRTH_COINS_COST[next_rb] or 999999999
	if player.leaderstats.Coins.Value < coins_cost then
		notifyEvent:FireClient(player,
			"Need " .. formatNumber(coins_cost) .. " coins for Rebirth " .. next_rb ..
			". You have: " .. formatNumber(player.leaderstats.Coins.Value), "error")
		return
	end
	local requirements = REBIRTH_REQUIREMENTS[next_rb]
	if requirements then
		local counts  = count_all_characters(player)
		local missing = {}
		for char_name, needed in pairs(requirements.Characters) do
			local have = counts[char_name] or 0
			if have < needed then
				table.insert(missing, char_name .. " (" .. have .. "/" .. needed .. ")")
			end
		end
		if #missing > 0 then
			notifyEvent:FireClient(player,
				"Rebirth " .. next_rb .. " needs: " .. table.concat(missing, ", "), "error")
			return
		end
	end
	local bonus_coins = REBIRTH_BONUS_COINS[next_rb] or 0
	local has_save_all = player:GetAttribute("HasBP_SaveAll") == true
	local saved_chars = {}
	if has_save_all then
		local bp = get_base_plateau(player)
		if bp then
			for _, slot in pairs(bp:GetChildren()) do
				if slot.Name:match("^Slot%d+$") then
					for _, child in pairs(slot:GetChildren()) do
						if child:IsA("BasePart") and child.Name == "PlacedCharacter" then
							table.insert(saved_chars, save_character_data(child))
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
					if child:IsA("BasePart") then
						table.insert(saved_chars, save_character_data(child))
					end
				end
			end
		end
	end
	player.leaderstats.Rebirths.Value = next_rb
	player.leaderstats.Coins.Value    = bonus_coins
	player:SetAttribute("SelectedBaseTheme", next_rb)
	apply_base_color(player)
	recalculate_personal_luck(player)
	local bp = get_base_plateau(player)
	if bp then
		for _, slot in pairs(bp:GetChildren()) do
			if slot.Name:match("^Slot%d+$") then
				for _, child in pairs(slot:GetChildren()) do
					if child.Name == "PlacedCharacter" then child:Destroy() end
				end
				slot:SetAttribute("Occupied", false)
			end
		end
	end
	local inv = player:FindFirstChild("Inventory")
	if inv then
		local stor = inv:FindFirstChild("Storage")
		if stor then for _, child in pairs(stor:GetChildren()) do child:Destroy() end end
		local ic = inv:FindFirstChild("InventoryCount")
		if ic then ic.Value = 0 end
	end
	update_slots_visibility(player)
	if has_save_all and #saved_chars > 0 then
		task.delay(1, function()
			local i2 = player:FindFirstChild("Inventory")
			if not i2 then return end
			local s2 = i2:FindFirstChild("Storage")
			if not s2 then return end
			local count = 0
			for _, cd in ipairs(saved_chars) do
				restore_character_to_storage(s2, cd)
				count = count + 1
			end
			local ic = i2:FindFirstChild("InventoryCount")
			if ic then ic.Value = ic.Value + count end
			notifyEvent:FireClient(player,
				"Save All: " .. count .. " characters survived the rebirth! (In Storage)", "success")
		end)
	end
	local showcase_count = 0
	if bp then
		for _, child in pairs(bp:GetChildren()) do
			if child.Name:match("^ShowcasePedestal") then
				for _, sc in pairs(child:GetChildren()) do
					if sc:IsA("BasePart") and sc.Name == "ShowcaseCharacter" then
						showcase_count = showcase_count + 1
					end
				end
			end
		end
	end
	local new_mult    = get_cash_multiplier(next_rb)
	local new_slots   = get_total_slots(player, next_rb)
	local new_storage = STORAGE_PER_REBIRTH[next_rb] or 4
	local new_luck    = get_rebirth_luck(next_rb)
	local saved_msg = ""
	if has_save_all then
		saved_msg = "\nAll characters saved!"
	elseif showcase_count > 0 then
		saved_msg = "\n" .. showcase_count .. " Trophy Stand character(s) survived!"
	end
	notifyEvent:FireClient(player,
		"REBIRTH " .. next_rb .. " SUCCESS!\n" ..
		"Multiplier: x" .. new_mult .. "\n" ..
		"Slots: " .. new_slots .. " | Storage: " .. new_storage .. "\n" ..
		"Luck: +x" .. string.format("%.1f", new_luck) .. " from rebirth\n" ..
		"Bonus: " .. formatNumber(bonus_coins) .. " coins!" .. saved_msg,
		"success")
	for _, p in pairs(Players:GetPlayers()) do
		if p ~= player then
			notifyEvent:FireClient(p, player.Name .. " reached Rebirth " .. next_rb .. "! (x" .. new_mult .. ")", "info")
		end
	end
	print("[MoneyManager] " .. player.Name .. " rebirth " .. next_rb ..
		" | mult: x" .. new_mult ..
		" | luck: +"  .. new_luck ..
		" | trophies: " .. showcase_count ..
		" | saveAll: "  .. tostring(has_save_all))
end)

-- rebirth info

rebirthInfoEvent.OnServerInvoke = function(player)
	if not player:FindFirstChild("leaderstats") then return nil end
	local current = player.leaderstats.Rebirths.Value
	local next_rb = current + 1
	if next_rb > 9 then
		return {
			MaxReached     = true,
			CurrentRebirth = current,
			Multiplier     = get_cash_multiplier(current),
			Slots          = get_total_slots(player, current),
			Storage        = STORAGE_PER_REBIRTH[current] or 55,
			RebirthLuck    = get_rebirth_luck(current),
		}
	end
	return {
		MaxReached         = false,
		CurrentRebirth     = current,
		NextRebirth        = next_rb,
		CoinsCost          = REBIRTH_COINS_COST[next_rb]  or 0,
		BonusCoins         = REBIRTH_BONUS_COINS[next_rb] or 0,
		RequiredCharacters = REBIRTH_REQUIREMENTS[next_rb] and REBIRTH_REQUIREMENTS[next_rb].Description or "None",
		CurrentCoins       = player.leaderstats.Coins.Value,
		Multiplier         = get_cash_multiplier(current),
		NextMultiplier     = get_cash_multiplier(next_rb),
		CurrentSlots       = get_total_slots(player, current),
		NextSlots          = get_total_slots(player, next_rb),
		CurrentStorage     = STORAGE_PER_REBIRTH[current] or 4,
		NextStorage        = STORAGE_PER_REBIRTH[next_rb] or 4,
		CurrentRebirthLuck = get_rebirth_luck(current),
		NextRebirthLuck    = get_rebirth_luck(next_rb),
	}
end

-- base theme change

changeThemeEvent.OnServerEvent:Connect(function(player, theme_index)
	if not player:FindFirstChild("leaderstats")     then return end
	if type(theme_index) ~= "number"                then return end
	if theme_index < 0 or theme_index > 8           then return end
	if player.leaderstats.Rebirths.Value < theme_index then return end
	player:SetAttribute("SelectedBaseTheme", theme_index)
	apply_base_color(player)
	local theme_names = {
		"Solo Leveling","Black Clover","Hunter x Hunter","Bleach","My Hero Academia",
		"Attack on Titan","Dragon Ball","Naruto","One Piece",
	}
	notifyEvent:FireClient(player, "Base theme: " .. (theme_names[theme_index + 1] or "Unknown"), "success")
end)

-- character seen event

local seen_event = ReplicatedStorage:FindFirstChild("CharacterSeenEvent")
if seen_event then
	seen_event.OnServerEvent:Connect(function(player, char_name)
		if type(char_name) ~= "string" or char_name == "" then return end
		local folder = player:FindFirstChild("SeenCharacters")
		if not folder then
			folder        = Instance.new("Folder")
			folder.Name   = "SeenCharacters"
			folder.Parent = player
		end
		if not folder:FindFirstChild(char_name) then
			local tag     = Instance.new("BoolValue")
			tag.Name      = char_name
			tag.Value     = true
			tag.Parent    = folder
		end
	end)
end

-- protect character event

protectCharEvent.OnServerEvent:Connect(function(player, character, action)
	if not character or not character.Parent then return end
	if not character:IsA("BasePart") or character.Name ~= "PlacedCharacter" then return end
	local pn     = player:GetAttribute("SpawnerNumber") or 1
	local parent = character.Parent
	local owned  = false
	if parent.Name:match("^Slot%d+$") then
		local bp = parent.Parent
		if bp and bp.Name == "BasePlateau" .. pn then owned = true end
	end
	if parent.Name == "Storage" then
		local inv = parent.Parent
		if inv and inv.Name == "Inventory" and inv.Parent == player then owned = true end
	end
	if not owned then return end
	local char_name = character:GetAttribute("CharacterName") or "Unknown"
	if action == "protect" then
		local already    = false
		local old_name   = nil
		local bp = get_base_plateau(player)
		if bp then
			for _, slot in pairs(bp:GetChildren()) do
				if slot.Name:match("^Slot%d+$") then
					for _, child in pairs(slot:GetChildren()) do
						if child.Name == "PlacedCharacter"
							and child:GetAttribute("IsProtected") == true
							and child ~= character then
							already  = true
							old_name = child:GetAttribute("CharacterName")
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
						already  = true
						old_name = child:GetAttribute("CharacterName")
					end
				end
			end
		end
		if already then
			notifyEvent:FireClient(player,
				"Already protecting: " .. (old_name or "Unknown") .. ". Unprotect it first!", "error")
			return
		end
		character:SetAttribute("IsProtected", true)
		notifyEvent:FireClient(player, char_name .. " is now protected! It will survive rebirth.", "success")
	elseif action == "unprotect" then
		character:SetAttribute("IsProtected", false)
		notifyEvent:FireClient(player, char_name .. " is no longer protected.", "info")
	end
end)

-- index collect event

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

indexCollectEvent.OnServerEvent:Connect(function(player, anime_name)
	if type(anime_name) ~= "string" then return end
	local info = INDEX_ANIME_DATA[anime_name]
	if not info then return end
	if player:GetAttribute("IndexCollected_" .. anime_name) == true then
		notifyEvent:FireClient(player, "Already collected the " .. anime_name .. " index reward!", "error")
		return
	end
	local discovered = player:FindFirstChild("DiscoveredCharacters")
	if not discovered then return end
	for _, char_name in ipairs(info.chars) do
		if not discovered:FindFirstChild(char_name) then
			notifyEvent:FireClient(player, "Haven't completed all " .. anime_name .. " characters yet!", "error")
			return
		end
	end
	player:SetAttribute("IndexCollected_" .. anime_name, true)
	local current_luck = player:GetAttribute("IndexLuck") or 0
	player:SetAttribute("IndexLuck", current_luck + info.luckBonus)
	for _, p in pairs(Players:GetPlayers()) do
		if p ~= player then
			notifyEvent:FireClient(p, player.Name .. " completed the " .. anime_name .. " Index!", "info")
		end
	end
	notifyEvent:FireClient(player,
		anime_name .. " INDEX COMPLETE! +x" .. string.format("%.1f", info.luckBonus) .. " Luck!", "success")
	print("[MoneyManager] " .. player.Name .. " completed " .. anime_name
		.. " index | IndexLuck now: " .. (current_luck + info.luckBonus))
end)

workspace:SetAttribute("ServerLuck", 1)
print("[MoneyManager] loaded")
