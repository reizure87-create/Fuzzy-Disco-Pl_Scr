--[[
	██╗  ██╗██╗   ██╗██████╗      ██╗  ██╗██╗   ██╗██████╗
	██║  ██║██║   ██║██╔══██╗     ██║  ██║██║   ██║██╔══██╗
	██████╔╝██║   ██║██████╔╝     ███████║██║   ██║██████╔╝
	██╔══██╗██║   ██║██╔══██╗     ██╔══██║██║   ██║██╔══██╗
	██║  ██║╚██████╔╝██████╔╝     ██║  ██║╚██████╔╝██████╔╝
	╚═╝  ╚═╝ ╚═════╝ ╚═════╝      ╚═╝  ╚═╝ ╚═════╝ ╚═════╝
	RiotHub v2.1.1 — Prison Life all-in-one · keyless · single file
	No external loadstrings, no key gates, no pastebin dependencies.
	Runs on Delta / Solara / Codex / Xeno / Wave / KRNL / Synapse-family, mobile OK.

	HOW TO USE
	  1. Join Prison Life.
	  2. Paste this whole file into your executor and press Execute.
	  3. Panel hotkey: RightCtrl (or U). Combat hotkeys: G / H / J.

	REMOTE WARRANTY
	  Devs rename/patch remotes between updates. Every remote hit here is
	  pcall-guarded and logged, so the log pane tells you exactly which call
	  failed instead of the hub crashing.
]]

-- ============================================================================
-- SERVICES / ENV
-- ============================================================================
local plrs    = game:GetService("Players")
local rs      = game:GetService("ReplicatedStorage")
local runSvc  = game:GetService("RunService")
local uis     = game:GetService("UserInputService")
local httpSvc = game:GetService("HttpService")
local starterGui = game:GetService("StarterGui")

local lp = plrs.LocalPlayer
-- Executors can inject before the local player exists (early-execute):
-- block here instead of hard-erroring on lp:GetMouse() a few lines down.
if not lp then
	local waited = 0
	while not plrs.LocalPlayer and waited < 20 do
		task.wait(0.25)
		waited = waited + 0.25
	end
	lp = plrs.LocalPlayer
end
if not lp then
	print("[RiotHub] stage 1 FAILED: no LocalPlayer (join the game first, then execute)")
	error("[RiotHub] no LocalPlayer present — join Prison Life, THEN execute", 0)
end
print("[RiotHub] stage 1: services + LocalPlayer ready")
local mouse = lp:GetMouse()

local function currentCam()
	return workspace.CurrentCamera
end

local function getGenv()
	if getgenv then return getgenv() end
	-- plain Lua environments (rare in-executor): keep state on _G instead
	if not _G.__RiotHubGenv then _G.__RiotHubGenv = {} end
	return _G.__RiotHubGenv
end

-- terminate a previous run cleanly so re-executions never double-spawn
pcall(function()
	if getGenv().RiotHub and getGenv().RiotHub.Unload then getGenv().RiotHub.Unload() end
end)
pcall(function()
	local parent = (gethui and gethui()) or game:FindFirstChildOfClass("CoreGui")
	if parent then
		for _, name in ipairs({ "RiotHub_GUI", "RiotHubFOVRing", "RiotHubEspOverlays" }) do
			local old = parent:FindFirstChild(name)
			if old then old:Destroy() end
		end
	end
end)

-- ============================================================================
-- CONFIG
-- ============================================================================
local CONFIG = {
	-- combat
	killAuraRadius   = 55,   killAuraRate = 0.35,
	killAuraIgnoreFF = true, killAuraRate = 0.35,
	loopKillRate     = 0.12,
	arrestAuraRadius = 90,   arrestAuraRate = 1.0,
	tazeRate         = 0.8,
	kAuraTargets     = "All", aimbotTargets = "All",
	triggerTargets   = "All",
	-- aim
	aimbotFov        = 160,  aimbotSmooth = 45,
	showAimFov       = true,
	silentFov        = 999,  silentHitChance = 100,
	silentWallCheck  = true, silentRandomPart = false,
	-- guns
	gunDamage        = 50,   gunBullets = 10,
	gunFireRate      = 0.001, gunSpread = 0,
	gunInfiniteAmmo  = true, gunAutoFire = true,
	gunAutoOnRespawn = false,
	gunChoice        = "M9", modTarget = "All Tools",
	-- visuals
	espBoxes         = true, espNames = true,
	espDistance      = true, espHealthBar = true,
	espTeamColor     = true, espVisibleOnly = false,
	chamsThroughWalls = false,
	-- movement
	walkSpeed        = 16,   jumpPower  = 50,
	tpWalk           = false, tpWalkPower = 3,
	noclip           = false, infJump = false,
	fly              = false, flySpeed = 3,
	spin             = false, spinSpeed = 25,
	noJumpCooldown   = false, fovChanger = 70,
	antiAfk          = false,
	-- world
	gateSpamInterval = 1.5,
	autoCollectEnabled = false, autoCollectRadius = 200,
	-- system
	safePacing   = true,  itemPace = 3.2,
	maxLogLines  = 40,    clickArrest = false,
}

-- ============================================================================
-- STATE
-- ============================================================================
local state = {
	toggles      = {},   -- runtime switchboard
	espUnits     = {},   -- [player] = unit table
	killCount    = {},   -- [playername] = n
	gunChoice    = "M9",
	modTarget    = "All Tools",
	detached     = false,
	logCounter   = 0,
	lastItemPull = 0,
}
local connections = {}

local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

-- ============================================================================
-- LOG / NOTIFY
-- ============================================================================
local logScroll, logText

local function log(msg, isErr)
	local body = tostring(msg)
	if #body > 150 then body = body:sub(1, 150) .. "..." end
	print("[RiotHub] " .. body)
	if logText and not state.detached then
		state.logCounter = state.logCounter + 1
		logText.Text = logText.Text .. "\n" .. string.format("%3d) %s%s",
			state.logCounter % 1000, isErr and "[ERR] " or "", body)
		local n = 0
		for _ in string.gmatch(logText.Text, "[^\n]+") do n = n + 1 end
		while n > CONFIG.maxLogLines do
			local _, rest = string.match(logText.Text, "([^\n]-\n)(.+)$")
			if not rest then break end
			logText.Text = rest
			n = n - 1
		end
		if logScroll then
			logScroll.CanvasSize = UDim2.new(0, 0, 0, n * 15 + 24)
			logScroll.CanvasPosition = Vector2.new(0, n * 15 + 24)
		end
	end
end

local function notify(title, text, dur)
	pcall(function()
		starterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = dur or 3 })
	end)
end

-- pcall-guarded remote caller: a patched remote logs instead of crashing
local function packArgs(...)
	local n, t = select("#", ...), {}
	for i = 1, n do t[i] = select(i, ...) end
	return t
end

-- arg spread across runtimes: 5.1-family executors expose a global `unpack`,
-- pure Luau only has table.unpack — accept both everywhere.
local function spread(t)
	if unpack then return unpack(t) end
	return table.unpack(t)
end

local function vsafe(fn, ...)
	local args = packArgs(...)
	local ok, err = pcall(function() fn(spread(args)) end)
	if not ok then log("remote call failed: " .. tostring(err):sub(1, 110), true) end
	return ok
end

-- ============================================================================
-- PACING — the current build reacts to rapid teleport-checked item pulls;
-- every ItemHandler call funnels through a single spaced-out door.
-- ============================================================================
local function pace()
	local now = tick()
	if CONFIG.safePacing then
		local left = state.lastItemPull + CONFIG.itemPace - now
		if left > 0 then task.wait(left) end
	end
	state.lastItemPull = tick()
end

-- ============================================================================
-- REMOTES / RESOLVERS (late binding, survives map updates)
-- ============================================================================
local function remoteFolder()
	return workspace:FindFirstChild("Remote")
end

local function getRemote(name, timeout)
	local folder = remoteFolder()
	if not folder then return nil end
	local remote = folder:FindFirstChild(name)
	if not remote then
		remote = folder:FindFirstChild(name .. "Event")
	end
	if not remote and timeout then
		remote = folder:WaitForChild(name, timeout)
	end
	return remote
end

local ItemHandler, shootingEvent, meleeEvent

-- Remote binding is deliberately ASYNC: the GUI below builds instantly even
-- while the map is still streaming (a mobile "execute during load" would
-- otherwise stare at a blank screen for up to ~45s of sequential
-- WaitForChild calls before any UI appeared). giveItem() and the Server
-- Report re-resolve on demand, so early button presses transparently wait.
local function resolveRemotesAsync()
	spawn(function()
		local folder = remoteFolder() or workspace:WaitForChild("Remote", 15)
		if folder then
			ItemHandler = folder:FindFirstChild("ItemHandler")
				or folder:WaitForChild("ItemHandler", 10)
		end
		log("remotes — ItemHandler: " .. tostring(not not ItemHandler))
	end)
	spawn(function()
		meleeEvent = rs:WaitForChild("meleeEvent", 15)
	end)
	spawn(function()
		shootingEvent = rs:WaitForChild("ShootEvent", 15)
	end)
	spawn(function()
		task.wait(15)
		meleeEvent = meleeEvent or rs:FindFirstChild("meleeEvent")
		shootingEvent = shootingEvent or rs:FindFirstChild("ShootEvent")
		log("remotes — melee: " .. tostring(not not meleeEvent)
			.. " shoot: " .. tostring(not not shootingEvent)
			.. " (nil means slow map stream — run Misc > Rebind Remotes)")
	end)
end
spawn(resolveRemotesAsync)

local function prisonTable()
	return workspace:FindFirstChild("Prison_ITEMS")
end

local function getItemIn(subfolder, itemName, childName)
	local t = prisonTable()
	if not t then return nil end
	local folder = t:FindFirstChild(subfolder)
	if not folder then return nil end
	local entry = folder:FindFirstChild(itemName)
	if not entry then return nil end
	if childName then
		return entry:FindFirstChild(childName) or entry:FindFirstChild("ITEMPICKUP")
			or entry:FindFirstChildWhichIsA("BasePart")
	end
	return entry
end

local function findItemAnywhere(itemName)
	local t = prisonTable()
	if not t then return nil end
	return t:FindFirstChild(itemName, true)
