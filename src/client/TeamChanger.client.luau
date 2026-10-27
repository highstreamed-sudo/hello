--!strict
--[[
	GroupTeams (client): team changer menu

	Open and close with the TEAMS button, Config.MenuKey (M) or Config.MenuGamepadKey.
	Every request is checked again by the server, so the menu is only a view.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("GroupTeams")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = Shared:WaitForChild("Remotes")
local GetTeams = Remotes:WaitForChild("GetTeams") :: RemoteFunction
local RequestTeam = Remotes:WaitForChild("RequestTeam") :: RemoteFunction
local DataChanged = Remotes:WaitForChild("DataChanged") :: RemoteEvent
local Notify = Remotes:WaitForChild("Notify") :: RemoteEvent

local THEME = {
	Panel = Color3.fromRGB(19, 22, 24),
	PanelStroke = Color3.fromRGB(72, 80, 66),
	Card = Color3.fromRGB(29, 33, 36),
	CardHover = Color3.fromRGB(37, 42, 45),
	CardStroke = Color3.fromRGB(52, 58, 54),
	Emblem = Color3.fromRGB(14, 16, 18),
	Text = Color3.fromRGB(236, 238, 230),
	SubText = Color3.fromRGB(160, 168, 154),
	Muted = Color3.fromRGB(110, 118, 108),
	Locked = Color3.fromRGB(46, 50, 52),
	Brass = Color3.fromRGB(201, 172, 98),
	Success = Color3.fromRGB(104, 196, 122),
	Danger = Color3.fromRGB(224, 96, 88),
}

local HEADING = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold)
local BODY = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium)
local BODY_BOLD = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)

local ICON_URL = "rbxthumb://type=GroupIcon&id=%d&w=150&h=150"
local CARD_HEIGHT = 88
local CARD_GAP = 12

type TeamData = {
	Team: Team,
	GroupId: number,
	RankName: string?,
	RankNumber: number,
	CanJoin: boolean,
	Reason: string?,
}

type Card = {
	Frame: Frame,
	Stroke: UIStroke,
	Bar: Frame,
	Emblem: ImageLabel,
	Initial: TextLabel,
	Title: TextLabel,
	Rank: TextLabel,
	Count: TextLabel,
	Button: TextButton,
	ButtonStroke: UIStroke,
	Team: Team,
	Data: TeamData,
	Hovered: boolean,
	Connections: { RBXScriptConnection },
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function outline(parent: Instance, color: Color3, transparency: number): UIStroke
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Color = color
	s.Transparency = transparency
	s.Thickness = 1
	s.Parent = parent
	return s
end

local function label(parent: Instance, name: string, font: Font, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.FontFace = font
	l.TextSize = size
	l.TextColor3 = color
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Text = ""
	l.Parent = parent
	return l
end

local function tween(instance: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?): Tween
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local t = TweenService:Create(instance, info, goal)
	t:Play()
	return t
end

local function escape(text: string): string
	return (
		text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
	)
end

-- Dark text on light team colours, white text on dark ones.
local function textOn(background: Color3): Color3
	local luminance = 0.2126 * background.R + 0.7152 * background.G + 0.0722 * background.B
	return if luminance > 0.55 then Color3.fromRGB(16, 18, 20) else Color3.new(1, 1, 1)
end

local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local keyName = UserInputService:GetStringForKeyCode(Config.MenuKey)
if keyName == "" then
	keyName = Config.MenuKey.Name
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local screen = Instance.new("ScreenGui")
screen.Name = "TeamChanger"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.DisplayOrder = 20

-- TEAMS button on the left edge of the screen.
local toggle = Instance.new("TextButton")
toggle.Name = "ToggleButton"
toggle.AnchorPoint = Vector2.new(0, 0.5)
toggle.Position = UDim2.new(0, 16, 0.5, 0)
toggle.Size = UDim2.fromOffset(if touchOnly then 104 else 132, 44)
toggle.BackgroundColor3 = THEME.Panel
toggle.BackgroundTransparency = 0.08
toggle.AutoButtonColor = false
toggle.Text = ""
toggle.Parent = screen
corner(toggle, 10)
local toggleStroke = outline(toggle, THEME.Brass, 0.45)

local toggleLabel = label(toggle, "Label", HEADING, 20, THEME.Text)
toggleLabel.Text = "TEAMS"
toggleLabel.Position = UDim2.fromOffset(16, 0)
toggleLabel.Size = UDim2.new(1, -16, 1, 0)
if touchOnly then
	toggleLabel.Position = UDim2.fromOffset(0, 0)
	toggleLabel.Size = UDim2.fromScale(1, 1)
	toggleLabel.TextXAlignment = Enum.TextXAlignment.Center
end

local keyChip = Instance.new("TextLabel")
keyChip.Name = "KeyHint"
keyChip.AnchorPoint = Vector2.new(1, 0.5)
keyChip.Position = UDim2.new(1, -10, 0.5, 0)
keyChip.Size = UDim2.fromOffset(30, 24)
keyChip.BackgroundColor3 = THEME.Card
keyChip.FontFace = BODY_BOLD
keyChip.TextSize = 14
keyChip.TextColor3 = THEME.Brass
keyChip.Text = keyName
keyChip.Visible = not touchOnly
keyChip.Parent = toggle
corner(keyChip, 6)
outline(keyChip, THEME.PanelStroke, 0.3)

-- Dimmed backdrop; clicking it closes the menu.
local backdrop = Instance.new("TextButton")
backdrop.Name = "Backdrop"
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
backdrop.BackgroundTransparency = 1
backdrop.AutoButtonColor = false
backdrop.Selectable = false
backdrop.Text = ""
backdrop.Visible = false
backdrop.ZIndex = 5
backdrop.Parent = screen

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.5, 0.5)
panel.Size = UDim2.fromScale(0.92, 0.84)
panel.BackgroundColor3 = THEME.Panel
panel.BackgroundTransparency = 0.03
panel.Active = true
panel.Visible = false
panel.ZIndex = 6
panel.Parent = screen
corner(panel, 14)
outline(panel, THEME.PanelStroke, 0.15)

local panelGradient = Instance.new("UIGradient")
panelGradient.Rotation = 90
panelGradient.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(190, 190, 190))
panelGradient.Parent = panel

