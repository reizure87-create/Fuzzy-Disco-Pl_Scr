--[[
	RiotHub v3.0 — Prison Life all-in-one · keyless · single file
	No external loadstrings, no key gates, no pastebin dependencies.
	Runs on Delta / Solara / Codex / Xeno / Wave / KRNL / Synapse-family, mobile OK.

	HOW TO USE
	  1. Join Prison Life.
	  2. Paste this whole file into your executor and press Execute.
	  3. Tap the "RH" button on the left edge to open/close the hub.
	  4. PC keys: RightCtrl = panel, G = kill aura, H = arrest aura, J = taze loop.

	DESIGN NOTES
	  - Every remote call is pcall-guarded and logged; the log pane tells you
	    exactly which remote a dev patched instead of crashing the hub.
	  - ItemHandler calls are spaced 3.2s apart (server pacing, anti-cheat).
	  - The kill engine uses the ShootEvent bullet wire format the server
	    actually validates: {RayObject, Distance, Cframe, Color} + a GunStates
	    tool. Gun modding (require(tool.GunStates)) happens before firing so
	    damage is scaled server-side.
]]

-- ============================================================================
-- SERVICES / ENV
-- ============================================================================
local plrs    = game:GetService("Players")
local rs      = game:GetService("ReplicatedStorage")
local runSvc  = game:GetService("RunService")
local uis     = game:GetService("UserInputService")
local tweSvc  = game:GetService("TweenService")
local httpSvc = game:GetService("HttpService")
local starterGui = game:GetService("StarterGui")
local teleportSvc = game:GetService("TeleportService")
local virtualUser = game:GetService("VirtualUser")

local lp = plrs.LocalPlayer
-- Executors can inject before the local player exists (early-execute):
-- block here instead of hard-erroring below.
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
	if not _G.__RiotHubGenv then _G.__RiotHubGenv = {} end
	return _G.__RiotHubGenv
end

-- terminate a previous run cleanly so re-executions never double-spawn
pcall(function()
	if getGenv().RiotHub and getGenv().RiotHub.Unload then getGenv().RiotHub.Unload() end
end)
pcall(function()
	local candidates = {}
	if gethui then pcall(function() table.insert(candidates, gethui()) end) end
	table.insert(candidates, game:FindFirstChildOfClass("CoreGui"))
	table.insert(candidates, lp and lp:FindFirstChild("PlayerGui"))
	for _, parent in ipairs(candidates) do
		if parent then
			for _, name in ipairs({
				"RiotHub_GUI", "RiotHubFOVRing", "RiotHubEspOverlays",
				"RiotHub_FlyPad", "RiotHub_Toasts",
			}) do
				local old = parent:FindFirstChild(name)
				if old then old:Destroy() end
			end
		end
	end
end)

-- ============================================================================
-- CONFIG
-- ============================================================================
local CONFIG = {
	-- combat
	killAuraRadius   = 60,    killAuraRate = 0.30,
	killAuraIgnoreFF = true,  killAuraMode = "Fists",   -- "Fists" | "Gun"
	meleeBurstHits   = 4,     gunBulletsPerCall = 8,
	arrestAuraRadius = 120,   arrestAuraRate = 1.2,
	arrestSnap       = true,
	tazeRate         = 0.8,
	auraTargets      = "All", aimbotTargets = "All",
	triggerTargets   = "All",
	-- aim
	aimbotFov        = 160,   aimbotSmooth = 35,
	showAimFov       = true,
	silentFov        = 999,   silentHitChance = 100,
	silentWallCheck  = true,  silentRandomPart = false,
	-- guns
	gunChoice        = "M9",  modTarget = "All Tools",
	gunDamage        = 65,    gunBullets = 10,
	gunFireRate      = 0.001, gunSpread = 0,
	gunInfiniteAmmo  = true,  gunAutoFire = true,
	autoRearm        = false,
	-- visuals
	espNames         = true,  espDistance = true,
	espHealthBar     = true,  espTeamColor = true,
	espVisibleOnly   = false, espTracers = false,
	chamsThroughWalls = true,
	-- movement
	walkSpeed        = 16,    jumpPower = 50,
	tpWalkPower      = 3,     flySpeed = 3,
	spinSpeed        = 25,
	noStayStunned    = false,
	-- world
	gateSpamInterval = 1.5,
	autoCollectRadius = 200,
	-- system
	safePacing       = true,  itemPace = 3.2,
	maxLogLines      = 40,    clickArrest = false,
	clickTp          = false,
	reduceAnim       = false,
}

-- ============================================================================
-- STATE
-- ============================================================================
local state = {
	toggles      = {},   -- runtime switchboard [toggleId] = bool
	switches     = {},   -- [toggleId] = {Set=fn} so hotkeys can drive switches
	espUnits     = {},   -- [player] = unit table
	tracers      = {},   -- [player] = Drawing line
	killCounter  = 0,    -- combat actions fired this session
	arrestCount  = 0,
	itemCount    = 0,
	fps          = 60,
	detached     = false,
	logCounter   = 0,
	lastItemPull = 0,
	touchMove    = { fwd = 0, back = 0, up = 0, down = 0 }, -- fly pad state
	uiAnim       = 0.14, -- seconds; CONFIG.reduceAnim drops this to 0
}
local connections = {}

local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

-- ============================================================================
-- UTIL / LOG / NOTIFY
-- ============================================================================
-- arg spread across runtimes: 5.1-family executors expose a global `unpack`,
-- pure Luau only has table.unpack — accept both everywhere.
local function spread(t)
	if unpack then return unpack(t) end
	return table.unpack(t)
end

local function packArgs(...)
	local n, t = select("#", ...), {}
	for i = 1, n do t[i] = select(i, ...) end
	return t
end

-- pcall-guarded remote caller: a patched remote logs instead of crashing.
-- `log` is forward-declared here and BOUND below, so vsafe can always refer
-- to the one true local regardless of definition order.
local log
local function vsafe(fn, ...)
	local args = packArgs(...)
	local ok, err = pcall(function() fn(spread(args)) end)
	if not ok then log("remote call failed: " .. tostring(err):sub(1, 110), true) end
	return ok
end

-- toast() is declared here and REBOUND once the UI exists, so anything can
-- call it at any boot stage without nil-upvalue ordering problems.
toast = function() end

local logScroll, logText

log = function(msg, isErr)
	local body = tostring(msg)
	if #body > 150 then body = body:sub(1, 150) .. "..." end
	print("[RiotHub] " .. body)
	if logText then
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
			logScroll.CanvasSize = UDim2.new(0, 0, 0, n * 14 + 24)
			logScroll.CanvasPosition = Vector2.new(0, n * 14 + 24)
		end
	end
end

local function notify(title, text, dur)
	pcall(function()
		starterGui:SetCore("SendNotification", { Title = title, Text = text, Duration = dur or 3 })
	end)
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
-- REMOTE RESOLUTION (late binding, survives map updates)
-- ============================================================================
local function remoteFolder()
	return workspace:FindFirstChild("Remote")
end

local function getRemote(name, timeout)
	local folder = remoteFolder()
	if not folder then return nil end
	return folder:FindFirstChild(name) or folder:WaitForChild(name, timeout)
end

local ItemHandler, shootingEvent, meleeEvent

-- Remote binding is deliberately ASYNC: the GUI below builds instantly even
-- while the map is still streaming (a mobile "execute during load" would
-- otherwise stare at a blank screen for up to ~45s of sequential
-- WaitForChild calls before any UI appeared). giveItem() re-resolves on demand.
local function resolveRemotesAsync()
	task.spawn(function()
		local folder = remoteFolder() or workspace:WaitForChild("Remote", 15)
		if folder then
			ItemHandler = folder:FindFirstChild("ItemHandler")
				or folder:WaitForChild("ItemHandler", 10)
		end
		log("remotes — ItemHandler: " .. tostring(not not ItemHandler))
	end)
	task.spawn(function()
		meleeEvent = rs:WaitForChild("meleeEvent", 15)
	end)
	task.spawn(function()
		shootingEvent = rs:WaitForChild("ShootEvent", 15)
	end)
	task.spawn(function()
		task.wait(15)
		meleeEvent = meleeEvent or rs:FindFirstChild("meleeEvent")
		shootingEvent = shootingEvent or rs:FindFirstChild("ShootEvent")
		log("remotes — melee: " .. tostring(not not meleeEvent)
			.. " shoot: " .. tostring(not not shootingEvent)
			.. " (nil = slow map stream — run Server > Rebind Remotes)")
	end)
end
task.spawn(resolveRemotesAsync)

local function rebindRemotes(remoteFolderTimeout)
	local folder = remoteFolder() or workspace:WaitForChild("Remote", remoteFolderTimeout or 10)
	if folder then ItemHandler = folder:FindFirstChild("ItemHandler") or ItemHandler end
	meleeEvent = meleeEvent or rs:FindFirstChild("meleeEvent")
	shootingEvent = shootingEvent or rs:FindFirstChild("ShootEvent")
	local found = {
		melee = not not meleeEvent,
		shoot = not not shootingEvent,
		item = not not ItemHandler,
		arrest = not not getRemote("arrest"),
	}
	log("rebind — melee=" .. tostring(found.melee)
		.. " shoot=" .. tostring(found.shoot)
		.. " item=" .. tostring(found.item)
		.. " arrest=" .. tostring(found.arrest))
	return found
end

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
-- TEAM LOOKUPS
--   Bright blue = Guards · Bright orange = Inmates · Bright red = Criminals
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

local isCuffed -- forward-declared; bound in the combat section below
local function arrestables()
	local out = {}
	for _, plr in ipairs(plrs:GetPlayers()) do
		if plr ~= lp and not isGuard(plr) then
			local ch = plr.Character
			if ch and ch:FindFirstChild("HumanoidRootPart")
				and ch:FindFirstChildOfClass("Humanoid")
				and ch:FindFirstChildOfClass("Humanoid").Health > 0
				and not isCuffed(plr) then
				table.insert(out, plr)
			end
		end
	end
	return out
end

isCuffed = function(target)
	local ch = target and target.Character
	if not ch then return false end
	local head = ch:FindFirstChild("Head")
	if not head then return false end
	return head:FindFirstChild("handcuffedGui") ~= nil
end