end

local function charHumanoid()
	local ch = lp.Character
	return ch and ch:FindFirstChildOfClass("Humanoid")
end

local function charRoot()
	local ch = lp.Character
	return ch and ch:FindFirstChild("HumanoidRootPart")
end

-- ============================================================================
-- TEAM LOOKUPS —
--   Bright blue = Guards · Bright orange = Inmates · Bright red = Criminals
-- Neutral / unassigned color names always pass the "All" filter only.
-- ============================================================================
local function teamColor(plr)
	local ok, col = pcall(function() return plr.TeamColor end)
	if not ok or not col then return "White" end
	return tostring(col.Name)
end
local function isGuard(plr)  return teamColor(plr) == "Bright blue"   end
local function isInmate(plr) return teamColor(plr) == "Bright orange" end
local function isCrim(plr)   return teamColor(plr) == "Bright red"    end

local function selTarget(plr, cfgKey)
	local want = CONFIG[cfgKey] or "All"
	if want == "All" then return true end
	if want == "Guards" then return isGuard(plr) end
	if want == "Inmates" then return isInmate(plr) end
	if want == "Criminals" then return isCrim(plr) end
	return true
end

-- ============================================================================
-- ITEM GRANTING
-- ============================================================================
local function giveItem(holder, label)
	if not ItemHandler then
		-- on-demand re-resolve: the async boot sync may not have fired yet
		local folder = remoteFolder()
		if folder then
			ItemHandler = folder:FindFirstChild("ItemHandler") or folder:WaitForChild("ItemHandler", 4)
		end
	end
	if not ItemHandler then log("ItemHandler unavailable on this server", true) return false end
	pace()
	local ok = vsafe(function() ItemHandler:InvokeServer(holder) end)
	if ok then log("granted: " .. tostring(label or holder.Name or "?")) end
	return ok
end

-- Modern form: server accepts {Position = pivot, Parent = item}, so any
-- catalogued item lands in our inventory without walking to the giver part.
local function giveAnywhere(itemName)
	local target = findItemAnywhere(itemName)
	if not target then
		log("item missing from map: " .. tostring(itemName), true)
		return false
	end
	local pivot = CFrame.new(0, 100, 0)
	pcall(function() pivot = lp.Character:GetPivot() end)
	return giveItem({ Position = pivot, Parent = target }, itemName)
end

-- Legacy path for older servers that validate the literal ITEMPICKUP part.
local function giveLegacy(itemName, subfolder)
	local child = getItemIn(subfolder, itemName, "ITEMPICKUP")
		or getItemIn("single", itemName, "ITEMPICKUP")
	if not child then
		child = getItemIn(subfolder or "giver", itemName) or getItemIn("single", itemName)
	end
	if not child then
		log("legacy giver path exhausted for " .. tostring(itemName), true)
		return false
	end
	return giveItem(child, itemName)
end

local GIVEN_GUNS  = { "M9", "Remington 870", "AK-47", "M4A1" }
local GIVEN_MELEE = { "Key card", "Hammer", "Crude Knife" }

local function giveAllLoot()
	spawn(function()
		for _, g in ipairs(GIVEN_GUNS) do
			if state.detached then return end
			if not giveAnywhere(g) then giveLegacy(g, "giver") end
		end
		for _, m in ipairs(GIVEN_MELEE) do
			if state.detached then return end
			giveAnywhere(m)
		end
		local riotPolice = findItemAnywhere("Riot Police")
		if riotPolice then
			local child = riotPolice:FindFirstChild("ITEMPICKUP")
			if child then giveItem(child, "Riot Police") end
		end
	end)
end

local function giveRiotGear()
	spawn(function()
		if not giveAnywhere("Riot Shield") then giveLegacy("Riot Shield", "giver") end
		local hat = getItemIn("hats", "Police hat", "hat") or getItemIn("hats", "Riot helmet", "hat")
		if hat then giveItem(hat, "Riot helmet / hat") end
		local mask = getItemIn("hats", "Ski mask", "hat")
		if mask then giveItem(mask, "Ski mask") end
	end)
end

-- ============================================================================
-- KILL / ARREST / TAZE CORES
-- ============================================================================
local function meleeKill(target)
	if not (meleeEvent and target and target.Character) then return false end
	vsafe(function() meleeEvent:FireServer(target) end)
	return true
end

local function shootKill(target, gunTool)
	if not shootingEvent then return false end
	local ch = target and target.Character
	if not ch then return false end
	local hitPart = ch:FindFirstChild("Torso") or ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart
	if not hitPart then return false end
	local bullet = {
		{
			Hit       = hitPart,
			Distance  = 15,
			Cframe    = currentCam().CFrame,
			RayObject = Ray.new(Vector3.new(0, 0, 0), Vector3.new(1, 0, 0)),
		},
	}
	vsafe(function() shootingEvent:FireServer(bullet, gunTool) end)
	return true
end

local function killTarget(target)
	if not (target and target.Character) then return false end
	local ff = target.Character:FindFirstChildOfClass("ForceField")
	if ff and not CONFIG.killAuraIgnoreFF then return false end
	if meleeKill(target) then return true end
	local tool = lp.Character and lp.Character:FindFirstChildWhichIsA("Tool")
		or lp.Backpack and lp.Backpack:FindFirstChildWhichIsA("Tool")
	shootKill(target, tool)
	return true
end

local function tazeTarget(target, taserTool)
	if not shootingEvent then return false end
	local ch = target and target.Character
	if not (ch and ch.PrimaryPart and taserTool) then return false end
	local bullet = {
		{
			Hit       = ch.PrimaryPart,
			Distance  = 15,
			Cframe    = currentCam().CFrame,
			RayObject = Ray.new(Vector3.new(0, 0, 0), Vector3.new(1, 0, 0)),
		},
	}
	vsafe(function() shootingEvent:FireServer(bullet, taserTool) end)
	return true
end

local function getTaser()
	return (lp.Character and lp.Character:FindFirstChild("Taser"))
		or (lp.Backpack and lp.Backpack:FindFirstChild("Taser"))
end

local function getArrestRemote()
	return getRemote("arrest") or getRemote("Arrest")
end

local function isCuffed(target)
	local ch = target and target.Character
	if not ch then return false end
	local head = ch:FindFirstChild("Head")
	if not head then return false end
	return head:FindFirstChild("handcuffedGui") ~= nil
end

-- Arrest is a RemoteFunction: step behind the target, invoke, repeat x10
local function arrestOnce(target)
	local remote = getArrestRemote()
	if not remote then
		log("arrest remote unavailable on this server", true)
		return false
	end
	local myRoot, myChar = charRoot(), lp.Character
	local theirRoot = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not (myRoot and theirRoot) then return false end
	myRoot.CFrame = theirRoot.CFrame * CFrame.new(0, 0, 1)
	vsafe(function() remote:InvokeServer(theirRoot) end)
	return true
end

local function arrestTarget(target)
	local cuffed = false
	for i = 1, 10 do
		if state.detached then return false end
		arrestOnce(target)
		task.wait(0.08)
		if isCuffed(target) then cuffed = true; break end
	end
	return cuffed
end

-- ============================================================================
-- ANTI-TAZE — sever the OnClientEvent handlers plus a WalkSpeed re-assert loop
-- ============================================================================
local function disableTazerEffects()
	spawn(function()
		local ok, tasedR = pcall(function()
			return rs:WaitForChild("GunRemotes", 12):WaitForChild("PlayerTased", 12)
		end)
		if not (ok and tasedR) then
			log("PlayerTased remote not located; anti-taze uses the stun-guard loop", true)
			return
		end
		local killed = 0
		if getconnections then
			for _, conn in pairs(getconnections(tasedR.OnClientEvent)) do
				pcall(function() conn:Disable() end)
				killed = killed + 1
			end
		end
		if killed > 0 then
			log("anti-taze: disabled " .. killed .. " PlayerTased handler(s)")
		else
			log("getconnections missing: stun-guard loop covers anti-taze instead")
		end
	end)
	spawn(function()
		while state.toggles.antiTaze and not state.detached do
			local hum = charHumanoid()
			if hum and hum.WalkSpeed == 0 and not CONFIG.fly then
				hum.WalkSpeed = CONFIG.walkSpeed
			end
			task.wait(0.25)
		end
	end)
end

-- ============================================================================
-- TEAM SWITCH / BECOME CRIMINAL
-- ============================================================================
local function switchTeam(kind)
	spawn(function()
		local teamR, loadChar = getRemote("TeamEvent"), getRemote("loadchar")
		if not (teamR and loadChar) then
			log("team remotes missing on this server", true)
			return
		end
		if kind == "Inmate" then
			vsafe(function() teamR:FireServer("Bright orange") end)
			task.wait(0.12)
			vsafe(function() loadChar:InvokeServer(lp.Name) end)
		elseif kind == "Guard" then
			vsafe(function() teamR:FireServer("Bright blue") end)
			task.wait(0.12)
			vsafe(function() loadChar:InvokeServer(lp.Name) end)
		else
			-- neutral solo loadout keeps guard-grade remote trust for the chat trick
			vsafe(function() loadChar:InvokeServer(lp.Name, "Medium stone grey") end)
		end
		log("team switch -> " .. kind)
	end)
end

local function becomeCriminal()
	spawn(function()
		local pivot
		local crimSpawn = workspace:FindFirstChild("Criminals Spawn")
		if crimSpawn then
			local sl = crimSpawn:FindFirstChildWhichIsA("SpawnLocation", true)
				or crimSpawn:FindFirstChildWhichIsA("BasePart", true)
			if sl then pivot = sl.CFrame end
		end
		if not pivot then pivot = CFrame.new(-938.77, 96, 2063.85) end
		local myRoot = charRoot()
		if not myRoot then return end
		myRoot.CFrame = pivot + Vector3.new(0, 3, 0)
		task.wait(0.6)
		log("criminal conversion executed (spawn-touch method)")
	end)
end