local panelLimit = Instance.new("UISizeConstraint")
panelLimit.MaxSize = Vector2.new(940, 640)
panelLimit.MinSize = Vector2.new(280, 260)
panelLimit.Parent = panel

local panelScale = Instance.new("UIScale")
panelScale.Parent = panel

-- Header
local brassTab = Instance.new("Frame")
brassTab.Name = "Tab"
brassTab.Position = UDim2.fromOffset(24, 18)
brassTab.Size = UDim2.fromOffset(4, 28)
brassTab.BackgroundColor3 = THEME.Brass
brassTab.BorderSizePixel = 0
brassTab.Parent = panel
corner(brassTab, 2)

local title = label(panel, "Title", HEADING, 28, THEME.Text)
title.Text = "TEAM SELECTION"
title.Position = UDim2.fromOffset(38, 14)
title.Size = UDim2.new(1, -110, 0, 36)

local subtitle = label(panel, "Subtitle", BODY, 15, THEME.SubText)
subtitle.Text = "Choose your unit. Ranks are verified live with each Roblox group."
subtitle.Position = UDim2.fromOffset(24, 52)
subtitle.Size = UDim2.new(1, -110, 0, 20)

local currentLabel = label(panel, "Current", BODY_BOLD, 14, THEME.SubText)
currentLabel.RichText = true
currentLabel.AnchorPoint = Vector2.new(1, 0)
currentLabel.Position = UDim2.new(1, -66, 0, 24)
currentLabel.Size = UDim2.fromOffset(300, 20)
currentLabel.TextXAlignment = Enum.TextXAlignment.Right

local closeButton = Instance.new("TextButton")
closeButton.Name = "Close"
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.new(1, -16, 0, 16)
closeButton.Size = UDim2.fromOffset(36, 36)
closeButton.BackgroundColor3 = THEME.Card
closeButton.AutoButtonColor = true
closeButton.FontFace = BODY_BOLD
closeButton.Text = "×"
closeButton.TextSize = 26
closeButton.TextColor3 = THEME.SubText
closeButton.Parent = panel
corner(closeButton, 8)
outline(closeButton, THEME.CardStroke, 0)

