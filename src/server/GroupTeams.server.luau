--!strict
--[[
	GroupTeams (server)

	- Creates one team per group in ReplicatedStorage.GroupTeams.Config
	- Checks each player's group ranks and only lets members join their group's team
	- Builds the overhead rank nameplate (group emblem, rank, name, unit, health)
	- Handles requests from the team changer menu

	Other scripts can read these Player attributes:
		RankName     string  role in the group of the player's current team
		RankNumber   number  rank 0-255 in that group (0 = not a member / civilian)
		RankGroupId  number  group ID of the player's current team (0 = none)

	SpawnLocations with a number attribute "GroupId" become that team's spawn
	(use 0 for the default team).
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Teams = game:GetService("Teams")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("GroupTeams")
local Config = require(Shared:WaitForChild("Config"))

local FETCH_ATTEMPTS = 3
local GROUP_INFO_TIMEOUT = 15
-- A rejected join re-checks the player's groups if the last check is older than this.
local RECHECK_AFTER = 20
local ICON_URL = "rbxthumb://type=GroupIcon&id=%d&w=150&h=150"
local OVERHEAD_NAME = "RankOverhead"

local HEADING_FONT = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local BODY_FONT = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)

type Membership = { Rank: number, Role: string, IsPrimary: boolean }

type TeamEntry = {
	Team: Team,
	-- nil for the default team
	GroupId: number?,
	MinRank: number,
	MinRoleName: string?,
}

type TeamPlan = {
	GroupId: number?,
	Name: string,
	Color: string,
	MinRank: number,
	MinRoleName: string?,
}

type Overhead = {
	Gui: BillboardGui,
	Icon: ImageLabel,
	Accent: Frame,
	Rank: TextLabel,
	Name: TextLabel,
	Unit: TextLabel,
	HealthBack: Frame,
	Health: Frame,
}

type PlayerState = {
	Memberships: { [number]: Membership },
	Loaded: boolean,
	Busy: boolean,
	LastFetch: number,
	LastTeamChange: number,
	Overhead: Overhead?,
}

type TeamChangeResult = { Ok: boolean, Message: string, Cooldown: number? }

local entries: { TeamEntry } = {}
local entryByTeam: { [Team]: TeamEntry } = {}
local entryByGroupId: { [number]: TeamEntry } = {}
local defaultEntry: TeamEntry? = nil
local states: { [Player]: PlayerState } = {}

local bypassIds: { [number]: boolean } = {}
for _, userId in Config.BypassUserIds do
	bypassIds[userId] = true
end

-- Runs a web call, retrying with a short backoff.
local function attempt(callback: () -> any): (boolean, any)
	local ok, result = false, nil
	for i = 1, FETCH_ATTEMPTS do
		ok, result = pcall(callback)
		if ok then
			return true, result
		end
		if i < FETCH_ATTEMPTS then
			task.wait(i)
		end
	end
	return false, result
end

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------

local oldRemotes = Shared:FindFirstChild("Remotes")
if oldRemotes then
	oldRemotes:Destroy()
end

local remotes = Instance.new("Folder")
remotes.Name = "Remotes"

local getTeamsRemote = Instance.new("RemoteFunction")
getTeamsRemote.Name = "GetTeams"
getTeamsRemote.Parent = remotes

local requestTeamRemote = Instance.new("RemoteFunction")
requestTeamRemote.Name = "RequestTeam"
requestTeamRemote.Parent = remotes

local dataChangedRemote = Instance.new("RemoteEvent")
dataChangedRemote.Name = "DataChanged"
dataChangedRemote.Parent = remotes

local notifyRemote = Instance.new("RemoteEvent")
notifyRemote.Name = "Notify"
notifyRemote.Parent = remotes

remotes.Parent = Shared

--------------------------------------------------------------------------------
-- Teams
--------------------------------------------------------------------------------

local function lowestRoleFrom(info: any, minRank: number): string?
	if type(info) ~= "table" or type(info.Roles) ~= "table" then
		return nil
	end
	local best: string?, bestRank: number = nil, math.huge
	for _, role in info.Roles do
		if type(role) == "table" and type(role.Rank) == "number" and role.Rank >= minRank and role.Rank < bestRank then
			best, bestRank = tostring(role.Name), role.Rank
		end
	end
	return best
end

local function setupTeams()
	-- Look up every group's name and roles at the same time.
	local infos: { [number]: any } = {}
	local remaining = #Config.Groups
	for _, group in Config.Groups do
		task.spawn(function()
			local ok, info = attempt(function()
				return GroupService:GetGroupInfoAsync(group.GroupId)
			end)
			if ok then
				infos[group.GroupId] = info
			else
				warn(`[GroupTeams] Couldn't load group {group.GroupId}: {info}`)
			end
			remaining -= 1
		end)
	end
	local deadline = os.clock() + GROUP_INFO_TIMEOUT
	while remaining > 0 and os.clock() < deadline do
		task.wait(0.1)
	end

	local plans: { TeamPlan } = {}
	local takenNames: { [string]: boolean } = {}
	local seenGroups: { [number]: boolean } = {}

	for _, group in Config.Groups do
		if seenGroups[group.GroupId] then
			warn(`[GroupTeams] Group {group.GroupId} is listed twice in Config; ignoring the second entry.`)
			continue
		end
		seenGroups[group.GroupId] = true

		local info = infos[group.GroupId]
		local name = group.TeamName
		if not name then
			name = if type(info) == "table" and type(info.Name) == "string" then info.Name else `Group {group.GroupId}`
		end
		if takenNames[name] then
			name = `{name} ({group.GroupId})`
		end
		takenNames[name] = true

		local minRank = math.clamp(group.MinRank or 1, 1, 255)
		table.insert(plans, {
			GroupId = group.GroupId,
			Name = name,
			Color = group.Color,
			MinRank = minRank,
			MinRoleName = lowestRoleFrom(info, minRank),
		})
	end

	local defaultConfig = Config.DefaultTeam
	if defaultConfig then
		local name = defaultConfig.TeamName
		if takenNames[name] then
			name = `{name} (Default)`
		end
		takenNames[name] = true
		table.insert(plans, { GroupId = nil, Name = name, Color = defaultConfig.Color, MinRank = 0 })
	end

	-- Team colours must be unique or Roblox mixes the teams up.
	local usedColors: { [number]: boolean } = {}
	for _, team in Teams:GetTeams() do
		if not takenNames[team.Name] then
			usedColors[team.TeamColor.Number] = true
		end
	end

	local function claimColor(colorName: string, teamName: string): BrickColor
		local color = BrickColor.new(colorName)
		if usedColors[color.Number] then
			for i = 0, 127 do
				local candidate = BrickColor.palette(i)
				if not usedColors[candidate.Number] then
					warn(`[GroupTeams] Colour "{colorName}" for {teamName} is already taken; using "{candidate.Name}".`)
					color = candidate
					break
				end
			end
		end
		usedColors[color.Number] = true
		return color
	end

	for _, plan in plans do
		local existing = Teams:FindFirstChild(plan.Name)
		local team: Team
		if existing and existing:IsA("Team") then
			team = existing
		else
			team = Instance.new("Team")
			team.Name = plan.Name
		end
		team.TeamColor = claimColor(plan.Color, plan.Name)
		team.AutoAssignable = false
		team:SetAttribute("GroupId", plan.GroupId or 0)
		team.Parent = Teams

		local entry: TeamEntry = {
			Team = team,
			GroupId = plan.GroupId,
			MinRank = plan.MinRank,
			MinRoleName = plan.MinRoleName,
		}
		entryByTeam[team] = entry

		local groupId = plan.GroupId
		if groupId then
			table.insert(entries, entry)
			entryByGroupId[groupId] = entry
		else
			defaultEntry = entry
		end
	end
end

local function linkSpawn(instance: Instance)
	if not instance:IsA("SpawnLocation") then
		return
	end
	local groupId = instance:GetAttribute("GroupId")
	if type(groupId) ~= "number" then
		return
	end
	local entry = if groupId == 0 then defaultEntry else entryByGroupId[groupId]
	if entry then
		instance.TeamColor = entry.Team.TeamColor
		instance.Neutral = false
		instance.AllowTeamChangeOnTouch = false
	else
		warn(`[GroupTeams] {instance:GetFullName()} has GroupId {groupId}, which isn't in Config.`)
	end
end

--------------------------------------------------------------------------------
-- Ranks and access
--------------------------------------------------------------------------------

local function hasBypass(player: Player): boolean
	return bypassIds[player.UserId] == true or (Config.BypassInStudio and RunService:IsStudio())
end

local function fetchMemberships(player: Player): { [number]: Membership }?
	-- Test players in a local Studio server have negative IDs and no groups.
	if player.UserId <= 0 then
		return {}
	end
	local ok, groups = attempt(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)
	if not ok or type(groups) ~= "table" then
		warn(`[GroupTeams] Couldn't load groups for {player.Name}: {groups}`)
		return nil
	end
	local memberships: { [number]: Membership } = {}
	for _, group in groups do
		if entryByGroupId[group.Id] then
			memberships[group.Id] = {
				Rank = group.Rank,
				Role = group.Role,
				IsPrimary = group.IsPrimary == true,
			}
		end
	end
	return memberships
end

-- Re-fetches a player's ranks. Returns false if the lookup failed or they left.
local function refreshMemberships(player: Player): boolean
	local state = states[player]
	if not state then
		return false
	end
	local memberships = fetchMemberships(player)
	if not memberships or states[player] ~= state then
		return false
	end
	state.Memberships = memberships
	state.LastFetch = os.clock()
	return true
end

local function checkAccess(player: Player, state: PlayerState, entry: TeamEntry): (boolean, string?)
	local groupId = entry.GroupId
	if groupId == nil or hasBypass(player) then
		return true, nil
	end
	local membership = state.Memberships[groupId]
	if not membership then
		return false, "Members only"
	end
	if membership.Rank < entry.MinRank then
		return false, if entry.MinRoleName then `Requires {entry.MinRoleName}+` else `Requires rank {entry.MinRank}+`
	end
	return true, nil
end

local function rankFor(state: PlayerState, entry: TeamEntry?): (string, number)
	if not entry then
		return "", 0
	end
	local groupId = entry.GroupId
	if groupId == nil then
		local defaultConfig = Config.DefaultTeam
		return if defaultConfig then defaultConfig.RankName else "", 0
	end
	local membership = state.Memberships[groupId]
	if membership then
		return membership.Role, membership.Rank
	end
	return Config.GuestRankName, 0
end

-- Best team for a player: primary group, then list order, then the default team.
local function pickTeam(player: Player, state: PlayerState): TeamEntry?
	for _, entry in entries do
		local groupId = entry.GroupId :: number
		local membership = state.Memberships[groupId]
		if membership and membership.IsPrimary and checkAccess(player, state, entry) then
			return entry
		end
	end
	for _, entry in entries do
		local groupId = entry.GroupId :: number
		if state.Memberships[groupId] and checkAccess(player, state, entry) then
			return entry
		end
	end
	return defaultEntry
end

local function setTeam(player: Player, entry: TeamEntry?)
	if entry then
		player.Neutral = false
		player.Team = entry.Team
	else
		player.Team = nil
		player.Neutral = true
	end
end

local function respawn(player: Player)
	task.defer(function()
		if player.Parent then
			player:LoadCharacter()
		end
	end)
end

--------------------------------------------------------------------------------
-- Overhead nameplate
--------------------------------------------------------------------------------

local function newText(parent: Instance, name: string, font: Font, maxSize: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.FontFace = font
	label.Text = ""
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0.45
	label.TextTruncate = Enum.TextTruncate.AtEnd

	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = maxSize
	limit.Parent = label

	label.Parent = parent
	return label
end

-- With an emblem the plate reads like an ID tag (emblem | text). Without one the
-- text is centred over the head.
local function layoutOverhead(overhead: Overhead, showIcon: boolean)
	local left = if showIcon then 0.295 else 0
	local width = 1 - left
	local align = if showIcon then Enum.TextXAlignment.Left else Enum.TextXAlignment.Center

	overhead.Icon.Visible = showIcon
	overhead.Accent.Visible = showIcon

	overhead.Rank.Position = UDim2.fromScale(left, 0.02)
	overhead.Rank.Size = UDim2.fromScale(width, 0.26)
	overhead.Name.Position = UDim2.fromScale(left, 0.27)
	overhead.Name.Size = UDim2.fromScale(width, 0.36)
	overhead.Unit.Position = UDim2.fromScale(left, 0.62)
	overhead.Unit.Size = UDim2.fromScale(width, 0.2)
	for _, label in { overhead.Rank, overhead.Name, overhead.Unit } do
		label.TextXAlignment = align
	end

	local back = overhead.HealthBack
	back.AnchorPoint = Vector2.new(if showIcon then 0 else 0.5, 0)
	back.Position = UDim2.fromScale(if showIcon then left else 0.5, 0.86)
	back.Size = UDim2.fromScale(if showIcon then 0.6 else 0.55, 0.075)
end

local function updateOverhead(player: Player, state: PlayerState, entry: TeamEntry?, rankName: string)
	local overhead = state.Overhead
	if not overhead then
		return
	end
	local team = player.Team
	local color = if team then team.TeamColor.Color else Color3.fromRGB(200, 200, 200)
	local groupId = if entry then entry.GroupId else nil

	overhead.Rank.Text = if Config.Overhead.UppercaseRank then string.upper(rankName) else rankName
	overhead.Rank.TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.2)
	overhead.Accent.BackgroundColor3 = color
	overhead.Name.Text = if Config.Overhead.NameStyle == "Username" then player.Name else player.DisplayName
	overhead.Unit.Text = if team then string.upper(team.Name) else ""
	overhead.Icon.Image = if groupId then string.format(ICON_URL, groupId) else ""
	layoutOverhead(overhead, Config.Overhead.ShowGroupIcon and groupId ~= nil)
end

local function buildOverhead(player: Player, character: Model)
	if not Config.Overhead.Enabled then
		return
	end
	local headInstance = character:WaitForChild("Head", 10)
	local humanoidInstance = character:WaitForChild("Humanoid", 10)
	if not (headInstance and headInstance:IsA("BasePart")) then
		return
	end
	if not (humanoidInstance and humanoidInstance:IsA("Humanoid")) then
		return
	end
	local head: BasePart = headInstance
	local humanoid: Humanoid = humanoidInstance
	local state = states[player]
	if not state or player.Character ~= character then
		return
	end

	-- Hide Roblox's default name and health bar; the plate replaces both.
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None

	local old = head:FindFirstChild(OVERHEAD_NAME)
	if old then
		old:Destroy()
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = OVERHEAD_NAME
	gui.Adornee = head
	gui.Size = UDim2.fromScale(6, 1.8)
	gui.StudsOffset = Vector3.new(0, 2.35, 0)
	gui.MaxDistance = Config.Overhead.MaxDistance
	gui.AlwaysOnTop = Config.Overhead.AlwaysOnTop
	gui.LightInfluence = 0
	if Config.Overhead.HideOwn then
		gui.PlayerToHideFrom = player
	end

	local icon = Instance.new("ImageLabel")
	icon.Name = "Emblem"
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.45)
	icon.Size = UDim2.fromScale(0.24, 0.8)
	icon.BackgroundColor3 = Color3.fromRGB(12, 14, 16)
	icon.BackgroundTransparency = 0.35
	icon.ScaleType = Enum.ScaleType.Fit
	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(0.18, 0)
	iconCorner.Parent = icon
	local iconAspect = Instance.new("UIAspectRatioConstraint")
	iconAspect.AspectRatio = 1
	iconAspect.Parent = icon
	icon.Parent = gui

	local accent = Instance.new("Frame")
	accent.Name = "Accent"
	accent.AnchorPoint = Vector2.new(0, 0.5)
	accent.Position = UDim2.fromScale(0.262, 0.45)
	accent.Size = UDim2.fromScale(0.012, 0.74)
	accent.BorderSizePixel = 0
	local accentCorner = Instance.new("UICorner")
	accentCorner.CornerRadius = UDim.new(1, 0)
	accentCorner.Parent = accent
	accent.Parent = gui

	local rank = newText(gui, "Rank", HEADING_FONT, 26)
	local name = newText(gui, "PlayerName", BODY_FONT, 34)
	local unit = newText(gui, "Unit", HEADING_FONT, 18)
	unit.TextColor3 = Color3.fromRGB(205, 210, 200)

	local healthBack = Instance.new("Frame")
	healthBack.Name = "HealthBar"
	healthBack.BackgroundColor3 = Color3.new(0, 0, 0)
	healthBack.BackgroundTransparency = 0.45
	healthBack.BorderSizePixel = 0
	healthBack.Visible = Config.Overhead.ShowHealthBar
	local backCorner = Instance.new("UICorner")
	backCorner.CornerRadius = UDim.new(1, 0)
	backCorner.Parent = healthBack
	healthBack.Parent = gui

	local health = Instance.new("Frame")
	health.Name = "Fill"
	health.BorderSizePixel = 0
	health.Size = UDim2.fromScale(1, 1)
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = health
	health.Parent = healthBack

	local overhead: Overhead = {
		Gui = gui,
		Icon = icon,
		Accent = accent,
		Rank = rank,
		Name = name,
		Unit = unit,
		HealthBack = healthBack,
		Health = health,
	}

	local function updateHealth()
		local fraction = if humanoid.MaxHealth > 0 then math.clamp(humanoid.Health / humanoid.MaxHealth, 0, 1) else 0
		health.Size = UDim2.fromScale(fraction, 1)
		-- Green at full health, through yellow, to red.
		health.BackgroundColor3 = Color3.fromHSV(fraction * 0.33, 0.8, 0.95)
	end
	updateHealth()
	humanoid.HealthChanged:Connect(updateHealth)
	humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(updateHealth)
	humanoid.Died:Connect(function()
		gui.Enabled = false
	end)

	state.Overhead = overhead
	local team = player.Team
	local entry = if team then entryByTeam[team] else nil
	updateOverhead(player, state, entry, (rankFor(state, entry)))
	gui.Parent = head