-- ============================================================================
-- WORLD: gate / doors / fences
-- ============================================================================
local function openGate()
	spawn(function()
		local gateBtn = getItemIn("buttons", "Prison Gate", "Prison Gate")
		if not gateBtn then
			log("Prison Gate button not present on this map", true)
			return
		end
		local ok = giveItem(gateBtn, "Prison Gate")
		if not ok then log("gate open rejected (server-side validation?)", true) end
	end)
end

local function removeDoors()
	local doors = workspace:FindFirstChild("Doors")
	local fences = workspace:FindFirstChild("Prison_Fences")
	local count = 0
	if doors then pcall(function() doors:Destroy() end); count = count + 1 end
	if fences then pcall(function() fences:Destroy() end); count = count + 1 end
	log("removed " .. count .. " world barrier container(s) (client-side)")
end

-- ============================================================================
-- TELEPORTS — CFrame constants verified on the live map; dynamic item seekers
-- track actual parts so dev edits to the prison layout survive.
-- ============================================================================
local TELEPORTS = {
	{ name = "Gate Button",      fn = function() return CFrame.new(504.53, 104.91, 2240.84) end },
	{ name = "Prison Spawn",     fn = function() return CFrame.new(916.81, 99.99, 2373.38) end },
	{ name = "Guards Spawn",     fn = function() return CFrame.new(837.35, 99.99, 2303.22) end },
	{ name = "Criminal Spawn",   fn = function() return CFrame.new(-938.77, 94.13, 2063.85) end },
	{ name = "Crim Base Hammer", fn = function() return CFrame.new(808.08, 95.59, 2525.31) end },
	{ name = "Riot Gear Stand",  fn = function() return CFrame.new(853.40, 100.70, 2216.49) end },
	{ name = "Police Room",      fn = function() return CFrame.new(909.45, 99.99, 2258.89) end },
	{ name = "Cafeteria",        fn = function() return CFrame.new(945.71, 99.80, 2320.33) end },
}

local function teleportTo(cframe)
	local myRoot = charRoot()
	if not myRoot then return end
	myRoot.CFrame = cframe + Vector3.new(0, 2.5, 0)
	log("teleported")
end

-- ============================================================================
-- GUN MODS — rewrites the tool's own GunStates module in place
-- ============================================================================
local function modGun(tool)
	if not (tool and tool:IsA("Tool") and tool:FindFirstChild("GunStates")) then
		log("not a moddable gun: " .. tostring(tool and tool.Name), true)
		return false
	end
	local ok = pcall(function()
		local gs = require(tool.GunStates)
		gs.Damage     = CONFIG.gunDamage
		gs.Bullets    = CONFIG.gunBullets
		gs.FireRate   = math.max(CONFIG.gunFireRate, 0.0001)
		gs.Spread     = CONFIG.gunSpread
		gs.ReloadTime = 0.0001
		gs.AutoFire   = CONFIG.gunAutoFire
		gs.MaxAmmo    = math.max(gs.MaxAmmo or 0, 1000)
		gs.StoredAmmo = 999999
		if CONFIG.gunInfiniteAmmo then
			gs.CurrentAmmo = math.huge
		else
			gs.CurrentAmmo = gs.MaxAmmo
		end
	end)
	if not ok then
		log("GunStates write failed on " .. tool.Name .. " (locked module?)", true)
		return false
	end
	log("modded " .. tool.Name)
	return true
end

local function modAllGuns()
	spawn(function()
		local hits = 0
		local sweep = function(container)
			if not container then return end
			for _, tool in ipairs(container:GetChildren()) do
				if tool:IsA("Tool") and tool:FindFirstChild("GunStates") then
					if modGun(tool) then hits = hits + 1 end
				end
			end
		end
		sweep(lp.Backpack)
		sweep(lp.Character)
		log("gun mods applied to " .. hits .. " tool(s)")
	end)
end

local function modNamed(name)
	spawn(function()
		local tool = (lp.Character and lp.Character:FindFirstChild(name))
			or (lp.Backpack and lp.Backpack:FindFirstChild(name))
		if not tool and name ~= "Taser" then
			giveAnywhere(name)
			for _ = 1, 20 do
				task.wait(0.25)
				tool = (lp.Character and lp.Character:FindFirstChild(name))
					or (lp.Backpack and lp.Backpack:FindFirstChild(name))
				if tool then break end
			end
		end
		if tool then modGun(tool) else log(name .. " unavailable to mod", true) end
	end)
end

-- ============================================================================
-- AIMBOT — camera lock with a live-scaled FOV ring
-- ============================================================================
local fovRing
local function buildFovRing()
	fovRing = Instance.new("ScreenGui")
	fovRing.Name = "RiotHubFOVRing"
	fovRing.IgnoreGuiInset = true
	fovRing.ResetOnSpawn = false
	fovRing.Parent = lp:WaitForChild("PlayerGui")

	local ringHolder = Instance.new("Frame")
	ringHolder.Name = "Ring"
	ringHolder.AnchorPoint = Vector2.new(0.5, 0.5)
	ringHolder.Position = UDim2.new(0.5, 0, 0.5, 0)
	ringHolder.BackgroundTransparency = 1
	ringHolder.Size = UDim2.fromOffset(CONFIG.aimbotFov * 2, CONFIG.aimbotFov * 2)
	ringHolder.Parent = fovRing

	local circle = Instance.new("Frame")
	circle.Name = "Circle"
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.new(0.5, 0, 0.5, 0)
	circle.Size = UDim2.new(1, 0, 1, 0)
	circle.BackgroundColor3 = Color3.fromRGB(255, 84, 100)
	circle.BackgroundTransparency = 0.88
	circle.BorderSizePixel = 0
	circle.Parent = ringHolder
	local uc = Instance.new("UICorner")
	uc.CornerRadius = UDim.new(1, 0)
	uc.Parent = circle
	local us = Instance.new("UIStroke")
	us.Color = Color3.fromRGB(255, 84, 100)
	us.Transparency = 0.35
	us.Thickness = 1.5
	us.Parent = circle
end

local function setupAimbot()
	local conn = runSvc.RenderStepped:Connect(function()
		if state.detached then return end
		local camera = currentCam()
		if not camera then return end
		if fovRing then
			local ring = fovRing:FindFirstChild("Ring")
			if ring then
				local show = CONFIG.showAimFov and (state.toggles.aim or state.toggles.silent)
				ring.Visible = show
				if show then
					local diameter = 2 * math.tan(math.rad(CONFIG.aimbotFov) / 2)
						/ math.tan(math.rad(camera.FieldOfView) / 2)
						* (camera.ViewportSize.Y / 2)
					ring.Size = UDim2.fromOffset(diameter, diameter)
				end
			end
		end
		if not state.toggles.aim then return end
		local best, bestAng
		for _, plr in ipairs(plrs:GetPlayers()) do
			if plr ~= lp and plr.Character and plr.Character:FindFirstChild("Head") then
				local hum = plr.Character:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 and selTarget(plr, "aimbotTargets") then
					local head = plr.Character.Head
					local to = head.Position - camera.CFrame.Position
					if to.Magnitude > 3 then
						local ang = math.deg(math.acos(math.clamp(
							camera.CFrame.LookVector:Dot(to.Unit), -1, 1)))
						if ang <= CONFIG.aimbotFov then
							if not bestAng or ang < bestAng then best, bestAng = head, ang end
						end
					end
				end
			end
		end
		if best then
			local goal = CFrame.lookAt(camera.CFrame.Position, best.Position)
			local smooth = math.clamp(1 - (CONFIG.aimbotSmooth / 100), 0.06, 1)
			camera.CFrame = camera.CFrame:Lerp(goal, smooth)
		end
	end)
	table.insert(connections, conn)
end

-- ============================================================================
-- SILENT AIM — hook the FireServer namecall and re-point bullet Hit parts
-- straight through the repl's call path, so the server receives edited shots
-- exactly like everything else this client sends.
-- ============================================================================
local hookInstalled = false
local function setupSilentAim()
	spawn(function()
		local hookFn = hookmetamethod
		if not hookFn then
			log("hookmetamethod absent in this executor — silent aim unavailable", true)
			return
		end
		if hookInstalled then return end
		hookInstalled = true
		local oldNamecall
		oldNamecall = hookFn(game, "__namecall", function(self, ...)
			local args = packArgs(...)
			if self == shootingEvent and state.toggles.silent and type(args[1]) == "table" then
				pcall(function()
					local camera = currentCam()
					if not camera then return end
					local best, bestAng
					for _, plr in ipairs(plrs:GetPlayers()) do
						if plr ~= lp and plr.Character and plr.Character:FindFirstChild("Head") then
							local hum = plr.Character:FindFirstChildOfClass("Humanoid")
							if hum and hum.Health > 0 and selTarget(plr, "triggerTargets") then
								local head = plr.Character.Head
								local to = head.Position - camera.CFrame.Position
								if to.Magnitude > 3 then
									local ang = math.deg(math.acos(math.clamp(
										camera.CFrame.LookVector:Dot(to.Unit), -1, 1)))
									if ang <= CONFIG.silentFov then
										if not bestAng or ang < bestAng then best, bestAng = head, ang end
									end
								end
							end
						end
					end
					if best then
						if CONFIG.silentWallCheck then
							local params = RaycastParams.new()
							params.FilterType = Enum.RaycastFilterType.Exclude
							params.FilterDescendantsInstances = { lp.Character, best.Parent }
							local hit = workspace:Raycast(
								camera.CFrame.Position,
								best.Position - camera.CFrame.Position, params)
							if hit and hit.Instance and not hit.Instance:IsDescendantOf(best.Parent) then
								return oldNamecall(self, spread(args))
							end
						end
						if math.random(1, 100) <= CONFIG.silentHitChance then
							for _, b in ipairs(args[1]) do
								if CONFIG.silentRandomPart then
									local other = best.Parent.PrimaryPart and best.Parent.PrimaryPart or best
									b.Hit = (math.random() < 0.5) and best or other
								else
									b.Hit = best
								end
							end
							log("silent bullet re-aimed to " .. best.Parent.Name)
						end
					end
				end)
			end
			return oldNamecall(self, spread(args))
		end)
		log("silent aim armed (ShootEvent FireServer hook)")
	end)
end