local divider = Instance.new("Frame")
divider.Name = "Divider"
divider.Position = UDim2.fromOffset(24, 84)
divider.Size = UDim2.new(1, -48, 0, 1)
divider.BackgroundColor3 = THEME.PanelStroke
divider.BackgroundTransparency = 0.3
divider.BorderSizePixel = 0
divider.Parent = panel

-- Team list
local list = Instance.new("ScrollingFrame")
list.Name = "Teams"
list.Position = UDim2.fromOffset(16, 96)
list.Size = UDim2.new(1, -32, 1, -96 - 48)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.ScrollingDirection = Enum.ScrollingDirection.Y
list.ScrollBarThickness = 4
list.ScrollBarImageColor3 = THEME.Brass
list.ScrollBarImageTransparency = 0.4
list.Selectable = false
list.Parent = panel

local listPadding = Instance.new("UIPadding")
listPadding.PaddingTop = UDim.new(0, 6)
listPadding.PaddingBottom = UDim.new(0, 6)
listPadding.PaddingLeft = UDim.new(0, 8)
listPadding.PaddingRight = UDim.new(0, 12)
listPadding.Parent = list

local grid = Instance.new("UIGridLayout")
grid.CellPadding = UDim2.fromOffset(CARD_GAP, CARD_GAP)
grid.CellSize = UDim2.new(0.5, -CARD_GAP / 2, 0, CARD_HEIGHT)
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.Parent = list

local emptyLabel = label(list, "Empty", BODY, 16, THEME.SubText)
emptyLabel.Text = "Checking your groups..."
emptyLabel.Size = UDim2.new(1, 0, 0, CARD_HEIGHT)
emptyLabel.TextXAlignment = Enum.TextXAlignment.Center
emptyLabel.LayoutOrder = -1

-- Footer
local hint = label(panel, "Hint", BODY, 14, THEME.Muted)
hint.Text = if touchOnly then "Tap TEAMS to open or close" else `Press {keyName} to open or close`
hint.AnchorPoint = Vector2.new(0, 1)
hint.Position = UDim2.new(0, 24, 1, -14)
hint.Size = UDim2.new(0.5, -24, 0, 20)

local status = label(panel, "Status", BODY_BOLD, 14, THEME.SubText)
status.AnchorPoint = Vector2.new(1, 1)
status.Position = UDim2.new(1, -24, 1, -14)
status.Size = UDim2.new(0.5, -24, 0, 20)
status.TextXAlignment = Enum.TextXAlignment.Right

-- Toasts
local toasts = Instance.new("Frame")
toasts.Name = "Toasts"
toasts.AnchorPoint = Vector2.new(0.5, 0)
toasts.Position = UDim2.new(0.5, 0, 0, 64)
toasts.Size = UDim2.fromScale(0.9, 0)
toasts.BackgroundTransparency = 1
toasts.ZIndex = 20
toasts.Parent = screen

local toastLimit = Instance.new("UISizeConstraint")
toastLimit.MaxSize = Vector2.new(440, math.huge)
toastLimit.Parent = toasts

local toastLayout = Instance.new("UIListLayout")
toastLayout.Padding = UDim.new(0, 8)
toastLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
toastLayout.Parent = toasts

local blur = Instance.new("BlurEffect")
blur.Name = "TeamChangerBlur"
blur.Size = 0
blur.Enabled = false

screen.Parent = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- Toasts
--------------------------------------------------------------------------------

local toastCount = 0

