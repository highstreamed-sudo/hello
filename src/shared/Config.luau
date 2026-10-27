--[[
	GroupTeams settings

	Each group below gets its own team. Team names, group emblems and rank names are
	loaded live from Roblox when the server starts, so you only need the group IDs.
]]

export type GroupTeam = {
	GroupId: number,
	-- Team name. Leave out to use the group's name from Roblox.
	TeamName: string?,
	-- BrickColor name. Every team needs a different colour.
	Color: string,
	-- Lowest group rank number (1-255) allowed to join. Leave out for "any member".
	MinRank: number?,
}

export type DefaultTeam = {
	TeamName: string,
	Color: string,
	-- Shown as the rank of everyone on this team.
	RankName: string,
}

local Config = {}

-- Listed in menu order. Order is also the priority when auto-assigning a player
-- who is in several groups (their primary group always wins).
Config.Groups = {
	{ GroupId = 290354561, Color = "Really red" },
	{ GroupId = 947866449, Color = "Bright blue" },
	{ GroupId = 355552548, Color = "Earth green" },
	{ GroupId = 230618254, Color = "Deep orange" },
	{ GroupId = 176234989, Color = "Royal purple" },
	{ GroupId = 522621024, Color = "Cyan" },
	{ GroupId = 290192955, Color = "New Yeller" },
	{ GroupId = 1101214163, Color = "Hot pink" },
	{ GroupId = 291239490, Color = "Reddish brown" },
	{ GroupId = 335766700, Color = "Teal" },
} :: { GroupTeam }

-- Team for players who aren't in any of the groups. Set to nil to remove it.
Config.DefaultTeam = {
	TeamName = "Civilians",
	Color = "Institutional white",
	RankName = "Civilian",
} :: DefaultTeam?

-- Rank shown for someone on a group team they're not a member of (only possible
-- for BypassUserIds / BypassInStudio).
Config.GuestRankName = "Guest"

-- Put players on a team when they join: their primary group if it's listed,
-- otherwise the first listed group they're in, otherwise the default team.
Config.AutoAssignOnJoin = true

-- Open the team menu automatically when a player joins.
Config.OpenMenuOnJoin = true

-- Respawn players at their new team's spawn after switching.
Config.RespawnOnTeamChange = true

-- Seconds a player must wait between team switches.
Config.TeamChangeCooldown = 5

-- How often (seconds) to re-check everyone's group ranks so promotions show up
-- without rejoining. 0 turns it off.
Config.RankRefreshInterval = 180

-- Move players off a group team if they leave the group or drop below MinRank.
Config.RemoveIneligiblePlayers = true

-- User IDs that may join any team (owners, admins, testers).
Config.BypassUserIds = {} :: { number }

-- Let everyone join every team while play-testing in Studio.
Config.BypassInStudio = false

-- Keys that open and close the team menu.
Config.MenuKey = Enum.KeyCode.M
Config.MenuGamepadKey = Enum.KeyCode.DPadUp

Config.Overhead = {
	Enabled = true,
	-- Studs from the camera before the nameplate disappears.
	MaxDistance = 80,
	-- true = visible through walls.
	AlwaysOnTop = false,
	-- true = players don't see their own nameplate.
	HideOwn = false,
	ShowGroupIcon = true,
	ShowHealthBar = true,
	UppercaseRank = true,
	-- "DisplayName" or "Username"
	NameStyle = "DisplayName",
}

-- Adds a coloured [Rank] tag in front of chat messages.
Config.ChatTags = true

-- Adds a "Rank" column to the player list.
Config.LeaderboardRank = true

return Config