-- ============================================================================
-- TRIGGERBOT
-- ============================================================================
local function triggerFire()
	pcall(function()
		if mouse1press then
			mouse1press()
			task.wait(0.01)
			if mouse1release then mouse1release() end
		else
			local tool = lp.Character and lp.Character:FindFirstChildWhichIsA("Tool")
			if tool then
				tool:Activate()
				task.delay(0.03, function() tool:Deactivate() end)
			end
		end
	end)
end

local function setupTriggerBot()
	local conn = runSvc.RenderStepped:Connect(function()
		if state.detached or not state.toggles.trig then return end
		local t = mouse.Target
		if not (t and t.Parent) then return end
		local hum = t.Parent:FindFirstChildOfClass("Humanoid")
		if not (hum and hum.Health > 0) then return end
		local plr = plrs:GetPlayerFromCharacter(t.Parent)
		if not plr or plr == lp then return end
		if not selTarget(plr, "triggerTargets") then return end
		local tool = lp.Character and lp.Character:FindFirstChildWhichIsA("Tool")
		if tool and tool:FindFirstChild("GunStates") then triggerFire() end
	end)
	table.insert(connections, conn)
end

-- ============================================================================
-- ESP + CHAMS
-- ============================================================================
local espContainer
local function ensureEspContainer()
	if espContainer then return espContainer end
	espContainer = Instance.new("Folder")
	espContainer.Name = "RiotHubEspOverlays"
	espContainer.Parent = (gethui and gethui()) or lp:WaitForChild("PlayerGui")
	return espContainer
end

local function applyChams(plr)
	pcall(function()
		local ch = plr.Character
		if not ch then return end
		local hil = ch:FindFirstChild("RiotHub_Cham")
		if not state.toggles.chams then
			if hil then hil:Destroy() end
			return
		end
		if not hil then
			hil = Instance.new("Highlight")
			hil.Name = "RiotHub_Cham"
			hil.DepthMode = CONFIG.chamsThroughWalls and Enum.HighlightDepthMode.AlwaysOnTop
				or Enum.HighlightDepthMode.Occluded
			hil.Parent = ch
		end
		hil.FillColor = isGuard(plr) and Color3.fromRGB(80, 130, 255)
			or isInmate(plr) and Color3.fromRGB(255, 145, 40)
			or isCrim(plr) and Color3.fromRGB(255, 60, 60)
			or Color3.fromRGB(220, 220, 220)
		hil.FillTransparency = 0.55
		hil.OutlineColor = Color3.new(0, 0, 0)
		hil.OutlineTransparency = 0.2
	end)
end

local function clearChams(plr)
	pcall(function()
		local ch = plr.Character
		if ch then
			local hil = ch:FindFirstChild("RiotHub_Cham")
			if hil then hil:Destroy() end
		end
	end)
end