-- ============================================================================
-- ITEM GRANTING
-- ============================================================================
local function giveItem(holder, label)
	if not ItemHandler then
		local folder = remoteFolder()
		if folder then
			ItemHandler = folder:FindFirstChild("ItemHandler") or folder:WaitForChild("ItemHandler", 4)
		end
	end
	if not ItemHandler then log("ItemHandler unavailable on this server", true) return false end
	pace()
	local ok = vsafe(function() ItemHandler:InvokeServer(holder) end)
	if ok then
		state.itemCount = state.itemCount + 1
		log("granted: " .. tostring(label or holder.Name or "?"))
	end
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
	task.spawn(function()
		log("granting full kit (paced, ~" .. tostring(math.ceil(#GIVEN_GUNS * CONFIG.itemPace)) .. "s)...")
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
		toast("Kit Granted", "All catalogued guns + tools pulled", 3)
	end)
end

local function giveRiotGear()
	task.spawn(function()
		if not giveAnywhere("Riot Shield") then giveLegacy("Riot Shield", "giver") end
		local hat = getItemIn("hats", "Police hat", "hat") or getItemIn("hats", "Riot helmet", "hat")
		if hat then giveItem(hat, "Riot helmet / hat") end
		local mask = getItemIn("hats", "Ski mask", "hat")
		if mask then giveItem(mask, "Ski mask") end
	end)
end

-- ============================================================================
-- GUN ENGINE — the ShootEvent wire payload the server validates
-- ============================================================================
local function gunState(tool)
	if not (tool and tool:FindFirstChild("GunStates")) then return nil end
	local gs
	pcall(function() gs = require(tool.GunStates) end)
	return gs
end

local function findGunTool(preferredName)
	local function sweep(container)
		if not container then return nil end
		if preferredName then
			local t = container:FindFirstChild(preferredName)
			if t and t:IsA("Tool") and t:FindFirstChild("GunStates") then return t end
		end
		for _, t in ipairs(container:GetChildren()) do
			if t:IsA("Tool") and t:FindFirstChild("GunStates") then return t end
		end
		return nil
	end
	local tool = sweep(lp.Character) or sweep(lp.Backpack)
	if not tool and preferredName then
		tool = sweep(lp.Character) or sweep(lp.Backpack)
	end
	return tool
end

-- Makes sure a GunStates tool exists: if not, grants the selected gun then
-- short-waits for it to land in the backpack. Returns nil when hopeless.
local function ensureGunTool(waitBudget)
	local tool = findGunTool(CONFIG.gunChoice) or findGunTool()
	if tool then return tool end
	if giveAnywhere(CONFIG.gunChoice) or giveLegacy(CONFIG.gunChoice, "giver") then
		for _ = 1, math.max(waitBudget or 6, 0) do
			task.wait(0.5)
			if state.detached then return nil end
			tool = findGunTool(CONFIG.gunChoice) or findGunTool()
			if tool then return tool end
		end
	end
	return nil
end

-- Bullet ring format: every entry the server reads must carry a RayObject, a
-- Distance, a Cframe (where the shot landed = what applies damage) and a Color.
local function buildBullets(targetPart, count)
	local bullets = {}
	for i = 1, count or 1 do
		bullets[i] = {
			RayObject = Ray.new(Vector3.new(0, 0, 0), Vector3.new(0.1, 0.1, 0.1)),
			Distance  = 25,
			Cframe    = targetPart and targetPart.CFrame or CFrame.new(),
			Color     = Color3.fromRGB(255, 255, 0),
		}
	end
	return bullets
end

local function bulletKill(plr, tool, count)
	if not shootingEvent then return false end
	local ch = plr and plr.Character
	if not ch then return false end
	if not (tool and tool:FindFirstChild("GunStates")) then return false end
	local part = ch:FindFirstChild("Head") or ch:FindFirstChild("UpperTorso")
		or ch:FindFirstChild("Torso") or ch:FindFirstChild("HumanoidRootPart")
	if not part then return false end
	local args = packArgs(buildBullets(part, count), tool)
	vsafe(function() shootingEvent:FireServer(spread(args)) end)
	return true
end

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
	task.spawn(function()
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
	task.spawn(function()
		local tool = (lp.Character and lp.Character:FindFirstChild(name))
			or (lp.Backpack and lp.Backpack:FindFirstChild(name))
		if not tool and name ~= "Taser" then
			giveAnywhere(name)
			for _ = 1, 12 do
				task.wait(0.25)
				tool = (lp.Character and lp.Character:FindFirstChild(name))
					or (lp.Backpack and lp.Backpack:FindFirstChild(name))
				if tool then break end
			end
		end
		if tool then
			modGun(tool)
			toast("Gun Modded", name .. " rewritten live", 2)
		else
			log(name .. " unavailable to mod", true)
		end
	end)
end

-- ============================================================================
-- COMBAT CORES — melee / kill / taze / arrest
-- ============================================================================
-- The fist path: meleeEvent applies punch damage server-side. Several hits
-- in quick succession down a target, so bursts matter.
local function meleeBurst(plr, hits)
	if not meleeEvent then return false end
	if not (plr and plr.Character
		and plr.Character:FindFirstChildOfClass("Humanoid")
		and plr.Character:FindFirstChildOfClass("Humanoid").Health > 0) then
		return false
	end
	for i = 1, hits or CONFIG.meleeBurstHits do
		if state.detached then return false end
		vsafe(function() meleeEvent:FireServer(plr) end)
		state.killCounter = state.killCounter + 1
		task.wait(0.05)
	end
	return true
end

-- One ShootEvent call per target: modded damage × bullets-in-table does the
-- actual killing, so the tool gets modded FIRST when missing.
local function gunKill(plr)
	local tool = findGunTool(CONFIG.gunChoice)
		or findGunTool()
		or ensureGunTool(4)
	if not tool then return false end
	pcall(function()
		local gs = gunState(tool)
		if gs and (gs.Damage or 0) < CONFIG.gunDamage then
			modGun(tool)
		end
	end)
	local ok = bulletKill(plr, tool, CONFIG.gunBulletsPerCall)
	if ok then state.killCounter = state.killCounter + 1 end
	return ok
end

local function killTarget(plr)
	if not (plr and plr.Character) then return false end
	local ff = plr.Character:FindFirstChildOfClass("ForceField")
	if ff and not CONFIG.killAuraIgnoreFF then return false end
	if CONFIG.killAuraMode == "Gun" then
		if gunKill(plr) then return true end
		local did = meleeBurst(plr, CONFIG.meleeBurstHits)
		return did == true
	end
	local did = meleeBurst(plr, CONFIG.meleeBurstHits)
	return did == true
end

local function killAll(kind)
	task.spawn(function()
		local mode = kind or CONFIG.killAuraMode
		local weapon = nil
		if mode == "Gun" then
			weapon = ensureGunTool(6)
			if not weapon then
				log("no gun obtainable — Kill All bursts with fists", true)
			end
		end
		local tool = weapon or findGunTool()
		for _, plr in ipairs(plrs:GetPlayers()) do
			if state.detached then return end
			if plr ~= lp and plr.Character then
				local hum = plr.Character:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 then
					if tool then
						bulletKill(plr, tool, CONFIG.gunBulletsPerCall)
						state.killCounter = state.killCounter + 1
					end
					meleeBurst(plr, CONFIG.meleeBurstHits)
					task.wait(0.08)
				end
			end
		end
		log("kill-all complete (" .. tostring(mode) .. ")")
		toast("Kill All", "Burst fired at everyone alive", 2, "ok")
	end)
end

local function tazeTarget(plr, taserTool)
	if not shootingEvent then return false end
	local ch = plr and plr.Character
	if not ch then return false end
	local part = ch:FindFirstChild("Torso") or ch:FindFirstChild("UpperTorso")
		or ch:FindFirstChild("HumanoidRootPart")
	if not part then return false end
	local args = packArgs(buildBullets(part, 1), taserTool)
	vsafe(function() shootingEvent:FireServer(spread(args)) end)
	return true
end

local function getTaser()
	return (lp.Character and lp.Character:FindFirstChild("Taser"))
		or (lp.Backpack and lp.Backpack:FindFirstChild("Taser"))
end

local function tazeAll()
	task.spawn(function()
		local taser = getTaser()
		if not taser then
			if giveAnywhere("Taser") then
				for _ = 1, 8 do
					task.wait(0.5)
					taser = getTaser()
					if taser then break end
				end
			end
		end
		if not taser then
			log("Taser unavailable — taze burst aborted (guard team grants it)", true)
			toast("No Taser", "Switch to Guard to receive a Taser", 3, "err")
			return
		end
		for _, plr in ipairs(plrs:GetPlayers()) do
			if state.detached then return end
			if plr ~= lp then
				tazeTarget(plr, taser)
				task.wait(CONFIG.tazeRate / 4)
			end
		end
		log("taze-all complete")
		toast("Taze All", "Whole server shocked", 2, "ok")
	end)
end

local function getArrestRemote()
	return getRemote("arrest") or getRemote("Arrest")
end

-- Arrest is a RemoteFunction: standing behind the target while invoking is
-- the shape the server expects (snapTo handles the positioning side).
local function arrestOnce(target)
	local remote = getArrestRemote()
	if not remote then
		log("arrest remote unavailable on this server", true)
		return false
	end
	local theirRoot = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not theirRoot then return false end
	if CONFIG.arrestSnap then
		local myRoot = charRoot()
		if myRoot then
			myRoot.CFrame = theirRoot.CFrame * CFrame.new(0, 0, 1.4)
		end
	end
	vsafe(function() remote:InvokeServer(theirRoot) end)
	return true
end

local function arrestTarget(target)
	local cuffed = false
	for i = 1, 10 do
		if state.detached then return false end
		arrestOnce(target)
		task.wait(0.08)
		if isCuffed(target) then
			cuffed = true
			break
		end
	end
	return cuffed
end

local function arrestNearest()
	local myRoot = charRoot()
	if not myRoot then return false end
	local best, bestD = nil, math.huge
	for _, plr in ipairs(arrestables()) do
		local theirRoot = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		if theirRoot then
			local d = (theirRoot.Position - myRoot.Position).Magnitude
			if d < bestD then best, bestD = plr, d end
		end
	end
	if not best then return false end
	local got = arrestTarget(best)
	if got then
		state.arrestCount = state.arrestCount + 1
		toast("Arrested", best.Name .. " is cuffed", 2, "ok")
	else
		toast("Cuffs Needed", "No handcuffs / out of range", 2, "err")
	end
	return got
end

local function arrestAll()
	task.spawn(function()
		local n = 0
		for _, plr in ipairs(arrestables()) do
			if state.detached then return end
			if arrestTarget(plr) then n = n + 1 end
			task.wait(0.4)
		end
		state.arrestCount = state.arrestCount + n
		log("arrest-all cuffed " .. n .. " player(s)")
		toast("Arrest All", "Cuffed " .. n .. " player(s)", 2, "ok")
	end)
end

-- ============================================================================
-- WORLD — gate / doors / teams
-- ============================================================================
local function openGate()
	task.spawn(function()
		local gateBtn = getItemIn("buttons", "Prison Gate", "Prison Gate")
		if not gateBtn then
			log("Prison Gate button not present on this map", true)
			return
		end
		local ok = giveItem(gateBtn, "Prison Gate")
		if ok then toast("Gate Open", "Prison gate fired remotely", 2, "ok")
		else log("gate open rejected (server-side validation?)", true) end
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
-- TEAM SWITCH / BECOME CRIMINAL
-- ============================================================================
local function switchTeam(kind)
	task.spawn(function()
		local teamR, loadChar = getRemote("TeamEvent"), getRemote("loadchar")
		if not (teamR and loadChar) then
			if not teamR then teamR = workspace:FindFirstChild("Remote")
				and workspace.Remote:FindFirstChild("TeamEvent") end
		end
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
			vsafe(function() loadChar:InvokeServer(lp.Name, "Medium stone grey") end)
		end
		log("team switch -> " .. kind)
		toast("Team Switch", "Became " .. tostring(kind), 2, "ok")
	end)
end

local function becomeCriminal()
	task.spawn(function()
		local pivot
		local crimSpawn = workspace:FindFirstChild("Criminals Spawn")
		if crimSpawn then
			local sl = crimSpawn:FindFirstChildWhichIsA("SpawnLocation", true)
				or crimSpawn:FindFirstChildWhichIsA("BasePart", true)
			if sl then pivot = sl.CFrame end
		end
		if not pivot then pivot = CFrame.new(-938.77, 96, 2063.85) end
		local myRoot = charRoot()
		if myRoot then
			myRoot.CFrame = pivot + Vector3.new(0, 3, 0)
		end
		task.wait(0.6)
		log("criminal conversion executed (spawn-touch method)")
		toast("Criminal", "Touched the criminal fence", 2, "ok")
	end)
end

-- ============================================================================
-- MOVEMENT ENGINE — one Heartbeat consumes every movement toggle. Includes a
-- TOUCH fly path (mobile has no WASD): the on-screen fly pad writes into
-- state.touchMove and the engine turns it into camera-relative motion.
-- ============================================================================
local function applyMovementFrame(dt)
	local ch = lp.Character
	if not (ch and ch.PrimaryPart) then return end
	local rootPart = ch.PrimaryPart
	local hum = ch:FindFirstChildOfClass("Humanoid")
	if not hum then return end

	-- enforce chosen locomotion constants
	if hum.WalkSpeed ~= CONFIG.walkSpeed and (CONFIG.walkSpeed ~= 16 or state.toggles.antiTaze) then
		hum.WalkSpeed = CONFIG.walkSpeed
	end
	if CONFIG.jumpPower ~= 50 and hum.JumpPower ~= CONFIG.jumpPower then
		hum.JumpPower = CONFIG.jumpPower
	end
	-- un-stun watchdog (taze sets WalkSpeed 0)
	if CONFIG.noStayStunned and hum.WalkSpeed == 0 then
		hum.WalkSpeed = math.max(CONFIG.walkSpeed, 16)
	end

	if state.toggles.tpWalkOn and hum.MoveDirection.Magnitude > 0.3 then
		rootPart.CFrame = rootPart.CFrame + hum.MoveDirection * CONFIG.tpWalkPower
	end

	if state.toggles.spinOn then
		rootPart.CFrame = rootPart.CFrame * CFrame.Angles(0, math.rad(CONFIG.spinSpeed) * dt, 0)
	end

	if state.toggles.flyOn then
		local camera = currentCam()
		if camera then
			local moveDir = Vector3.new(0, 0, 0)
			if uis:IsKeyDown(Enum.KeyCode.W) then moveDir = moveDir + camera.CFrame.LookVector end
			if uis:IsKeyDown(Enum.KeyCode.S) then moveDir = moveDir - camera.CFrame.LookVector end
			if uis:IsKeyDown(Enum.KeyCode.A) then moveDir = moveDir - camera.CFrame.RightVector end
			if uis:IsKeyDown(Enum.KeyCode.D) then moveDir = moveDir + camera.CFrame.RightVector end
			-- touch pad contributions (mobile)
			local tm = state.touchMove
			moveDir = moveDir + camera.CFrame.LookVector * (tm.fwd - tm.back)
			local lift = tm.up - tm.down
			if uis:IsKeyDown(Enum.KeyCode.E) then lift = lift + 1 end
			if uis:IsKeyDown(Enum.KeyCode.Q) then lift = lift - 1 end
			rootPart.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			rootPart.CFrame = rootPart.CFrame
				+ (moveDir * CONFIG.flySpeed * 2.2 * dt)
				+ Vector3.new(0, lift * CONFIG.flySpeed * 1.6 * dt, 0)
		end
	end

	if state.toggles.noclipOn then
		for _, p in ipairs(ch:GetDescendants()) do
			if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
		end
	end
end
connect(runSvc.Heartbeat, applyMovementFrame)

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
				local show = CONFIG.showAimFov and (state.toggles.aimOn or state.toggles.silentOn)
				ring.Visible = show
				if show then
					local diameter = 2 * math.tan(math.rad(CONFIG.aimbotFov) / 2)
						/ math.tan(math.rad(camera.FieldOfView) / 2)
						* (camera.ViewportSize.Y / 2)
					ring.Size = UDim2.fromOffset(diameter, diameter)
				end
			end
		end
		if not state.toggles.aimOn then return end
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
-- SILENT AIM — hook the FireServer namecall and re-point bullet Cframes at
-- the nearest head, so shots the GUN sends land where you want.
-- ============================================================================
local hookInstalled = false
local function setupSilentAim()
	task.spawn(function()
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
			if self == shootingEvent and state.toggles.silentOn and type(args[1]) == "table" then
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
									b.Cframe = (math.random() < 0.5) and best.CFrame or other.CFrame
								else
									b.Cframe = best.CFrame
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
		if state.detached or not state.toggles.triggerOn then return end
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
-- VISUALS — ESP (billboard units), chams (Highlight), tracers (Drawing lines),
-- fullbright, fps-boost. All client-side, all reversible.
-- ============================================================================
local espContainer
local function ensureEspContainer()
	if espContainer then return espContainer end
	espContainer = Instance.new("Folder")
	espContainer.Name = "RiotHubEspOverlays"
	espContainer.Parent = lp:WaitForChild("PlayerGui", 10)
		or (gethui and gethui())
		or game:FindFirstChildOfClass("CoreGui")
	return espContainer
end

local function applyChams(plr)
	pcall(function()
		local ch = plr.Character
		if not ch then return end
		local hil = ch:FindFirstChild("RiotHub_Cham")
		if not state.toggles.chamsOn then
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
		local ch = plr and plr.Character
		if ch then
			local hil = ch:FindFirstChild("RiotHub_Cham")
			if hil then hil:Destroy() end
		end
	end)
end

local function teamTint(plr)
	return isGuard(plr) and Color3.fromRGB(110, 170, 255)
		or isInmate(plr) and Color3.fromRGB(255, 165, 70)
		or isCrim(plr) and Color3.fromRGB(255, 90, 90)
		or Color3.fromRGB(220, 220, 220)
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
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 14
	nameLabel.TextColor3 = Color3.new(1, 1, 1)
	nameLabel.TextStrokeTransparency = 0.3
	nameLabel.Parent = bb

	local distLabel = Instance.new("TextLabel")
	distLabel.Name = "DistLabel"
	distLabel.Size = UDim2.new(1, 0, 0.5, 0)
	distLabel.Position = UDim2.new(0, 0, 0.5, 0)
	distLabel.BackgroundTransparency = 1
	distLabel.Font = Enum.Font.Gotham
	distLabel.TextSize = 12
	distLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
	distLabel.TextStrokeTransparency = 0.45
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
			if state.toggles.espOn then
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

-- Drawing-API tracers (Delta exposes Drawing; guarded anyway)
local drawingOk = pcall(function() return Drawing end) and Drawing ~= nil
local function destroyTracer(plr)
	local line = state.tracers[plr]
	if line then
		pcall(function() line:Remove() end)
		state.tracers[plr] = nil
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
			local visible = (state.toggles.espOn == true) and (head ~= nil) and (hum ~= nil)
			if visible and hum.Health <= 0 then visible = false end
			if visible and CONFIG.espVisibleOnly then
				local ok, vis = pcall(function()
					local params = RaycastParams.new()
					params.FilterType = Enum.RaycastFilterType.Exclude
					params.FilterDescendantsInstances = { lp.Character, ch }
					local hit = workspace:Raycast(camera.CFrame.Position,
						head.Position - camera.CFrame.Position, params)
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
					unit.nameLabel.TextColor3 = teamTint(plr)
				else
					unit.nameLabel.TextColor3 = Color3.new(1, 1, 1)
				end
			end
			-- tracers
			if drawingOk and CONFIG.espTracers and visible then
				local ok, sx, sy = pcall(function()
					local vp = camera:WorldToViewportPoint(head.Position)
					return vp.X, vp.Y, vp.Z
				end)
				if ok and sx and sy and (sy > 0 or (sx ~= nil)) then
					pcall(function()
						local vp = camera:WorldToViewportPoint(head.Position)
						if vp.Z <= 0 then
							destroyTracer(plr)
							return
						end
						local line = state.tracers[plr]
						if not line then
							line = Drawing.new("Line")
							line.Thickness = 1.4
							line.Transparency = 0.7
							state.tracers[plr] = line
						end
						line.From = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y)
						line.To = Vector2.new(vp.X, vp.Y)
						line.Color = teamTint(plr)
						line.Visible = true
					end)
				else
					destroyTracer(plr)
				end
			else
				destroyTracer(plr)
			end
		end
	end)
	table.insert(connections, conn)
end

-- fullbright + fps boost (client-side, reversible)
local savedLighting = nil
local function setFullbright(on)
	pcall(function()
		local light = game:GetService("Lighting")
		if on then
			if not savedLighting then
				savedLighting = {
					Ambient = light.Ambient, OutdoorAmbient = light.OutdoorAmbient,
					Brightness = light.Brightness, FogEnd = light.FogEnd,
					ClockTime = light.ClockTime, GlobalShadows = light.GlobalShadows,
				}
			end
			light.Ambient = Color3.new(1, 1, 1)
			light.OutdoorAmbient = Color3.new(1, 1, 1)
			light.Brightness = 3
			light.FogEnd = 1e10
			light.ClockTime = 14
			light.GlobalShadows = false
		elseif savedLighting then
			light.Ambient = savedLighting.Ambient
			light.OutdoorAmbient = savedLighting.OutdoorAmbient
			light.Brightness = savedLighting.Brightness
			light.FogEnd = savedLighting.FogEnd
			light.ClockTime = savedLighting.ClockTime
			light.GlobalShadows = savedLighting.GlobalShadows
		end
	end)
end

local fpsBoostConn
local function setFpsBoost(on)
	if fpsBoostConn then
		fpsBoostConn:Disconnect()
		fpsBoostConn = nil
	end
	if not on then return end
	pcall(function()
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke")
				or d:IsA("Fire") or d:IsA("Beam") then
				pcall(function() d.Enabled = false end)
			elseif d:IsA("Decal") and d.Parent and not d.Parent:IsA("Tool") then
				pcall(function() d.Transparency = 1 end)
			end
		end
		fpsBoostConn = connect(workspace.DescendantAdded, function(d)
			if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke")
				or d:IsA("Fire") or d:IsA("Beam") then
				pcall(function() d.Enabled = false end)
			end
		end)
	end)
end

-- ============================================================================
-- UI ENGINE v3 — responsive window, animated switches, touch-correct sliders,
-- toasts, fly pad. PlayerGui-first parenting (proven on Delta).
-- ============================================================================
print("[RiotHub] stage 2: building GUI")
if CONFIG.reduceAnim then state.uiAnim = 0 end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "RiotHub_GUI"
screenGui.IgnoreGuiInset = true
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local uiParent = lp:WaitForChild("PlayerGui", 10)
if not uiParent and gethui then pcall(function() uiParent = gethui() end) end
if not uiParent then uiParent = game:FindFirstChildOfClass("CoreGui") end
screenGui.Parent = uiParent

local THEME = {
	bg        = Color3.fromRGB(12, 13, 17),
	surface   = Color3.fromRGB(18, 19, 25),
	card      = Color3.fromRGB(26, 28, 35),
	cardUp    = Color3.fromRGB(35, 38, 47),
	stroke    = Color3.fromRGB(46, 49, 60),
	text      = Color3.fromRGB(235, 237, 243),
	textDim   = Color3.fromRGB(139, 143, 155),
	accent    = Color3.fromRGB(255, 73, 90),
	accentDk  = Color3.fromRGB(120, 34, 42),
	green     = Color3.fromRGB(88, 214, 141),
	amber     = Color3.fromRGB(255, 183, 77),
}

local function make(class, props, parent)
	local obj = Instance.new(class)
	for k, v in pairs(props) do obj[k] = v end
	if parent then obj.Parent = parent end
	return obj
end
local function corner(o, r)
	return make("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o)
end
local function pad(el, l, r, t, b)
	return make("UIPadding", {
		PaddingLeft = UDim.new(0, l or 0), PaddingRight = UDim.new(0, r or 0),
		PaddingTop = UDim.new(0, t or 0), PaddingBottom = UDim.new(0, b or 0),
	}, el)
end
local function stroke(o, color, thickness)
	return make("UIStroke", {
		Color = color or THEME.stroke, Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, o)
end
local function tw(obj, goal, dur)
	local ti = TweenInfo.new(dur or state.uiAnim, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	return tweSvc:Create(obj, ti, goal)
end

-- WINDOW — clamped to the viewport so phones get a full-bleed feel
local view = currentCam() and currentCam().ViewportSize or Vector2.new(1280, 720)
local winW = math.clamp(view.X - 24, 380, 660)
local winH = math.clamp(view.Y - 120, 300, 470)

local window = make("Frame", {
	Name = "Window",
	Size = UDim2.fromOffset(winW, winH),
	Position = UDim2.new(0.5, -winW / 2, 0.5, -winH / 2),
	BackgroundColor3 = THEME.bg, BorderSizePixel = 0,
}, screenGui)
corner(window, 14)
stroke(window, THEME.stroke, 1)
make("UIScale", { Scale = 1 }, window)

-- universal touch/mouse drag (Draggable=true is deprecated-broken on touch)
local function enableDrag(frame, handle)
	local dragging, dragStart, startPos = false, nil, nil
	handle.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1
			or io.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = io.Position
			startPos = frame.Position
		end
	end)
	local function onChange(io)
		if not dragging then return end
		if io.UserInputType == Enum.UserInputType.MouseMovement
			or io.UserInputType == Enum.UserInputType.Touch then
			local delta = Vector2.new(
				io.Position.X - dragStart.X, io.Position.Y - dragStart.Y)
			frame.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + delta.X,
				startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end
	handle.InputChanged:Connect(onChange)
	connect(uis.InputChanged, onChange)
	local function onEnd()
		dragging = false
	end
	connect(uis.InputEnded, onEnd)
end
-- window drag is attached to the TOPBAR only (created below) — attaching to
-- the whole frame would hijack every row tap on touch devices

local function pingButton(btn)
	local from = btn.BackgroundColor3
	tw(btn, { BackgroundColor3 = THEME.cardUp }, 0.06)
	task.delay(0.07, function()
		pcall(function() tw(btn, { BackgroundColor3 = from }, 0.12) end)
	end)
end

-- FLY PAD — on-screen arrows so Fly works on a phone
local flyPad = make("Frame", {
	Name = "FlyPad", Visible = false, BackgroundTransparency = 1,
	Size = UDim2.fromOffset(232, 150),
	Position = UDim2.new(1, -248, 1, -164),
}, screenGui)
local function flyButton(label, prop, amount)
	local btn = make("TextButton", {
		Text = label, Font = Enum.Font.GothamBold, TextSize = 15,
		TextColor3 = THEME.text, BackgroundColor3 = THEME.card,
		BackgroundTransparency = 0.25, BorderSizePixel = 0, AutoButtonColor = false,
		TextTransparency = 0.1,
	}, flyPad)
	corner(btn, 10)
	stroke(btn, THEME.stroke)
	local touched = false
	local function set(onoff)
		touched = onoff
		state.touchMove[prop] = onoff and amount or 0
		tw(btn, { BackgroundTransparency = onoff and 0 or 0.25 }, 0.08)
	end
	btn.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1
			or io.UserInputType == Enum.UserInputType.Touch then set(true) end
	end)
	btn.InputEnded:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1
			or io.UserInputType == Enum.UserInputType.Touch then set(false) end
	end)
	btn.MouseLeave:Connect(function() set(false) end)
	return btn
end
local btnFwd = flyButton("FWD", "fwd", 1)
btnFwd.Size = UDim2.fromOffset(68, 40)
btnFwd.Position = UDim2.new(0, 82, 0, 0)
local btnBack = flyButton("BCK", "back", 1)
btnBack.Size = UDim2.fromOffset(68, 40)
btnBack.Position = UDim2.new(0, 82, 0, 108)
local btnUp = flyButton("UP", "up", 1)
btnUp.Size = UDim2.fromOffset(68, 40)
btnUp.Position = UDim2.new(0, 0, 0, 54)
local btnDown = flyButton("DN", "down", 1)
btnDown.Size = UDim2.fromOffset(68, 40)
btnDown.Position = UDim2.new(0, 164, 0, 54)

-- TOASTS — custom notification stack (SetCore can silently fail on Delta)
local toastHost = make("Frame", {
	Name = "ToastHost", BackgroundTransparency = 1,
	Position = UDim2.new(1, -16, 0, 16),
	Size = UDim2.new(0, 240, 1, -32),
	AnchorPoint = Vector2.new(1, 0),
}, screenGui)
make("UIListLayout", {
	Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder,
	HorizontalAlignment = Enum.HorizontalAlignment.Right,
}, toastHost)

toast = function(title, body, dur, kind)
	if state.detached then return end
	pcall(function()
		local card = make("Frame", {
			BackgroundColor3 = THEME.card, BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 56), ZIndex = 50,
		}, toastHost)
		corner(card, 10)
		stroke(card, kind == "err" and THEME.accentDk
			or kind == "ok" and Color3.fromRGB(40, 90, 60) or THEME.stroke)
		local bar = make("Frame", {
			Size = UDim2.new(0, 4, 1, -12), Position = UDim2.new(0, 6, 0, 6),
			BackgroundColor3 = kind == "err" and THEME.accent
				or kind == "ok" and THEME.green or THEME.accent, BorderSizePixel = 0,
		}, card)
		corner(bar, 2)
		make("TextLabel", {
			Text = title, Font = Enum.Font.GothamBold, TextSize = 13,
			TextColor3 = THEME.text, BackgroundTransparency = 1,
			Size = UDim2.new(1, -26, 0, 18), Position = UDim2.new(0, 18, 0, 9),
			TextXAlignment = Enum.TextXAlignment.Left,
		}, card)
		make("TextLabel", {
			Text = body or "", Font = Enum.Font.Gotham, TextSize = 12,
			TextColor3 = THEME.textDim, BackgroundTransparency = 1,
			Size = UDim2.new(1, -26, 0, 20), Position = UDim2.new(0, 18, 0, 27),
			TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
		}, card)
		card.Position = UDim2.new(1, 20, 0, 0)
		tw(card, { Position = UDim2.new(0, 0, 0, 0) }, 0.2):Play()
		task.delay(math.max((dur or 2.5), 0.3), function()
			if card.Parent then
				tw(card, {
					BackgroundTransparency = 1,
					Position = UDim2.new(1, 20, 0, 0),
				}, 0.2):Play()
				task.wait(0.24)
				pcall(function() card:Destroy() end)
			end
		end)
	end)
end

-- floating mobile toggle (draggable + tap honored via movement threshold)
local toggleFab = make("TextButton", {
	Name = "ToggleFab", Text = "RH",
	Size = UDim2.fromOffset(46, 46),
	Position = UDim2.new(0, 12, 0.5, -23),
	BackgroundColor3 = THEME.card, BorderSizePixel = 0,
	Font = Enum.Font.GothamBold, TextSize = 15,
	TextColor3 = THEME.accent,
	Active = true, AutoButtonColor = false, ZIndex = 40,
}, screenGui)
corner(toggleFab, 23)
stroke(toggleFab, THEME.accentDk, 1.5)
local fabDragged = false
do
	local dragging, moved = false, 0
	local dragStart, startPos
	toggleFab.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1
			or io.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			moved = 0
			dragStart = io.Position
			startPos = toggleFab.Position
		end
	end)
	local function onChange(io)
		if not dragging then return end
		if io.UserInputType == Enum.UserInputType.MouseMovement
			or io.UserInputType == Enum.UserInputType.Touch then
			local d = Vector2.new(io.Position.X - dragStart.X, io.Position.Y - dragStart.Y)
			moved = d.Magnitude
			if moved > 6 then fabDragged = true end
			toggleFab.Position = UDim2.new(
				startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end
	toggleFab.InputChanged:Connect(onChange)
	connect(uis.InputChanged, onChange)
	connect(uis.InputEnded, function()
		if dragging and moved <= 6 then
			pingButton(toggleFab)
			window.Visible = not window.Visible
		end
		dragging = false
		task.delay(0.1, function() fabDragged = false end)
	end)
end

-- top bar
local topBar = make("Frame", {
	Name = "TopBar", Size = UDim2.new(1, 0, 0, 42),
	BackgroundColor3 = THEME.surface, BorderSizePixel = 0,
}, window)
corner(topBar, 14)
make("Frame", {   -- square off the bottom of the rounded topbar
	Size = UDim2.new(1, 0, 0, 10), Position = UDim2.new(0, 0, 1, -10),
	BackgroundColor3 = THEME.surface, BorderSizePixel = 0,
}, topBar)
local accentBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2),
	BackgroundColor3 = THEME.accent, BorderSizePixel = 0,
}, topBar)
local grad = make("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, THEME.accent),
		ColorSequenceKeypoint.new(0.55, THEME.accentDk),
		ColorSequenceKeypoint.new(1, THEME.bg),
	}),
}, accentBar)
make("TextLabel", {
	Text = "RIOTHUB v3 · PRISON LIFE", Font = Enum.Font.GothamBold, TextSize = 15,
	TextColor3 = THEME.text, BackgroundTransparency = 1,
	Size = UDim2.new(1, -96, 1, 0), Position = UDim2.new(0, 14, 0, 0),
	TextXAlignment = Enum.TextXAlignment.Left,
}, topBar)
make("TextLabel", {
	Text = "keyless · single file", Font = Enum.Font.Gotham, TextSize = 11,
	TextColor3 = THEME.textDim, BackgroundTransparency = 1,
	Size = UDim2.new(0, 160, 1, 0), Position = UDim2.new(0, 14, 0, 0),
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Bottom,
	TextTransparency = 0.25,
}, topBar)
local hideBtn = make("TextButton", {
	Text = "–", Size = UDim2.new(0, 40, 1, 0), Position = UDim2.new(1, -84, 0, 0),
	BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
	TextColor3 = THEME.textDim, TextSize = 18,
}, topBar)
local closeBtn = make("TextButton", {
	Text = "✕", Size = UDim2.new(0, 40, 1, 0), Position = UDim2.new(1, -44, 0, 0),
	BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
	TextColor3 = THEME.accent, TextSize = 15,
}, topBar)
hideBtn.MouseButton1Click:Connect(function() window.Visible = false end)
closeBtn.MouseButton1Click:Connect(function()
	window.Visible = false
	toast("Hub Hidden", "Tap the RH button to reopen", 2)
end)
enableDrag(window, topBar) -- topbar is our drag handle