local function toast(message: string, kind: string?)
	if message == "" then
		return
	end
	local color = if kind == "success" then THEME.Success elseif kind == "error" then THEME.Danger else THEME.Brass
	toastCount += 1

	local frame = Instance.new("CanvasGroup")
	frame.Name = "Toast"
	frame.LayoutOrder = toastCount
	frame.Size = UDim2.new(1, 0, 0, 48)
	frame.BackgroundColor3 = THEME.Panel
	frame.BackgroundTransparency = 0.04
	frame.GroupTransparency = 1
	frame.ZIndex = 20
	corner(frame, 10)
	outline(frame, color, 0.35)

	local bar = Instance.new("Frame")
	bar.Position = UDim2.fromOffset(12, 12)
	bar.Size = UDim2.new(0, 4, 1, -24)
	bar.BackgroundColor3 = color
	bar.BorderSizePixel = 0
	bar.ZIndex = 21
	bar.Parent = frame
	corner(bar, 2)

	local text = label(frame, "Message", BODY_BOLD, 16, THEME.Text)
	text.Position = UDim2.fromOffset(26, 0)
	text.Size = UDim2.new(1, -38, 1, 0)
	text.TextWrapped = true
	text.TextTruncate = Enum.TextTruncate.None
	text.Text = message
	text.ZIndex = 21

	frame.Parent = toasts

	-- Keep at most three on screen.
	local shown = {}
	for _, child in toasts:GetChildren() do
		if child:IsA("CanvasGroup") then
			table.insert(shown, child)
		end
	end
	table.sort(shown, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #shown - 3 do
		shown[i]:Destroy()
	end

	tween(frame, 0.25, { GroupTransparency = 0 })
	task.delay(3.5, function()
		if frame.Parent then
			tween(frame, 0.35, { GroupTransparency = 1 }).Completed:Wait()
			frame:Destroy()
		end
	end)
end

--------------------------------------------------------------------------------
-- Cards
--------------------------------------------------------------------------------

local cards: { [Team]: Card } = {}
local cooldownUntil = 0
local busyTeam: Team? = nil
local loaded = false

local function onCooldown(): boolean
	return os.clock() < cooldownUntil
end

local function updateCount(card: Card)
	local count = #card.Team:GetPlayers()
	card.Count.Text = `{count} ON DUTY`
end

local function refreshCard(card: Card)
	local data = card.Data
	local team = card.Team
	local color = team.TeamColor.Color
	local isCurrent = player.Team == team

	card.Frame.Name = team.Name
	card.Bar.BackgroundColor3 = color
	card.Title.Text = string.upper(team.Name)
	card.Initial.Text = string.upper(string.sub(team.Name, 1, 1))

	if data.RankName then
		card.Rank.Text = `Your rank: <font color="#{THEME.Text:ToHex()}">{escape(data.RankName)}</font>`
		card.Rank.TextColor3 = THEME.SubText
	elseif data.GroupId == 0 then
		card.Rank.Text = "Open to everyone"
		card.Rank.TextColor3 = THEME.SubText
	elseif data.CanJoin then
		card.Rank.Text = "Not a member (bypass)"
		card.Rank.TextColor3 = THEME.SubText
	else
		card.Rank.Text = escape(data.Reason or "Members only")
		card.Rank.TextColor3 = THEME.Danger
	end

	local button = card.Button
	local stroke = card.ButtonStroke
	if isCurrent then
		button.Text = "CURRENT"
		button.BackgroundTransparency = 1
		button.TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.25)
		stroke.Color = color
		stroke.Transparency = 0.1
	elseif busyTeam == team then
		button.Text = "JOINING..."
		button.BackgroundTransparency = 0
		button.BackgroundColor3 = color
		button.TextColor3 = textOn(color)
		stroke.Transparency = 1
	elseif not data.CanJoin then
		button.Text = "LOCKED"
		button.BackgroundTransparency = 0
		button.BackgroundColor3 = THEME.Locked
		button.TextColor3 = THEME.Muted
		stroke.Transparency = 1
	elseif onCooldown() then
		button.Text = `WAIT {math.ceil(cooldownUntil - os.clock())}s`
		button.BackgroundTransparency = 0
		button.BackgroundColor3 = THEME.Locked
		button.TextColor3 = THEME.SubText
		stroke.Transparency = 1
	else
		button.Text = "JOIN"
		button.BackgroundTransparency = 0
		button.BackgroundColor3 = color
		button.TextColor3 = textOn(color)
		stroke.Transparency = 1
	end
	button.AutoButtonColor = data.CanJoin and not isCurrent

	card.Stroke.Color = if isCurrent or card.Hovered then color else THEME.CardStroke
	card.Stroke.Transparency = if isCurrent then 0.2 elseif card.Hovered then 0.45 else 0
	card.Frame.BackgroundColor3 = if card.Hovered then THEME.CardHover else THEME.Card
	updateCount(card)
end