local function buildEspUnit(plr)
	local unit = { conns = {} }
	local bb = Instance.new("BillboardGui")
	bb.Name = "RiotHub_ESP"
	bb.Size = UDim2.new(7, 0, 2.2, 0)
	bb.StudsOffset = Vector3.new(0, 1.6, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 2000
	bb.Adornee = plr.Character and plr.Character:FindFirstChild("Head")
	bb.Parent = ensureEspContainer()

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.Size = UDim2.new(1, 0, 0.5, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.SourceSansBold
	nameLabel.TextSize = 14
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextStrokeTransparency = 0.25
	nameLabel.Parent = bb

	local distLabel = Instance.new("TextLabel")
	distLabel.Name = "DistLabel"
	distLabel.Size = UDim2.new(1, 0, 0.5, 0)
	distLabel.Position = UDim2.new(0, 0, 0.5, 0)
	distLabel.BackgroundTransparency = 1
	distLabel.Font = Enum.Font.SourceSans
	distLabel.TextSize = 12
	distLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	distLabel.TextStrokeTransparency = 0.4
	distLabel.Parent = bb
	unit.billboard = bb
	unit.nameLabel = nameLabel
	unit.distLabel = distLabel

	table.insert(unit.conns, connect(plr.CharacterAdded, function()
		task.wait(0.3)
		bb.Adornee = plr.Character and plr.Character:FindFirstChild("Head")
		applyChams(plr)
	end))
	applyChams(plr)
	return unit
end

local function destroyEspUnit(plr)
	local unit = state.espUnits[plr]
	if not unit then return end
	for _, c in ipairs(unit.conns) do pcall(function() c:Disconnect() end) end
	if unit.billboard then unit.billboard:Destroy() end
	state.espUnits[plr] = nil
end

local function refreshEsp()
	for _, plr in ipairs(plrs:GetPlayers()) do
		if plr ~= lp then
			if state.toggles.esp then
				if not state.espUnits[plr] then state.espUnits[plr] = buildEspUnit(plr) end
			else
				destroyEspUnit(plr)
			end
			applyChams(plr)
		end
	end
	for plr, _ in pairs(state.espUnits) do
		if not plr.Parent then destroyEspUnit(plr) end
	end
end

local function setupEspFrame()
	local conn = runSvc.RenderStepped:Connect(function()
		if state.detached then return end
		local camera = currentCam()
		if not camera then return end
		for plr, unit in pairs(state.espUnits) do
			local ch = plr.Character
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			local head = ch and ch:FindFirstChild("Head")
			-- boolean-coerced: assigning an Instance to .Enabled would throw
			local visible = (state.toggles.esp == true) and (head ~= nil) and (hum ~= nil)
			if visible and hum.Health <= 0 then visible = false end
			if visible and CONFIG.espVisibleOnly then
				local ok, vis = pcall(function()
					local params = RaycastParams.new()
					params.FilterType = Enum.RaycastFilterType.Exclude
					params.FilterDescendantsInstances = { lp.Character, ch }
					local hit = workspace:Raycast(camera.CFrame.Position, head.Position - camera.CFrame.Position, params)
					if hit and hit.Instance then
						return hit.Instance:IsDescendantOf(ch)
					end
					return true
				end)
				visible = (not ok) and true or vis
			end
			unit.billboard.Enabled = visible
			if visible then
				unit.billboard.Adornee = head
				local dist = (head.Position - camera.CFrame.Position).Magnitude
				local hpTxt = ""
				if CONFIG.espHealthBar then
					hpTxt = string.format("  [%d%%]",
						math.floor(hum.Health / math.max(hum.MaxHealth, 1) * 100 + 0.5))
				end
				unit.nameLabel.Text = (CONFIG.espNames and (plr.Name .. hpTxt) or "")
				unit.distLabel.Text = (CONFIG.espDistance and string.format("%dm", dist) or "")
				if CONFIG.espTeamColor then
					unit.nameLabel.TextColor3 = isGuard(plr) and Color3.fromRGB(110, 170, 255)
						or isInmate(plr) and Color3.fromRGB(255, 165, 70)
						or isCrim(plr) and Color3.fromRGB(255, 90, 90)
						or Color3.fromRGB(220, 220, 220)
				else
					unit.nameLabel.TextColor3 = Color3.new(1, 1, 1)
				end
			end
		end
	end)
	table.insert(connections, conn)
end

connect(plrs.PlayerRemoving, function(plr)
	destroyEspUnit(plr)
end)

-- ============================================================================
-- MOVEMENT — a single heartbeat reads config each frame
-- ============================================================================
local function applyMovementFrame(dt)
	local ch = lp.Character
	if not (ch and ch.PrimaryPart) then return end
	local rootPart = ch.PrimaryPart
	local hum = ch:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	if CONFIG.walkSpeed ~= 16 and not CONFIG.tpWalk then
		hum.WalkSpeed = CONFIG.walkSpeed
	end
	if CONFIG.noJumpCooldown then hum.JumpPower = CONFIG.jumpPower end

	if state.toggles.tpWalkRun and hum.MoveDirection.Magnitude > 0.3 then
		rootPart.CFrame = rootPart.CFrame + hum.MoveDirection * CONFIG.tpWalkPower
	end

	if state.toggles.spinMode then
		rootPart.CFrame = rootPart.CFrame * CFrame.Angles(0, math.rad(CONFIG.spinSpeed) * dt, 0)
	end

	if state.toggles.fly then
		local camera = currentCam()
		if camera then
			local moveDir = Vector3.new(0, 0, 0)
			if uis:IsKeyDown(Enum.KeyCode.W) then moveDir = moveDir + camera.CFrame.LookVector end
			if uis:IsKeyDown(Enum.KeyCode.S) then moveDir = moveDir - camera.CFrame.LookVector end
			if uis:IsKeyDown(Enum.KeyCode.A) then moveDir = moveDir - camera.CFrame.RightVector end
			if uis:IsKeyDown(Enum.KeyCode.D) then moveDir = moveDir + camera.CFrame.RightVector end
			local h = 0
			if uis:IsKeyDown(Enum.KeyCode.E) then h = 1 end
			if uis:IsKeyDown(Enum.KeyCode.Q) then h = -1 end
			rootPart.Velocity = Vector3.new(0, 0, 0)
			rootPart.CFrame = rootPart.CFrame
				+ (moveDir * CONFIG.flySpeed * 2.2 * dt)
				+ Vector3.new(0, h * CONFIG.flySpeed * 1.6 * dt, 0)
		end
	end

	if state.toggles.noclip then
		for _, p in ipairs(ch:GetDescendants()) do
			if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
		end
	end
end

local moveConn = runSvc.Heartbeat:Connect(applyMovementFrame)
table.insert(connections, moveConn)

connect(uis.JumpRequest, function()
	if not state.toggles.infJump then return end
	local hum = charHumanoid()
	if hum then
		local st = hum:GetState()
		if st ~= Enum.HumanoidStateType.Jumping and st ~= Enum.HumanoidStateType.Freefall then
			hum:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end
end)

-- ============================================================================
-- UI LIBRARY — built FIRST, so the panel is on-screen instantly even while
-- remotes / Prison_ITEMS are still resolving in the background
-- ============================================================================
print("[RiotHub] stage 2: building GUI")
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "RiotHub_GUI"
screenGui.IgnoreSafeArea = true
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local uiParent = (gethui and gethui()) or game:FindFirstChildOfClass("CoreGui") or lp:WaitForChild("PlayerGui")
screenGui.Parent = uiParent

local function make(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props) do obj[k] = v end
	if parent then obj.Parent = parent end
	return obj
end
local function corner(o, r)
	return make("UICorner", { CornerRadius = UDim.new(0, r or 7) }, o)
end
local function pad(el, l, r, t, b)
	return make("UIPadding", {
		PaddingLeft = UDim.new(0, l or 0), PaddingRight = UDim.new(0, r or 0),
		PaddingTop = UDim.new(0, t or 0), PaddingBottom = UDim.new(0, b or 0),
	}, el)
end

local window = make("Frame", {
	Name = "Window",
	Size = UDim2.fromOffset(640, 460),
	Position = UDim2.new(0.5, -320, 0.5, -230),
	BackgroundColor3 = Color3.fromRGB(17, 17, 21),
	Active = true, Draggable = true, BorderSizePixel = 0,
}, screenGui)
corner(window, 10)

-- floating mobile toggle: phones have no RightCtrl / G / H / J keyboard
local toggleFab = make("TextButton", {
	Name = "ToggleFab", Text = "RH",
	Size = UDim2.fromOffset(42, 42),
	Position = UDim2.new(0, 10, 0.5, -21),
	BackgroundColor3 = Color3.fromRGB(24, 24, 29),
	BackgroundTransparency = 0.15,
	Font = Enum.Font.Code, TextSize = 15,
	TextColor3 = Color3.fromRGB(255, 84, 100),
	BorderSizePixel = 0, AutoButtonColor = true,
	Active = true, Draggable = true,
}, screenGui)
corner(toggleFab, 18)
toggleFab.MouseButton1Click:Connect(function()
	window.Visible = not window.Visible
end)

local topBar = make("Frame", {
	Name = "TopBar", Size = UDim2.new(1, 0, 0, 34),
	BackgroundColor3 = Color3.fromRGB(25, 25, 30), BorderSizePixel = 0,
}, window)
make("TextLabel", {
	Text = "RIOTHUB  //  PRISON LIFE",
	Size = UDim2.new(1, -80, 1, 0), Position = UDim2.new(0, 12, 0, 0),
	BackgroundTransparency = 1, Font = Enum.Font.Code,
	TextColor3 = Color3.fromRGB(255, 84, 100),
	TextXAlignment = Enum.TextXAlignment.Left, TextSize = 15,
}, topBar)
local closeBtn = make("TextButton", {
	Text = "X", Size = UDim2.new(0, 34, 1, 0), Position = UDim2.new(1, -34, 0, 0),
	BackgroundTransparency = 1, Font = Enum.Font.Code,
	TextColor3 = Color3.fromRGB(210, 90, 96), TextSize = 16,
}, topBar)

local tabsRail = make("ScrollingFrame", {
	Size = UDim2.new(0, 138, 1, -34 - 88), Position = UDim2.new(0, 0, 0, 34),
	BackgroundTransparency = 1, BorderSizePixel = 0,
	CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 2,
}, window)
make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, tabsRail)
pad(tabsRail, 8, 4, 6)

local contentHolder = make("ScrollingFrame", {
	Size = UDim2.new(1, -150, 1, -34 - 88), Position = UDim2.new(0, 138, 0, 34),
	BackgroundColor3 = Color3.fromRGB(23, 23, 28), BorderSizePixel = 0,
	CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 3,
}, window)
corner(contentHolder, 8)
pad(contentHolder, 4, 12, 4)

local logPanel = make("Frame", {
	Name = "LogPanel", Size = UDim2.new(1, 0, 0, 88), Position = UDim2.new(0, 0, 1, -88),
	BackgroundColor3 = Color3.fromRGB(13, 13, 16), BorderSizePixel = 0,
}, window)
pad(logPanel, 6, 6, 2)
logScroll = make("ScrollingFrame", {
	Name = "LogScroll", Size = UDim2.new(1, -8, 1, -4),
	BackgroundTransparency = 1, BorderSizePixel = 0,
	CanvasSize = UDim2.new(0, 0, 0, 40), ScrollBarThickness = 2,
}, logPanel)
logText = make("TextLabel", {
	Name = "LogText", Text = "riot hub v2.0 — waiting for your first action",
	Size = UDim2.new(1, -8, 0, 20), BackgroundTransparency = 1,
	Font = Enum.Font.Code, TextColor3 = Color3.fromRGB(120, 235, 170),
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
	TextSize = 13,
}, logScroll)

-- tab framework
local tabButtons = {}
local activeTabEntry = nil

local function newTab(name, icon)
	local btn = make("TextButton", {
		Text = (icon or "*") .. "  " .. name,
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = Color3.fromRGB(25, 25, 31),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.Code, TextSize = 14,
		TextColor3 = Color3.fromRGB(168, 168, 178),
		AutoButtonColor = true, BorderSizePixel = 0,
	}, tabsRail)
	pad(btn, 8)

	local page = make("Frame", {
		Name = name .. "Page", Size = UDim2.new(1, -8, 1, 0),
		BackgroundTransparency = 1, Visible = false,
	}, contentHolder)
	make("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, page)

	local entry = { txt = btn, page = page }
	tabButtons[name] = entry
	btn.MouseButton1Click:Connect(function()
		if activeTabEntry then activeTabEntry.page.Visible = false end
		activeTabEntry = entry
		for _, e in pairs(tabButtons) do
			e.txt.BackgroundColor3 = Color3.fromRGB(25, 25, 31)
			e.txt.TextColor3 = Color3.fromRGB(168, 168, 178)
		end
		btn.BackgroundColor3 = Color3.fromRGB(52, 30, 36)
		btn.TextColor3 = Color3.fromRGB(255, 220, 224)
		page.Visible = true
	end)
	return page
end

local function ensureCanvas(page)
	local list = page:FindFirstChildOfClass("UIListLayout")
	if list then
		connect(list:GetPropertyChangedSignal("AbsoluteContentSize"), function()
			contentHolder.CanvasSize = UDim2.new(0, 0, 0, list.AbsoluteContentSize.Y + 24)
		end)
	end
end

local function section(page, label)
	local row = make("Frame", {
		Size = UDim2.new(1, -6, 0, 22), BackgroundTransparency = 1,
	}, page)
	make("TextLabel", {
		Text = string.upper(label),
		Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1,
		Font = Enum.Font.Code, TextColor3 = Color3.fromRGB(255, 84, 100),
		TextXAlignment = Enum.TextXAlignment.Left, TextSize = 12,
	}, row)
end

local function toggleRow(owner, label, desc, default, callback, key)
	local row = make("TextButton", {
		Size = UDim2.new(1, -6, 0, desc and 46 or 30),
		BackgroundColor3 = Color3.fromRGB(29, 29, 34),
		Parent = owner, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
	}, owner)
	corner(row, 7)
	local body = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -46, 1, 0) }, row)
	pad(body, 10)
	make("TextLabel", {
		Text = label, Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
		Font = Enum.Font.Code, TextSize = 14, TextColor3 = Color3.fromRGB(224, 224, 230),
		TextXAlignment = Enum.TextXAlignment.Left,
	}, body)
	if desc then
		make("TextLabel", {
			Text = desc, Size = UDim2.new(1, 0, 0, 20), Position = UDim2.new(0, 0, 0, 22),
			BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 11,
			TextColor3 = Color3.fromRGB(132, 132, 142), TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
		}, body)
	end
	local indicator = make("Frame", {
		Size = UDim2.new(0, 34, 0, 18), Position = UDim2.new(1, -40, 0.5, -9),
		BackgroundColor3 = default and Color3.fromRGB(72, 190, 122) or Color3.fromRGB(58, 58, 64),
		BorderSizePixel = 0,
	}, row)
	corner(indicator, 9)
	local knob = make("Frame", {
		Size = UDim2.new(0, 14, 0, 14),
		Position = default and UDim2.new(1, -16, 0, 2) or UDim2.new(0, 2, 0, 2),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
	}, indicator)
	corner(knob, 7)
	if key then
		make("TextLabel", {
			Text = key, Size = UDim2.new(0, 26, 1, 0), Position = UDim2.new(1, -72, 0, 0),
			BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 12,
			TextColor3 = Color3.fromRGB(110, 110, 120),
		}, row)
	end

	local enabled = (default == true)
	local function set(v)
		enabled = v
		state.toggles[label] = v
		indicator.BackgroundColor3 = v and Color3.fromRGB(72, 190, 122) or Color3.fromRGB(58, 58, 64)
		knob.Position = v and UDim2.new(1, -16, 0, 2) or UDim2.new(0, 2, 0, 2)
		if callback then callback(v) end
	end
	row.MouseButton1Click:Connect(function() set(not enabled) end)
	if key then
		connect(uis.InputBegan, function(input, processed)
			if state.detached or processed then return end
			if input.UserInputType == Enum.UserInputType.Keyboard
				and input.KeyCode.Name == key then
				set(not enabled)
			end
		end)
	end
	state.toggles[label] = enabled
	return { Set = set }
end