end

--------------------------------------------------------------------------------
-- Players
--------------------------------------------------------------------------------

local function findRankValue(player: Player): StringValue?
	local leaderstats = player:FindFirstChild("leaderstats")
	local value = leaderstats and leaderstats:FindFirstChild("Rank")
	if value and value:IsA("StringValue") then
		return value
	end
	return nil
end

local function setupLeaderstats(player: Player)
	-- Give other scripts a moment to create leaderstats so there's only one folder.
	local leaderstats = player:WaitForChild("leaderstats", 1)
	if not leaderstats then
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
		leaderstats = folder
	end
	if player.Parent and not findRankValue(player) then
		local value = Instance.new("StringValue")
		value.Name = "Rank"
		value.Value = "-"
		value.Parent = leaderstats
	end
end

-- Pushes the player's current rank to attributes, the player list and the nameplate.
local function updatePlayer(player: Player)
	local state = states[player]
	if not state then
		return
	end
	local team = player.Team
	local entry = if team then entryByTeam[team] else nil
	local rankName, rankNumber = rankFor(state, entry)

	player:SetAttribute("RankName", rankName)
	player:SetAttribute("RankNumber", rankNumber)
	player:SetAttribute("RankGroupId", if entry then entry.GroupId or 0 else 0)

	local rankValue = findRankValue(player)
	if rankValue then
		rankValue.Value = if rankName ~= "" then rankName else "-"
	end
	updateOverhead(player, state, entry, rankName)