local function updateHeader()
	local team = player.Team
	if team then
		local hex = team.TeamColor.Color:ToHex()
		currentLabel.Text = `CURRENT  <font color="#{hex}">■</font>  <font color="#{THEME.Text:ToHex()}">{escape(string.upper(team.Name))}</font>`
	else
		currentLabel.Text = "CURRENT  —  NONE"
	end
	if onCooldown() then
		status.Text = `Switch available in {math.ceil(cooldownUntil - os.clock())}s`
		status.TextColor3 = THEME.Brass
	elseif not loaded then
		status.Text = "Checking your groups..."
		status.TextColor3 = THEME.SubText
	else
		local rank = player:GetAttribute("RankName")
		status.Text = if type(rank) == "string" and rank ~= "" then `Rank: {rank}` else ""
		status.TextColor3 = THEME.SubText
	end
end

local function refreshAll()
	for _, card in cards do
		refreshCard(card)
	end
	updateHeader()
end

local requestJoin: (card: Card) -> ()

local function createCard(team: Team, data: TeamData): Card
	local frame = Instance.new("Frame")
	frame.Name = team.Name
	frame.BackgroundColor3 = THEME.Card
	frame.BorderSizePixel = 0
	corner(frame, 10)
	local stroke = outline(frame, THEME.CardStroke, 0)

	local bar = Instance.new("Frame")
	bar.Name = "TeamColor"
	bar.Position = UDim2.fromOffset(10, 14)
	bar.Size = UDim2.new(0, 4, 1, -28)
	bar.BorderSizePixel = 0
	bar.Parent = frame
	corner(bar, 2)

	local emblem = Instance.new("ImageLabel")
	emblem.Name = "Emblem"
	emblem.AnchorPoint = Vector2.new(0, 0.5)
	emblem.Position = UDim2.new(0, 24, 0.5, 0)
	emblem.Size = UDim2.fromOffset(58, 58)
	emblem.BackgroundColor3 = THEME.Emblem
	emblem.ScaleType = Enum.ScaleType.Fit
	emblem.Image = if data.GroupId > 0 then string.format(ICON_URL, data.GroupId) else ""
	emblem.Parent = frame
	corner(emblem, 8)
	outline(emblem, THEME.CardStroke, 0)

	-- Letter badge for the default team, which has no group emblem.
	local initial = Instance.new("TextLabel")
	initial.Name = "Initial"
	initial.BackgroundTransparency = 1
	initial.Size = UDim2.fromScale(1, 1)
	initial.FontFace = HEADING
	initial.TextSize = 30
	initial.TextColor3 = THEME.SubText
	initial.Visible = data.GroupId == 0
	initial.Parent = emblem

	local textLeft = 96
	local buttonSpace = 120

	local titleLabel = label(frame, "Title", HEADING, 20, THEME.Text)
	titleLabel.Position = UDim2.fromOffset(textLeft, 12)
	titleLabel.Size = UDim2.new(1, -(textLeft + buttonSpace), 0, 26)

	local rankLabel = label(frame, "Rank", BODY, 15, THEME.SubText)
	rankLabel.RichText = true
	rankLabel.Position = UDim2.fromOffset(textLeft, 40)
	rankLabel.Size = UDim2.new(1, -(textLeft + buttonSpace), 0, 18)

	local countLabel = label(frame, "Count", BODY_BOLD, 13, THEME.Muted)
	countLabel.Position = UDim2.fromOffset(textLeft, 60)
	countLabel.Size = UDim2.new(1, -(textLeft + buttonSpace), 0, 16)

	local button = Instance.new("TextButton")
	button.Name = "Join"
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -14, 0.5, 0)
	button.Size = UDim2.fromOffset(98, 38)
	button.FontFace = HEADING
	button.TextSize = 17
	button.Parent = frame
	corner(button, 8)
	local buttonStroke = outline(button, THEME.CardStroke, 1)
	local buttonScale = Instance.new("UIScale")
	buttonScale.Parent = button

	local card: Card = {
		Frame = frame,
		Stroke = stroke,
		Bar = bar,
		Emblem = emblem,
		Initial = initial,
		Title = titleLabel,
		Rank = rankLabel,
		Count = countLabel,
		Button = button,
		ButtonStroke = buttonStroke,
		Team = team,
		Data = data,
		Hovered = false,
		Connections = {},
	}

	local function setHovered(hovered: boolean)
		card.Hovered = hovered
		refreshCard(card)
	end

	table.insert(card.Connections, frame.MouseEnter:Connect(function()
		setHovered(true)
	end))
	table.insert(card.Connections, frame.MouseLeave:Connect(function()
		setHovered(false)
	end))
	table.insert(card.Connections, button.SelectionGained:Connect(function()
		setHovered(true)
	end))
	table.insert(card.Connections, button.SelectionLost:Connect(function()
		setHovered(false)
	end))
	table.insert(card.Connections, button.MouseButton1Down:Connect(function()
		tween(buttonScale, 0.08, { Scale = 0.94 })
	end))
	table.insert(card.Connections, button.MouseButton1Up:Connect(function()
		tween(buttonScale, 0.15, { Scale = 1 }, Enum.EasingStyle.Back)
	end))
	table.insert(card.Connections, button.MouseLeave:Connect(function()
		buttonScale.Scale = 1
	end))
	table.insert(card.Connections, button.Activated:Connect(function()
		requestJoin(card)
	end))
	table.insert(card.Connections, team.PlayerAdded:Connect(function()
		updateCount(card)
	end))
	table.insert(card.Connections, team.PlayerRemoved:Connect(function()
		updateCount(card)
	end))
	table.insert(card.Connections, team.Changed:Connect(function()
		refreshCard(card)
		updateHeader()
	end))

	frame.Parent = list
	return card