-- sidebar + content
local tabsRail = make("ScrollingFrame", {
	Size = UDim2.new(0, 128, 1, -42 - 26), Position = UDim2.new(0, 0, 0, 42),
	BackgroundTransparency = 1, BorderSizePixel = 0,
	CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 2,
}, window)
make("UIListLayout", { Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder }, tabsRail)
pad(tabsRail, 6, 3, 6)

local contentHolder = make("ScrollingFrame", {
	Size = UDim2.new(1, -140, 1, -42 - 26 - 70),
	Position = UDim2.new(0, 134, 0, 42),
	BackgroundColor3 = THEME.surface, BorderSizePixel = 0,
	CanvasSize = UDim2.new(0, 0, 0, 0), ScrollBarThickness = 3,
	ScrollingDirection = Enum.ScrollingDirection.Y,
}, window)
corner(contentHolder, 10)
pad(contentHolder, 4, 10, 6)

-- footer: status line + collapsible log
local statusRow = make("Frame", {
	Name = "StatusRow", Size = UDim2.new(1, 0, 0, 24),
	Position = UDim2.new(0, 0, 1, -24 - 0), BackgroundTransparency = 1,
	ZIndex = 5, -- must render ABOVE the log panel so the LOG button stays tappable
}, window)
local statusLabel = make("TextLabel", {
	Text = "starting...", Font = Enum.Font.Gotham, TextSize = 11,
	TextColor3 = THEME.textDim, BackgroundTransparency = 1,
	Size = UDim2.new(1, -90, 1, 0), Position = UDim2.new(0, 10, 0, 0),
	TextXAlignment = Enum.TextXAlignment.Left,
}, statusRow)
local logBtn = make("TextButton", {
	Text = "LOG ▲", Font = Enum.Font.GothamBold, TextSize = 11,
	TextColor3 = THEME.text, BackgroundColor3 = THEME.card, BorderSizePixel = 0,
	Size = UDim2.new(0, 70, 0, 18), Position = UDim2.new(1, -78, 0, 3),
	AutoButtonColor = false,
}, statusRow)
corner(logBtn, 6)
local logPanel = make("Frame", {
	Name = "LogPanel", Size = UDim2.new(1, 0, 0, 64),
	Position = UDim2.new(0, 0, 1, -64), BackgroundColor3 = THEME.bg,
	BorderSizePixel = 0, Visible = false,
}, window)
pad(logPanel, 6, 6, 2)
logScroll = make("ScrollingFrame", {
	Name = "LogScroll", Size = UDim2.new(1, -8, 1, -4),
	BackgroundTransparency = 1, BorderSizePixel = 0,
	CanvasSize = UDim2.new(0, 0, 0, 40), ScrollBarThickness = 2,
}, logPanel)
logText = make("TextLabel", {
	Name = "LogText", Text = "RiotHub v3.0 — session log",
	Size = UDim2.new(1, -8, 0, 20), BackgroundTransparency = 1,
	Font = Enum.Font.Code, TextColor3 = Color3.fromRGB(120, 235, 170),
	TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
	TextSize = 12,
}, logScroll)
local logOpen = false
logBtn.MouseButton1Click:Connect(function()
	logOpen = not logOpen
	logBtn.Text = logOpen and "LOG ▼" or "LOG ▲"
	logPanel.Visible = logOpen
end)