end

-- Moves a player off a team they no longer qualify for.
local function enforceAccess(player: Player, state: PlayerState)
	if not Config.RemoveIneligiblePlayers then
		return
	end
	local team = player.Team
	local entry = if team then entryByTeam[team] else nil
	if not entry or checkAccess(player, state, entry) then
		return
	end
	local newEntry = pickTeam(player, state)
	setTeam(player, newEntry)
	local destination = if newEntry then newEntry.Team.Name else "no team"
	notifyRemote:FireClient(player, `You no longer qualify for {entry.Team.Name} and were moved to {destination}.`, "error")
	if Config.RespawnOnTeamChange then
		respawn(player)
	end
end

local function onPlayerAdded(player: Player)
	local state: PlayerState = {
		Memberships = {},
		Loaded = false,
		Busy = false,
		LastFetch = 0,
		LastTeamChange = -math.huge,
		Overhead = nil,
	}
	states[player] = state

	if Config.LeaderboardRank then
		task.spawn(setupLeaderstats, player)
	end

	player:GetPropertyChangedSignal("Team"):Connect(function()
		updatePlayer(player)
	end)
	player.CharacterAdded:Connect(function(character)
		buildOverhead(player, character)
	end)
	player.CharacterRemoving:Connect(function(character)
		local overhead = state.Overhead
		if overhead and overhead.Gui:IsDescendantOf(character) then
			state.Overhead = nil
		end
	end)
	if player.Character then
		task.spawn(buildOverhead, player, player.Character)
	end

	local memberships = fetchMemberships(player)
	if states[player] ~= state then
		return
	end
	if memberships then
		state.Memberships = memberships
		state.LastFetch = os.clock()
	end
	state.Loaded = true

	local currentTeam = player.Team
	if Config.AutoAssignOnJoin and not (currentTeam and entryByTeam[currentTeam]) then
		local entry = pickTeam(player, state)
		if entry then
			setTeam(player, entry)
			local rankName = rankFor(state, entry)
			local message = if entry.GroupId and rankName ~= ""
				then `Assigned to {entry.Team.Name} as {rankName}.`
				else `Assigned to {entry.Team.Name}.`
			notifyRemote:FireClient(player, message, "info")
			if Config.RespawnOnTeamChange and player.Character then
				respawn(player)
			end
		end
	end

	updatePlayer(player)
	dataChangedRemote:FireClient(player)