local function sliderRow(owner, label, minV, maxV, default, callback, suffix)
	local row = make("Frame", {
		Size = UDim2.new(1, -6, 0, 42), BackgroundColor3 = Color3.fromRGB(29, 29, 34),
		BorderSizePixel = 0,
	}, owner)
	corner(row, 7)
	pad(row, 10, 12, 4)
	make("TextLabel", {
		Text = label, Size = UDim2.new(0.64, 0, 0, 16), BackgroundTransparency = 1,
		Font = Enum.Font.Code, TextSize = 13, TextColor3 = Color3.fromRGB(224, 224, 230),
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	local valueLabel = make("TextLabel", {
		Text = tostring(default) .. (suffix or ""), Size = UDim2.new(0.36, 0, 0, 16),
		Position = UDim2.new(0.64, 0, 0, 0), BackgroundTransparency = 1,
		Font = Enum.Font.Code, TextSize = 13, TextColor3 = Color3.fromRGB(255, 84, 100),
		TextXAlignment = Enum.TextXAlignment.Right,
	}, row)
	local bar = make("Frame", {
		Size = UDim2.new(1, 0, 0, 6), Position = UDim2.new(0, 0, 0, 24),
		BackgroundColor3 = Color3.fromRGB(45, 45, 52), BorderSizePixel = 0,
	}, row)
	corner(bar, 3)
	local fill = make("Frame", {
		Size = UDim2.new(math.clamp((default - minV) / math.max(maxV - minV, 0.001), 0, 1), 0, 1, 0),
		BackgroundColor3 = Color3.fromRGB(255, 84, 100), BorderSizePixel = 0,
	}, bar)
	corner(fill, 3)

	local dragging = false
	local function refreshBar(m)
		local a, s = bar.AbsolutePosition, bar.AbsoluteSize
		local ratio = math.clamp((m.X - a.X) / math.max(s.X, 1), 0, 1)
		local value = minV + (maxV - minV) * ratio
		fill.Size = UDim2.new(ratio, 0, 1, 0)
		valueLabel.Text = string.format("%.0f%s", value, suffix or "")
		if callback then callback(value) end
	end
	bar.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1
			or io.UserInputType == Enum.UserInputType.Touch then
			dragging = true
		end
	end)
	connect(uis.InputEnded, function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1
			or io.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	connect(runSvc.RenderStepped, function()
		if dragging then refreshBar(uis:GetMouseLocation()) end
	end)
end

local function buttonRow(owner, label, callback)
	local btn = make("TextButton", {
		Text = label, Size = UDim2.new(1, -6, 0, 30),
		BackgroundColor3 = Color3.fromRGB(29, 29, 34),
		Font = Enum.Font.Code, TextSize = 13, TextColor3 = Color3.fromRGB(224, 224, 230),
		AutoButtonColor = true, BorderSizePixel = 0,
	}, owner)
	corner(btn, 7)
	btn.MouseButton1Click:Connect(function()
		local ok, err = pcall(callback)
		if not ok then log("button error: " .. tostring(err), true) end
	end)
	return btn
end

local function dropdownRow(owner, label, options, default, callback)
	local row = make("TextButton", {
		Size = UDim2.new(1, -6, 0, 30), BackgroundColor3 = Color3.fromRGB(29, 29, 34),
		BorderSizePixel = 0, AutoButtonColor = false, Text = "",
	}, owner)
	corner(row, 7)
	pad(row, 10)
	make("TextLabel", {
		Text = label, Size = UDim2.new(0.66, -10, 1, 0),
		BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 13,
		TextColor3 = Color3.fromRGB(224, 224, 230), TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	local chosen = make("TextLabel", {
		Text = default or "-", Size = UDim2.new(0.34, -8, 1, 0), Position = UDim2.new(0.66, 0, 0, 0),
		BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 13,
		TextColor3 = Color3.fromRGB(255, 84, 100), TextXAlignment = Enum.TextXAlignment.Right,
	}, row)
	local list = make("Frame", {
		Size = UDim2.new(1, -12, 0, math.min(#options, 7) * 24 + 4),
		BackgroundColor3 = Color3.fromRGB(36, 36, 42), BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, 4), Visible = false, ZIndex = 6,
	}, row)
	corner(list, 7)
	local openTgl = false
	for idx, opt in ipairs(options) do
		local optBtn = make("TextButton", {
			Text = opt, Size = UDim2.new(1, 0, 0, 22),
			BackgroundColor3 = Color3.fromRGB(41, 41, 47),
			Font = Enum.Font.Code, TextSize = 13, TextColor3 = Color3.fromRGB(206, 206, 212),
			AutoButtonColor = true, BorderSizePixel = 0, ZIndex = 6, LayoutOrder = idx,
		}, list)
		optBtn.MouseButton1Click:Connect(function()
			chosen.Text = opt
			if callback then callback(opt) end
			list.Visible = false
			openTgl = false
		end)
	end
	row.MouseButton1Click:Connect(function()
		openTgl = not openTgl
		list.Visible = openTgl
	end)
	return { Text = chosen }
end

-- ============================================================================
-- TABS
-- ============================================================================
local pageCombat = newTab("Combat", "*")
ensureCanvas(pageCombat)
local pageGun  = newTab("Weapons", "*")
ensureCanvas(pageGun)
local pageWorld = newTab("World", "*")
ensureCanvas(pageWorld)
local pageMov  = newTab("Movement", "*")
ensureCanvas(pageMov)
local pageVis  = newTab("Visuals", "*")
ensureCanvas(pageVis)
local pageMisc = newTab("Misc", "*")
ensureCanvas(pageMisc)
local pageCfg  = newTab("Settings", "*")
ensureCanvas(pageCfg)

do
	local first = tabButtons["Combat"]
	if first then
		activeTabEntry = first
		first.txt.BackgroundColor3 = Color3.fromRGB(52, 30, 36)
		first.txt.TextColor3 = Color3.fromRGB(255, 220, 224)
		first.page.Visible = true
	end
end

-- ---------------------------------------------------------------------------
-- COMBAT PAGE
-- ---------------------------------------------------------------------------
section(pageCombat, "Kill / Arrest / Taze")
toggleRow(pageCombat, "killAura", "Auto-melee every valid target inside the radius",
	false, function(v) end, "G")
sliderRow(pageCombat, "Kill Radius", 10, 260, CONFIG.killAuraRadius,
	function(v) CONFIG.killAuraRadius = math.floor(v + 0.5) end)
toggleRow(pageCombat, "killFFskip", "Killing forcefielded targets is skipped",
	CONFIG.killAuraIgnoreFF, function(v) CONFIG.killAuraIgnoreFF = v end)
dropdownRow(pageCombat, "Aura Targets",
	{ "All", "Inmates", "Guards", "Criminals" }, CONFIG.kAuraTargets,
	function(choice) CONFIG.kAuraTargets = choice end)
toggleRow(pageCombat, "arrestAura", "Snap behind nearby non-guards and spam the arrest remote",
	false, function(v) end, "H")
sliderRow(pageCombat, "Arrest Radius", 20, 500, CONFIG.arrestAuraRadius,
	function(v) CONFIG.arrestAuraRadius = math.floor(v + 0.5) end)
toggleRow(pageCombat, "loopTaze", "Loop ShootEvent-Taser against the whole server",
	false, function(v) end, "J")
buttonRow(pageCombat, "Kill All (burst)", function()
	spawn(function()
		for _, plr in ipairs(plrs:GetPlayers()) do
			if plr ~= lp then killTarget(plr) end
		end
		if not meleeEvent then log("meleeEvent missing — burst is shot-only", true) end
		log("kill-all burst complete")
	end)
end)
buttonRow(pageCombat, "Arrest All (inmates)", function()
	spawn(function()
		for _, plr in ipairs(plrs:GetPlayers()) do
			if plr ~= lp and not isGuard(plr) and not isCuffed(plr) then
				arrestTarget(plr)
				task.wait(0.4)
			end
		end
		log("arrest-all complete")
	end)
end)
buttonRow(pageCombat, "Taze All (burst)", function()
	spawn(function()
		local taser = getTaser()
		if not taser then
			log("no Taser — firing TeamEvent to guard before re-try", true)
			local teamR = getRemote("TeamEvent")
			if teamR then vsafe(function() teamR:FireServer("Bright blue") end) end
			task.wait(1)
			taser = getTaser()
		end
		if not taser then log("Taser unavailable — taze burst aborted", true) return end
		for _, plr in ipairs(plrs:GetPlayers()) do
			if plr ~= lp then tazeTarget(plr, taser) end
		end
		log("taze-all burst complete")
	end)
end)
section(pageCombat, "Aim")
toggleRow(pageCombat, "aim", "Force the camera onto the nearest head inside the ring",
	false, function(v) end)
sliderRow(pageCombat, "Aim FOV", 20, 500, CONFIG.aimbotFov,
	function(v) CONFIG.aimbotFov = math.floor(v + 0.5) end)
sliderRow(pageCombat, "Aim Smoothness", 0, 100, CONFIG.aimbotSmooth,
	function(v) CONFIG.aimbotSmooth = v end, "%")
toggleRow(pageCombat, "silent", "Re-aim ShootEvent bullets to the nearest head on the wire",
	false, function(v) end)
sliderRow(pageCombat, "Silent FOV", 20, 999, CONFIG.silentFov,
	function(v) CONFIG.silentFov = math.floor(v + 0.5) end)
sliderRow(pageCombat, "Silent Hit %", 0, 100, CONFIG.silentHitChance,
	function(v) CONFIG.silentHitChance = math.floor(v + 0.5) end, "%")
toggleRow(pageCombat, "silentWall", "Raycast line-of-sight check before re-aiming bullets",
	CONFIG.silentWallCheck, function(v) CONFIG.silentWallCheck = v end)
toggleRow(pageCombat, "silentRandom", "Randomize the hit part so kill-cams read human",
	CONFIG.silentRandomPart, function(v) CONFIG.silentRandomPart = v end)
dropdownRow(pageCombat, "Aimbot Targets",
	{ "All", "Inmates", "Guards", "Criminals" }, CONFIG.aimbotTargets,
	function(choice) CONFIG.aimbotTargets = choice end)
toggleRow(pageCombat, "trig", "Auto-fire the held gun when your crosshair sits on a target",
	false, function(v) end)
dropdownRow(pageCombat, "Trigger Targets",
	{ "All", "Inmates", "Guards", "Criminals" }, CONFIG.triggerTargets,
	function(choice) CONFIG.triggerTargets = choice end)
toggleRow(pageCombat, "clickArrest", "Click a player with the panel closed to arrest them",
	CONFIG.clickArrest, function(v) CONFIG.clickArrest = v end)

-- ---------------------------------------------------------------------------
-- WEAPONS PAGE
-- ---------------------------------------------------------------------------
section(pageGun, "Acquisition")
dropdownRow(pageGun, "Give Gun",
	{ "M9", "Remington 870", "AK-47", "M4A1" }, CONFIG.gunChoice,
	function(choice) CONFIG.gunChoice = choice end)
buttonRow(pageGun, "Give Selected Gun", function() giveAnywhere(CONFIG.gunChoice) end)
buttonRow(pageGun, "Give All Guns + Tools", function() giveAllLoot() end)
buttonRow(pageGun, "Give Key Card", function() giveAnywhere("Key card") end)
buttonRow(pageGun, "Give Hammer", function() giveAnywhere("Hammer") end)
buttonRow(pageGun, "Give Crude Knife", function() giveAnywhere("Crude Knife") end)
buttonRow(pageGun, "Give Riot Gear", function() giveRiotGear() end)
buttonRow(pageGun, "Give Handcuffs (guard team)", function()
	spawn(function()
		switchTeam("Guard")
		for _ = 1, 10 do
			task.wait(0.4)
			local cuffs = (lp.Character and lp.Character:FindFirstChild("Handcuffs"))
				or (lp.Backpack and lp.Backpack:FindFirstChild("Handcuffs"))
			if cuffs then break end
		end
		local cuffs2 = (lp.Character and lp.Character:FindFirstChild("Handcuffs"))
			or (lp.Backpack and lp.Backpack:FindFirstChild("Handcuffs"))
		log(cuffs2 and "Handcuffs delivered" or "Handcuffs did not arrive (may need re-spawn)", not cuffs2)
	end)
end)
toggleRow(pageGun, "autoGuns", "Fire the full item-give loop after every respawn",
	CONFIG.gunAutoOnRespawn, function(v) CONFIG.gunAutoOnRespawn = v end)
section(pageGun, "Gun Mods (GunStates rewrites)")
sliderRow(pageGun, "Damage", 1, 250, CONFIG.gunDamage, function(v) CONFIG.gunDamage = math.floor(v + 0.5) end)
sliderRow(pageGun, "Bullets Per Shot", 1, 30, CONFIG.gunBullets, function(v) CONFIG.gunBullets = math.floor(v + 0.5) end)
sliderRow(pageGun, "Fire Rate", 0, 100, 1, function(v) CONFIG.gunFireRate = math.max(v / 10000, 0.0001) end)
sliderRow(pageGun, "Spread", 0, 100, CONFIG.gunSpread, function(v) CONFIG.gunSpread = v / 1000 end)
toggleRow(pageGun, "infAmmo", "CurrentAmmo pinned to infinity in GunStates",
	CONFIG.gunInfiniteAmmo, function(v) CONFIG.gunInfiniteAmmo = v end)
toggleRow(pageGun, "autoFire", "Converts held weapons to full-auto",
	CONFIG.gunAutoFire, function(v) CONFIG.gunAutoFire = v end)
dropdownRow(pageGun, "Mod Target",
	{ "All Tools", "Held Tool", "M9", "Remington 870", "AK-47", "M4A1", "Taser" },
	CONFIG.modTarget, function(choice) CONFIG.modTarget = choice end)
buttonRow(pageGun, "Apply Gun Mods", function()
	if CONFIG.modTarget == "All Tools" then
		modAllGuns()
	elseif CONFIG.modTarget == "Held Tool" then
		local tool = lp.Character and lp.Character:FindFirstChildWhichIsA("Tool")
		if tool then modGun(tool) else log("no tool held", true) end
	else
		modNamed(CONFIG.modTarget)
	end
end)
buttonRow(pageGun, "Reset Gun Mods", function()
	CONFIG.gunDamage, CONFIG.gunBullets, CONFIG.gunFireRate = 12, 1, 0.18
	CONFIG.gunSpread, CONFIG.gunInfiniteAmmo, CONFIG.gunAutoFire = 2, false, false
	log("gun mod sliders reset to vanilla-ish defaults")
end)
section(pageGun, "Auto Collect")
toggleRow(pageGun, "autoCollectRun", "ItemHandler sweep over every item part near you",
	CONFIG.autoCollectEnabled, function(v) end)
sliderRow(pageGun, "Collect Radius", 40, 900, CONFIG.autoCollectRadius,
	function(v) CONFIG.autoCollectRadius = math.floor(v + 0.5) end)

-- ---------------------------------------------------------------------------
-- WORLD PAGE
-- ---------------------------------------------------------------------------
section(pageWorld, "Spots")
for _, spot in ipairs(TELEPORTS) do
	buttonRow(pageWorld, spot.name, function() teleportTo(spot.fn()) end)
end
buttonRow(pageWorld, "Armory (M4A1 giver)", function()
	local item = findItemAnywhere("M4A1")
	local pickup = item and item:FindFirstChild("ITEMPICKUP")
	if pickup then
		teleportTo(pickup.CFrame)
	else
		log("M4A1 giver not present", true)
	end
end)
buttonRow(pageWorld, "Inmate Yard Spawner", function()
	local sp
	pcall(function() sp = workspace:FindFirstChild("Spawns"):FindFirstChildWhichIsA("SpawnLocation", true) end)
	if sp and sp:IsA("SpawnLocation") then
		teleportTo(sp.CFrame)
	else
		log("Spawns folder not found", true)
	end
end)
section(pageWorld, "World Manipulation")
buttonRow(pageWorld, "Open Prison Gate", function() openGate() end)
toggleRow(pageWorld, "gateLoop", "Re-fire the gate button on an interval",
	false, function(v) end)
sliderRow(pageWorld, "Gate Interval", 0.5, 6, CONFIG.gateSpamInterval,
	function(v) CONFIG.gateSpamInterval = math.max(0.5, v) end, "s")
buttonRow(pageWorld, "Remove Doors + Fences", function() removeDoors() end)
buttonRow(pageWorld, "Restore World (respawn)", function()
	local loadChar = getRemote("loadchar")
	if loadChar then vsafe(function() loadChar:InvokeServer(lp.Name) end) else log("loadchar missing", true) end
end)
section(pageWorld, "Teams / Roles")
buttonRow(pageWorld, "Become Inmate", function() switchTeam("Inmate") end)
buttonRow(pageWorld, "Become Guard", function() switchTeam("Guard") end)
buttonRow(pageWorld, "Solo Neutral Mode", function() switchTeam("Neutral") end)
buttonRow(pageWorld, "Become Criminal", function() becomeCriminal() end)
section(pageWorld, "Protections")
toggleRow(pageWorld, "antiTaze", "Sever PlayerTased OnClientEvent handlers so tazing fails",
	false, function(v) if v then disableTazerEffects() end end)
toggleRow(pageWorld, "safePacing", "Throttle ItemHandler calls 3.2s apart (anti-cheat pacing)",
	CONFIG.safePacing, function(v) CONFIG.safePacing = v end)
buttonRow(pageWorld, "Server Report", function()
	log("place " .. tostring(game.PlaceId) .. " · " .. tostring(#plrs:GetPlayers()) .. " players")
	log("remotes — melee=" .. tostring(not not meleeEvent) .. " shoot=" .. tostring(not not shootingEvent)
		.. " item=" .. tostring(not not ItemHandler) .. " arrest=" .. tostring(not not getArrestRemote()))
end)

-- ---------------------------------------------------------------------------
-- MOVEMENT PAGE
-- ---------------------------------------------------------------------------
section(pageMov, "Locomotion")
sliderRow(pageMov, "Walk Speed", 8, 250, CONFIG.walkSpeed,
	function(v) CONFIG.walkSpeed = math.floor(v + 0.5) end)
sliderRow(pageMov, "Jump Power", 8, 250, CONFIG.jumpPower,
	function(v) CONFIG.jumpPower = math.floor(v + 0.5) end)
toggleRow(pageMov, "infJump", "Re-commit the character to the jumping state",
	false, function(v) CONFIG.infJump = v end)
toggleRow(pageMov, "noclip", "Every character part passes through walls",
	CONFIG.noclip, function(v) end)
toggleRow(pageMov, "tpWalkRun", "Heartbeat-shift your root further down the move direction",
	false, function(v) end)
sliderRow(pageMov, "Tp-Walk Power", 1, 15, CONFIG.tpWalkPower,
	function(v) CONFIG.tpWalkPower = math.floor(v + 0.5) end)
toggleRow(pageMov, "fly", "Camera-relative flight — WASD to steer, E/Q for altitude",
	false, function(v) end)
sliderRow(pageMov, "Fly Speed", 1, 30, CONFIG.flySpeed,
	function(v) CONFIG.flySpeed = math.floor(v + 0.5) end)
toggleRow(pageMov, "spinMode", "Constant spin at the configured rate",
	CONFIG.spin, function(v) end)
sliderRow(pageMov, "Spin Rate", 1, 200, CONFIG.spinSpeed,
	function(v) CONFIG.spinSpeed = math.floor(v + 0.5) end)
sliderRow(pageMov, "Field of View", 30, 120, CONFIG.fovChanger, function(v)
	local value = math.floor(v + 0.5)
	CONFIG.fovChanger = value
	pcall(function() currentCam().FieldOfView = value end)
end)
toggleRow(pageMov, "antiAfk", "VirtualUser idle-click so Roblox never kicks you",
	CONFIG.antiAfk, function(v) CONFIG.antiAfk = v end)
toggleRow(pageMov, "noJumpCooldown", "Keeps JumpPower re-applied every frame",
	CONFIG.noJumpCooldown, function(v) CONFIG.noJumpCooldown = v end)
buttonRow(pageMov, "Reset Movement", function()
	CONFIG.walkSpeed, CONFIG.jumpPower = 16, 50
	CONFIG.tpWalkPower = 3
	log("movement values reset")
end)

-- ---------------------------------------------------------------------------
-- VISUALS PAGE
-- ---------------------------------------------------------------------------
section(pageVis, "ESP")
toggleRow(pageVis, "esp", "Billboard name plates with distance + HP",
	CONFIG.espBoxes, function(v) refreshEsp() end)
toggleRow(pageVis, "espNames", "Show the username line",
	CONFIG.espNames, function(v) CONFIG.espNames = v end)
toggleRow(pageVis, "espDist", "Show the meter distance line",
	CONFIG.espDistance, function(v) CONFIG.espDistance = v end)
toggleRow(pageVis, "espHp", "Show the HP percentage suffix",
	CONFIG.espHealthBar, function(v) CONFIG.espHealthBar = v end)
toggleRow(pageVis, "espTeam", "Color labels by team (cops blue / inmates orange / crims red)",
	CONFIG.espTeamColor, function(v) CONFIG.espTeamColor = v end)
toggleRow(pageVis, "espVisOnly", "Hide ESP when the target has no line of sight",
	CONFIG.espVisibleOnly, function(v) CONFIG.espVisibleOnly = v end)
section(pageVis, "Chams")
toggleRow(pageVis, "chams", "Highlight fills + outlines colored by team",
	false, function(v) refreshEsp() end)
toggleRow(pageVis, "chamsWall", "Also render team highlights through geometry",
	CONFIG.chamsThroughWalls, function(v)
		CONFIG.chamsThroughWalls = v
		for _, plr in ipairs(plrs:GetPlayers()) do
			applyChams(plr)
		end
	end)
section(pageVis, "Combat Aids")
toggleRow(pageVis, "showAimFov", "Show the aim FOV ring around your crosshair",
	CONFIG.showAimFov, function(v) CONFIG.showAimFov = v end)

-- ---------------------------------------------------------------------------
-- MISC PAGE
-- ---------------------------------------------------------------------------
section(pageMisc, "Session Tools")
buttonRow(pageMisc, "Rebind Remotes (post-patch)", function()
	local folder = remoteFolder()
	if folder then ItemHandler = folder:FindFirstChild("ItemHandler") end
	meleeEvent = rs:FindFirstChild("meleeEvent")
	shootingEvent = rs:FindFirstChild("ShootEvent")
	log("resync — melee=" .. tostring(not not meleeEvent) .. " shoot=" .. tostring(not not shootingEvent)
		.. " item=" .. tostring(not not ItemHandler))
end)
toggleRow(pageMisc, "killFeed", "Print a per-kill counter to the dev console",
	false, function(v) end)
buttonRow(pageMisc, "Hide Panel", function() window.Visible = false end)
buttonRow(pageMisc, "Unload Riot Hub", function()
	state.detached = true
	for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
	pcall(function() screenGui:Destroy() end)
	pcall(function() if fovRing then fovRing:Destroy() end end)
	pcall(function() if espContainer then espContainer:Destroy() end end)
	if getgenv then getgenv().RiotHub = nil end
	log("unloaded")
end)
section(pageMisc, "Config")
buttonRow(pageMisc, "Save Config", function()
	if writefile then
		pcall(function() writefile("RiotHubConfig.json", httpSvc:JSONEncode(CONFIG)) end)
		log("config persisted to RiotHubConfig.json")
	else
		getGenv().RiotHubConfig = CONFIG
		log("writefile unavailable — config cached in getgenv().RiotHubConfig")
	end
end)
buttonRow(pageMisc, "Load Config", function()
	local raw
	if writefile and readfile and isfile and isfile("RiotHubConfig.json") then
		raw = readfile("RiotHubConfig.json")
	elseif getGenv().RiotHubConfig then
		raw = httpSvc:JSONEncode(getGenv().RiotHubConfig)
	end
	if raw then
		local ok = pcall(function()
			local loaded = httpSvc:JSONDecode(raw)
			for k, v in pairs(loaded) do CONFIG[k] = v end
		end)
		log(ok and "config loaded" or "config parse failed", not ok)
	else
		log("no stored config found", true)
	end
end)

-- ---------------------------------------------------------------------------
-- SETTINGS PAGE
-- ---------------------------------------------------------------------------
section(pageCfg, "Keybinds")
local keybindLabel = make("TextLabel", {
	Text = "RightCtrl / U — toggle the panel\n"
		.. "G — kill aura toggle\n"
		.. "H — arrest aura toggle\n"
		.. "J — loop taze toggle\n"
		.. "WASD + E / Q — flight (with Fly on)\n"
		.. "F3 — open the prison gate",
	Size = UDim2.new(1, -8, 0, 116), BackgroundColor3 = Color3.fromRGB(25, 25, 30),
	Font = Enum.Font.Code, TextSize = 12, TextColor3 = Color3.fromRGB(196, 196, 206),
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
}, pageCfg)
corner(keybindLabel, 7)
pad(keybindLabel, 10)
section(pageCfg, "About")
local aboutLabel = make("TextLabel", {
	Text = "RiotHub v2.1.1 — self-contained, keyless, no external deps.\n"
		.. "Combat: aura loops (kill / arrest / taze), aimbot, silent aim,\ntrigger bot.\n"
		.. "Guns: pull every catalogued item from anywhere, rewrite GunStates live.\n"
		.. "Visuals: ESP + team chams + FOV ring. Movement: full suite.\n"
		.. "Every remote call is logged; the log pane shows which calls a\nserver renamed or patched after a dev update.",
	Size = UDim2.new(1, -8, 0, 128), BackgroundColor3 = Color3.fromRGB(25, 25, 30),
	Font = Enum.Font.Code, TextSize = 12, TextColor3 = Color3.fromRGB(196, 196, 206),
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
}, pageCfg)
corner(aboutLabel, 7)
pad(aboutLabel, 10)

-- ============================================================================
-- BACKGROUND WORKERS
-- ============================================================================
spawn(function()
	while not state.detached do
		task.wait(0.16)
		local myRoot = charRoot()
		if myRoot then
			if state.toggles.killAura then
				for _, plr in ipairs(plrs:GetPlayers()) do
					if plr ~= lp and state.toggles.killAura and not state.detached then
						local ch = plr.Character
						local hum = ch and ch:FindFirstChildOfClass("Humanoid")
						local theirRoot = ch and ch:FindFirstChild("HumanoidRootPart")
						if hum and hum.Health > 0 and theirRoot then
							local d = (theirRoot.Position - myRoot.Position).Magnitude
							if d <= CONFIG.killAuraRadius and selTarget(plr, "kAuraTargets") then
								if killTarget(plr) then
									state.killCount[plr.Name] = (state.killCount[plr.Name] or 0) + 1
									if state.toggles.killFeed then
										print(string.format("[RiotHub] kills on %s: %d",
											plr.Name, state.killCount[plr.Name]))
									end
								end
								task.wait(CONFIG.killAuraRate)
							end
						end
					end
				end
			end
			if state.toggles.arrestAura then
				for _, plr in ipairs(plrs:GetPlayers()) do
					if plr ~= lp and state.toggles.arrestAura and not state.detached and not isGuard(plr) then
						local ch = plr.Character
						local theirRoot = ch and ch:FindFirstChild("HumanoidRootPart")
						if theirRoot and not isCuffed(plr) then
							local d = (theirRoot.Position - myRoot.Position).Magnitude
							if d <= CONFIG.arrestAuraRadius then
								arrestTarget(plr)
								task.wait(CONFIG.arrestAuraRate)
							end
						end
					end
				end
			end
		end
	end
end)

spawn(function()
	while not state.detached do
		task.wait(0.4)
		if state.toggles.loopTaze then
			local taser = getTaser()
			if not taser then
				task.wait(2)
			else
				for _, plr in ipairs(plrs:GetPlayers()) do
					if plr ~= lp and state.toggles.loopTaze and not state.detached then
						tazeTarget(plr, taser)
						task.wait(CONFIG.tazeRate / 4)
					end
				end
			end
		end
	end
end)

spawn(function()
	while not state.detached do
		task.wait(0.5)
		if state.toggles.autoCollectRun then
			local myRoot = charRoot()
			if myRoot and ItemHandler and prisonTable() then
				for _, candidate in ipairs(prisonTable():GetDescendants()) do
					if state.detached or not state.toggles.autoCollectRun then break end
					if candidate.Name == "ITEMPICKUP" and candidate:IsA("BasePart") then
						local d = (candidate.Position - myRoot.Position).Magnitude
						if d <= CONFIG.autoCollectRadius then
							pace()
							vsafe(function()
								ItemHandler:InvokeServer({
									Position = myRoot.CFrame,
									Parent = candidate.Parent or candidate,
								})
							end)
						end
					end
				end
			end
		end
	end
end)

spawn(function()
	while not state.detached do
		task.wait(CONFIG.gateSpamInterval)
		if state.toggles.gateLoop then openGate() end
	end
end)

-- anti-afk
connect(lp.Idled, function()
	if not CONFIG.antiAfk then return end
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new())
	end)
end)

-- global keys
connect(uis.InputBegan, function(input, processed)
	if state.detached then return end
	local kc = input.KeyCode
	if kc == Enum.KeyCode.RightControl or kc == Enum.KeyCode.U then
		if not processed then window.Visible = not window.Visible end
	elseif kc == Enum.KeyCode.F3 then
		openGate()
	end
end)

-- click arrest while the panel is hidden
connect(mouse.Button1Down, function()
	if window.Visible or state.detached or not CONFIG.clickArrest then return end
	local t = mouse.Target
	if not (t and t.Parent) then return end
	local plr = plrs:GetPlayerFromCharacter(t.Parent)
	if plr and plr ~= lp and not isGuard(plr) then
		local remote = getArrestRemote()
		if remote then vsafe(function() remote:InvokeServer(t) end) end
	end
end)

-- respawn hook
connect(lp.CharacterAdded, function(ch)
	task.wait(0.4)
	if CONFIG.gunAutoOnRespawn then
		giveAllLoot()
		task.wait(4)
		modAllGuns()
	end
	if CONFIG.fovChanger ~= 70 then
		pcall(function() currentCam().FieldOfView = CONFIG.fovChanger end)
	end
	if state.toggles.antiTaze then disableTazerEffects() end
	pcall(function()
		local hum = ch:FindFirstChildOfClass("Humanoid")
		if hum and CONFIG.walkSpeed ~= 16 then hum.WalkSpeed = CONFIG.walkSpeed end
	end)
end)

-- team-change re-tint sweep (cheap)
spawn(function()
	while not state.detached do
		task.wait(2)
		if state.toggles.chams then
			for _, plr in ipairs(plrs:GetPlayers()) do
				if plr ~= lp then applyChams(plr) end
			end
		end
	end
end)

-- boot sequence
print("[RiotHub] stage 3: arming hooks (aimbot / silent aim / trigger / esp)")
buildFovRing()
setupAimbot()
setupTriggerBot()
setupSilentAim()
setupEspFrame()

getGenv().RiotHub = {
	Unload = function()
		state.detached = true
		for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
		pcall(function() screenGui:Destroy() end)
		pcall(function() if espContainer then espContainer:Destroy() end end)
	end,
	log = log,
	notify = notify,
	config = CONFIG,
}

log("riot hub v2.1.1 armed for " .. lp.Name)
notify("Riot Hub", "loaded - tap the RH button / RightCtrl to open", 4)