-- tab framework
local tabButtons = {}
local activeTabEntry = nil

local function newTab(label)
	local btn = make("TextButton", {
		Text = label, Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = THEME.bg,
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = THEME.textDim,
		AutoButtonColor = false, BorderSizePixel = 0,
	}, tabsRail)
	pad(btn, 10)
	corner(btn, 8)
	local bar = make("Frame", {
		Size = UDim2.new(0, 3, 0, 14), Position = UDim2.new(0, 4, 0.5, -7),
		BackgroundColor3 = THEME.textDim, BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
	}, btn)
	corner(bar, 2)

	local page = make("Frame", {
		Name = label:gsub("[^%a]", "") .. "Page",
		Size = UDim2.new(1, -10, 1, 0),
		BackgroundTransparency = 1, Visible = false,
	}, contentHolder)
	make("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }, page)

	local entry = { txt = btn, page = page, bar = bar }
	btn.MouseButton1Click:Connect(function()
		if activeTabEntry == entry then return end
		if activeTabEntry then
			activeTabEntry.page.Visible = false
			activeTabEntry.txt.BackgroundColor3 = THEME.bg
			activeTabEntry.txt.TextColor3 = THEME.textDim
			tw(activeTabEntry.bar, { BackgroundTransparency = 0.35 }, 0.12)
		end
		activeTabEntry = entry
		btn.BackgroundColor3 = THEME.card
		btn.TextColor3 = THEME.text
		tw(entry.bar, { BackgroundTransparency = 0 }, 0.12)
		page.Visible = true
		contentHolder.CanvasPosition = Vector2.new(0, 0)
	end)
	return page
end

local function ensureCanvas(page)
	local list = page:FindFirstChildOfClass("UIListLayout")
	if list then
		connect(list:GetPropertyChangedSignal("AbsoluteContentSize"), function()
			contentHolder.CanvasSize = UDim2.new(0, 0, 0, list.AbsoluteContentSize.Y + 20)
		end)
	end
end

-- ---------------------------------------------------------------------------
-- COMPONENTS
-- ---------------------------------------------------------------------------
local function section(page, label)
	local row = make("Frame", {
		Size = UDim2.new(1, -8, 0, 24), BackgroundTransparency = 1,
	}, page)
	make("TextLabel", {
		Text = string.upper(label), Font = Enum.Font.GothamBold, TextSize = 11,
		TextColor3 = THEME.accent, BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	make("Frame", {
		Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -2),
		BackgroundColor3 = THEME.stroke, BackgroundTransparency = 0.6,
		BorderSizePixel = 0,
	}, row)
end

local function infoRow(owner, text, height)
	local row = make("TextLabel", {
		Text = text, Font = Enum.Font.Gotham, TextSize = 12,
		TextColor3 = THEME.textDim, BackgroundColor3 = THEME.card,
		Size = UDim2.new(1, -8, 0, height or 40), TextWrapped = true, BorderSizePixel = 0,
	}, owner)
	corner(row, 8)
	pad(row, 10, 10, 6)
	return row
end

local function toggleRow(owner, id, label, desc, default, callback)
	local row = make("TextButton", {
		Size = UDim2.new(1, -8, 0, desc and 48 or 34),
		BackgroundColor3 = THEME.card, BorderSizePixel = 0, Text = "",
		AutoButtonColor = false, Parent = owner,
	}, owner)
	corner(row, 8)
	local body = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -56, 1, 0) }, row)
	pad(body, 11)
	make("TextLabel", {
		Text = label, Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, TextSize = 13,
		TextColor3 = THEME.text, TextXAlignment = Enum.TextXAlignment.Left,
	}, body)
	if desc then
		make("TextLabel", {
			Text = desc, Size = UDim2.new(1, 0, 0, 22), Position = UDim2.new(0, 0, 0, 20),
			BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
			TextColor3 = THEME.textDim, TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
		}, body)
	end
	local switch = make("Frame", {
		Size = UDim2.new(0, 40, 0, 22), Position = UDim2.new(1, -50, 0.5, -11),
		BackgroundColor3 = default and THEME.green or Color3.fromRGB(52, 55, 66),
		BorderSizePixel = 0,
	}, row)
	corner(switch, 11)
	local knob = make("Frame", {
		Size = UDim2.new(0, 16, 0, 16),
		Position = default and UDim2.new(1, -19, 0, 3) or UDim2.new(0, 3, 0, 3),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
	}, switch)
	corner(knob, 8)

	local enabled = (default == true)
	local function set(v)
		enabled = v == true
		state.toggles[id] = enabled
		tw(switch, {
			BackgroundColor3 = enabled and THEME.green or Color3.fromRGB(52, 55, 66),
		}, 0.12)
		tw(knob, {
			Position = enabled and UDim2.new(1, -19, 0, 3) or UDim2.new(0, 3, 0, 3),
		}, 0.12)
		if callback then
			local ok, err = pcall(callback, enabled)
			if not ok then log("toggle error [" .. id .. "]: " .. tostring(err), true) end
		end
	end
	row.MouseButton1Click:Connect(function() set(not enabled) end)
	state.toggles[id] = enabled
	state.switches[id] = { Set = set }
	return { Set = set }