end

local function teamListFor(player: Player): { [string]: any }
	local state = states[player]
	local list = {}
	local all = table.clone(entries)
	if defaultEntry then
		table.insert(all, defaultEntry)
	end
	for _, entry in all do
		local canJoin: boolean, reason: string? = false, "Loading..."
		local membership: Membership? = nil
		if state and state.Loaded then
			canJoin, reason = checkAccess(player, state, entry)
			local groupId = entry.GroupId
			membership = if groupId then state.Memberships[groupId] else nil
		end
		table.insert(list, {
			Team = entry.Team,
			GroupId = entry.GroupId or 0,
			RankName = if membership then membership.Role else nil,
			RankNumber = if membership then membership.Rank else 0,
			CanJoin = canJoin,
			Reason = reason,
		})
	end
	local cooldown = 0
	if state then
		cooldown = math.max(0, Config.TeamChangeCooldown - (os.clock() - state.LastTeamChange))
	end
	return {
		Teams = list,
		Loaded = state ~= nil and state.Loaded,
		CooldownRemaining = cooldown,
	}
end

local function handleTeamRequest(player: Player, team: any): TeamChangeResult
	local state = states[player]
	if not state or not state.Loaded then
		return { Ok = false, Message = "Still checking your groups. Try again in a moment." }
	end
	if typeof(team) ~= "Instance" or not team:IsA("Team") then
		return { Ok = false, Message = "That team doesn't exist." }
	end
	local entry = entryByTeam[team]
	if not entry then
		return { Ok = false, Message = "That team doesn't exist." }
	end
	if player.Team == team then
		return { Ok = false, Message = `You're already on {team.Name}.` }
	end
	if state.Busy then
		return { Ok = false, Message = "Already switching teams..." }
	end
	local wait = Config.TeamChangeCooldown - (os.clock() - state.LastTeamChange)
	if wait > 0 then
		return { Ok = false, Message = `Wait {math.ceil(wait)}s before switching again.` }
	end

	state.Busy = true
	local allowed, reason = checkAccess(player, state, entry)
	if not allowed and os.clock() - state.LastFetch > RECHECK_AFTER then
		-- They may have joined the group or been promoted since we last checked.
		if refreshMemberships(player) then
			allowed, reason = checkAccess(player, state, entry)
		end
	end
	state.Busy = false

	if not allowed then
		return { Ok = false, Message = `{team.Name}: {reason or "Not allowed"}` }
	end
	if not player.Parent then
		return { Ok = false, Message = "" }
	end

	state.LastTeamChange = os.clock()
	setTeam(player, entry)
	if Config.RespawnOnTeamChange then
		respawn(player)
	end
	local rankName = rankFor(state, entry)
	local message = if entry.GroupId and rankName ~= "" then `Joined {team.Name} as {rankName}.` else `Joined {team.Name}.`
	return { Ok = true, Message = message, Cooldown = Config.TeamChangeCooldown }
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

setupTeams()

for _, instance in Workspace:GetDescendants() do
	linkSpawn(instance)
end
Workspace.DescendantAdded:Connect(linkSpawn)

getTeamsRemote.OnServerInvoke = teamListFor
requestTeamRemote.OnServerInvoke = handleTeamRequest

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(player)
	states[player] = nil
end)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end

if Config.RankRefreshInterval > 0 then
	task.spawn(function()
		while true do
			task.wait(Config.RankRefreshInterval)
			for _, player in Players:GetPlayers() do
				local state = states[player]
				if state and state.Loaded and refreshMemberships(player) then
					enforceAccess(player, state)
					updatePlayer(player)
					dataChangedRemote:FireClient(player)
				end
				-- Spread the web requests out.
				task.wait(0.25)
			end
		end
	end)
end