end

local function destroyCard(card: Card)
	for _, connection in card.Connections do
		connection:Disconnect()
	end
	card.Frame:Destroy()
end

local function updateGrid()
	-- Measure without the open/close animation's scale.
	local scale = math.max(panelScale.Scale, 0.01)
	local width = list.AbsoluteSize.X / scale - 20
	local columns = if width >= 600 then 2 else 1
	grid.CellSize = UDim2.new(1 / columns, -math.ceil(CARD_GAP * (columns - 1) / columns), 0, CARD_HEIGHT)
end

--------------------------------------------------------------------------------
-- Server data
--------------------------------------------------------------------------------

local isOpen = false
local openedOnJoin = false
local open: (gamepad: boolean?, skipRefresh: boolean?) -> ()

local function applyData(data: any)
	if type(data) ~= "table" or type(data.Teams) ~= "table" then
		return
	end
	local seen: { [Team]: boolean } = {}
	for index, raw in data.Teams do
		local team = raw.Team
		if typeof(team) ~= "Instance" or not team:IsA("Team") then
			continue
		end
		seen[team] = true
		local teamData: TeamData = {
			Team = team,
			GroupId = tonumber(raw.GroupId) or 0,
			RankName = if type(raw.RankName) == "string" then raw.RankName else nil,
			RankNumber = tonumber(raw.RankNumber) or 0,
			CanJoin = raw.CanJoin == true,
			Reason = if type(raw.Reason) == "string" then raw.Reason else nil,
		}
		local card = cards[team]
		if card then
			card.Data = teamData
		else
			card = createCard(team, teamData)
			cards[team] = card
		end
		card.Frame.LayoutOrder = index
	end
	for team, card in cards do
		if not seen[team] then
			destroyCard(card)
			cards[team] = nil
		end
	end

	if type(data.CooldownRemaining) == "number" and data.CooldownRemaining > 0 then
		cooldownUntil = math.max(cooldownUntil, os.clock() + data.CooldownRemaining)
	end
	loaded = data.Loaded == true
	emptyLabel.Visible = not loaded or next(cards) == nil
	emptyLabel.Text = if loaded then "No teams are set up." else "Checking your groups..."
	refreshAll()

	if loaded and Config.OpenMenuOnJoin and not openedOnJoin then
		openedOnJoin = true
		open(false, true)
	end
end

local refreshing = false
local refreshQueued = false

local function refresh()
	if refreshing then
		refreshQueued = true
		return
	end
	refreshing = true
	repeat
		refreshQueued = false
		local ok, data = pcall(function()
			return GetTeams:InvokeServer()
		end)
		if ok then
			applyData(data)
		else
			warn(`[GroupTeams] Couldn't load teams: {data}`)
		end
	until not refreshQueued
	refreshing = false
end

--------------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------------

local closeToken = 0

local function firstJoinButton(): GuiObject?
	local best: Card? = nil
	for _, card in cards do
		if not best or card.Frame.LayoutOrder < best.Frame.LayoutOrder then
			best = card
		end
	end
	return if best then best.Button else nil