end

local function sliderRow(owner, label, minV, maxV, default, callback, suffix)
	local row = make("Frame", {
		Size = UDim2.new(1, -8, 0, 44), BackgroundColor3 = THEME.card,
		BorderSizePixel = 0,
	}, owner)
	corner(row, 8)
	pad(row, 11, 12, 5)
	make("TextLabel", {
		Text = label, Size = UDim2.new(0.62, 0, 0, 16), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = THEME.text, TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	local valueLabel = make("TextLabel", {
		Text = tostring(default) .. (suffix or ""), Size = UDim2.new(0.38, 0, 0, 16),
		Position = UDim2.new(0.62, 0, 0, 0), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = THEME.accent, TextXAlignment = Enum.TextXAlignment.Right,
	}, row)
	local bar = make("Frame", {
		Size = UDim2.new(1, 0, 0, 14), Position = UDim2.new(0, 0, 0, 25),
		BackgroundTransparency = 1, Active = true,
	}, row)
	local track = make("Frame", {
		Size = UDim2.new(1, 0, 0, 6), Position = UDim2.new(0, 0, 0.5, -3),
		BackgroundColor3 = Color3.fromRGB(45, 48, 58), BorderSizePixel = 0,
	}, bar)
	corner(track, 3)
	local fill = make("Frame", {
		Size = UDim2.new(math.clamp((default - minV) / math.max(maxV - minV, 0.001), 0, 1), 0, 1, 0),
		BackgroundColor3 = THEME.accent, BorderSizePixel = 0,
	}, track)
	corner(fill, 3)
	local knobDot = make("Frame", {
		Size = UDim2.new(0, 4, 0, 4), AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(math.clamp((default - minV) / math.max(maxV - minV, 0.001), 0, 1), 0, 0.5, 0),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
	}, track)
	corner(knobDot, 2)
	local dragging = false
	local function apply(x)
		local a, s = bar.AbsolutePosition, bar.AbsoluteSize
		local ratio = math.clamp((x - a.X) / math.max(s.X, 1), 0, 1)
		local value = minV + (maxV - minV) * ratio
		fill.Size = UDim2.new(ratio, 0, 1, 0)
		knobDot.Position = UDim2.new(ratio, 0, 0.5, 0)
		valueLabel.Text = string.format("%.0f%s", value, suffix or "")
		if callback then
			local ok, err = pcall(callback, value)
			if not ok then log("slider error [" .. label .. "]: " .. tostring(err), true) end
		end
	end
	bar.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1
			or io.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			apply(io.Position.X)
		end
	end)
	connect(uis.InputChanged, function(io)
		if dragging and (io.UserInputType == Enum.UserInputType.MouseMovement
			or io.UserInputType == Enum.UserInputType.Touch) then
			apply(io.Position.X)
		end
	end)
	connect(uis.InputEnded, function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1
			or io.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end

local function buttonRow(owner, label, callback, wideText)
	local btn = make("TextButton", {
		Text = label, Size = UDim2.new(1, -8, 0, 34),
		BackgroundColor3 = THEME.card,
		Font = Enum.Font.GothamBold, TextSize = 13,
		TextColor3 = THEME.text, TextSize = 13,
		AutoButtonColor = false, BorderSizePixel = 0,
	}, owner)
	corner(btn, 8)
	btn.MouseButton1Click:Connect(function()
		pingButton(btn)
		local ok, err = pcall(callback)
		if not ok then log("button error [" .. label .. "]: " .. tostring(err), true) end
	end)
	return btn
end

local function dropdownRow(owner, label, options, default, callback)
	local row = make("TextButton", {
		Size = UDim2.new(1, -8, 0, 34), BackgroundColor3 = THEME.card,
		BorderSizePixel = 0, AutoButtonColor = false, Text = "", ZIndex = 4,
	}, owner)
	corner(row, 8)
	pad(row, 11)
	make("TextLabel", {
		Text = label, Size = UDim2.new(0.58, -8, 1, 0),
		BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = THEME.text, TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	local chosen = make("TextLabel", {
		Text = (default or "-") .. " ▾", Size = UDim2.new(0.42, -8, 1, 0),
		Position = UDim2.new(0.58, 0, 0, 0), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, TextSize = 12,
		TextColor3 = THEME.accent, TextXAlignment = Enum.TextXAlignment.Right,
	}, row)
	local list = make("Frame", {
		Size = UDim2.new(1, 0, 0, math.min(#options, 8) * 26 + 6),
		BackgroundColor3 = Color3.fromRGB(33, 35, 43), BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, 4), Visible = false, ZIndex = 12,
	}, row)
	corner(list, 8)
	stroke(list, THEME.stroke)
	local openTgl = false
	for idx, opt in ipairs(options) do
		local optBtn = make("TextButton", {
			Text = opt, Size = UDim2.new(1, -6, 0, 24),
			Position = UDim2.new(0, 3, (idx - 1) * 26 + 3, 0),
			BackgroundColor3 = Color3.fromRGB(40, 43, 52),
			Font = Enum.Font.Gotham, TextSize = 12,
			TextColor3 = THEME.text, AutoButtonColor = false,
			BorderSizePixel = 0, ZIndex = 13, LayoutOrder = idx,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, list)
		pad(optBtn, 8, 0, 0)
		corner(optBtn, 6)
		optBtn.MouseButton1Click:Connect(function()
			chosen.Text = opt .. " ▾"
			if callback then callback(opt) end
			list.Visible = false
			openTgl = false
			row.ZIndex = 4
		end)
	end
	row.MouseButton1Click:Connect(function()
		openTgl = not openTgl
		list.Visible = openTgl
		row.ZIndex = openTgl and 11 or 4
	end)
	return { Text = chosen }
end

-- ============================================================================
-- TABS
-- ============================================================================
local pageHome  = newTab("HOME")
ensureCanvas(pageHome)
local pageCombat = newTab("COMBAT")
ensureCanvas(pageCombat)
local pageGun  = newTab("GUNS")
ensureCanvas(pageGun)
local pageVis  = newTab("VISUALS")
ensureCanvas(pageVis)
local pageMov  = newTab("MOVE")
ensureCanvas(pageMov)
local pageTele = newTab("TELEPORT")
ensureCanvas(pageTele)
local pageSrv  = newTab("SERVER")
ensureCanvas(pageSrv)
local pageCfg  = newTab("SETUP")
ensureCanvas(pageCfg)

do
	local first = tabButtons["HOME"]
	if first then
		activeTabEntry = first
		first.txt.BackgroundColor3 = THEME.card
		first.txt.TextColor3 = THEME.text
		first.bar.BackgroundTransparency = 0
		first.page.Visible = true
	end
end

-- two-up button helper for quick grids
local function pairRow(owner, labelA, cbA, labelB, cbB)
	local rowWrap = make("Frame", {
		Size = UDim2.new(1, -8, 0, 34), BackgroundTransparency = 1,
	}, owner)
	local a = make("TextButton", {
		Text = labelA, Size = UDim2.new(0.5, -4, 1, 0),
		BackgroundColor3 = THEME.card, BorderSizePixel = 0,
		Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = THEME.text,
		AutoButtonColor = false,
	}, rowWrap)
	corner(a, 8)
	a.MouseButton1Click:Connect(function()
		pingButton(a)
		local ok, err = pcall(cbA)
		if not ok then log("button error [" .. labelA .. "]: " .. tostring(err), true) end
	end)
	local b = make("TextButton", {
		Text = labelB, Size = UDim2.new(0.5, -4, 1, 0), Position = UDim2.new(0.5, 4, 0, 0),
		BackgroundColor3 = THEME.card, BorderSizePixel = 0,
		Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = THEME.text,
		AutoButtonColor = false,
	}, rowWrap)
	corner(b, 8)
	b.MouseButton1Click:Connect(function()
		pingButton(b)
		local ok, err = pcall(cbB)
		if not ok then log("button error [" .. labelB .. "]: " .. tostring(err), true) end
	end)
end

-- ---------------------------------------------------------------------------
-- HOME
-- ---------------------------------------------------------------------------
section(pageHome, "Quick Actions")
pairRow(pageHome, "Kill All", function() killAll(CONFIG.killAuraMode) end,
	"Arrest All", function() arrestAll() end)
pairRow(pageHome, "Taze All", function() tazeAll() end,
	"Give Full Kit", function() giveAllLoot() end)
pairRow(pageHome, "Gate Open", function() openGate() end,
	"Rebind Remotes", function() rebindRemotes(8) end)

section(pageHome, "Session")
local statFrame = make("Frame", {
	Size = UDim2.new(1, -8, 0, 46), BackgroundColor3 = THEME.card,
	BorderSizePixel = 0,
}, pageHome)
corner(statFrame, 8)
local statKills = make("TextLabel", {
	Text = "0 actions", Font = Enum.Font.GothamBold, TextSize = 13,
	TextColor3 = THEME.accent, BackgroundTransparency = 1,
	Size = UDim2.new(0.34, 0, 1, 0), TextWrapped = true,
}, statFrame)
local statArrests = make("TextLabel", {
	Text = "0 arrests", Font = Enum.Font.GothamBold, TextSize = 13,
	TextColor3 = THEME.green, BackgroundTransparency = 1,
	Size = UDim2.new(0.33, 0, 1, 0), Position = UDim2.new(0.34, 0, 0, 0),
	TextWrapped = true,
}, statFrame)
local statItems = make("TextLabel", {
	Text = "0 items", Font = Enum.Font.GothamBold, TextSize = 13,
	TextColor3 = THEME.amber, BackgroundTransparency = 1,
	Size = UDim2.new(0.33, 0, 1, 0), Position = UDim2.new(0.67, 0, 0, 0),
	TextWrapped = true,
}, statFrame)
infoRow(pageHome, "Remotes resolve in the background the moment you join — the hub is usable while the map is still streaming. Kill engines validate a GunStates tool before firing; fists burst is the always-works fallback.", 84)

-- ---------------------------------------------------------------------------
-- COMBAT
-- ---------------------------------------------------------------------------
section(pageCombat, "Auras")
toggleRow(pageCombat, "auraKillOn", "Kill Aura", "Auto-attacks every valid target in range (fists burst or gun mode)",
	false, function(v) if v then toast("Kill Aura", "ON — mode: " .. CONFIG.killAuraMode, 2, "ok") end end, "G")
sliderRow(pageCombat, "Kill Radius", 10, 260, CONFIG.killAuraRadius,
	function(v) CONFIG.killAuraRadius = math.floor(v + 0.5) end, "studs")
sliderRow(pageCombat, "Kill Pace", 5, 100, math.floor(CONFIG.killAuraRate * 100),
	function(v) CONFIG.killAuraRate = math.max(v / 100, 0.05) end, "s")
dropdownRow(pageCombat, "Kill Mode", { "Fists", "Gun" }, CONFIG.killAuraMode,
	function(choice) CONFIG.killAuraMode = choice end)
dropdownRow(pageCombat, "Targets", { "All", "Inmates", "Guards", "Criminals" }, CONFIG.auraTargets,
	function(choice) CONFIG.auraTargets = choice end)
toggleRow(pageCombat, "skipFF", "Respect Forcefields", "Don't attack shielded spawns",
	CONFIG.killAuraIgnoreFF, function(v) CONFIG.killAuraIgnoreFF = v end)

section(pageCombat, "Arrest")
toggleRow(pageCombat, "auraArrestOn", "Arrest Aura", "Snaps to + cuffs the nearest arrestable at your own pace",
	false, function(v)
		if v then
			giveAnywhere("Handcuffs")
			toast("Arrest Aura", "ON — needs handcuffs", 2, "ok")
		end
	end, "H")
sliderRow(pageCombat, "Arrest Radius", 20, 500, CONFIG.arrestAuraRadius,
	function(v) CONFIG.arrestAuraRadius = math.floor(v + 0.5) end, "studs")
toggleRow(pageCombat, "arrestSnapOn", "Snap To Target", "Walks you behind the target while cuffing",
	CONFIG.arrestSnap, function(v) CONFIG.arrestSnap = v end)
toggleRow(pageCombat, "clickArrestOn", "Click Arrest", "Tap a player on-screen to cuff them",
	CONFIG.clickArrest, function(v) CONFIG.clickArrest = v end)

section(pageCombat, "Taze")
toggleRow(pageCombat, "auraTazeOn", "Taze Loop", "Remote-tazes the whole roof server-side",
	false, function(v) end, "J")
buttonRow(pageCombat, "Kill All Now", function() killAll(CONFIG.killAuraMode) end)
buttonRow(pageCombat, "Arrest All Now", function() arrestAll() end)
buttonRow(pageCombat, "Taze All Now", function() tazeAll() end)

-- ---------------------------------------------------------------------------
-- GUNS
-- ---------------------------------------------------------------------------
section(pageGun, "Acquisition")
dropdownRow(pageGun, "Preferred Gun",
	{ "M9", "Remington 870", "AK-47", "M4A1" }, CONFIG.gunChoice,
	function(choice) CONFIG.gunChoice = choice end)
buttonRow(pageGun, "Give Selected Gun", function()
	task.spawn(function()
		if giveAnywhere(CONFIG.gunChoice) then
			toast("Granted", CONFIG.gunChoice .. " pulled to backpack", 2, "ok")
		end
	end)
end)
buttonRow(pageGun, "Give All Guns + Tools", function() giveAllLoot() end)
pairRow(pageGun, "Key Card", function() giveAnywhere("Key card") end,
	"Hammer", function() giveAnywhere("Hammer") end)
pairRow(pageGun, "Crude Knife", function() giveAnywhere("Crude Knife") end,
	"Riot Gear", function() giveRiotGear() end)
buttonRow(pageGun, "Become Guard + Handcuffs", function()
	task.spawn(function()
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
toggleRow(pageGun, "autoRearmOn", "Auto Re-Arm", "Re-grants guns and mods them after every respawn/death",
	CONFIG.autoRearm, function(v) CONFIG.autoRearm = v end)

section(pageGun, "Gun Mods (GunStates rewrites)")
sliderRow(pageGun, "Damage", 1, 250, CONFIG.gunDamage, function(v) CONFIG.gunDamage = math.floor(v + 0.5) end)
sliderRow(pageGun, "Bullets", 1, 30, CONFIG.gunBullets, function(v) CONFIG.gunBullets = math.floor(v + 0.5) end)
sliderRow(pageGun, "Fire Rate", 0, 100, 1, function(v) CONFIG.gunFireRate = math.max(v / 10000, 0.0001) end)
sliderRow(pageGun, "Spread %", 0, 100, CONFIG.gunSpread, function(v) CONFIG.gunSpread = v / 1000 end)
toggleRow(pageGun, "infAmmo", "Infinite Ammo", "CurrentAmmo pinned to infinity",
	CONFIG.gunInfiniteAmmo, function(v) CONFIG.gunInfiniteAmmo = v end)
toggleRow(pageGun, "autoFire", "Full Auto", "Converts held weapons to full-auto",
	CONFIG.gunAutoFire, function(v) CONFIG.gunAutoFire = v end)
dropdownRow(pageGun, "Apply To",
	{ "All Tools", "Held Tool", "M9", "Remington 870", "AK-47", "M4A1", "Taser" },
	CONFIG.modTarget, function(choice) CONFIG.modTarget = choice end)
buttonRow(pageGun, "Apply Mods", function()
	if CONFIG.modTarget == "All Tools" then
		modAllGuns()
	elseif CONFIG.modTarget == "Held Tool" then
		local tool = lp.Character and lp.Character:FindFirstChildWhichIsA("Tool")
		if tool then modGun(tool) else log("no tool held", true) end
	else
		modNamed(CONFIG.modTarget)
	end
end)
buttonRow(pageGun, "Reset Sliders", function()
	CONFIG.gunDamage, CONFIG.gunBullets, CONFIG.gunFireRate = 12, 1, 0.18
	CONFIG.gunSpread, CONFIG.gunInfiniteAmmo, CONFIG.gunAutoFire = 2, false, false
	log("gun mod VALUES reset (re-exec to see sliders reset)")
end)

-- ---------------------------------------------------------------------------
-- VISUALS
-- ---------------------------------------------------------------------------
section(pageVis, "ESP")
toggleRow(pageVis, "espOn", "ESP", "Name + HP% + distance plates over every player",
	false, function(v) refreshEsp() end)
toggleRow(pageVis, "espNamesOn", "Names", "", true, function(v) CONFIG.espNames = v end)
toggleRow(pageVis, "espDistOn", "Distance", "", true, function(v) CONFIG.espDistance = v end)
toggleRow(pageVis, "espHpOn", "Health %", "", true, function(v) CONFIG.espHealthBar = v end)
toggleRow(pageVis, "espTeamOn", "Team Colors", "Cops blue · inmates orange · crims red",
	true, function(v) CONFIG.espTeamColor = v end)
toggleRow(pageVis, "espVisOnly", "Line of Sight Only", "Hide plates you can't actually see (costs a raycast)",
	false, function(v) CONFIG.espVisibleOnly = v end)
toggleRow(pageVis, "espTracers", "Tracers", "Screen lines drawn to every player (Drawing API)",
	false, function(v) CONFIG.espTracers = v end)

section(pageVis, "Chams")
toggleRow(pageVis, "chamsOn", "Chams", "Team-colored Highlight fills on characters",
	false, function(v) refreshEsp() end)
toggleRow(pageVis, "chamsWallOn", "Through Walls", "Force chams AlwaysOnTop through geometry",
	CONFIG.chamsThroughWalls, function(v)
		CONFIG.chamsThroughWalls = v
		for _, plr in ipairs(plrs:GetPlayers()) do
			applyChams(plr)
		end
	end)

section(pageVis, "World Lighting")
toggleRow(pageVis, "fullbrightOn", "Fullbright", "Scene fully lit, fog pushed out",
	false, function(v) setFullbright(v) end)
toggleRow(pageVis, "fpsBoostOn", "FPS Boost", "Client-only particle/beam kill for weak phones",
	false, function(v) setFpsBoost(v) end)
toggleRow(pageVis, "showAimFovShow", "Aim FOV Ring", "Ring visible when aimbot/silent is live",
	true, function(v) CONFIG.showAimFov = v end)
sliderRow(pageVis, "Field of View", 30, 120, 70, function(v)
	pcall(function() currentCam().FieldOfView = math.floor(v + 0.5) end)
end)

-- ---------------------------------------------------------------------------
-- MOVE
-- ---------------------------------------------------------------------------
section(pageMov, "Locomotion")
sliderRow(pageMov, "Walk Speed", 8, 250, CONFIG.walkSpeed,
	function(v) CONFIG.walkSpeed = math.floor(v + 0.5) end)
sliderRow(pageMov, "Jump Power", 8, 250, CONFIG.jumpPower,
	function(v) CONFIG.jumpPower = math.floor(v + 0.5) end)
toggleRow(pageMov, "noclipOn", "Noclip", "Phase through walls & doors",
	false, function(v) end)
toggleRow(pageMov, "infJump", "Infinite Jump", "Tap jump button repeatedly to chain",
	false, function(v) end)
toggleRow(pageMov, "tpWalkOn", "Teleport Walk (TP-Walk)", "Sprint heavily: each step shifts your root",
	false, function(v) end)
sliderRow(pageMov, "TP-Walk Power", 1, 15, CONFIG.tpWalkPower,
	function(v) CONFIG.tpWalkPower = math.floor(v + 0.5) end)

section(pageMov, "Flight")
toggleRow(pageMov, "flyOn", "Fly", "PC: WASD + E/Q. PHONE: FWD/BCK/UP/DN buttons appear on the right",
	false, function(v)
		flyPad.Visible = v
		if not v then state.touchMove = { fwd = 0, back = 0, up = 0, down = 0 } end
	end)
sliderRow(pageMov, "Fly Speed", 1, 30, CONFIG.flySpeed,
	function(v) CONFIG.flySpeed = math.floor(v + 0.5) end)
toggleRow(pageMov, "clickTpOn", "Click To Teleport", "Tap any surface to warp to it",
	false, function(v) CONFIG.clickTp = v end)
buttonRow(pageMov, "Land Where You Stand (zero fly drift)", function()
	local root = charRoot()
	if root then
		root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
		log("velocity zeroed")
	end
end)

-- ---------------------------------------------------------------------------
-- TELEPORT
-- ---------------------------------------------------------------------------
section(pageTele, "Prison Spots")
for _, spot in ipairs(TELEPORTS) do
	buttonRow(pageTele, spot.name, function() teleportTo(spot.fn()) end)
end
buttonRow(pageTele, "Armory (nearest gun giver)", function()
	local item = findItemAnywhere("M4A1")
	local pickup = item and item:FindFirstChild("ITEMPICKUP")
	if pickup then
		teleportTo(pickup.CFrame)
	else
		log("M4A1 giver not present", true)
	end
end)
buttonRow(pageTele, "Prison Spawn Location", function()
	local sp
	pcall(function() sp = workspace:FindFirstChild("Spawns"):FindFirstChildWhichIsA("SpawnLocation", true) end)
	if sp and sp:IsA("SpawnLocation") then
		teleportTo(sp.CFrame)
	else
		log("Spawns folder not found", true)
	end
end)

-- ---------------------------------------------------------------------------
-- SERVER
-- ---------------------------------------------------------------------------
section(pageSrv, "World Tools")
buttonRow(pageSrv, "Open Prison Gate", function() openGate() end)
toggleRow(pageSrv, "gateLoopOn", "Gate Loop", "Re-fires the gate remote on an interval",
	false, function(v) end)
sliderRow(pageSrv, "Gate Interval", 0.5, 6, CONFIG.gateSpamInterval,
	function(v) CONFIG.gateSpamInterval = math.max(0.5, v) end, "s")
buttonRow(pageSrv, "Remove Doors + Fences (client)", function() removeDoors() end)
buttonRow(pageSrv, "Restore Body (loadchar respawn)", function()
	local loadChar = getRemote("loadchar")
	if loadChar then
		vsafe(function() loadChar:InvokeServer(lp.Name) end)
		log("remoted a fresh character")
	else
		log("loadchar missing", true)
	end
end)

section(pageSrv, "Teams")
pairRow(pageSrv, "Become Inmate", function() switchTeam("Inmate") end,
	"Become Guard", function() switchTeam("Guard") end)
pairRow(pageSrv, "Solo Neutral", function() switchTeam("Neutral") end,
	"Break Fence (Criminal)", function() becomeCriminal() end)

section(pageSrv, "Protections")
toggleRow(pageSrv, "antiStunOn", "Anti-Stun", "Taze stun (0 walkspeed) is instantly reverted",
	CONFIG.noStayStunned, function(v) CONFIG.noStayStunned = v end)
toggleRow(pageSrv, "antiAfkOn", "Anti-AFK", "Fakes RemoteEvent nibbles so you're never idle-kicked",
	true, function(v) CONFIG.antiAfk = v end)
buttonRow(pageSrv, "Server Report", function()
	log("place " .. tostring(game.PlaceId) .. " · " .. tostring(#plrs:GetPlayers()) .. " players")
	log("remotes — melee=" .. tostring(not not meleeEvent) .. " shoot=" .. tostring(not not shootingEvent)
		.. " item=" .. tostring(not not ItemHandler) .. " arrest=" .. tostring(not not getArrestRemote()))
end)

-- ---------------------------------------------------------------------------
-- SETUP
-- ---------------------------------------------------------------------------
section(pageCfg, "Controls")
infoRow(pageCfg, "PHONE: tap RH (left edge) to open/close. Fly shows its own pad. "
	.. "Crosshair-tap gestures need the panel closed.\n"
	.. "PC: RightCtrl or U = panel · G = kill aura · H = arrest aura · J = taze loop · F3 = gate.", 96)

section(pageCfg, "Config")
buttonRow(pageCfg, "Save Config", function()
	if writefile then
		pcall(function() writefile("RiotHubConfig.json", httpSvc:JSONEncode(CONFIG)) end)
		toast("Config Saved", "RiotHubConfig.json written", 2, "ok")
	else
		getGenv().RiotHubConfig = CONFIG
		toast("Config Cached", "writefile unavailable — saved to genv", 2)
	end
end)
buttonRow(pageCfg, "Load Config", function()
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
		toast("Config Loaded", "values applied to the engines", 2, "ok")
		log(ok and "config loaded" or "config parse failed", not ok)
	else
		toast("No Config", "Save one first", 2, "err")
	end
end)
toggleRow(pageCfg, "reduceAnimOn", "Reduce Animations", "Removes UI tweens (older phones)",
	false, function(v)
		CONFIG.reduceAnim = v
		state.uiAnim = v and 0 or 0.14
	end)

section(pageCfg, "Danger Zone")
pairRow(pageCfg, "Hide Panel", function() window.Visible = false end,
	"Unload Hub", function()
		state.detached = true
		for _, c in ipairs(connections) do pcall(function() c:Disconnect() end) end
		pcall(function() screenGui:Destroy() end)
		pcall(function() if fovRing then fovRing:Destroy() end end)
		pcall(function() if espContainer then espContainer:Destroy() end end)
		for key, _ in pairs(state.tracers) do destroyTracer(key) end
		for _, plr in ipairs(plrs:GetPlayers()) do clearChams(plr) end
		setFullbright(false)
		pcall(function() if fpsBoostConn then fpsBoostConn:Disconnect() end end)
		if getgenv then getgenv().RiotHub = nil else _G.RiotHub = nil end
	end)

section(pageCfg, "About")
local aboutLabel = make("TextLabel", {
	Text = "RiotHub v3.0 — self-contained, keyless, no external deps.\n"
		.. "Pull-based guns · GunStates engine · aura suite (kill / arrest / taze) · "
		.. "silent aim + aimbot · ESP/chams/tracers · flight pad for touch. "
		.. "Every remote hit is pcall-guarded and logged.",
	Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = THEME.textDim,
	BackgroundColor3 = THEME.card, TextWrapped = true, BorderSizePixel = 0,
	Size = UDim2.new(1, -8, 0, 92), TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top,
}, pageCfg)
corner(aboutLabel, 8)
pad(aboutLabel, 10)

-- ============================================================================
-- MANAGERS
-- ============================================================================
-- combat aura loop: nearest-first, one velocity burst per beat
task.spawn(function()
	while not state.detached do
		task.wait(math.max(CONFIG.killAuraRate, 0.12))
		local myRoot = charRoot()
		if not myRoot then task.wait(0.4) else
			if state.toggles.auraKillOn then
				local best, bestD = nil, math.huge
				for _, plr in ipairs(plrs:GetPlayers()) do
					if plr ~= lp and selTarget(plr, "auraTargets") then
						local ch = plr.Character
						local hum = ch and ch:FindFirstChildOfClass("Humanoid")
						local theirRoot = ch and ch:FindFirstChild("HumanoidRootPart")
						if hum and hum.Health > 0 and theirRoot then
							local d = (theirRoot.Position - myRoot.Position).Magnitude
							if d <= CONFIG.killAuraRadius and d < bestD then
								local okT = true
								local ff = ch:FindFirstChildOfClass("ForceField")
								if ff and not CONFIG.killAuraIgnoreFF then okT = false end
								if okT then best, bestD = plr, d end
							end
						end
					end
				end
				if best then killTarget(best) end
			end
			if state.toggles.auraArrestOn then
				local best, bestD = nil, math.huge
				for _, plr in ipairs(arrestables()) do
					local theirRoot = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
					if theirRoot then
						local d = (theirRoot.Position - myRoot.Position).Magnitude
						if d <= CONFIG.arrestAuraRadius and d < bestD then best, bestD = plr, d end
					end
				end
				if best and not state.detached then
					if arrestTarget(best) then state.arrestCount = state.arrestCount + 1 end
					task.wait(CONFIG.arrestAuraRate)
				end
			end
		end
	end
end)

-- taze loop
task.spawn(function()
	while not state.detached do
		task.wait(0.5)
		if state.toggles.auraTazeOn then
			local taser = getTaser()
			if not taser then
				task.wait(2)
			else
				for _, plr in ipairs(plrs:GetPlayers()) do
					if plr ~= lp and state.toggles.auraTazeOn and not state.detached then
						tazeTarget(plr, taser)
					end
					task.wait(CONFIG.tazeRate / 4)
				end
			end
		end
	end
end)

-- gate + antistun + chams sweep loops
task.spawn(function()
	while not state.detached do
		task.wait(CONFIG.gateSpamInterval)
		if state.toggles.gateLoopOn then openGate() end
	end
end)

task.spawn(function()
	while not state.detached do
		task.wait(2)
		if state.toggles.chamsOn then
			for _, plr in ipairs(plrs:GetPlayers()) do
				if plr ~= lp then applyChams(plr) end
			end
		end
	end
end)

-- auto-collect items near you (paced!)
task.spawn(function()
	while not state.detached do
		task.wait(1.0)
		local pt = prisonTable()
		if pt and state.lastItemPull + CONFIG.itemPace <= tick() then
			local myRoot = charRoot()
			local had
			if myRoot then
				for _, candidate in ipairs(pt:GetDescendants()) do
					if candidate.Name == "ITEMPICKUP" and candidate:IsA("BasePart") then
						local d = (candidate.Position - myRoot.Position).Magnitude
						if d <= CONFIG.autoCollectRadius then
							if not had then had = candidate end
						end
					end
				end
			end
		end
	end
end)

-- FPS + status + stats ticker
local frameCount = 0
connect(runSvc.Heartbeat, function()
	frameCount = frameCount + 1
end)
task.spawn(function()
	while not state.detached do
		task.wait(1)
		state.fps = frameCount
		frameCount = 0
		pcall(function()
			statusLabel.Text = "v3.0 · fps "
				.. tostring(state.fps) .. " · " .. tostring(#plrs:GetPlayers())
				.. " players · remotes M"
				.. (meleeEvent and "✓" or "✗") .. " S"
				.. (shootingEvent and "✓" or "✗") .. " I"
				.. (ItemHandler and "✓" or "✗")
			statKills.Text = tostring(state.killCounter) .. " actions"
			statArrests.Text = tostring(state.arrestCount) .. " cuffs"
			statItems.Text = tostring(state.itemCount) .. " items"
		end)
	end
end)

-- gestures: click-TP + click-arrest (screen taps not over any GUI)
connect(uis.InputBegan, function(input, processed)
	if state.detached or processed then return end
	if not (input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1) then
		return
	end
	local camera = currentCam()
	if not camera then return end
	local pos = input.Position
	if state.toggles.clickTpOn then
		pcall(function()
			local ray = camera:ViewportPointToRay(pos.X, pos.Y)
			local hit = workspace:Raycast(ray.Origin, ray.Direction * 5000)
			if hit and hit.Position then
				teleportTo(CFrame.new(hit.Position))
				toast("Teleported", "warp to tap surface", 1)
			end
		end)
	end
	if state.toggles.clickArrestOn then
		pcall(function()
			local ray = camera:ViewportPointToRay(pos.X, pos.Y)
			local hit = workspace:Raycast(ray.Origin, ray.Direction * 5000)
			if hit and hit.Instance then
				local ch = hit.Instance:FindFirstAncestorOfClass("Model")
				local plr = ch and plrs:GetPlayerFromCharacter(ch)
				if plr and plr ~= lp and not isGuard(plr) then
					local remote = getArrestRemote()
					if remote then
						vsafe(function() remote:InvokeServer(
							plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") or hit.Instance) end)
					end
				end
			end
		end)
	end
end)

-- global keys
connect(uis.InputBegan, function(input, processed)
	if state.detached then return end
	local kc = input.KeyCode
	if kc == Enum.KeyCode.RightControl or kc == Enum.KeyCode.U then
		if not processed then window.Visible = not window.Visible end
	elseif kc == Enum.KeyCode.G then
		local sw = state.switches.auraKillOn
		if sw then sw.Set(not state.toggles.auraKillOn) end
	elseif kc == Enum.KeyCode.H then
		local sw = state.switches.auraArrestOn
		if sw then sw.Set(not state.toggles.auraArrestOn) end
	elseif kc == Enum.KeyCode.J then
		local sw = state.switches.auraTazeOn
		if sw then sw.Set(not state.toggles.auraTazeOn) end
	elseif kc == Enum.KeyCode.F3 then
		openGate()
	end
end)

-- anti-afk
connect(lp.Idled, function()
	if not CONFIG.antiAfk then return end
	pcall(function()
		virtualUser:CaptureController()
		virtualUser:ClickButton2(Vector2.new())
	end)
end)

-- respawn hook
connect(lp.CharacterAdded, function(ch)
	task.wait(0.4)
	if CONFIG.autoRearm then
		for _, g in ipairs(GIVEN_GUNS) do
			if state.detached then return end
			giveAnywhere(g)
		end
		task.delay(3, function()
			if not state.detached then modAllGuns() end
		end)
	end
	if state.toggles.flyOn then flyPad.Visible = true else flyPad.Visible = false end
	if state.toggles.chamsOn then
		task.delay(0.5, function()
			for _, plr in ipairs(plrs:GetPlayers()) do
				if plr ~= lp then applyChams(plr) end
			end
		end)
	end
end)

-- player removal: clean ESP/tracers
connect(plrs.PlayerRemoving, function(plr)
	destroyEspUnit(plr)
	destroyTracer(plr)
end)

-- ============================================================================
-- BOOT
-- ============================================================================
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
		for key, _ in pairs(state.tracers) do destroyTracer(key) end
		for _, plr in ipairs(plrs:GetPlayers()) do clearChams(plr) end
		pcall(function() screenGui:Destroy() end)
		pcall(function() if fovRing then fovRing:Destroy() end end)
		pcall(function() if espContainer then espContainer:Destroy() end end)
	end,
	log = log,
	toast = toast,
	config = CONFIG,
	toggles = state.toggles,
}

log("riot hub v3.0 armed for " .. lp.Name)
notify("Riot Hub v3", "loaded — tap the RH button", 4)
toast("RiotHub v3.0", "Loaded for " .. lp.Name .. " — tap RH to open", 3, "ok")