end

open = function(gamepad: boolean?, skipRefresh: boolean?)
	if isOpen then
		return
	end
	isOpen = true
	closeToken += 1
	if not skipRefresh then
		task.spawn(refresh)
	end
	refreshAll()

	backdrop.Visible = true
	panel.Visible = true
	panelScale.Scale = 0.94
	panel.Position = UDim2.fromScale(0.5, 0.52)
	tween(panelScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	tween(panel, 0.3, { Position = UDim2.fromScale(0.5, 0.5) })
	tween(backdrop, 0.25, { BackgroundTransparency = 0.45 })
	tween(toggleStroke, 0.2, { Transparency = 0 })

	blur.Parent = Workspace.CurrentCamera
	blur.Enabled = true
	tween(blur, 0.25, { Size = 14 })

	if gamepad then
		GuiService.SelectedObject = firstJoinButton()
	end
end

local function close()
	if not isOpen then
		return
	end
	isOpen = false
	closeToken += 1
	local token = closeToken

	tween(panelScale, 0.18, { Scale = 0.94 }, Enum.EasingStyle.Quad)
	tween(panel, 0.18, { Position = UDim2.fromScale(0.5, 0.52) }, Enum.EasingStyle.Quad)
	tween(backdrop, 0.18, { BackgroundTransparency = 1 })
	tween(toggleStroke, 0.2, { Transparency = 0.45 })
	tween(blur, 0.18, { Size = 0 })

	local selected = GuiService.SelectedObject
	if selected and selected:IsDescendantOf(screen) then
		GuiService.SelectedObject = nil
	end

	task.delay(0.2, function()
		if token == closeToken then
			panel.Visible = false
			backdrop.Visible = false
			blur.Enabled = false
		end
	end)
end

local function toggleMenu(gamepad: boolean?)
	if isOpen then
		close()
	else
		open(gamepad)
	end
end

requestJoin = function(card: Card)
	if busyTeam or onCooldown() or not card.Data.CanJoin or player.Team == card.Team then
		return
	end
	busyTeam = card.Team
	refreshCard(card)

	local ok, result = pcall(function()
		return RequestTeam:InvokeServer(card.Team)
	end)
	busyTeam = nil

	if ok and type(result) == "table" then
		local message = if type(result.Message) == "string" then result.Message else ""
		if result.Ok then
			if type(result.Cooldown) == "number" then
				cooldownUntil = os.clock() + result.Cooldown
			end
			toast(message, "success")
			close()
		else
			toast(if message ~= "" then message else "Couldn't switch teams.", "error")
		end
	else
		toast("Couldn't reach the server. Try again.", "error")
	end
	refreshAll()
	task.spawn(refresh)
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

toggle.Activated:Connect(function()
	toggleMenu(false)
end)
toggle.MouseEnter:Connect(function()
	tween(toggle, 0.15, { BackgroundColor3 = THEME.CardHover })
end)
toggle.MouseLeave:Connect(function()
	tween(toggle, 0.15, { BackgroundColor3 = THEME.Panel })
end)
closeButton.Activated:Connect(close)
backdrop.Activated:Connect(close)

ContextActionService:BindAction("GroupTeamsMenu", function(_, inputState, input)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	toggleMenu(input.KeyCode == Config.MenuGamepadKey)
	return Enum.ContextActionResult.Sink
end, false, Config.MenuKey, Config.MenuGamepadKey)

list:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateGrid)
updateGrid()

player:GetPropertyChangedSignal("Team"):Connect(refreshAll)
player:GetAttributeChangedSignal("RankName"):Connect(updateHeader)
Players.PlayerRemoving:Connect(function()
	task.defer(function()
		for _, card in cards do
			updateCount(card)
		end
	end)
end)

DataChanged.OnClientEvent:Connect(function()
	task.spawn(refresh)
end)
Notify.OnClientEvent:Connect(function(message: any, kind: any)
	toast(tostring(message), if type(kind) == "string" then kind else nil)
end)

-- Count down the switch cooldown on the buttons.
task.spawn(function()
	while true do
		task.wait(0.25)
		if isOpen and os.clock() < cooldownUntil + 0.5 then
			refreshAll()
		end
	end
end)

updateHeader()
refresh()
