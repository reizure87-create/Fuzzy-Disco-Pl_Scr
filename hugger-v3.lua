--[[
    HUGGER V3  //  TROLL HUG TOWER
    A ground-up rebuild of the attached Troll-Hug-Tower v2.0 hub.

    This file is self-contained. Execute it in TROLL Hug Tower (Trash Container,
    place 103037106396302) with a client that exposes ProximityPrompt control.

    Design rules used throughout:
      * The game's own hug control comes first: ProximityPrompt -> Tool -> opt-in
        remote fallback. Guessed remote payload spam is gone.
      * A carry is only reported as confirmed when the client can see a weld,
        a state value, a carry tool, or a helpless humanoid state. Otherwise the
        result is reported as UNCONFIRMED, never as a fake success.
      * Every switch has a real callback, an ERROR state, and a reversible cleanup.
      * No feature claims to bypass server anti-cheat or to grant gamepass items.
      * UI is mobile-first and resizes from a 360 px phone to a desktop viewport.

    The original v2 file is preserved separately and is not modified.
]]

local VERSION = "3.0"
local PLACE_ID = 103037106396302

local Env = (getgenv and getgenv()) or _G
if type(Env.HuggerV3) == "table" then
    local previous = Env.HuggerV3
    local stop = previous.unload or previous.Unload
    if type(stop) == "function" then pcall(stop) end
end

local function service(name)
    local ok, svc = pcall(function()
        return game:GetService(name)
    end)
    if ok then return svc end
    return nil
end

local cloneref = cloneref or function(object) return object end
local Players = cloneref(service("Players"))
local Replicated = cloneref(service("ReplicatedStorage"))
local RunService = cloneref(service("RunService"))
local UserInput = cloneref(service("UserInputService"))
local TweenService = cloneref(service("TweenService"))
local Lighting = cloneref(service("Lighting"))
local Teleport = cloneref(service("TeleportService"))
local VirtualUser = cloneref(service("VirtualUser"))
local Stats = cloneref(service("Stats"))
local HttpService = cloneref(service("HttpService"))
local CollectionService = cloneref(service("CollectionService"))

if not Players then
    error("[HUGGER] Players service is unavailable.", 0)
end

local LP = Players.LocalPlayer
if not LP then
    local waited = 0
    while not Players.LocalPlayer and waited < 20 do
        task.wait(0.25)
        waited = waited + 0.25
    end
    LP = Players.LocalPlayer
end
if not LP then
    error("[HUGGER] Join TROLL Hug Tower, then execute the script.", 0)
end

local PlayerGui = LP:FindFirstChild("PlayerGui")
if not PlayerGui then
    local waited = 0
    while not LP:FindFirstChild("PlayerGui") and waited < 15 do
        task.wait(0.25)
        waited = waited + 0.25
    end
    PlayerGui = LP:FindFirstChild("PlayerGui")
end
if not PlayerGui then
    error("[HUGGER] PlayerGui is not ready. Rejoin and execute again.", 0)
end

local function currentCamera()
    return workspace.CurrentCamera
end

local function now()
    return os.clock()
end

local function clamp(value, low, high)
    value = tonumber(value) or low
    if value < low then return low end
    if value > high then return high end
    return value
end

local function round(value)
    return math.floor((tonumber(value) or 0) + 0.5)
end

local function getChar(player)
    player = player or LP
    return player and player.Character
end

local function getHum(player)
    local char = getChar(player)
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function getRoot(player)
    local char = getChar(player)
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
end

local function getPivot(player)
    local root = getRoot(player)
    if root then return root.Position end
    local char = getChar(player)
    if char then
        local ok, cf = pcall(function() return char:GetPivot() end)
        if ok and cf then return cf.Position end
    end
    return nil
end

local function isAlive(player)
    local hum = getHum(player)
    local root = getRoot(player)
    return hum ~= nil and root ~= nil and hum.Health > 0
end

local function showName(player)
    if not player then return "Nobody" end
    local ok, name = pcall(function()
        return player.DisplayName or player.Name
    end)
    if ok and name and name ~= "" then return tostring(name) end
    return tostring(player.Name or "Player")
end

local function distanceTo(player)
    local mine = getPivot(LP)
    local theirs = getPivot(player)
    if not mine or not theirs then return math.huge end
    return (mine - theirs).Magnitude
end

local function playerByUserId(userId)
    if not userId then return nil end
    for _, player in ipairs(Players:GetPlayers()) do
        if player.UserId == userId then return player end
    end
    return nil
end

local H = {}
local CONFIG = {
    -- grab engine
    autoGrab           = false,
    grabReach          = 18,
    autoApproach       = true,
    maxApproach        = 40,
    promptBoost        = false,
    autoThrow          = false,
    throwDelay         = 1.2,
    aimLava            = true,
    remoteFallback     = false,
    grabPayload        = "Player",
    throwPayload       = "None",
    actionCooldown     = 1.1,
    fallbackPace       = 0.35,
    stickyTarget       = true,
    skipCarriedTargets = true,
    skipFriends        = false,
    -- guard
    carryAlarm         = true,
    autoStruggle       = false,
    antiFling          = true,
    antiLava           = true,
    antiVoid           = false,
    autoDodge          = false,
    dodgeDistance      = 9,
    respawnSafe        = false,
    -- movement
    walkEnabled        = false,
    jumpEnabled        = false,
    walkSpeed          = 24,
    jumpPower          = 60,
    flyEnabled         = false,
    flySpeed           = 55,
    noclip             = false,
    autoJump           = false,
    infiniteJump       = false,
    lowGravity         = false,
    gravity            = 60,
    antiAfk            = true,
    -- visuals
    esp                = false,
    espRange           = 500,
    espNames           = true,
    espHealth          = true,
    espDistance        = true,
    espTracers         = false,
    espChams           = true,
    beacon             = true,
    lavaGlow           = false,
    spectate           = false,
    fullbright         = false,
    lockFov            = false,
    fov                = 90,
    -- system
    uiScale            = 1,
    showPerf           = true,
    logMax             = 120,
}

local STATE = {
    version          = VERSION,
    startedAt        = now(),
    unloaded         = false,
    connections      = {},
    toggles          = {},
    switches         = {},
    ui               = {},
    pages            = {},
    target           = { mode = "nearest", userId = nil },
    grab             = {
        state = "idle", busy = false, token = 0, target = nil,
        prompt = nil, source = "", lastTry = 0, cooldownUntil = 0,
        lastFailure = "", carrySince = 0, confirms = 0,
    },
    throw            = { busy = false, token = 0, state = "idle", lastTry = 0, cooldownUntil = 0 },
    carry            = { carrying = nil, carrier = nil, signal = "", at = 0 },
    stats            = { attempts = 0, fired = 0, carries = 0, throws = 0, releases = 0, lava = 0, failures = 0 },
    logLines         = {},
    pipeline         = "READY",
    safety           = {
        lastSafe = nil, lastSave = 0, guardUntil = 0, voidUntil = 0,
        spawn = nil, lavaParts = {}, lavaScan = 0, lowestLavaY = nil, scanning = false,
    },
    tower            = { platforms = {}, highest = nil, scanned = 0, best = 0 },
    esp              = { frames = {}, gui = nil, last = 0, highlights = {}, chams = {} },
    beacon           = { gui = nil, player = nil },
    spectate         = { active = false, subject = nil, cameraType = nil, player = nil },
    fly              = { on = false, bv = nil, bg = nil, savedPlatform = false, held = {}, last = 0, velocity = nil, pad = nil },
    noclip           = { on = false, saved = {}, conn = nil },
    lighting         = { on = false, saved = nil },
    lavaGlow         = { on = false, saved = {}, parts = {} },
    remote           = { grabs = {}, throws = {}, escapes = {}, scanned = 0, list = {} },
    server           = { list = {}, lastScan = 0, busy = false, lastMessage = "" },
    alarms           = { near = {}, lastCarried = nil, warned = 0 },
    tools             = { rows = {}, built = 0 },
    perf             = { fps = 0, frames = 0, last = now(), ping = 0, lastPing = 0 },
    uiScale          = 1,
    heroSignature    = "",
    lastStatus       = "",
    errorCount       = 0,
    movement         = { baseWalk = nil, baseJump = nil, baseGravity = nil },
    visual           = { baseFov = nil, camera = nil },
}

local THEME = {
    bg        = Color3.fromRGB(13, 10, 22),
    bg2       = Color3.fromRGB(20, 15, 32),
    panel     = Color3.fromRGB(22, 17, 36),
    card      = Color3.fromRGB(29, 23, 45),
    cardOn    = Color3.fromRGB(44, 31, 62),
    line      = Color3.fromRGB(62, 48, 88),
    text      = Color3.fromRGB(248, 244, 255),
    dim       = Color3.fromRGB(191, 179, 214),
    faint     = Color3.fromRGB(137, 123, 164),
    accent    = Color3.fromRGB(255, 74, 140),
    accent2   = Color3.fromRGB(255, 154, 66),
    mint      = Color3.fromRGB(92, 235, 174),
    red       = Color3.fromRGB(255, 94, 112),
    gold      = Color3.fromRGB(255, 207, 102),
    blue      = Color3.fromRGB(126, 174, 255),
    purple    = Color3.fromRGB(177, 130, 255),
}

local function log(message, isError)
    if STATE.unloaded then return end
    local text = tostring(message or "")
    if #text > 220 then text = text:sub(1, 217) .. "..." end
    table.insert(STATE.logLines, { text = text, err = isError == true, at = os.date("%H:%M:%S") })
    while #STATE.logLines > CONFIG.logMax do
        table.remove(STATE.logLines, 1)
    end
    if isError then
        warn("[HUGGER] " .. text)
    else
        print("[HUGGER] " .. text)
    end
    if STATE.ui and STATE.ui.logLabel then
        local rows = {}
        local first = math.max(1, #STATE.logLines - 17)
        for index = first, #STATE.logLines do
            local entry = STATE.logLines[index]
            table.insert(rows, string.format("%s %s%s",
                entry.at, entry.err and "[!] " or "    ", entry.text))
        end
        pcall(function()
            STATE.ui.logLabel.Text = table.concat(rows, "\n")
        end)
    end
end
STATE.log = log

local function safe(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        STATE.errorCount = STATE.errorCount + 1
        log(label .. ": " .. tostring(err), true)
        if STATE.ui and STATE.ui.toast then
            pcall(STATE.ui.toast, "ERROR", tostring(label) .. " failed", 4, "err")
        end
    end
    return ok, err
end

local function connect(signal, fn)
    if not signal then return nil end
    local ok, conn = pcall(function() return signal:Connect(fn) end)
    if ok and conn then
        table.insert(STATE.connections, conn)
        return conn
    end
    return nil
end

local function disconnectAll()
    for _, conn in ipairs(STATE.connections) do
        pcall(function() conn:Disconnect() end)
    end
    STATE.connections = {}
end

local function make(class, properties, parent)
    local object = Instance.new(class)
    if properties then
        for key, value in pairs(properties) do
            pcall(function() object[key] = value end)
        end
    end
    if parent then
        pcall(function() object.Parent = parent end)
    end
    return object
end

local function corner(object, radius)
    return make("UICorner", { CornerRadius = UDim.new(0, radius or 10) }, object)
end

local function stroke(object, color, thickness, transparency)
    return make("UIStroke", {
        Color = color or THEME.line,
        Thickness = thickness or 1,
        Transparency = transparency or 0.45,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, object)
end

local function gradient(object, colorA, colorB, rotation, transparency)
    if not ColorSequence or not ColorSequenceKeypoint then return nil end
    local sequence = ColorSequence.new({
        ColorSequenceKeypoint.new(0, colorA or THEME.accent),
        ColorSequenceKeypoint.new(1, colorB or THEME.accent2),
    })
    return make("UIGradient", {
        Color = sequence,
        Rotation = rotation or 0,
        Transparency = transparency,
    }, object)
end

local function padding(object, left, right, top, bottom)
    return make("UIPadding", {
        PaddingLeft = UDim.new(0, left or 0),
        PaddingRight = UDim.new(0, right or 0),
        PaddingTop = UDim.new(0, top or 0),
        PaddingBottom = UDim.new(0, bottom or 0),
    }, object)
end

local function tween(object, goal, duration, style, direction)
    if not object or STATE.unloaded then return nil end
    local info = TweenInfo.new(duration or 0.18,
        style or Enum.EasingStyle.Quint,
        direction or Enum.EasingDirection.Out)
    local ok, tw = pcall(function()
        return TweenService:Create(object, info, goal)
    end)
    if ok and tw then
        pcall(function() tw:Play() end)
        return tw
    end
    return nil
end

local function setStatus(text, kind)
    STATE.pipeline = tostring(text or "")
    if STATE.ui.setStatus then
        pcall(STATE.ui.setStatus, STATE.pipeline, kind)
    end
end

H.Version = VERSION
H.PlaceId = PLACE_ID
H.Config = CONFIG
H.State = STATE
H.Theme = THEME
H.log = log
H.safe = safe
H.connect = connect
H.disconnectAll = disconnectAll
H.make = make
H.corner = corner
H.stroke = stroke
H.gradient = gradient
H.padding = padding
H.tween = tween
H.now = now
H.clamp = clamp
H.round = round
H.getChar = getChar
H.getHum = getHum
H.getRoot = getRoot
H.getPivot = getPivot
H.isAlive = isAlive
H.showName = showName
H.distanceTo = distanceTo
H.playerByUserId = playerByUserId
H.currentCamera = currentCamera
H.setStatus = setStatus
H.services = {
    Players = Players,
    Replicated = Replicated,
    RunService = RunService,
    UserInput = UserInput,
    TweenService = TweenService,
    Lighting = Lighting,
    Teleport = Teleport,
    VirtualUser = VirtualUser,
    Stats = Stats,
    HttpService = HttpService,
    CollectionService = CollectionService,
}
Env.HuggerV3 = H

-- ============================================================
--  UI SHELL, WIDGETS, MODALS, TOASTS, ANIMATION
-- ============================================================
do
    local function parentCandidates()
        local list = {}
        table.insert(list, PlayerGui)
        if gethui then
            local ok, hui = pcall(gethui)
            if ok and hui then table.insert(list, hui) end
        end
        local core = service("CoreGui")
        if core then table.insert(list, core) end
        return list
    end

    local candidates = parentCandidates()
    for _, parent in ipairs(candidates) do
        local ok, children = pcall(function() return parent:GetChildren() end)
        if ok and children then
            for _, child in ipairs(children) do
                if child.Name == "HuggerV3_GUI" then
                    pcall(function() child:Destroy() end)
                end
            end
        end
    end

    local screen
    for _, parent in ipairs(candidates) do
        local ok, gui = pcall(function()
            local object = Instance.new("ScreenGui")
            object.Name = "HuggerV3_GUI"
            object.ResetOnSpawn = false
            object.IgnoreGuiInset = true
            object.DisplayOrder = 999
            object.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
            object.Enabled = true
            object.Parent = parent
            return object
        end)
        if ok and gui and gui.Parent then
            screen = gui
            break
        elseif gui then
            pcall(function() gui:Destroy() end)
        end
    end
    if not screen then
        error("[HUGGER] Could not create the interface (PlayerGui/CoreGui locked).", 0)
    end
    STATE.ui.screen = screen

    local function viewport()
        local camera = currentCamera()
        local vp = camera and camera.ViewportSize
        if not vp or vp.X <= 0 or vp.Y <= 0 then
            return Vector2.new(1280, 720)
        end
        return vp
    end

    local mainScale = make("UIScale", { Scale = 1 }, screen)
    local main = make("Frame", {
        Name = "Main",
        BackgroundColor3 = THEME.bg,
        BorderSizePixel = 0,
        ClipsDescendants = true,
        Active = true,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        Size = UDim2.fromOffset(660, 500),
    }, screen)
    corner(main, 16)
    stroke(main, THEME.accent, 1.4, 0.55)
    make("UIGradient", {
        Color = ColorSequence and ColorSequence.new({
            ColorSequenceKeypoint.new(0, THEME.bg2),
            ColorSequenceKeypoint.new(1, THEME.bg),
        }) or nil,
        Rotation = 90,
    }, main)
    STATE.ui.main = main
    STATE.ui.mainScale = mainScale

    local header = make("Frame", {
        Name = "Header",
        Size = UDim2.new(1, 0, 0, 58),
        BackgroundColor3 = THEME.panel,
        BorderSizePixel = 0,
        Active = true,
    }, main)
    corner(header, 16)
    make("Frame", {
        Size = UDim2.new(1, 0, 0, 2),
        BackgroundColor3 = THEME.accent,
        BorderSizePixel = 0,
    }, header)
    gradient(header:FindFirstChildWhichIsA("Frame"), THEME.accent, THEME.accent2, 0)
    STATE.ui.header = header

    local logo = make("Frame", {
        Size = UDim2.fromOffset(34, 34),
        Position = UDim2.fromOffset(12, 11),
        BackgroundColor3 = THEME.accent,
        BorderSizePixel = 0,
    }, header)
    corner(logo, 10)
    gradient(logo, THEME.accent, THEME.accent2, 0)
    make("TextLabel", {
        Text = "H",
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBlack,
        TextSize = 18,
        TextColor3 = THEME.bg,
    }, logo)

    local title = make("TextLabel", {
        Text = "HUGGER",
        Size = UDim2.new(0, 110, 0, 18),
        Position = UDim2.fromOffset(54, 7),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBlack,
        TextSize = 15,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, header)
    make("TextLabel", {
        Text = "TROLL HUG TOWER",
        Size = UDim2.new(0, 150, 0, 12),
        Position = UDim2.fromOffset(54, 24),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 7,
        TextColor3 = THEME.faint,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, header)
    local versionChip = make("Frame", {
        Size = UDim2.fromOffset(26, 15),
        Position = UDim2.fromOffset(124, 9),
        BackgroundColor3 = THEME.cardOn,
        BorderSizePixel = 0,
    }, header)
    corner(versionChip, 5)
    make("TextLabel", {
        Text = "V3",
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBlack,
        TextSize = 8,
        TextColor3 = THEME.accent2,
    }, versionChip)
    title.Text = "HUGGER"

    local headerStatus = make("Frame", {
        Size = UDim2.fromOffset(70, 20),
        Position = UDim2.new(1, -168, 0, 18),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
    }, header)
    corner(headerStatus, 10)
    local headerStatusDot = make("Frame", {
        Size = UDim2.fromOffset(5, 5),
        Position = UDim2.new(0, 8, 0.5, -2.5),
        BackgroundColor3 = THEME.mint,
        BorderSizePixel = 0,
    }, headerStatus)
    corner(headerStatusDot, 3)
    local headerStatusText = make("TextLabel", {
        Text = "LIVE",
        Size = UDim2.new(1, -17, 1, 0),
        Position = UDim2.fromOffset(17, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 8,
        TextColor3 = THEME.mint,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, headerStatus)
    STATE.ui.headerStatus = headerStatus
    STATE.ui.headerStatusText = headerStatusText
    STATE.ui.headerStatusDot = headerStatusDot

    local minimizeBtn = make("TextButton", {
        Text = "–",
        Size = UDim2.fromOffset(26, 26),
        Position = UDim2.new(1, -62, 0, 16),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        TextSize = 14,
        TextColor3 = THEME.dim,
    }, header)
    corner(minimizeBtn, 8)
    local closeBtn = make("TextButton", {
        Text = "×",
        Size = UDim2.fromOffset(26, 26),
        Position = UDim2.new(1, -32, 0, 16),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextColor3 = THEME.dim,
    }, header)
    corner(closeBtn, 8)

    -- target hero
    local hero = make("Frame", {
        Name = "Hero",
        Size = UDim2.new(1, -12, 0, 82),
        Position = UDim2.fromOffset(6, 64),
        BackgroundColor3 = Color3.fromRGB(37, 24, 51),
        BorderSizePixel = 0,
        ClipsDescendants = true,
    }, main)
    corner(hero, 13)
    stroke(hero, THEME.accent, 1, 0.72)
    make("Frame", {
        Size = UDim2.fromOffset(3, 62),
        Position = UDim2.new(0, 0, 0.5, -31),
        BackgroundColor3 = THEME.accent,
        BorderSizePixel = 0,
    }, hero)
    gradient(hero:FindFirstChildWhichIsA("Frame"), THEME.accent, THEME.accent2, 90)
    local heroAvatar = make("Frame", {
        Size = UDim2.fromOffset(46, 46),
        Position = UDim2.fromOffset(12, 18),
        BackgroundColor3 = THEME.cardOn,
        BorderSizePixel = 0,
    }, hero)
    corner(heroAvatar, 23)
    local heroAvatarLetter = make("TextLabel", {
        Text = "♥",
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBlack,
        TextSize = 20,
        TextColor3 = THEME.accent,
    }, heroAvatar)
    local heroName = make("TextLabel", {
        Text = "No target",
        Size = UDim2.new(1, -170, 0, 18),
        Position = UDim2.fromOffset(68, 10),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBlack,
        TextSize = 14,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, hero)
    local heroMeta = make("TextLabel", {
        Text = "Open the picker to choose a player",
        Size = UDim2.new(1, -170, 0, 14),
        Position = UDim2.fromOffset(68, 28),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 8,
        TextColor3 = THEME.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, hero)
    local heroChip = make("Frame", {
        Size = UDim2.fromOffset(74, 16),
        Position = UDim2.fromOffset(68, 47),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
    }, hero)
    corner(heroChip, 5)
    local heroChipText = make("TextLabel", {
        Text = "IDLE",
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 7,
        TextColor3 = THEME.faint,
    }, heroChip)
    local changeBtn = make("TextButton", {
        Text = "CHANGE",
        Size = UDim2.fromOffset(52, 14),
        Position = UDim2.fromOffset(148, 48),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        TextSize = 7,
        TextColor3 = THEME.accent2,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, hero)
    local heroGrab = make("TextButton", {
        Text = "",
        Size = UDim2.fromOffset(94, 52),
        Position = UDim2.new(1, -104, 0, 15),
        BackgroundColor3 = THEME.accent,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        ClipsDescendants = true,
    }, hero)
    corner(heroGrab, 12)
    gradient(heroGrab, THEME.accent, THEME.accent2, 0)
    stroke(heroGrab, Color3.fromRGB(255, 210, 225), 1, 0.35)
    local heroGrabLabel = make("TextLabel", {
        Text = "HUG",
        Size = UDim2.new(1, 0, 0, 22),
        Position = UDim2.fromOffset(0, 8),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBlack,
        TextSize = 15,
        TextColor3 = Color3.fromRGB(30, 12, 24),
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = 3,
    }, heroGrab)
    local heroGrabSub = make("TextLabel", {
        Text = "GRAB TARGET",
        Size = UDim2.new(1, 0, 0, 12),
        Position = UDim2.fromOffset(0, 31),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 7,
        TextColor3 = Color3.fromRGB(74, 28, 44),
        TextXAlignment = Enum.TextXAlignment.Center,
        ZIndex = 3,
    }, heroGrab)
    local heroGrabScale = make("UIScale", { Scale = 1 }, heroGrab)
    STATE.ui.hero = hero
    STATE.ui.heroAvatar = heroAvatar
    STATE.ui.heroAvatarLetter = heroAvatarLetter
    STATE.ui.heroName = heroName
    STATE.ui.heroMeta = heroMeta
    STATE.ui.heroChip = heroChip
    STATE.ui.heroChipText = heroChipText
    STATE.ui.heroGrab = heroGrab
    STATE.ui.heroGrabLabel = heroGrabLabel
    STATE.ui.heroGrabSub = heroGrabSub
    STATE.ui.heroGrabScale = heroGrabScale
    STATE.ui.changeBtn = changeBtn

    -- tabs
    local tabBar = make("ScrollingFrame", {
        Name = "Tabs",
        Size = UDim2.new(1, -12, 0, 36),
        Position = UDim2.fromOffset(6, 152),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 2,
        ScrollBarImageColor3 = THEME.accent,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.X,
        ScrollingDirection = Enum.ScrollingDirection.X,
        ScrollingEnabled = true,
        ClipsDescendants = true,
    }, main)
    make("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 4),
        SortOrder = Enum.SortOrder.LayoutOrder,
        VerticalAlignment = Enum.VerticalAlignment.Center,
    }, tabBar)
    STATE.ui.tabBar = tabBar

    local pageHost = make("Frame", {
        Name = "Pages",
        Size = UDim2.new(1, -12, 1, -216),
        Position = UDim2.fromOffset(6, 192),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
    }, main)
    STATE.ui.pageHost = pageHost

    local footer = make("Frame", {
        Name = "Footer",
        Size = UDim2.new(1, 0, 0, 24),
        Position = UDim2.new(0, 0, 1, -24),
        BackgroundColor3 = THEME.panel,
        BorderSizePixel = 0,
    }, main)
    make("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = THEME.line,
        BorderSizePixel = 0,
        BackgroundTransparency = 0.4,
    }, footer)
    local footerDot = make("Frame", {
        Size = UDim2.fromOffset(5, 5),
        Position = UDim2.fromOffset(11, 9.5),
        BackgroundColor3 = THEME.mint,
        BorderSizePixel = 0,
    }, footer)
    corner(footerDot, 3)
    local footerText = make("TextLabel", {
        Text = "READY",
        Size = UDim2.new(1, -200, 1, 0),
        Position = UDim2.fromOffset(22, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 8,
        TextColor3 = THEME.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, footer)
    local perfLabel = make("TextLabel", {
        Text = "FPS --  ·  --ms",
        Size = UDim2.fromOffset(170, 1),
        Position = UDim2.new(1, -178, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 8,
        TextColor3 = THEME.faint,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, footer)
    STATE.ui.footerDot = footerDot
    STATE.ui.footerText = footerText
    STATE.ui.perfLabel = perfLabel

    local pages = STATE.pages
    local pageGroups = {}
    local tabButtons = {}
    local activePage = nil
    local pageHooks = {}
    STATE.ui.pageGroups = pageGroups
    STATE.ui.tabButtons = tabButtons
    STATE.ui.pageHooks = pageHooks

    local function createPage(id, label, icon)
        local btn = make("TextButton", {
            Text = "",
            Size = UDim2.fromOffset(77, 32),
            BackgroundColor3 = THEME.card,
            BackgroundTransparency = 0.35,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            LayoutOrder = #tabButtons + 1,
            ClipsDescendants = true,
        }, tabBar)
        corner(btn, 8)
        local iconLabel = make("TextLabel", {
            Text = icon,
            Size = UDim2.fromOffset(16, 16),
            Position = UDim2.fromOffset(7, 7),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextColor3 = THEME.dim,
            TextXAlignment = Enum.TextXAlignment.Center,
        }, btn)
        local textLabel = make("TextLabel", {
            Text = label,
            Size = UDim2.new(1, -26, 1, 0),
            Position = UDim2.fromOffset(24, -2),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 8,
            TextColor3 = THEME.dim,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, btn)
        local underline = make("Frame", {
            Size = UDim2.new(0.58, 0, 0, 2),
            Position = UDim2.new(0.21, 0, 1, -3),
            BackgroundColor3 = THEME.accent,
            BorderSizePixel = 0,
            Visible = false,
        }, btn)
        corner(underline, 1)
        gradient(underline, THEME.accent, THEME.accent2, 0)

        local okGroup, group = pcall(function()
            return Instance.new("CanvasGroup")
        end)
        if not okGroup or not group then
            group = Instance.new("Frame")
        end
        group.Name = id
        group.Size = UDim2.new(1, 0, 1, 0)
        group.BackgroundTransparency = 1
        group.BorderSizePixel = 0
        group.Visible = false
        pcall(function() group.GroupTransparency = 0 end)
        group.Parent = pageHost
        local scroll = make("ScrollingFrame", {
            Name = id .. "Scroll",
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ScrollBarThickness = 3,
            ScrollBarImageColor3 = THEME.accent,
            CanvasSize = UDim2.new(0, 0, 0, 0),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollingDirection = Enum.ScrollingDirection.Y,
            ScrollingEnabled = true,
            ClipsDescendants = true,
        }, group)
        make("UIListLayout", {
            Padding = UDim.new(0, 6),
            SortOrder = Enum.SortOrder.LayoutOrder,
        }, scroll)
        padding(scroll, 2, 7, 4, 14)
        pages[id] = scroll
        pageGroups[id] = group
        tabButtons[id] = {
            Button = btn,
            Icon = iconLabel,
            Text = textLabel,
            Underline = underline,
        }

        btn.MouseButton1Click:Connect(function()
            if activePage == id then return end
            H.showPage(id)
        end)
        btn.MouseEnter:Connect(function()
            if activePage ~= id then btn.BackgroundTransparency = 0.1 end
        end)
        btn.MouseLeave:Connect(function()
            if activePage ~= id then btn.BackgroundTransparency = 0.35 end
        end)
        return scroll
    end

    local function showPage(id)
        if STATE.unloaded then return end
        if not pages[id] then return end
        for key, group in pairs(pageGroups) do
            local active = key == id
            group.Visible = active
            local refs = tabButtons[key]
            if refs then
                refs.Button.BackgroundColor3 = active and THEME.cardOn or THEME.card
                refs.Button.BackgroundTransparency = active and 0 or 0.35
                refs.Text.TextColor3 = active and THEME.text or THEME.dim
                refs.Icon.TextColor3 = active and THEME.accent2 or THEME.dim
                refs.Underline.Visible = active
            end
        end
        local group = pageGroups[id]
        pcall(function() group.GroupTransparency = 1 end)
        pcall(function() group.Position = UDim2.fromOffset(7, 0) end)
        tween(group, { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) }, 0.22)
        activePage = id
        STATE.ui.activePage = id
        for _, hook in ipairs(pageHooks) do
            pcall(hook, id)
        end
        local refs = tabButtons[id]
        if refs then
            pcall(function()
                local parent = tabBar
                local target = refs.Button
                local x = target.AbsolutePosition.X - parent.AbsolutePosition.X + parent.CanvasPosition.X
                local width = tabBar.AbsoluteSize.X
                if x < parent.CanvasPosition.X + 8 then
                    parent.CanvasPosition = Vector2.new(math.max(0, x - 8), 0)
                elseif x + target.AbsoluteSize.X > parent.CanvasPosition.X + width - 8 then
                    parent.CanvasPosition = Vector2.new(
                        x + target.AbsoluteSize.X - width + 8, 0)
                end
            end)
        end
    end
    STATE.ui.showPage = showPage

    local function section(page, titleText)
        local box = make("Frame", {
            Size = UDim2.new(1, -4, 0, 24),
            BackgroundTransparency = 1,
        }, page)
        local dot = make("Frame", {
            Size = UDim2.fromOffset(4, 4),
            Position = UDim2.fromOffset(2, 10),
            BackgroundColor3 = THEME.accent,
            BorderSizePixel = 0,
        }, box)
        corner(dot, 2)
        make("TextLabel", {
            Text = string.upper(titleText),
            Size = UDim2.new(0, 150, 1, 0),
            Position = UDim2.fromOffset(12, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBlack,
            TextSize = 9,
            TextColor3 = THEME.accent2,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, box)
        make("Frame", {
            Size = UDim2.new(1, -176, 0, 1),
            Position = UDim2.fromOffset(170, 12),
            BackgroundColor3 = THEME.line,
            BorderSizePixel = 0,
            BackgroundTransparency = 0.3,
        }, box)
        return box
    end

    local function note(page, text, color)
        return make("TextLabel", {
            Text = text,
            Size = UDim2.new(1, -4, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 9,
            TextColor3 = color or THEME.faint,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
            LineHeight = 1.15,
        }, page)
    end

    local function disclaimer(page, text, color)
        local label = make("TextLabel", {
            Text = text,
            Size = UDim2.new(1, -4, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = THEME.card,
            BorderSizePixel = 0,
            Font = Enum.Font.Gotham,
            TextSize = 9,
            TextColor3 = color or THEME.dim,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            TextWrapped = true,
            LineHeight = 1.15,
        }, page)
        corner(label, 8)
        stroke(label, THEME.line, 1, 0.55)
        padding(label, 12, 10, 9, 9)
        local bar = make("Frame", {
            Size = UDim2.fromOffset(2, 0),
            Position = UDim2.fromOffset(0, 8),
            BackgroundColor3 = color or THEME.accent2,
            BorderSizePixel = 0,
            ZIndex = 2,
        }, label)
        local function sizeBar()
            pcall(function()
                bar.Size = UDim2.new(0, 2, 1, -16)
            end)
        end
        task.defer(sizeBar)
        return label
    end

    local function spacer(page, height)
        return make("Frame", {
            Size = UDim2.new(1, -4, 0, height or 4),
            BackgroundTransparency = 1,
        }, page)
    end

    local toasts = {}
    local toastHolder = make("Frame", {
        Name = "Toasts",
        Size = UDim2.new(0, 280, 1, -24),
        Position = UDim2.new(1, -292, 0, 12),
        BackgroundTransparency = 1,
        ZIndex = 40,
    }, screen)
    make("UIListLayout", {
        VerticalAlignment = Enum.VerticalAlignment.Top,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        Padding = UDim.new(0, 7),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, toastHolder)
    STATE.ui.toastHolder = toastHolder

    local function toast(titleText, body, duration, kind)
        if STATE.unloaded or not screen.Enabled then return end
        local color
        if kind == "err" then color = THEME.red
        elseif kind == "warn" then color = THEME.accent2
        elseif kind == "info" then color = THEME.blue
        else color = THEME.mint end
        local okCard, card = pcall(function()
            return Instance.new("CanvasGroup")
        end)
        if not okCard or not card then
            card = Instance.new("Frame")
        end
        card.Name = "Toast"
        card.Size = UDim2.new(1, 0, 0, 60)
        card.BackgroundColor3 = THEME.panel
        card.BorderSizePixel = 0
        card.ZIndex = 41
        pcall(function() card.GroupTransparency = 1 end)
        card.Parent = toastHolder
        corner(card, 10)
        stroke(card, color, 1, 0.2)
        make("Frame", {
            Size = UDim2.fromOffset(3, 42),
            Position = UDim2.fromOffset(0, 9),
            BackgroundColor3 = color,
            BorderSizePixel = 0,
            ZIndex = 42,
        }, card)
        make("TextLabel", {
            Text = titleText,
            Size = UDim2.new(1, -24, 0, 15),
            Position = UDim2.fromOffset(12, 7),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBlack,
            TextSize = 9,
            TextColor3 = color,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            ZIndex = 42,
        }, card)
        make("TextLabel", {
            Text = body or "",
            Size = UDim2.new(1, -24, 0, 26),
            Position = UDim2.fromOffset(12, 22),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 9,
            TextColor3 = THEME.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            TextTruncate = Enum.TextTruncate.AtEnd,
            ZIndex = 42,
        }, card)
        local progress = make("Frame", {
            Size = UDim2.new(1, -24, 0, 2),
            Position = UDim2.new(0, 12, 1, -5),
            BackgroundColor3 = color,
            BorderSizePixel = 0,
            BackgroundTransparency = 0.35,
            ZIndex = 42,
        }, card)
        corner(progress, 1)
        local track = make("UIScale", { Scale = 0.96 }, card)
        table.insert(toasts, card)
        while #toasts > 4 do
            local old = table.remove(toasts, 1)
            if old then pcall(function() old:Destroy() end) end
        end
        pcall(function() card.GroupTransparency = 1 end)
        tween(card, { GroupTransparency = 0 }, 0.2)
        tween(track, { Scale = 1 }, 0.24, Enum.EasingStyle.Back)
        tween(progress, { Size = UDim2.new(0, 0, 0, 2) }, duration or 3.2,
            Enum.EasingStyle.Linear)
        task.delay(duration or 3.2, function()
            if not card or not card.Parent then return end
            tween(card, { GroupTransparency = 1 }, 0.22)
            task.delay(0.25, function()
                for index, item in ipairs(toasts) do
                    if item == card then table.remove(toasts, index) break end
                end
                pcall(function() card:Destroy() end)
            end)
        end)
    end
    STATE.ui.toast = toast

    local function setStatus(text, kind)
        if STATE.unloaded then return end
        local color
        if kind == "err" then color = THEME.red
        elseif kind == "warn" then color = THEME.accent2
        elseif kind == "ok" then color = THEME.mint
        elseif kind == "busy" then color = THEME.blue
        else color = THEME.faint end
        pcall(function()
            footerText.Text = tostring(text or "READY")
            footerDot.BackgroundColor3 = color
        end)
    end
    STATE.ui.setStatus = setStatus

    local function flashLabel(text)
        if STATE.ui.flashLabel then
            pcall(function() STATE.ui.flashLabel.Text = text end)
        end
    end
    STATE.ui.flashLabel = flashLabel

    -- switch painting
    local function paintSwitch(row, track, knob, status, on, isError)
        if not row then return end
        if on then
            row.BackgroundColor3 = THEME.cardOn
            track.BackgroundColor3 = THEME.accent
            tween(knob, { Position = UDim2.new(0, 21, 0.5, -8) }, 0.18,
                Enum.EasingStyle.Back)
            status.Text = isError and "ERROR" or "ON"
            status.TextColor3 = isError and THEME.red or THEME.mint
        else
            row.BackgroundColor3 = THEME.card
            track.BackgroundColor3 = Color3.fromRGB(55, 46, 76)
            tween(knob, { Position = UDim2.new(0, 4, 0.5, -8) }, 0.18,
                Enum.EasingStyle.Back)
            status.Text = isError and "ERROR" or "OFF"
            status.TextColor3 = isError and THEME.red or THEME.faint
        end
    end

    local function toggleRow(page, id, titleText, desc, default, callback)
        local height = desc and 50 or 42
        local row = make("TextButton", {
            Text = "",
            Size = UDim2.new(1, -4, 0, height),
            BackgroundColor3 = default and THEME.cardOn or THEME.card,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            ClipsDescendants = true,
        }, page)
        corner(row, 9)
        local rowStroke = stroke(row, THEME.line, 1, 0.5)
        make("TextLabel", {
            Text = titleText,
            Size = UDim2.new(1, -104, 0, 16),
            Position = UDim2.fromOffset(10, desc and 6 or 4),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 9,
            TextColor3 = THEME.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
        if desc then
            make("TextLabel", {
                Text = desc,
                Size = UDim2.new(1, -104, 0, 14),
                Position = UDim2.fromOffset(10, 23),
                BackgroundTransparency = 1,
                Font = Enum.Font.Gotham,
                TextSize = 8,
                TextColor3 = THEME.faint,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
            }, row)
        end
        local status = make("TextLabel", {
            Text = default and "ON" or "OFF",
            Size = UDim2.fromOffset(38, 10),
            Position = UDim2.new(1, -96, 0, 6),
            BackgroundTransparency = 1,
            Font = Enum.Font.Code,
            TextSize = 7,
            TextColor3 = default and THEME.mint or THEME.faint,
            TextXAlignment = Enum.TextXAlignment.Right,
        }, row)
        local track = make("Frame", {
            Size = UDim2.fromOffset(40, 22),
            Position = UDim2.new(1, -46, 0.5, -11),
            BackgroundColor3 = default and THEME.accent or Color3.fromRGB(55, 46, 76),
            BorderSizePixel = 0,
        }, row)
        corner(track, 11)
        local knob = make("Frame", {
            Size = UDim2.fromOffset(16, 16),
            Position = UDim2.new(0, default and 21 or 4, 0.5, -8),
            BackgroundColor3 = Color3.fromRGB(255, 250, 255),
            BorderSizePixel = 0,
        }, track)
        corner(knob, 8)

        local enabled = default == true
        local busy = false
        local errored = false

        local function set(value, silent)
            if STATE.unloaded then return end
            if busy then
                if not silent then toast("BUSY", "The previous toggle is still running.", 2, "warn") end
                return
            end
            value = value == true
            local previous = enabled
            enabled = value
            STATE.toggles[id] = value
            errored = false
            paintSwitch(row, track, knob, status, value, false)
            rowStroke.Transparency = value and 0.15 or 0.5
            rowStroke.Color = value and THEME.accent or THEME.line
            if not silent then flashLabel(titleText .. "  " .. (value and "ON" or "OFF")) end
            if not callback then return end
            busy = true
            task.spawn(function()
                local ok, result, reason = pcall(callback, value)
                busy = false
                if STATE.unloaded then return end
                if not ok or result == false then
                    local message = reason
                    if not ok then message = result end
                    message = tostring(message or "callback failed")
                    enabled = previous
                    STATE.toggles[id] = previous
                    errored = true
                    paintSwitch(row, track, knob, status, previous, true)
                    rowStroke.Color = THEME.red
                    rowStroke.Transparency = 0.1
                    log("toggle " .. id .. ": " .. message, true)
                    toast(titleText, message, 4, "err")
                else
                    paintSwitch(row, track, knob, status, enabled, false)
                    rowStroke.Transparency = enabled and 0.15 or 0.5
                    rowStroke.Color = enabled and THEME.accent or THEME.line
                end
            end)
        end

        row.MouseButton1Click:Connect(function()
            set(not enabled)
        end)
        STATE.toggles[id] = enabled
        STATE.switches[id] = {
            Set = set,
            Get = function() return enabled end,
            Row = row,
        }
        return STATE.switches[id]
    end

    local function buttonRow(page, label, desc, callback, accent)
        local height = desc and 44 or 36
        local row = make("TextButton", {
            Text = "",
            Size = UDim2.new(1, -4, 0, height),
            BackgroundColor3 = accent and Color3.fromRGB(55, 30, 51) or THEME.card,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            ClipsDescendants = true,
        }, page)
        corner(row, 9)
        local rowStroke = stroke(row, accent and THEME.accent or THEME.line, 1, accent and 0.3 or 0.55)
        if accent then
            gradient(row, Color3.fromRGB(66, 29, 56), THEME.card, 0, NumberSequence and NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.35),
                NumberSequenceKeypoint.new(1, 0.9),
            }) or nil)
        end
        make("TextLabel", {
            Text = label,
            Size = UDim2.new(1, -70, 0, 15),
            Position = UDim2.fromOffset(10, desc and 6 or 9),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 9,
            TextColor3 = accent and THEME.text or THEME.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
        if desc then
            make("TextLabel", {
                Text = desc,
                Size = UDim2.new(1, -70, 0, 14),
                Position = UDim2.fromOffset(10, 22),
                BackgroundTransparency = 1,
                Font = Enum.Font.Gotham,
                TextSize = 8,
                TextColor3 = accent and THEME.dim or THEME.faint,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
            }, row)
        end
        local chip = make("TextLabel", {
            Text = "RUN",
            Size = UDim2.fromOffset(42, 16),
            Position = UDim2.new(1, -52, 0.5, -8),
            BackgroundTransparency = 1,
            Font = Enum.Font.Code,
            TextSize = 8,
            TextColor3 = accent and THEME.accent2 or THEME.faint,
            TextXAlignment = Enum.TextXAlignment.Right,
        }, row)
        local scale = make("UIScale", { Scale = 1 }, row)
        local busy = false
        row.MouseButton1Click:Connect(function()
            if STATE.unloaded then return end
            if busy then
                toast("BUSY", "That action is still running.", 2, "warn")
                return
            end
            busy = true
            chip.Text = "..."
            flashLabel(label)
            tween(scale, { Scale = 0.975 }, 0.08)
            tween(rowStroke, { Transparency = 0.05 }, 0.08)
            task.delay(0.12, function()
                if not row or not row.Parent then return end
                tween(scale, { Scale = 1 }, 0.18, Enum.EasingStyle.Back)
                tween(rowStroke, { Transparency = accent and 0.3 or 0.55 }, 0.18)
            end)
            task.spawn(function()
                local ok, result, reason = pcall(callback)
                busy = false
                if STATE.unloaded or not row or not row.Parent then return end
                if not ok or result == false then
                    chip.Text = "FAIL"
                    chip.TextColor3 = THEME.red
                    local message = reason
                    if not ok then message = result end
                    toast(label, tostring(message or "action failed"), 4, "err")
                    log("button " .. label .. ": " .. tostring(message or "failed"), true)
                else
                    chip.Text = "OK"
                    chip.TextColor3 = THEME.mint
                end
                task.delay(1.1, function()
                    if not row or not row.Parent then return end
                    chip.Text = "RUN"
                    chip.TextColor3 = accent and THEME.accent2 or THEME.faint
                end)
            end)
        end)
        return row
    end

    -- one shared drag controller for all sliders
    local drag = nil
    local function stopDrag()
        if drag then
            pcall(function()
                if drag.scroll then drag.scroll.ScrollingEnabled = true end
                if drag.knob then drag.knob.BackgroundColor3 = THEME.text end
            end)
            drag = nil
        end
    end
    connect(UserInput.InputChanged, function(input)
        if not drag then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            drag.apply(input.Position.X)
        end
    end)
    connect(UserInput.InputEnded, function(input)
        if not drag then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            stopDrag()
        end
    end)

    local function sliderRow(page, titleText, low, high, default, suffix, callback)
        local box = make("Frame", {
            Size = UDim2.new(1, -4, 0, 48),
            BackgroundColor3 = THEME.card,
            BorderSizePixel = 0,
        }, page)
        corner(box, 9)
        stroke(box, THEME.line, 1, 0.55)
        local label = make("TextLabel", {
            Text = string.format("%s: %d%s", titleText, round(default), suffix or ""),
            Size = UDim2.new(1, -18, 0, 16),
            Position = UDim2.fromOffset(10, 5),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 9,
            TextColor3 = THEME.text,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, box)
        local hit = make("TextButton", {
            Text = "",
            Size = UDim2.new(1, -16, 0, 24),
            Position = UDim2.fromOffset(8, 22),
            BackgroundTransparency = 1,
            AutoButtonColor = false,
        }, box)
        local track = make("Frame", {
            Size = UDim2.new(1, -8, 0, 5),
            Position = UDim2.fromOffset(4, 9),
            BackgroundColor3 = Color3.fromRGB(55, 46, 76),
            BorderSizePixel = 0,
        }, hit)
        corner(track, 3)
        local fraction = clamp((default - low) / math.max(high - low, 1), 0, 1)
        local fill = make("Frame", {
            Size = UDim2.new(fraction, 0, 1, 0),
            BackgroundColor3 = THEME.accent,
            BorderSizePixel = 0,
        }, track)
        corner(fill, 3)
        gradient(fill, THEME.accent, THEME.accent2, 0)
        local thumb = make("Frame", {
            Size = UDim2.fromOffset(13, 13),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(fraction, 0, 0.5, 0),
            BackgroundColor3 = THEME.text,
            BorderSizePixel = 0,
        }, track)
        corner(thumb, 7)
        local value = default

        local function applyPixel(px)
            local width = math.max(track.AbsoluteSize.X, 1)
            local alpha = clamp((px - track.AbsolutePosition.X) / width, 0, 1)
            value = round(low + (high - low) * alpha)
            local percent = (value - low) / math.max(high - low, 1)
            fill.Size = UDim2.new(percent, 0, 1, 0)
            thumb.Position = UDim2.new(percent, 0, 0.5, 0)
            label.Text = string.format("%s: %d%s", titleText, value, suffix or "")
            if callback then
                local ok, err = pcall(callback, value)
                if not ok then log("slider " .. titleText .. ": " .. tostring(err), true) end
            end
        end

        local function setValue(newValue)
            newValue = clamp(round(newValue), low, high)
            value = newValue
            local percent = (newValue - low) / math.max(high - low, 1)
            fill.Size = UDim2.new(percent, 0, 1, 0)
            thumb.Position = UDim2.new(percent, 0, 0.5, 0)
            label.Text = string.format("%s: %d%s", titleText, newValue, suffix or "")
            if callback then
                local ok, err = pcall(callback, newValue)
                if not ok then log("slider " .. titleText .. ": " .. tostring(err), true) end
            end
        end

        hit.InputBegan:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseButton1
                and input.UserInputType ~= Enum.UserInputType.Touch then
                return
            end
            local targetScroll = page
            while targetScroll and not targetScroll:IsA("ScrollingFrame") do
                targetScroll = targetScroll.Parent
            end
            drag = { apply = applyPixel, scroll = targetScroll, knob = thumb }
            if targetScroll then targetScroll.ScrollingEnabled = false end
            thumb.BackgroundColor3 = THEME.accent2
            applyPixel(input.Position.X)
        end)
        hit.MouseButton1Click:Connect(function()
            if not drag then applyPixel(UserInput:GetMouseLocation().X) end
        end)

        return {
            Set = setValue,
            Get = function() return value end,
            Box = box,
            Label = label,
        }
    end

    local function choiceRow(page, titleText, options, default, callback)
        local index = 1
        for i, option in ipairs(options) do
            if tostring(option) == tostring(default) then index = i break end
        end
        local box = make("Frame", {
            Size = UDim2.new(1, -4, 0, 38),
            BackgroundColor3 = THEME.card,
            BorderSizePixel = 0,
        }, page)
        corner(box, 9)
        stroke(box, THEME.line, 1, 0.55)
        local label = make("TextLabel", {
            Text = titleText .. ":  " .. tostring(options[index] or ""),
            Size = UDim2.new(1, -64, 1, 0),
            Position = UDim2.fromOffset(10, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 9,
            TextColor3 = THEME.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, box)
        local prev = make("TextButton", {
            Text = "‹",
            Size = UDim2.fromOffset(26, 30),
            Position = UDim2.new(1, -58, 0.5, -15),
            BackgroundColor3 = THEME.cardOn,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Font = Enum.Font.GothamBold,
            TextSize = 14,
            TextColor3 = THEME.dim,
        }, box)
        corner(prev, 7)
        local nextBtn = make("TextButton", {
            Text = "›",
            Size = UDim2.fromOffset(26, 30),
            Position = UDim2.new(1, -30, 0.5, -15),
            BackgroundColor3 = THEME.cardOn,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Font = Enum.Font.GothamBold,
            TextSize = 14,
            TextColor3 = THEME.dim,
        }, box)
        corner(nextBtn, 7)
        local function apply(delta)
            index = index + delta
            if index < 1 then index = #options end
            if index > #options then index = 1 end
            label.Text = titleText .. ":  " .. tostring(options[index] or "")
            if callback then
                local ok, err = pcall(callback, options[index])
                if not ok then
                    log("choice " .. titleText .. ": " .. tostring(err), true)
                end
            end
        end
        prev.MouseButton1Click:Connect(function() apply(-1) end)
        nextBtn.MouseButton1Click:Connect(function() apply(1) end)
        label.Text = titleText .. ":  " .. tostring(options[index] or "")
        return {
            Get = function() return options[index] end,
            Set = function(value)
                for i, option in ipairs(options) do
                    if tostring(option) == tostring(value) then
                        index = i
                        label.Text = titleText .. ":  " .. tostring(options[index] or "")
                        return
                    end
                end
            end,
        }
    end

    local function statRow(page, labelText, initial)
        local row = make("Frame", {
            Size = UDim2.new(1, -4, 0, 26),
            BackgroundColor3 = THEME.card,
            BorderSizePixel = 0,
        }, page)
        corner(row, 7)
        make("TextLabel", {
            Text = labelText,
            Size = UDim2.new(0.55, -10, 1, 0),
            Position = UDim2.fromOffset(9, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 8,
            TextColor3 = THEME.dim,
            TextXAlignment = Enum.TextXAlignment.Left,
        }, row)
        local value = make("TextLabel", {
            Text = initial or "-",
            Size = UDim2.new(0.45, -10, 1, 0),
            Position = UDim2.new(0.55, 0, 0, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.Code,
            TextSize = 8,
            TextColor3 = THEME.text,
            TextXAlignment = Enum.TextXAlignment.Right,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
        return value
    end

    STATE.ui.make = make
    STATE.ui.corner = corner
    STATE.ui.stroke = stroke
    STATE.ui.gradient = gradient
    STATE.ui.padding = padding
    STATE.ui.tween = tween
    STATE.ui.section = section
    STATE.ui.note = note
    STATE.ui.disclaimer = disclaimer
    STATE.ui.spacer = spacer
    STATE.ui.toggleRow = toggleRow
    STATE.ui.buttonRow = buttonRow
    STATE.ui.sliderRow = sliderRow
    STATE.ui.choiceRow = choiceRow
    STATE.ui.statRow = statRow
    STATE.ui.showPage = showPage
    STATE.ui.createPage = createPage

    -- hero button animation
    local function pressHero()
        tween(heroGrabScale, { Scale = 0.955 }, 0.08)
        tween(heroGrab, { BackgroundTransparency = 0.06 }, 0.08)
        task.delay(0.11, function()
            if not heroGrab or not heroGrab.Parent then return end
            tween(heroGrabScale, { Scale = 1 }, 0.22, Enum.EasingStyle.Back)
            tween(heroGrab, { BackgroundTransparency = 0 }, 0.18)
        end)
    end
    heroGrab.MouseButton1Click:Connect(function()
        pressHero()
        if STATE.ui.heroAction then
            local ok, err = pcall(STATE.ui.heroAction)
            if not ok then log("hero action: " .. tostring(err), true) end
        else
            toast("NOT READY", "The grab engine is still starting.", 2, "warn")
        end
    end)
    changeBtn.MouseButton1Click:Connect(function()
        if STATE.ui.openPlayerModal then STATE.ui.openPlayerModal() end
    end)

    -- player picker modal
    local modalBackdrop = make("TextButton", {
        Name = "ModalBackdrop",
        Text = "",
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundColor3 = Color3.fromRGB(4, 2, 9),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Visible = false,
        ZIndex = 60,
    }, screen)
    local modal = make("Frame", {
        Name = "PlayerModal",
        Size = UDim2.fromOffset(420, 470),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        BackgroundColor3 = THEME.panel,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 61,
        ClipsDescendants = true,
    }, screen)
    corner(modal, 14)
    stroke(modal, THEME.accent, 1.2, 0.35)
    local modalScale = make("UIScale", { Scale = 0.94 }, modal)
    make("Frame", {
        Size = UDim2.new(1, 0, 0, 2),
        BackgroundColor3 = THEME.accent,
        BorderSizePixel = 0,
        ZIndex = 62,
    }, modal)
    gradient(modal:FindFirstChildWhichIsA("Frame"), THEME.accent, THEME.accent2, 0)
    make("TextLabel", {
        Text = "CHOOSE A TARGET",
        Size = UDim2.new(0, 240, 0, 18),
        Position = UDim2.fromOffset(14, 11),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBlack,
        TextSize = 11,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 62,
    }, modal)
    local modalCount = make("TextLabel", {
        Text = "",
        Size = UDim2.new(0, 100, 0, 12),
        Position = UDim2.new(1, -144, 0, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 8,
        TextColor3 = THEME.faint,
        TextXAlignment = Enum.TextXAlignment.Right,
        ZIndex = 62,
    }, modal)
    local modalClose = make("TextButton", {
        Text = "×",
        Size = UDim2.fromOffset(28, 26),
        Position = UDim2.new(1, -38, 0, 8),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextColor3 = THEME.dim,
        ZIndex = 62,
    }, modal)
    corner(modalClose, 7)
    local searchBox = make("TextBox", {
        Text = "",
        PlaceholderText = "Search players...",
        PlaceholderColor3 = THEME.faint,
        Size = UDim2.new(1, -28, 0, 32),
        Position = UDim2.fromOffset(14, 42),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        Font = Enum.Font.Gotham,
        TextSize = 10,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false,
        ZIndex = 62,
    }, modal)
    corner(searchBox, 8)
    stroke(searchBox, THEME.line, 1, 0.4)
    padding(searchBox, 12, 10, 0, 0)
    local searchIcon = make("TextLabel", {
        Text = "⌕",
        Size = UDim2.fromOffset(26, 32),
        Position = UDim2.new(1, -40, 0, 42),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 15,
        TextColor3 = THEME.faint,
        ZIndex = 62,
    }, modal)
    local modalList = make("ScrollingFrame", {
        Size = UDim2.new(1, -24, 1, -120),
        Position = UDim2.fromOffset(12, 82),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = THEME.accent,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        ZIndex = 62,
    }, modal)
    make("UIListLayout", {
        Padding = UDim.new(0, 5),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, modalList)
    padding(modalList, 1, 5, 1, 4)
    local modalEmpty = make("TextLabel", {
        Text = "No players match that search.",
        Size = UDim2.new(1, -24, 0, 40),
        Position = UDim2.new(0, 12, 1, -44),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextColor3 = THEME.faint,
        Visible = false,
        ZIndex = 62,
    }, modal)
    local modalNote = make("TextLabel", {
        Text = "Rows are sorted by distance. Tap a row to lock the target.",
        Size = UDim2.new(1, -24, 0, 14),
        Position = UDim2.new(0, 12, 1, -18),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 7,
        TextColor3 = THEME.faint,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 62,
    }, modal)
    STATE.ui.modal = modal
    STATE.ui.modalBackdrop = modalBackdrop
    STATE.ui.modalList = modalList
    STATE.ui.searchBox = searchBox

    local modalRows = {}
    local modalOpen = false
    STATE.ui.modalOpen = false
    local modalSignature = ""

    local function clearModalRows()
        for _, row in ipairs(modalRows) do
            pcall(function() row:Destroy() end)
        end
        modalRows = {}
    end

    local function playerStatus(player)
        if STATE.carry.carrying == player then return "CARRYING", THEME.mint end
        if STATE.carry.carrier == player then return "GRABBING YOU", THEME.red end
        if not isAlive(player) then return "DEAD", THEME.faint end
        local prompt = H.findGrabPrompt and H.findGrabPrompt(player)
        if prompt then return "PROMPT", THEME.accent2 end
        return "NO PROMPT", THEME.faint
    end

    local function renderModal()
        if not modalOpen or STATE.unloaded then return end
        local query = string.lower(tostring(searchBox.Text or ""))
        local list = {}
        local signatureParts = { query }
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LP then
                local name = string.lower(showName(player) .. " " .. tostring(player.Name))
                if query == "" or string.find(name, query, 1, true) then
                    table.insert(list, player)
                end
            end
        end
        table.sort(list, function(a, b)
            return distanceTo(a) < distanceTo(b)
        end)
        for _, player in ipairs(list) do
            local label, _ = playerStatus(player)
            table.insert(signatureParts, tostring(player.UserId) .. ":" .. label)
        end
        local signature = table.concat(signatureParts, "|")
        modalCount.Text = tostring(#list) .. " ONLINE"
        modalEmpty.Visible = #list == 0
        if signature == modalSignature then return end
        modalSignature = signature
        clearModalRows()
        for index, player in ipairs(list) do
            local dist = distanceTo(player)
            local label, colour = playerStatus(player)
            local row = make("Frame", {
                Size = UDim2.new(1, -2, 0, 54),
                BackgroundColor3 = THEME.card,
                BorderSizePixel = 0,
                LayoutOrder = index,
            }, modalList)
            corner(row, 9)
            stroke(row, label == "PROMPT" and THEME.accent or THEME.line, 1,
                label == "PROMPT" and 0.35 or 0.55)
            local avatar = make("Frame", {
                Size = UDim2.fromOffset(30, 30),
                Position = UDim2.fromOffset(10, 12),
                BackgroundColor3 = THEME.cardOn,
                BorderSizePixel = 0,
            }, row)
            corner(avatar, 15)
            local initial = string.sub(showName(player), 1, 1)
            make("TextLabel", {
                Text = string.upper(initial == "" and "?" or initial),
                Size = UDim2.new(1, 0, 1, 0),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamBlack,
                TextSize = 12,
                TextColor3 = colour,
            }, avatar)
            local selectBtn = make("TextButton", {
                Text = "",
                Size = UDim2.new(1, -74, 1, 0),
                BackgroundTransparency = 1,
                AutoButtonColor = false,
            }, row)
            make("TextLabel", {
                Text = showName(player),
                Size = UDim2.new(1, -8, 0, 15),
                Position = UDim2.fromOffset(48, 6),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamBold,
                TextSize = 10,
                TextColor3 = THEME.text,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
            }, selectBtn)
            make("TextLabel", {
                Text = string.format("%s  ·  %d studs  ·  %d HP",
                    label, round(dist), round((getHum(player) and getHum(player).Health) or 0)),
                Size = UDim2.new(1, -8, 0, 12),
                Position = UDim2.fromOffset(48, 23),
                BackgroundTransparency = 1,
                Font = Enum.Font.Gotham,
                TextSize = 8,
                TextColor3 = colour,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
            }, selectBtn)
            selectBtn.MouseButton1Click:Connect(function()
                if H.selectTarget then
                    H.selectTarget(player, true)
                end
                if STATE.ui.closePlayerModal then STATE.ui.closePlayerModal() end
            end)
            local tpBtn = make("TextButton", {
                Text = "GO",
                Size = UDim2.fromOffset(36, 28),
                Position = UDim2.new(1, -48, 0.5, -14),
                BackgroundColor3 = THEME.cardOn,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                Font = Enum.Font.Code,
                TextSize = 8,
                TextColor3 = THEME.accent2,
            }, row)
            corner(tpBtn, 7)
            tpBtn.MouseButton1Click:Connect(function()
                if H.selectTarget then H.selectTarget(player, false) end
                if STATE.ui.closePlayerModal then STATE.ui.closePlayerModal() end
                if H.teleportBehind then
                    local ok, err = pcall(H.teleportBehind, player)
                    if not ok then log("teleport: " .. tostring(err), true) end
                end
            end)
            table.insert(modalRows, row)
        end
    end

    local function openPlayerModal()
        if STATE.unloaded then return end
        modalOpen = true
        STATE.ui.modalOpen = true
        modalBackdrop.Visible = true
        modal.Visible = true
        modalSignature = ""
        modalBackdrop.BackgroundTransparency = 1
        modalScale.Scale = 0.94
        tween(modalBackdrop, { BackgroundTransparency = 0.48 }, 0.18)
        tween(modalScale, { Scale = 1 }, 0.24, Enum.EasingStyle.Back)
        renderModal()
    end
    local function closePlayerModal()
        if not modalOpen then return end
        modalOpen = false
        STATE.ui.modalOpen = false
        tween(modalBackdrop, { BackgroundTransparency = 1 }, 0.16)
        tween(modalScale, { Scale = 0.94 }, 0.15)
        task.delay(0.17, function()
            if modalOpen then return end
            modalBackdrop.Visible = false
            modal.Visible = false
        end)
    end
    STATE.ui.openPlayerModal = openPlayerModal
    STATE.ui.closePlayerModal = closePlayerModal
    modalClose.MouseButton1Click:Connect(closePlayerModal)
    modalBackdrop.MouseButton1Click:Connect(closePlayerModal)
    searchBox:GetPropertyChangedSignal("Text"):Connect(function()
        modalSignature = ""
        renderModal()
    end)
    STATE.ui.renderModal = renderModal

    -- confirmation modal
    local confirmBackdrop = make("TextButton", {
        Text = "",
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundColor3 = Color3.fromRGB(4, 2, 9),
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Visible = false,
        ZIndex = 70,
    }, screen)
    local confirmCard = make("Frame", {
        Size = UDim2.fromOffset(330, 176),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0.5, 0, 0.5, 0),
        BackgroundColor3 = THEME.panel,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 71,
    }, screen)
    corner(confirmCard, 14)
    stroke(confirmCard, THEME.red, 1.2, 0.35)
    local confirmScale = make("UIScale", { Scale = 0.94 }, confirmCard)
    local confirmTitle = make("TextLabel", {
        Text = "CONFIRM",
        Size = UDim2.new(1, -28, 0, 20),
        Position = UDim2.fromOffset(14, 14),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBlack,
        TextSize = 11,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 72,
    }, confirmCard)
    local confirmBody = make("TextLabel", {
        Text = "",
        Size = UDim2.new(1, -28, 0, 60),
        Position = UDim2.fromOffset(14, 40),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextColor3 = THEME.dim,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        ZIndex = 72,
    }, confirmCard)
    local cancelBtn = make("TextButton", {
        Text = "CANCEL",
        Size = UDim2.fromOffset(138, 34),
        Position = UDim2.new(0, 14, 1, -48),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = THEME.dim,
        ZIndex = 72,
    }, confirmCard)
    corner(cancelBtn, 8)
    local yesBtn = make("TextButton", {
        Text = "CONFIRM",
        Size = UDim2.fromOffset(150, 34),
        Position = UDim2.new(1, -164, 1, -48),
        BackgroundColor3 = THEME.red,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBlack,
        TextSize = 9,
        TextColor3 = Color3.fromRGB(38, 8, 14),
        ZIndex = 72,
    }, confirmCard)
    corner(yesBtn, 8)
    local confirmAction = nil
    local confirmOpen = false
    local function closeConfirm()
        confirmOpen = false
        tween(confirmBackdrop, { BackgroundTransparency = 1 }, 0.14)
        tween(confirmScale, { Scale = 0.94 }, 0.13)
        task.delay(0.15, function()
            if confirmOpen then return end
            confirmBackdrop.Visible = false
            confirmCard.Visible = false
        end)
    end
    local function openConfirm(titleText, bodyText, yesText, onYes)
        if STATE.unloaded then return end
        confirmOpen = true
        confirmTitle.Text = titleText or "CONFIRM"
        confirmBody.Text = bodyText or ""
        yesBtn.Text = yesText or "CONFIRM"
        confirmAction = onYes
        confirmBackdrop.Visible = true
        confirmCard.Visible = true
        confirmBackdrop.BackgroundTransparency = 1
        confirmScale.Scale = 0.94
        tween(confirmBackdrop, { BackgroundTransparency = 0.55 }, 0.15)
        tween(confirmScale, { Scale = 1 }, 0.2, Enum.EasingStyle.Back)
    end
    cancelBtn.MouseButton1Click:Connect(closeConfirm)
    confirmBackdrop.MouseButton1Click:Connect(closeConfirm)
    yesBtn.MouseButton1Click:Connect(function()
        local action = confirmAction
        closeConfirm()
        if action then
            local ok, err = pcall(action)
            if not ok then log("confirm: " .. tostring(err), true) end
        end
    end)
    STATE.ui.confirm = openConfirm
    STATE.ui.closeConfirm = closeConfirm

    -- floating orb
    local orb = make("TextButton", {
        Name = "Orb",
        Text = "H",
        Size = UDim2.fromOffset(52, 52),
        Position = UDim2.new(1, -66, 0.5, -26),
        BackgroundColor3 = THEME.accent,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Font = Enum.Font.GothamBlack,
        TextSize = 20,
        TextColor3 = Color3.fromRGB(34, 10, 24),
        Visible = false,
        ZIndex = 80,
    }, screen)
    corner(orb, 26)
    gradient(orb, THEME.accent, THEME.accent2, 45)
    local orbStroke = stroke(orb, Color3.fromRGB(255, 220, 232), 1.2, 0.35)
    local orbBadge = make("Frame", {
        Size = UDim2.fromOffset(18, 14),
        Position = UDim2.new(1, -19, 1, -17),
        BackgroundColor3 = THEME.bg,
        BorderSizePixel = 0,
        ZIndex = 81,
    }, orb)
    corner(orbBadge, 5)
    make("TextLabel", {
        Text = "V3",
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBlack,
        TextSize = 6,
        TextColor3 = THEME.accent2,
        ZIndex = 82,
    }, orbBadge)
    local orbPulse = TweenService and TweenInfo and tween and nil
    pcall(function()
        local info = TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
        local tw = TweenService:Create(orbStroke, info, { Transparency = 0.8 })
        tw:Play()
    end)
    STATE.ui.orb = orb

    local function setWindowVisible(visible)
        if STATE.unloaded then return end
        visible = visible == true
        main.Visible = visible
        orb.Visible = not visible
        if not visible and STATE.ui.modalOpen then closePlayerModal() end
    end
    STATE.ui.setWindowVisible = setWindowVisible
    orb.MouseButton1Click:Connect(function()
        if orb.Attributes and orb:GetAttribute("Dragged") then
            orb:SetAttribute("Dragged", false)
            return
        end
        setWindowVisible(true)
    end)
    minimizeBtn.MouseButton1Click:Connect(function()
        setWindowVisible(false)
        toast("MINIMIZED", "Tap the floating H to reopen HUGGER V3.", 2, "info")
    end)

    -- draggable header
    local dragging = false
    local dragStart = nil
    local dragOrigin = nil
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            dragOrigin = main.Position
        end
    end)
    connect(UserInput.InputChanged, function(input)
        if not dragging or not dragStart then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - dragStart
        if delta.Magnitude > 4 then STATE.ui.dragged = true end
        main.Position = UDim2.new(
            dragOrigin.X.Scale, dragOrigin.X.Offset + delta.X,
            dragOrigin.Y.Scale, dragOrigin.Y.Offset + delta.Y)
    end)
    connect(UserInput.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
            dragStart = nil
            dragOrigin = nil
        end
    end)

    -- draggable orb
    local orbDrag = false
    local orbStart = nil
    local orbOrigin = nil
    local orbMoved = 0
    orb.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            orbDrag = true
            orbMoved = 0
            orbStart = input.Position
            orbOrigin = orb.Position
        end
    end)
    connect(UserInput.InputChanged, function(input)
        if not orbDrag or not orbStart then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - orbStart
        orbMoved = math.max(orbMoved, delta.Magnitude)
        orb.Position = UDim2.new(
            orbOrigin.X.Scale, orbOrigin.X.Offset + delta.X,
            orbOrigin.Y.Scale, orbOrigin.Y.Offset + delta.Y)
    end)
    connect(UserInput.InputEnded, function(input)
        if not orbDrag then return end
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            orbDrag = false
            orbStart = nil
            orbOrigin = nil
            if orbMoved > 6 then
                orb:SetAttribute("Dragged", true)
                task.delay(0.15, function()
                    if orb then orb:SetAttribute("Dragged", false) end
                end)
            end
        end
    end)

    local layoutHooks = {}
    local function onLayout(fn)
        table.insert(layoutHooks, fn)
    end
    STATE.ui.onLayout = onLayout

    local function layout()
        if STATE.unloaded then return end
        local vp = viewport()
        local phone = vp.X < 620
        local scale = clamp(STATE.uiScale or 1, 0.8, 1.1)
        pcall(function() mainScale.Scale = scale end)
        local width = phone and math.min(vp.X - 10, 470) or math.min(680, vp.X - 48)
        local height = phone and math.min(vp.Y - 14, 760) or math.min(500, vp.Y - 48)
        width = math.max(310, width / scale)
        height = math.max(360, height / scale)
        width = math.min(width, (vp.X - 6) / scale)
        height = math.min(height, (vp.Y - 6) / scale)
        main.Size = UDim2.fromOffset(width, height)
        if not STATE.ui.dragged then
            main.Position = UDim2.new(0.5, 0, 0.5, 0)
        else
            local x = main.Position.X.Offset
            local y = main.Position.Y.Offset
            local halfW = width * scale / 2
            local halfH = height * scale / 2
            x = clamp(x, -vp.X / 2 + halfW, vp.X / 2 - halfW)
            y = clamp(y, -vp.Y / 2 + halfH, vp.Y / 2 - halfH)
            main.Position = UDim2.new(0.5, x, 0.5, y)
        end
        pcall(function()
            modal.Size = UDim2.fromOffset(math.min(430, vp.X - 20), math.min(480, vp.Y - 36))
        end)
        pcall(function()
            toastHolder.Size = phone and UDim2.new(1, -20, 0, 240) or UDim2.new(0, 280, 1, -24)
            toastHolder.Position = phone and UDim2.new(0, 10, 0, 8) or UDim2.new(1, -292, 0, 12)
        end)
        pcall(function()
            confirmCard.Size = UDim2.fromOffset(math.min(330, vp.X - 30), 176)
        end)
        pcall(function()
            local ow = orb.AbsoluteSize.X
            if ow <= 0 then ow = 52 end
            orb.Position = UDim2.new(1, -ow - 14, 0.5, -ow / 2)
        end)
        for _, hook in ipairs(layoutHooks) do
            pcall(hook, vp, phone)
        end
    end
    STATE.ui.layout = layout

    local function bindViewport()
        local camera = currentCamera()
        if not camera then return end
        local conn = camera:GetPropertyChangedSignal("ViewportSize")
        if conn then
            connect(conn, function()
                layout()
            end)
        end
        layout()
    end
    bindViewport()
    task.delay(0.2, bindViewport)
    STATE.ui.bindViewport = bindViewport

    local function refreshPerf()
        if not STATE.ui.perfLabel then return end
        if not CONFIG.showPerf then
            STATE.ui.perfLabel.Text = ""
            return
        end
        local ping = STATE.perf.ping or 0
        STATE.ui.perfLabel.Text = string.format("FPS %d  ·  %s",
            round(STATE.perf.fps or 0),
            ping > 0 and (round(ping) .. "ms") or "--ms")
    end
    STATE.ui.refreshPerf = refreshPerf

    local function setUIScale(value)
        STATE.uiScale = clamp(value, 0.8, 1.1)
        CONFIG.uiScale = STATE.uiScale
        layout()
    end
    STATE.ui.setUIScale = setUIScale

    local function recenter()
        STATE.ui.dragged = false
        layout()
    end
    STATE.ui.recenter = recenter

    local function updateHero()
        if STATE.unloaded then return end
        local carry = STATE.carry
        local target = STATE.ui.heroTarget
        local mode = "grab"
        local nameText, metaText, chipText, chipColor
        local letter = "♥"
        local avatarColor = THEME.accent
        if carry.carrier and carry.carrier ~= LP then
            mode = "struggle"
            nameText = "Carried by " .. showName(carry.carrier)
            metaText = "Press STRUGGLE · " .. tostring(carry.signal or "carry detected")
            chipText = "CARRIED"
            chipColor = THEME.red
            letter = "!"
            avatarColor = THEME.red
        elseif carry.carrying and carry.carrying ~= LP then
            mode = "throw"
            nameText = showName(carry.carrying)
            metaText = string.format("Carrying · %d studs · %s", round(distanceTo(carry.carrying)),
                tostring(carry.signal or "signal"))
            chipText = "CARRYING"
            chipColor = THEME.mint
            letter = "↗"
            avatarColor = THEME.mint
        elseif target then
            nameText = showName(target)
            local hum = getHum(target)
            local dist = distanceTo(target)
            local prompt = H.findGrabPrompt and H.findGrabPrompt(target)
            local promptText = prompt and "PROMPT READY" or "NO PROMPT"
            metaText = string.format("%s · %d studs · %d HP", promptText, round(dist),
                round((hum and hum.Health) or 0))
            chipText = prompt and "IN RANGE?" or "NO CONTROL"
            chipColor = prompt and THEME.accent2 or THEME.faint
            if prompt then
                local promptDist = H.promptDistance and H.promptDistance(prompt) or 0
                local maxDist = prompt and prompt.MaxActivationDistance or 0
                if promptDist > maxDist + 0.5 then
                    chipText = "STEP IN"
                    chipColor = THEME.gold
                else
                    chipText = "READY"
                    chipColor = THEME.mint
                end
            end
            if not isAlive(target) then
                chipText = "DEAD"
                chipColor = THEME.faint
            end
            if target == carry.carrier then
                chipText = "GRABBING YOU"
                chipColor = THEME.red
            end
            letter = string.upper(string.sub(showName(target), 1, 1))
            if letter == "" then letter = "?" end
            local hash = math.fmod((target.UserId or 0), 5)
            if hash == 0 then avatarColor = THEME.accent
            elseif hash == 1 then avatarColor = THEME.accent2
            elseif hash == 2 then avatarColor = THEME.purple
            elseif hash == 3 then avatarColor = THEME.blue
            else avatarColor = THEME.mint end
        else
            nameText = "No target"
            metaText = "Tap CHANGE or use Grab Nearest"
            chipText = "IDLE"
            chipColor = THEME.faint
        end
        if STATE.grab.state == "pending" then
            chipText = "SENT"
            chipColor = THEME.blue
        elseif STATE.grab.state == "approaching" then
            chipText = "STEPPING IN"
            chipColor = THEME.gold
        elseif STATE.grab.state == "unconfirmed" then
            chipText = "UNCONFIRMED"
            chipColor = THEME.accent2
        end
        local signature = table.concat({
            nameText, metaText, chipText, mode, tostring(target and target.UserId or 0),
        }, "|")
        if signature == STATE.heroSignature then return end
        STATE.heroSignature = signature
        pcall(function()
            heroName.Text = nameText
            heroMeta.Text = metaText
            heroChipText.Text = chipText
            heroChipText.TextColor3 = chipColor
            heroChip.BackgroundColor3 = Color3.fromRGB(
                math.floor(chipColor.R * 0.22 * 255),
                math.floor(chipColor.G * 0.22 * 255),
                math.floor(chipColor.B * 0.22 * 255))
            heroChip.Size = UDim2.fromOffset(math.max(58, #chipText * 5 + 16), 16)
            heroAvatarLetter.Text = letter
            heroAvatarLetter.TextColor3 = avatarColor
            heroAvatar.BackgroundColor3 = Color3.fromRGB(
                math.floor(avatarColor.R * 0.18 * 255),
                math.floor(avatarColor.G * 0.18 * 255),
                math.floor(avatarColor.B * 0.18 * 255))
            if mode == "throw" then
                heroGrabLabel.Text = "THROW"
                heroGrabSub.Text = "RELEASE TARGET"
            elseif mode == "struggle" then
                heroGrabLabel.Text = "ESCAPE"
                heroGrabSub.Text = "STRUGGLE NOW"
            else
                heroGrabLabel.Text = "HUG"
                heroGrabSub.Text = "GRAB TARGET"
            end
        end)
    end
    STATE.ui.updateHero = updateHero

    local function heroAction()
        local mode = "grab"
        if STATE.carry.carrier then mode = "struggle"
        elseif STATE.carry.carrying then mode = "throw" end
        if mode == "struggle" then
            if H.struggle then
                local ok, err = pcall(H.struggle)
                if not ok then log("struggle: " .. tostring(err), true) end
            end
        elseif mode == "throw" then
            if H.throwCarried then
                local ok, err = pcall(H.throwCarried, "manual")
                if not ok then log("throw: " .. tostring(err), true) end
            end
        else
            local target = H.resolveTarget and H.resolveTarget(true)
            if not target then
                openPlayerModal()
                toast("NO TARGET", "Choose a player to hug.", 2, "info")
                return
            end
            if H.grabPlayer then
                local ok, err = pcall(H.grabPlayer, target, { reason = "manual" })
                if not ok then log("grab: " .. tostring(err), true) end
            end
        end
    end
    STATE.ui.heroAction = heroAction

    closeBtn.MouseButton1Click:Connect(function()
        openConfirm("UNLOAD HUGGER V3",
            "This restores lighting, movement, noclip, ESP, fly, and every other change before closing.",
            "UNLOAD", function()
                if H.unload then H.unload() end
            end)
    end)

    -- initial page
    createPage("hug", "HUG", "♥")
    createPage("guard", "GUARD", "◈")
    createPage("climb", "CLIMB", "▲")
    createPage("move", "MOVE", "➤")
    createPage("esp", "ESP", "◎")
    createPage("server", "SERVER", "▤")
    createPage("setup", "SETUP", "⚙")
    showPage("hug")
    layout()

    STATE.ui.ready = true
end
-- ============================================================
--  GRAB ENGINE  //  PROMPT-FIRST, VERIFIED, PACED
-- ============================================================
do
    local grabWords = { "hug", "grab", "carry", "catch", "pickup", "pick up", "troll" }
    local throwWords = { "throw", "toss", "yeet", "launch", "drop", "release", "unhug" }
    local escapeWords = { "escape", "struggle", "break free", "breakfree", "ungrab", "unhug", "free" }
    local blockWords = { "hit", "damage", "push", "punch", "slap", "kick", "ban", "report",
        "donate", "shop", "purchase", "buy", "claim", "daily", "quest", "door", "seat" }
    local promptCache = {}
    local promptOriginals = {}
    local lastRemoteFire = 0
    local lastNoControl = 0
    local lastThrowFail = 0
    local updateHeroSignature

    local function lower(text)
        return string.lower(tostring(text or ""))
    end

    local function matches(text, words)
        local haystack = lower(text)
        for _, word in ipairs(words) do
            if string.find(haystack, word, 1, true) then return word end
        end
        return nil
    end

    local function blocked(text)
        return matches(text, blockWords) ~= nil
    end

    local function isFriend(player)
        if not player or player == LP then return false end
        local ok, result = pcall(function() return player:IsFriendsWith(LP.UserId) end)
        if ok and result == true then return true end
        local okStatus, status = pcall(function() return LP:GetFriendStatus(player) end)
        if okStatus and status == Enum.FriendStatus.Friend then return true end
        return false
    end

    local function promptLabel(prompt)
        local parts = { tostring(prompt.Name or "Prompt") }
        local okAction, action = pcall(function() return prompt.ActionText end)
        local okObject, object = pcall(function() return prompt.ObjectText end)
        if okAction and action and action ~= "" then table.insert(parts, tostring(action)) end
        if okObject and object and object ~= "" then table.insert(parts, tostring(object)) end
        return table.concat(parts, " · ")
    end

    local function partOf(object)
        if not object then return nil end
        local okType, isPart = pcall(function() return object:IsA("BasePart") end)
        if okType and isPart then return object end
        local okAttach, isAttachment = pcall(function() return object:IsA("Attachment") end)
        if okAttach and isAttachment then
            local ok, world = pcall(function() return object.WorldPosition end)
            if ok and world then return object end
        end
        local ok, found = pcall(function()
            return object:FindFirstChildWhichIsA("BasePart", true)
        end)
        if ok and found then return found end
        return nil
    end

    local function promptWorldPosition(prompt)
        local parent = prompt.Parent
        if not parent then return nil end
        local okType, isAttachment = pcall(function() return parent:IsA("Attachment") end)
        if okType and isAttachment then
            local ok, world = pcall(function() return parent.WorldPosition end)
            if ok and world then return world end
        end
        local part = partOf(parent)
        if part then
            local ok, position = pcall(function() return part.Position end)
            if ok then return position end
        end
        return nil
    end

    local function promptDistance(prompt)
        local mine = getPivot(LP)
        local there = promptWorldPosition(prompt)
        if not mine or not there then return math.huge end
        return (mine - there).Magnitude
    end

    local function promptMax(prompt)
        local ok, value = pcall(function() return prompt.MaxActivationDistance end)
        if ok and tonumber(value) then return tonumber(value) end
        return 10
    end

    local function promptScore(prompt)
        local text = promptLabel(prompt)
        local hit = matches(text, grabWords)
        if hit then
            if lower(prompt.Name or "") == "hug" then return 140 end
            if lower(prompt.Name or "") == "hugprompt" then return 135 end
            return 100
        end
        if blocked(text) then return 0 end
        local okAction, action = pcall(function() return prompt.ActionText end)
        local okObject, object = pcall(function() return prompt.ObjectText end)
        if (not okAction or action == "") and (not okObject or object == "") then
            return 35
        end
        return 0
    end

    local function findGrabPrompt(player)
        if not player or player == LP then return nil end
        local char = getChar(player)
        if not char then return nil end
        local cached = promptCache[player.UserId]
        if cached and cached.char == char and now() - cached.at < 0.35 then
            local prompt = cached.prompt
            local ok, enabled = pcall(function() return prompt.Enabled end)
            if prompt and prompt.Parent and ok and enabled then return prompt end
        end
        local best, bestScore, count = nil, 0, 0
        local okScan, descendants = pcall(function() return char:GetDescendants() end)
        if not okScan then return nil end
        for _, desc in ipairs(descendants) do
            local okPrompt, isPrompt = pcall(function() return desc:IsA("ProximityPrompt") end)
            if okPrompt and isPrompt then
                local okEnabled, enabled = pcall(function() return desc.Enabled end)
                if okEnabled and enabled then
                    count = count + 1
                    local score = promptScore(desc)
                    if score > bestScore then
                        best = desc
                        bestScore = score
                    end
                end
            end
        end
        if not best and count == 1 then
            for _, desc in ipairs(descendants) do
                local okPrompt, isPrompt = pcall(function() return desc:IsA("ProximityPrompt") end)
                if okPrompt and isPrompt and not blocked(desc.Name) then
                    local okEnabled, enabled = pcall(function() return desc.Enabled end)
                    if okEnabled and enabled then best = desc end
                end
            end
        end
        promptCache[player.UserId] = { char = char, prompt = best, at = now() }
        return best
    end

    local function clearPromptCache()
        promptCache = {}
    end

    local function findTool(kind)
        local char = getChar(LP)
        local backpack = LP:FindFirstChildOfClass("Backpack")
        local words = kind == "throw" and throwWords or (kind == "escape" and escapeWords or grabWords)
        local best, bestScore
        local containers = {}
        if char then table.insert(containers, char) end
        if backpack then table.insert(containers, backpack) end
        for _, container in ipairs(containers) do
            local ok, descendants = pcall(function() return container:GetDescendants() end)
            if ok then
                for _, desc in ipairs(descendants) do
                    local okTool, isTool = pcall(function() return desc:IsA("Tool") end)
                    if okTool and isTool then
                        local text = tostring(desc.Name or "")
                        local hit = matches(text, words)
                        if hit and not blocked(text) then
                            local score = 60
                            if lower(text) == lower(hit) then score = 120
                            elseif lower(text) == "hug" or lower(text) == "grab" then score = 130 end
                            if kind == "throw" and matches(text, { "throw", "toss", "yeet" }) then score = 130 end
                            if not bestScore or score > bestScore then
                                best = desc
                                bestScore = score
                            end
                        end
                    end
                end
            end
        end
        return best
    end

    local function isOurGui(object)
        local screen = STATE.ui.screen
        if not screen then return false end
        local current = object
        for _ = 1, 12 do
            if not current then return false end
            if current == screen then return true end
            current = current.Parent
        end
        return false
    end

    local function findGameButton(kind)
        local words = kind == "throw" and throwWords or (kind == "escape" and escapeWords or grabWords)
        local best, bestScore
        local ok, descendants = pcall(function() return PlayerGui:GetDescendants() end)
        if not ok then return nil end
        for _, desc in ipairs(descendants) do
            local okButton, isButton = pcall(function() return desc:IsA("GuiButton") end)
            if okButton and isButton and not isOurGui(desc) then
                local okVisible, visible = pcall(function() return desc.Visible end)
                if okVisible and visible then
                    local text = tostring(desc.Name or "")
                    local okText, buttonText = pcall(function() return desc.Text end)
                    if okText and buttonText and buttonText ~= "" then
                        text = text .. " " .. tostring(buttonText)
                    end
                    if not blocked(text) then
                        local hit = matches(text, words)
                        if hit then
                            local score = 45
                            if lower(desc.Name or "") == lower(hit) then score = 100 end
                            if kind == "throw" and matches(text, { "throw", "toss", "yeet" }) then score = 130 end
                            if kind == "escape" and matches(text, { "escape", "struggle" }) then score = 120 end
                            if not bestScore or score > bestScore then
                                best = desc
                                bestScore = score
                            end
                        end
                    end
                end
            end
        end
        return best
    end

    local function findPromptOnCharacter(kind, character)
        if not character then return nil end
        local words = kind == "throw" and throwWords or escapeWords
        local best, bestScore
        local ok, descendants = pcall(function() return character:GetDescendants() end)
        if not ok then return nil end
        for _, desc in ipairs(descendants) do
            local okPrompt, isPrompt = pcall(function() return desc:IsA("ProximityPrompt") end)
            if okPrompt and isPrompt then
                local okEnabled, enabled = pcall(function() return desc.Enabled end)
                if okEnabled and enabled then
                    local text = promptLabel(desc)
                    if not blocked(text) then
                        local hit = matches(text, words)
                        if hit then
                            local score = 80
                            if lower(desc.Name or "") == lower(hit) then score = 120 end
                            if not bestScore or score > bestScore then
                                best = desc
                                bestScore = score
                            end
                        end
                    end
                end
            end
        end
        return best
    end

    local function scanRemotes()
        if STATE.unloaded then return end
        local grabs, throws, escapes, list = {}, {}, {}, {}
        local containers = { Replicated }
        local char = getChar(LP)
        if char then table.insert(containers, char) end
        local backpack = LP:FindFirstChildOfClass("Backpack")
        if backpack then table.insert(containers, backpack) end
        local scanned = 0
        for _, container in ipairs(containers) do
            local ok, descendants = pcall(function() return container:GetDescendants() end)
            if ok then
                for _, desc in ipairs(descendants) do
                    scanned = scanned + 1
                    if scanned % 1200 == 0 then task.wait() end
                    local okRemote, isRemote = pcall(function() return desc:IsA("RemoteEvent") end)
                    if okRemote and isRemote then
                        local name = tostring(desc.Name or "")
                        local key = lower(name)
                        if not blocked(key) then
                            local scoreGrab = 0
                            local scoreThrow = 0
                            local scoreEscape = 0
                            if key == "hug" or key == "hugremote" or key == "hugprompt" then scoreGrab = 130
                            elseif string.find(key, "hug", 1, true) then scoreGrab = 90
                            elseif string.find(key, "grab", 1, true) then scoreGrab = 85
                            elseif string.find(key, "carry", 1, true) then scoreGrab = 80
                            elseif string.find(key, "catch", 1, true) then scoreGrab = 75
                            elseif string.find(key, "pickup", 1, true) or string.find(key, "pick up", 1, true) then scoreGrab = 70 end
                            if key == "throw" or key == "throwremote" then scoreThrow = 130
                            elseif string.find(key, "throw", 1, true) then scoreThrow = 100
                            elseif string.find(key, "toss", 1, true) or string.find(key, "yeet", 1, true) then scoreThrow = 95
                            elseif string.find(key, "launch", 1, true) then scoreThrow = 85
                            elseif string.find(key, "drop", 1, true) then scoreThrow = 80
                            elseif string.find(key, "release", 1, true) then scoreThrow = 75 end
                            if string.find(key, "escape", 1, true) or string.find(key, "struggle", 1, true)
                                or string.find(key, "break", 1, true) then scoreEscape = 90 end
                            if scoreGrab > 0 then table.insert(grabs, { remote = desc, score = scoreGrab, name = name }) end
                            if scoreThrow > 0 then table.insert(throws, { remote = desc, score = scoreThrow, name = name }) end
                            if scoreEscape > 0 then table.insert(escapes, { remote = desc, score = scoreEscape, name = name }) end
                            if scoreGrab > 0 or scoreThrow > 0 or scoreEscape > 0 then
                                table.insert(list, string.format("%s [%s]", name, desc:GetFullName()))
                            end
                        end
                    end
                end
            end
        end
        local function sortScore(a, b) return a.score > b.score end
        table.sort(grabs, sortScore)
        table.sort(throws, sortScore)
        table.sort(escapes, sortScore)
        STATE.remote.grabs = grabs
        STATE.remote.throws = throws
        STATE.remote.escapes = escapes
        STATE.remote.list = list
        STATE.remote.scanned = now()
        log(string.format("Remote scan: %d descendants, %d grab, %d throw, %d escape candidates.",
            scanned, #grabs, #throws, #escapes))
    end

    local function bestRemote(kind)
        local list = STATE.remote.grabs
        if kind == "throw" then list = STATE.remote.throws end
        if kind == "escape" then list = STATE.remote.escapes end
        return list and list[1] or nil
    end

    local function fireRemote(kind, target)
        local entry = bestRemote(kind)
        if not entry or not entry.remote or not entry.remote.Parent then return false, "no matching remote" end
        local wait = CONFIG.fallbackPace - (now() - lastRemoteFire)
        if wait > 0 then task.wait(wait) end
        lastRemoteFire = now()
        local ok, err
        if kind == "grab" then
            local schema = CONFIG.grabPayload
            if schema == "Player" then
                ok, err = pcall(function() entry.remote:FireServer(target) end)
            elseif schema == "Character" then
                ok, err = pcall(function() entry.remote:FireServer(target.Character) end)
            elseif schema == "Hug" then
                ok, err = pcall(function() entry.remote:FireServer("Hug", target) end)
            else
                ok, err = pcall(function() entry.remote:FireServer("Grab", target) end)
            end
        elseif kind == "throw" then
            local schema = CONFIG.throwPayload
            if schema == "Throw" then
                ok, err = pcall(function() entry.remote:FireServer("Throw") end)
            elseif schema == "Drop" then
                ok, err = pcall(function() entry.remote:FireServer("Drop") end)
            elseif schema == "Release" then
                ok, err = pcall(function() entry.remote:FireServer("Release") end)
            else
                ok, err = pcall(function() entry.remote:FireServer() end)
            end
        else
            ok, err = pcall(function() entry.remote:FireServer() end)
        end
        if not ok then
            log("remote " .. entry.name .. ": " .. tostring(err), true)
            return false, tostring(err)
        end
        log("Fired opt-in fallback remote " .. entry.name .. " (" .. kind .. ")")
        return true, entry.name
    end

    local function restorePrompt(prompt)
        local saved = promptOriginals[prompt]
        if not saved then return end
        pcall(function() prompt.HoldDuration = saved.hold end)
        pcall(function() prompt.MaxActivationDistance = saved.distance end)
        pcall(function() prompt.RequiresLineOfSight = saved.los end)
        promptOriginals[prompt] = nil
    end

    local function firePrompt(prompt)
        if not prompt or not prompt.Parent then return false, "prompt disappeared" end
        local boost = CONFIG.promptBoost
        if boost then
            local okHold, hold = pcall(function() return prompt.HoldDuration end)
            local okDistance, distance = pcall(function() return prompt.MaxActivationDistance end)
            local okLos, los = pcall(function() return prompt.RequiresLineOfSight end)
            promptOriginals[prompt] = {
                hold = okHold and hold or 0,
                distance = okDistance and distance or 10,
                los = okLos and los or true,
            }
            pcall(function() prompt.HoldDuration = 0 end)
            pcall(function() prompt.MaxActivationDistance = math.max(32, tonumber(distance) or 10) end)
            pcall(function() prompt.RequiresLineOfSight = false end)
        end
        local source = nil
        if fireproximityprompt then
            local ok, err = pcall(fireproximityprompt, prompt)
            if ok then
                source = "fireproximityprompt"
            else
                log("fireproximityprompt failed: " .. tostring(err), true)
            end
        end
        if not source then
            local okBegin, errBegin = pcall(function() prompt:InputHoldBegin() end)
            if okBegin then
                local okHold, hold = pcall(function() return prompt.HoldDuration end)
                local duration = okHold and tonumber(hold) or 0
                duration = clamp(duration, 0, 1.2)
                if duration > 0 then task.wait(duration + 0.03) else task.wait(0.05) end
                pcall(function() prompt:InputHoldEnd() end)
                source = "input-hold"
            else
                log("prompt input failed: " .. tostring(errBegin), true)
            end
        end
        if boost then
            task.delay(0.7, function() restorePrompt(prompt) end)
        end
        if not source then return false, "no prompt executor (fireproximityprompt/InputHold missing)" end
        return true, source
    end

    local function fireGameButton(button)
        if not button then return false, "no button" end
        if not firesignal then return false, "firesignal is not available" end
        local ok = pcall(function()
            firesignal(button.Activated)
            firesignal(button.MouseButton1Click)
            firesignal(button.MouseButton1Down)
        end)
        if ok then return true, "firesignal" end
        return false, "firesignal failed"
    end

    local function equipTool(tool)
        if not tool or not tool.Parent then return false, "tool missing" end
        local hum = getHum(LP)
        if not hum then return false, "no humanoid" end
        local char = getChar(LP)
        if tool.Parent ~= char then
            local ok, err = pcall(function() hum:EquipTool(tool) end)
            if not ok then return false, tostring(err) end
            task.wait(0.18)
        end
        if tool.Parent ~= char then return false, "tool did not equip" end
        if tool.Activate then
            local ok, err = pcall(function() tool:Activate() end)
            if not ok then return false, tostring(err) end
        else
            return false, "tool has no Activate"
        end
        return true, "tool: " .. tostring(tool.Name)
    end

    local function jointParts(instance)
        local ok, part0 = pcall(function() return instance.Part0 end)
        local ok2, part1 = pcall(function() return instance.Part1 end)
        if ok and ok2 and part0 and part1 then return part0, part1 end
        return nil
    end

    local function resolveValue(value)
        if not value then return nil end
        local okPlayer, isPlayer = pcall(function() return value:IsA("Player") end)
        if okPlayer and isPlayer then return value, "player" end
        local okModel, isModel = pcall(function() return value:IsA("Model") end)
        if okModel and isModel then
            local ok, player = pcall(function() return Players:GetPlayerFromCharacter(value) end)
            if ok and player then return player, "character" end
        end
        local okObject, isObject = pcall(function() return value:IsA("ObjectValue") end)
        if okObject and isObject then
            local okRead, inner = pcall(function() return value.Value end)
            if okRead and inner then
                local okInnerPlayer, innerPlayer = pcall(function() return inner:IsA("Player") end)
                if okInnerPlayer and innerPlayer then return inner, "object" end
                local okInnerModel, innerModel = pcall(function() return inner:IsA("Model") end)
                if okInnerModel and innerModel then
                    local ok, player = pcall(function() return Players:GetPlayerFromCharacter(inner) end)
                    if ok and player then return player, "object character" end
                end
            end
        end
        local okString, isString = pcall(function() return value:IsA("StringValue") end)
        if okString and isString then
            for _, player in ipairs(Players:GetPlayers()) do
                if player.Name == value.Value or showName(player) == value.Value then
                    return player, "string"
                end
            end
        end
        return nil
    end

    local function scanCarryValues(owner)
        if not owner then return nil, nil, nil, nil end
        local ok, descendants = pcall(function() return owner:GetDescendants() end)
        if not ok then return nil, nil, nil, nil end
        local carrying, carryingSignal, carrier, carrierSignal
        for _, desc in ipairs(descendants) do
            local okValue, isValue = pcall(function() return desc:IsA("ValueBase") end)
            if okValue and isValue then
                local name = lower(desc.Name)
                local looksCarry = string.find(name, "carry", 1, true)
                    or string.find(name, "carrying", 1, true)
                    or string.find(name, "hug", 1, true)
                    or string.find(name, "grab", 1, true)
                    or string.find(name, "held", 1, true)
                local looksCarrier = string.find(name, "carriedby", 1, true)
                    or string.find(name, "carried_by", 1, true)
                    or string.find(name, "grabbedby", 1, true)
                    or string.find(name, "huggedby", 1, true)
                    or string.find(name, "carrier", 1, true)
                    or string.find(name, "holder", 1, true)
                    or string.find(name, "captor", 1, true)
                if looksCarry or looksCarrier then
                    local okRead, value = pcall(function() return desc.Value end)
                    if okRead then
                        local player, kind = resolveValue(value)
                        if player and player ~= LP then
                            local signal = "value " .. tostring(desc.Name) .. " (" .. tostring(kind) .. ")"
                            if looksCarrier and not carrier then
                                carrier = player
                                carrierSignal = signal
                            elseif looksCarry and not carrying then
                                carrying = player
                                carryingSignal = signal
                            end
                        end
                    end
                end
            end
        end
        return carrying, carryingSignal, carrier, carrierSignal
    end

    local function scanToolsForCarry(owner)
        if not owner then return nil end
        local ok, descendants = pcall(function() return owner:GetDescendants() end)
        if not ok then return nil end
        for _, desc in ipairs(descendants) do
            local okTool, isTool = pcall(function() return desc:IsA("Tool") end)
            if okTool and isTool then
                local name = lower(desc.Name)
                if string.find(name, "carry", 1, true) or string.find(name, "hold", 1, true) then
                    return desc
                end
            end
        end
        return nil
    end

    local function nearbyPlayer(radius, exclude)
        local mine = getPivot(LP)
        if not mine then return nil end
        local best, bestDistance
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LP and player ~= exclude and isAlive(player) then
                local there = getPivot(player)
                if there then
                    local distance = (mine - there).Magnitude
                    if distance <= (radius or 7) and (not bestDistance or distance < bestDistance) then
                        best = player
                        bestDistance = distance
                    end
                end
            end
        end
        return best
    end

    local function humanoidHelpless(hum)
        if not hum then return false end
        local value = false
        -- PlatformStand is the carry signal used by the game. Sitting alone is
        -- deliberately excluded here so a chair does not read as a carry.
        pcall(function()
            value = hum.PlatformStand == true or hum.Health <= 0
        end)
        return value
    end

    local function detectCarryState(force)
        local stamp = now()
        if not force and stamp - STATE.carry.at < 0.18 then
            return STATE.carry
        end
        STATE.carry.at = stamp
        local carrying, carryingSignal = nil, "none"
        local carrier, carrierSignal = nil, "none"
        local myChar = getChar(LP)
        local myHum = getHum(LP)
        if not myChar then
            STATE.carry.carrying = nil
            STATE.carry.carrier = nil
            STATE.carry.signal = "none"
            return STATE.carry
        end
        local selfHelpless = humanoidHelpless(myHum) and not STATE.fly.on

        local joints = {}
        for _, desc in ipairs(myChar:GetDescendants()) do
            local ok, isJoint = pcall(function()
                return desc:IsA("Weld") or desc:IsA("WeldConstraint")
                    or desc:IsA("Motor6D") or desc:IsA("JointInstance")
            end)
            if ok and isJoint then table.insert(joints, desc) end
        end
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LP and player.Character then
                local ok, descendants = pcall(function() return player.Character:GetDescendants() end)
                if ok then
                    for _, desc in ipairs(descendants) do
                        local okJoint, isJoint = pcall(function()
                            return desc:IsA("Weld") or desc:IsA("WeldConstraint")
                                or desc:IsA("Motor6D") or desc:IsA("JointInstance")
                        end)
                        if okJoint and isJoint then table.insert(joints, desc) end
                    end
                end
            end
        end

        for _, joint in ipairs(joints) do
            local part0, part1 = jointParts(joint)
            if part0 and part1 then
                local p0Mine, p1Mine = false, false
                pcall(function() p0Mine = part0:IsDescendantOf(myChar) end)
                pcall(function() p1Mine = part1:IsDescendantOf(myChar) end)
                if p0Mine ~= p1Mine then
                    local otherPart = p0Mine and part1 or part0
                    local otherChar = otherPart.Parent
                    local otherPlayer = nil
                    pcall(function() otherPlayer = Players:GetPlayerFromCharacter(otherChar) end)
                    if not otherPlayer and otherChar then
                        local ancestor = otherChar
                        for _ = 1, 4 do
                            if not ancestor then break end
                            local ok, found = pcall(function() return Players:GetPlayerFromCharacter(ancestor) end)
                            if ok and found then otherPlayer = found break end
                            ancestor = ancestor.Parent
                        end
                    end
                    if otherPlayer and otherPlayer ~= LP then
                        local otherHelpless = humanoidHelpless(getHum(otherPlayer))
                        local signal = "weld (" .. tostring(joint.Name) .. ")"
                        local iAmCarrier
                        if selfHelpless and not otherHelpless then
                            iAmCarrier = false
                        elseif otherHelpless and not selfHelpless then
                            iAmCarrier = true
                        elseif p0Mine and not p1Mine then
                            iAmCarrier = true
                        elseif p1Mine and not p0Mine then
                            iAmCarrier = false
                        else
                            iAmCarrier = not selfHelpless
                        end
                        if iAmCarrier then
                            if not carrying then
                                carrying = otherPlayer
                                carryingSignal = signal
                            end
                        else
                            if not carrier then
                                carrier = otherPlayer
                                carrierSignal = signal
                            end
                        end
                    end
                end
            end
        end

        local vCarry, vCarrySignal, vCarrier, vCarrierSignal = scanCarryValues(myChar)
        if not vCarry and not vCarrier then
            vCarry, vCarrySignal, vCarrier, vCarrierSignal = scanCarryValues(LP)
        end
        if not carrying and vCarry then
            carrying = vCarry
            carryingSignal = vCarrySignal
        end
        if not carrier and vCarrier then
            carrier = vCarrier
            carrierSignal = vCarrierSignal
        end

        if not carrying and not carrier then
            local tool = scanToolsForCarry(myChar) or scanToolsForCarry(LP:FindFirstChildOfClass("Backpack"))
            if tool then
                local near = nearbyPlayer(9)
                if near then
                    carrying = near
                    carryingSignal = "tool " .. tostring(tool.Name) .. " + proximity"
                end
            end
        end

        if not carrying and not carrier and not selfHelpless then
            local mine = getPivot(LP)
            if mine then
                for _, player in ipairs(Players:GetPlayers()) do
                    if player ~= LP and isAlive(player) then
                        local hum = getHum(player)
                        local there = getPivot(player)
                        if hum and there and humanoidHelpless(hum) then
                            local distance = (there - mine).Magnitude
                            if distance <= 6 then
                                carrying = player
                                carryingSignal = "humanoid state + proximity"
                                break
                            end
                        end
                    end
                end
            end
        end

        if not carrier and selfHelpless then
            local near = nearbyPlayer(8)
            if near then
                carrier = near
                carrierSignal = "helpless state + proximity"
            end
        end

        if carrying and carrier then
            if selfHelpless then
                carrying = nil
                carryingSignal = "none"
            else
                carrier = nil
                carrierSignal = "none"
            end
        end

        STATE.carry.carrying = carrying
        STATE.carry.carrier = carrier
        STATE.carry.signal = carrying and carryingSignal or (carrier and carrierSignal or "none")
        return STATE.carry
    end

    local function waitForCarry(target, timeout)
        local deadline = now() + (timeout or 1.4)
        while now() < deadline do
            task.wait(0.08)
            local state = detectCarryState(true)
            if state.carrying then
                return state.carrying == target, state.carrying, state.signal, nil
            end
            if state.carrier then
                return false, nil, "you were grabbed instead", state.carrier
            end
        end
        return false, nil, "no carry signal", nil
    end

    local function waitForRelease(player, timeout)
        local deadline = now() + (timeout or 1.5)
        while now() < deadline do
            task.wait(0.08)
            local state = detectCarryState(true)
            if state.carrying ~= player then return true, state end
        end
        return false, detectCarryState(true)
    end

    local function approachTarget(target)
        local myRoot = getRoot(LP)
        local targetRoot = getRoot(target)
        if not myRoot or not targetRoot then return false, "missing root" end
        local targetPosition = targetRoot.Position
        local myPosition = myRoot.Position
        local flat = Vector3.new(myPosition.X - targetPosition.X, 0, myPosition.Z - targetPosition.Z)
        if flat.Magnitude < 0.1 then
            flat = targetRoot.CFrame.LookVector * -1
        end
        flat = flat.Unit
        local destination = targetPosition + flat * 2.5 + Vector3.new(0, 0.2, 0)
        local ok, err = pcall(function()
            myRoot.CFrame = CFrame.lookAt(destination,
                Vector3.new(targetPosition.X, destination.Y, targetPosition.Z))
            myRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end)
        if not ok then return false, tostring(err) end
        task.wait(0.2)
        local after = getPivot(LP)
        if not after then return false, "character lost" end
        if (after - targetPosition).Magnitude > CONFIG.maxApproach then
            return false, "server rejected the step-in"
        end
        return true, "stepped in"
    end

    local function aimAtLava(target)
        local lava = H.getNearestLava and H.getNearestLava()
        if not lava then return false, "no lava found" end
        local root = getRoot(LP)
        if not root then return false, "no root" end
        local position = lava.Position
        local ok = pcall(function()
            root.CFrame = CFrame.lookAt(root.Position,
                Vector3.new(position.X, position.Y, position.Z))
        end)
        if not ok then return false, "camera/Facing update failed" end
        if target then
            task.wait(0.05)
        end
        return true, "facing lava"
    end

    local function finishGrab(token, stateName, message, kind, toastTitle, toastBody)
        if STATE.grab.token == token then
            STATE.grab.state = stateName
            STATE.grab.busy = false
            STATE.grab.cooldownUntil = now() + CONFIG.actionCooldown
            if kind == "success" then
                STATE.stats.carries = STATE.stats.carries + 1
                STATE.grab.confirms = STATE.grab.confirms + 1
                STATE.grab.carrySince = now()
                if STATE.ui.toast then
                    STATE.ui.toast(toastTitle or "HUG CONFIRMED",
                        toastBody or message, 3.2, "ok")
                end
                setStatus("CARRYING — " .. tostring(message), "ok")
            elseif kind == "warn" then
                STATE.stats.failures = STATE.stats.failures + 1
                if STATE.ui.toast then
                    STATE.ui.toast(toastTitle or "UNCONFIRMED", toastBody or message, 4, "warn")
                end
                setStatus("UNCONFIRMED — " .. tostring(message), "warn")
            else
                STATE.stats.failures = STATE.stats.failures + 1
                if STATE.ui.toast and toastTitle then
                    STATE.ui.toast(toastTitle, toastBody or message, 4, "err")
                end
                setStatus("GRAB FAILED — " .. tostring(message), "err")
            end
            log("grab " .. stateName .. ": " .. tostring(message))
        end
    end

    local function armGrabWatchdog(token)
        task.delay(7, function()
            if STATE.unloaded then return end
            if STATE.grab.token ~= token or not STATE.grab.busy then return end
            finishGrab(token, "failed", "grab pipeline timed out", "err",
                "GRAB TIMEOUT", "No carry signal arrived. State was reset; retry when ready.")
        end)
    end

    local function grabPlayer(target, options)
        options = options or {}
        if STATE.unloaded then return false, "unloaded" end
        if STATE.grab.busy then
            if not options.auto and STATE.ui.toast then
                STATE.ui.toast("BUSY", "A grab or throw is already running.", 2, "warn")
            end
            return false, "busy"
        end
        if not target or target == LP then return false, "no target" end
        if not isAlive(target) then
            if not options.auto and STATE.ui.toast then
                STATE.ui.toast("TARGET DEAD", showName(target) .. " is not alive.", 2, "warn")
            end
            return false, "target dead"
        end
        local carryState = detectCarryState(true)
        if carryState.carrier then
            if STATE.ui.toast then
                STATE.ui.toast("YOU ARE CARRIED",
                    "Use Struggle first; a server carry cannot be grabbed out of.", 3, "err")
            end
            return false, "being carried"
        end
        if carryState.carrying and carryState.carrying ~= target then
            if STATE.ui.toast then
                STATE.ui.toast("ALREADY CARRYING",
                    "Throw " .. showName(carryState.carrying) .. " first.", 2.5, "warn")
            end
            return false, "already carrying"
        end
        if now() < STATE.grab.cooldownUntil and not options.force then
            return false, "cooldown"
        end
        local hum = getHum(target)
        local helpless = false
        if hum then
            pcall(function() helpless = hum.PlatformStand == true or hum.Sit == true end)
        end
        if helpless and not options.allowHelpless then
            if not options.auto and STATE.ui.toast then
                STATE.ui.toast("TARGET BUSY", showName(target) .. " already looks carried.", 2.5, "warn")
            end
            return false, "target already carried"
        end

        local prompt = findGrabPrompt(target)
        local tool = findTool("grab")
        local remote = nil
        if not prompt and not tool and CONFIG.remoteFallback then
            remote = bestRemote("grab")
        end
        if not prompt and not tool and not remote then
            if not options.auto and STATE.ui.toast then
                STATE.ui.toast("NO GRAB CONTROL",
                    "No hug prompt or hug tool was found on " .. showName(target)
                    .. ". Enable the opt-in remote fallback only if you understand it is unverified.",
                    5, "err")
            end
            if now() - lastNoControl > 4 then
                lastNoControl = now()
                log("No grab control on " .. showName(target) ..
                    "; prompt/tool missing, remote fallback " ..
                    (CONFIG.remoteFallback and "enabled" or "disabled"), true)
            end
            STATE.grab.lastFailure = "no control"
            return false, "no grab control"
        end

        local initialDistance = distanceTo(target)
        if prompt then
            local promptDistanceValue = promptDistance(prompt)
            local maxDistance = promptMax(prompt) + 0.75
            if promptDistanceValue > maxDistance then
                if not CONFIG.autoApproach then
                    if not options.auto and STATE.ui.toast then
                        STATE.ui.toast("OUT OF RANGE",
                            string.format("%s is %.1f studs away; this prompt accepts %.1f.",
                                showName(target), promptDistanceValue, promptMax(prompt)),
                            4, "warn")
                    end
                    STATE.grab.lastFailure = "out of range"
                    return false, "out of range"
                end
                if promptDistanceValue > CONFIG.maxApproach then
                    if not options.auto and STATE.ui.toast then
                        STATE.ui.toast("TOO FAR",
                            string.format("Step-in is limited to %d studs (target is %.1f).",
                                CONFIG.maxApproach, promptDistanceValue), 4, "warn")
                    end
                    STATE.grab.lastFailure = "too far"
                    return false, "too far"
                end
            end
        elseif tool then
            if initialDistance > CONFIG.maxApproach then
                if not options.auto and STATE.ui.toast then
                    STATE.ui.toast("TOO FAR",
                        string.format("Target is %.1f studs away; step-in limit is %d.",
                            initialDistance, CONFIG.maxApproach), 4, "warn")
                end
                STATE.grab.lastFailure = "too far"
                return false, "too far"
            end
        elseif remote then
            if initialDistance > 220 then
                return false, "too far for fallback"
            end
        end

        local token = STATE.grab.token + 1
        STATE.grab.token = token
        STATE.grab.busy = true
        STATE.grab.state = "seeking"
        STATE.grab.target = target
        STATE.grab.lastTry = now()
        STATE.grab.lastFailure = ""
        STATE.stats.attempts = STATE.stats.attempts + 1
        setStatus("GRABBING — " .. showName(target), "busy")
        log("Grab attempt -> " .. showName(target) .. " (" .. tostring(prompt and "prompt" or tool and "tool" or "remote") .. ")")

        task.spawn(function()
            armGrabWatchdog(token)
            do
                if prompt and promptDistance(prompt) > promptMax(prompt) + 0.75 then
                    STATE.grab.state = "approaching"
                    setStatus("STEPPING IN — " .. showName(target), "busy")
                    local stepped, stepReason = approachTarget(target)
                    if not stepped then
                        finishGrab(token, "failed", "step-in failed: " .. tostring(stepReason), "err",
                            "STEP-IN FAILED", "The server did not accept the position update.")
                        return
                    end
                    clearPromptCache()
                    prompt = findGrabPrompt(target)
                    if not prompt then
                        finishGrab(token, "failed", "prompt disappeared after step-in", "err",
                            "PROMPT LOST", "The target moved or streamed out.")
                        return
                    end
                    if promptDistance(prompt) > promptMax(prompt) + 1.2 then
                        finishGrab(token, "failed",
                            string.format("still %.1f studs away (prompt %.1f)",
                                promptDistance(prompt), promptMax(prompt)),
                            "err", "STILL OUT OF RANGE", "Move closer manually and retry.")
                        return
                    end
                end
                if not prompt and tool and initialDistance > CONFIG.grabReach + 6 and CONFIG.autoApproach then
                    STATE.grab.state = "approaching"
                    setStatus("STEPPING IN — " .. showName(target), "busy")
                    local stepped = approachTarget(target)
                    if not stepped then
                        finishGrab(token, "failed", "step-in failed", "err",
                            "STEP-IN FAILED", "The server did not accept the position update.")
                        return
                    end
                    task.wait(0.12)
                end
                STATE.grab.state = "pending"
                STATE.grab.source = ""
                setStatus("HUG SENT — waiting for carry signal", "busy")
                local fired, fireSource
                if prompt then
                    STATE.grab.prompt = prompt
                    fired, fireSource = firePrompt(prompt)
                elseif tool then
                    fired, fireSource = equipTool(tool)
                else
                    fired, fireSource = fireRemote("grab", target)
                end
                if not fired then
                    finishGrab(token, "failed", tostring(fireSource), "err",
                        "GRAB CONTROL FAILED", tostring(fireSource))
                    return
                end
                STATE.grab.source = tostring(fireSource or "unknown")
                STATE.stats.fired = STATE.stats.fired + 1
                log("Grab control fired via " .. tostring(fireSource))
                local confirmed, who, signal, grabbedBy = waitForCarry(target, 1.5)
                if confirmed then
                    STATE.carry.carrying = target
                    STATE.carry.carrier = nil
                    STATE.carry.signal = tostring(signal)
                    finishGrab(token, "carrying",
                        showName(target) .. " — signal: " .. tostring(signal),
                        "success", "HUG CONFIRMED",
                        showName(target) .. " is attached. Use Throw when ready.")
                elseif grabbedBy then
                    STATE.carry.carrier = grabbedBy
                    finishGrab(token, "failed",
                        showName(grabbedBy) .. " grabbed you first",
                        "err", "YOU WERE GRABBED",
                        "Use Struggle to escape " .. showName(grabbedBy) .. ".")
                elseif who and who ~= target then
                    STATE.carry.carrying = who
                    STATE.carry.carrier = nil
                    STATE.carry.signal = tostring(signal)
                    finishGrab(token, "carrying",
                        "grabbed " .. showName(who) .. " instead (signal: " .. tostring(signal) .. ")",
                        "success", "DIFFERENT TARGET", "The game attached " .. showName(who) .. ".")
                else
                    STATE.grab.state = "unconfirmed"
                    detectCarryState(true)
                    finishGrab(token, "unconfirmed",
                        "control fired via " .. tostring(fireSource) .. " but no carry signal appeared. "
                        .. "The server may have rejected it, or the game hides its carry state.",
                        "warn", "HUG UNCONFIRMED",
                        "No weld, state value, or carry tool was visible. Not claiming success.")
                end
            end
            if STATE.grab.token == token then
                STATE.grab.busy = false
                updateHeroSignature()
            end
        end)
        return true
    end

    local function findThrowControl(carried)
        local prompt = findPromptOnCharacter("throw", getChar(LP))
        if not prompt then prompt = findPromptOnCharacter("throw", carried and getChar(carried)) end
        if prompt then
            return { kind = "prompt", object = prompt, label = promptLabel(prompt) }
        end
        local tool = findTool("throw")
        if tool then
            return { kind = "tool", object = tool, label = "Tool " .. tostring(tool.Name) }
        end
        local button = findGameButton("throw")
        if button then
            local text = tostring(button.Name)
            local ok, value = pcall(function() return button.Text end)
            if ok and value and value ~= "" then text = tostring(value) end
            return { kind = "button", object = button, label = "UI " .. text }
        end
        if CONFIG.remoteFallback then
            local entry = bestRemote("throw")
            if entry then
                return { kind = "remote", object = entry.remote, label = "Remote " .. tostring(entry.name) }
            end
        end
        return nil
    end

    local function fireThrowControl(control, carried)
        if not control then return false, "no throw control" end
        if control.kind == "prompt" then
            return firePrompt(control.object)
        elseif control.kind == "tool" then
            return equipTool(control.object)
        elseif control.kind == "button" then
            return fireGameButton(control.object)
        elseif control.kind == "remote" then
            return fireRemote("throw", carried)
        end
        return false, "unknown control"
    end

    local function isInLava(position)
        if not position then return false end
        for _, entry in ipairs(STATE.safety.lavaParts) do
            local part = entry.part or entry
            if part and part.Parent then
                local ok, inside = false, false
                local invoke = pcall(function()
                    local localPoint = part.CFrame:PointToObjectSpace(position)
                    local size = part.Size
                    inside = math.abs(localPoint.X) <= size.X / 2 + 1
                        and math.abs(localPoint.Y) <= size.Y / 2 + 2
                        and math.abs(localPoint.Z) <= size.Z / 2 + 1
                end)
                if invoke and inside then return true end
                if not invoke then
                    local okPos, partPosition = pcall(function() return part.Position end)
                    local okSize, size = pcall(function() return part.Size end)
                    if okPos and okSize and partPosition and size then
                        if (partPosition - position).Magnitude <= math.max(size.X, size.Z, size.Y) then
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    local function verifyLavaToss(player)
        task.delay(1.6, function()
            if STATE.unloaded then return end
            local char = getChar(player)
            local root = getRoot(player)
            if not root then
                local hum = getHum(player)
                if hum and hum.Health <= 0 then
                    STATE.stats.lava = STATE.stats.lava + 1
                    if STATE.ui.toast then
                        STATE.ui.toast("LAVA TOSS", showName(player) .. " was eliminated after the throw.", 3.6, "ok")
                    end
                    log("Lava toss verified by elimination: " .. showName(player))
                end
                return
            end
            if isInLava(root.Position) then
                STATE.stats.lava = STATE.stats.lava + 1
                if STATE.ui.toast then
                    STATE.ui.toast("LAVA TOSS", showName(player) .. " is in the lava.", 3.6, "ok")
                end
                log("Lava toss verified by position: " .. showName(player))
            end
        end)
    end

    local function armThrowWatchdog(token, carried)
        task.delay(6, function()
            if STATE.unloaded then return end
            if STATE.throw.token ~= token or not STATE.throw.busy then return end
            STATE.throw.busy = false
            STATE.throw.state = "stuck"
            STATE.throw.cooldownUntil = now() + 2.0
            if STATE.ui.toast then
                STATE.ui.toast("THROW TIMEOUT",
                    "No release signal appeared. The carry may still be attached.", 4, "warn")
            end
            setStatus("THROW TIMEOUT — carry may still be attached", "warn")
            log("Throw watchdog fired for " .. showName(carried), true)
        end)
    end

    local function throwCarried(mode)
        if STATE.unloaded then return false, "unloaded" end
        if STATE.throw.busy then return false, "busy" end
        local state = detectCarryState(true)
        local carried = state.carrying
        if not carried then
            if STATE.ui.toast then
                STATE.ui.toast("NOT CARRYING", "There is no verified carried player to throw.", 2.5, "warn")
            end
            return false, "not carrying"
        end
        if now() < STATE.throw.cooldownUntil then return false, "cooldown" end
        local control = findThrowControl(carried)
        if not control then
            STATE.throw.busy = false
            if STATE.ui.toast and mode ~= "auto" then
                STATE.ui.toast("NO THROW CONTROL",
                    "No throw prompt, throw tool, or visible game button was found. Use the game's own control.",
                    5, "err")
            end
            setStatus("NO THROW CONTROL — use the game's Throw button", "warn")
            log("Throw blocked: no throw control detected", true)
            STATE.throw.cooldownUntil = now() + 2.5
            lastThrowFail = now()
            return false, "no throw control"
        end
        STATE.throw.busy = true
        STATE.throw.state = "throwing"
        STATE.throw.token = (STATE.throw.token or 0) + 1
        local throwToken = STATE.throw.token
        STATE.stats.throws = STATE.stats.throws + 1
        STATE.throw.lastTry = now()
        setStatus("THROWING — " .. showName(carried), "busy")
        task.spawn(function()
            armThrowWatchdog(throwToken, carried)
            do
                if CONFIG.aimLava then
                    local aimed, aimReason = aimAtLava(carried)
                    if not aimed then
                        log("Aim at lava skipped: " .. tostring(aimReason), true)
                    end
                end
                local fired, source = fireThrowControl(control, carried)
                if not fired then
                    STATE.throw.busy = false
                    STATE.throw.cooldownUntil = now() + 2.0
                    if STATE.ui.toast then
                        STATE.ui.toast("THROW FAILED", tostring(source), 4, "err")
                    end
                    setStatus("THROW FAILED — " .. tostring(source), "err")
                    return
                end
                log("Throw control fired via " .. tostring(source) .. " (" .. tostring(control.label) .. ")")
                local released, after = waitForRelease(carried, 1.6)
                STATE.throw.busy = false
                STATE.throw.cooldownUntil = now() + CONFIG.actionCooldown
                if released then
                    STATE.carry.carrying = nil
                    STATE.carry.signal = "released"
                    STATE.stats.releases = STATE.stats.releases + 1
                    STATE.throw.state = "released"
                    STATE.grab.state = "idle"
                    STATE.grab.carrySince = 0
                    if STATE.ui.toast then
                        STATE.ui.toast("THROWN", showName(carried) .. " was released by " .. tostring(control.label) .. ".", 3, "ok")
                    end
                    setStatus("RELEASED — " .. showName(carried), "ok")
                    verifyLavaToss(carried)
                else
                    STATE.throw.state = "stuck"
                    STATE.throw.cooldownUntil = now() + 2.5
                    if STATE.ui.toast then
                        STATE.ui.toast("STILL ATTACHED",
                            "The throw control fired, but the carry signal is still present. Try again or use the game's button.",
                            4, "warn")
                    end
                    setStatus("THROW SENT — carry still attached", "warn")
                    log("Throw fired but carry signal persisted", true)
                end
            end
            if STATE.throw.token == throwToken then
                STATE.throw.busy = false
            end
        end)
        return true
    end

    local function struggle(mode)
        if STATE.unloaded then return false, "unloaded" end
        local state = detectCarryState(true)
        if not state.carrier then
            if STATE.ui.toast and mode ~= "auto" then
                STATE.ui.toast("NOT CARRIED", "No carrier is detected right now.", 2, "info")
            end
            return false, "not carried"
        end
        local stamp = now()
        if mode == "auto" and stamp - (STATE.struggleLast or 0) < 0.8 then
            return false, "struggle cooldown"
        end
        STATE.struggleLast = stamp
        local control
        local prompt = findPromptOnCharacter("escape", getChar(LP))
        if prompt then
            control = { kind = "prompt", object = prompt, label = promptLabel(prompt) }
        else
            local tool = findTool("escape")
            if tool then
                control = { kind = "tool", object = tool, label = "Tool " .. tool.Name }
            else
                local button = findGameButton("escape")
                if button then
                    control = { kind = "button", object = button, label = "UI " .. button.Name }
                elseif CONFIG.remoteFallback then
                    local entry = bestRemote("escape")
                    if entry then
                        control = { kind = "remote", object = entry.remote, label = "Remote " .. entry.name }
                    end
                end
            end
        end
        local fired, source = false, "jump only"
        if control then
            if control.kind == "prompt" then
                fired, source = firePrompt(control.object)
            elseif control.kind == "tool" then
                fired, source = equipTool(control.object)
            elseif control.kind == "button" then
                fired, source = fireGameButton(control.object)
            elseif control.kind == "remote" then
                fired, source = fireRemote("escape", state.carrier)
            end
        end
        local hum = getHum(LP)
        local root = getRoot(LP)
        if hum then
            pcall(function() hum.Jump = true end)
            pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
        end
        if root then
            pcall(function()
                local velocity = root.AssemblyLinearVelocity
                root.AssemblyLinearVelocity = Vector3.new(velocity.X, math.max(velocity.Y, 32), velocity.Z)
            end)
        end
        if control and not fired then
            log("Struggle control failed: " .. tostring(source), true)
        end
        task.wait(0.35)
        local after = detectCarryState(true)
        if not after.carrier then
            STATE.stats.releases = STATE.stats.releases + 1
            if STATE.ui.toast then
                STATE.ui.toast("FREE", "The carrier is gone. " .. (control and ("Used " .. tostring(control.label) .. ".") or "Jump impulse only."), 3, "ok")
            end
            setStatus("FREE — carrier released", "ok")
            return true
        end
        if STATE.ui.toast and mode ~= "auto" then
            STATE.ui.toast("STILL CARRIED",
                control and ("Fired " .. tostring(control.label) .. " but the carry persists.")
                    or "No escape control is exposed. Jumped instead; the server carry may persist.",
                3.5, "warn")
        end
        setStatus("STILL CARRIED — " .. tostring(after.signal or "carry signal"), "warn")
        return false
    end

    local function findNearestTarget(requireControl)
        local best, bestScore
        for _, player in ipairs(Players:GetPlayers()) do
            local friendSkip = CONFIG.skipFriends and isFriend(player)
            if player ~= LP and not friendSkip and isAlive(player) then
                local dist = distanceTo(player)
                if dist < 400 then
                    local prompt = findGrabPrompt(player)
                    local tool = findTool("grab")
                    local hasControl = prompt ~= nil or tool ~= nil
                        or (CONFIG.remoteFallback and bestRemote("grab") ~= nil)
                    local skip = false
                    local hum = getHum(player)
                    if hum then
                        pcall(function() skip = hum.PlatformStand == true or hum.Sit == true end)
                    end
                    if skip and CONFIG.skipCarriedTargets then
                        hasControl = false
                    end
                    if (not requireControl) or hasControl then
                        local score = dist
                        if prompt then score = score - 12 end
                        if STATE.target.userId == player.UserId then score = score - 20 end
                        if not bestScore or score < bestScore then
                            best = player
                            bestScore = score
                        end
                    end
                end
            end
        end
        return best
    end

    local function resolveTarget(preferControl)
        if STATE.target.userId then
            local player = playerByUserId(STATE.target.userId)
            if player and isAlive(player) then return player end
            if CONFIG.stickyTarget then return nil end
            STATE.target.userId = nil
            STATE.target.mode = "nearest"
        end
        if STATE.target.mode == "locked" then return nil end
        return findNearestTarget(preferControl)
    end

    local function selectTarget(player, lock)
        if not player then
            STATE.target.userId = nil
            STATE.target.mode = "nearest"
            STATE.heroSignature = ""
            H.updateBeacon()
            setStatus("TARGET — nearest", "idle")
            return false
        end
        STATE.target.userId = player.UserId
        STATE.target.mode = lock == false and "nearest" or "locked"
        STATE.heroSignature = ""
        clearPromptCache()
        if STATE.ui.updateHero then STATE.ui.updateHero() end
        H.updateBeacon()
        if STATE.ui.toast then
            STATE.ui.toast("TARGET SET", showName(player) .. "  ·  " .. round(distanceTo(player)) .. " studs", 2.5, "info")
        end
        log("Target locked: " .. showName(player) .. " (" .. tostring(player.UserId) .. ")")
        return true
    end

    local function teleportBehind(player)
        if not player or player == LP or not isAlive(player) then
            return false, "no target"
        end
        local root = getRoot(LP)
        local targetRoot = getRoot(player)
        if not root or not targetRoot then return false, "missing root" end
        local targetPosition = targetRoot.Position
        local direction = targetRoot.CFrame.LookVector * -1
        if direction.Magnitude < 0.1 then direction = Vector3.new(0, 0, 1) end
        local destination = targetPosition + direction.Unit * 3.1 + Vector3.new(0, 0.2, 0)
        local ok, err = pcall(function()
            root.CFrame = CFrame.lookAt(destination, targetPosition)
            root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end)
        if not ok then return false, tostring(err) end
        task.wait(0.18)
        local after = getPivot(LP)
        if after and (after - targetPosition).Magnitude <= 8 then
            if STATE.ui.toast then
                STATE.ui.toast("TELEPORTED", "Next to " .. showName(player) .. ".", 2, "ok")
            end
            return true, "ok"
        end
        if STATE.ui.toast then
            STATE.ui.toast("TELEPORT BLOCKED", "The server did not accept the position update.", 3, "warn")
        end
        return false, "rejected"
    end

    local function updateCarryState()
        local previousCarrying = STATE.carry.carrying
        local previousCarrier = STATE.carry.carrier
        local state = detectCarryState(true)
        if state.carrying and state.carrying ~= previousCarrying then
            STATE.grab.carrySince = now()
            STATE.throw.fails = 0
            if state.carrying ~= STATE.grab.target then
                STATE.grab.target = state.carrying
            end
            if STATE.grab.state ~= "carrying" and STATE.grab.state ~= "pending" then
                STATE.grab.state = "carrying"
            end
            if STATE.ui.toast and previousCarrying == nil then
                STATE.ui.toast("CARRY DETECTED", showName(state.carrying) .. "  ·  " .. tostring(state.signal), 2.4, "info")
            end
        elseif not state.carrying and previousCarrying then
            STATE.grab.carrySince = 0
            if STATE.grab.state == "carrying" or STATE.grab.state == "unconfirmed" then
                STATE.grab.state = "idle"
            end
            if STATE.ui.toast then
                STATE.ui.toast("CARRY LOST", "The carry signal is gone.", 2, "info")
            end
        end
        if state.carrier and state.carrier ~= previousCarrier then
            STATE.alarms.lastCarried = now()
            if STATE.ui.toast then
                STATE.ui.toast("GRABBED", showName(state.carrier) .. " is carrying you. Use STRUGGLE.", 4, "err")
            end
            setStatus("CARRIED BY " .. showName(state.carrier), "err")
        elseif not state.carrier and previousCarrier then
            STATE.alarms.lastCarried = nil
            if STATE.ui.toast then
                STATE.ui.toast("FREE", "The carrier released you.", 2.2, "ok")
            end
        end
        return state
    end

    updateHeroSignature = function()
        if STATE.ui.updateHero then
            local ok, err = pcall(STATE.ui.updateHero)
            if not ok then log("hero update: " .. tostring(err), true) end
        end
    end
    STATE.ui.updateHeroSignature = updateHeroSignature

    local function grabTick()
        if STATE.unloaded or not CONFIG.autoGrab then return end
        if STATE.grab.busy or STATE.throw.busy then return end
        if STATE.carry.carrier then return end
        if STATE.carry.carrying then return end
        if now() < STATE.grab.cooldownUntil then return end
        local target = resolveTarget(true)
        if not target then
            local nearest = resolveTarget(false)
            if not nearest then return end
            local has = findGrabPrompt(nearest) or findTool("grab")
            if not has then
                if now() - lastNoControl > 5 then
                    lastNoControl = now()
                    setStatus("AUTO-GRAB — no hug control on " .. showName(nearest), "warn")
                end
                return
            end
            target = nearest
        end
        local dist = distanceTo(target)
        if dist > CONFIG.grabReach + (CONFIG.autoApproach and 3 or 0) then
            return
        end
        local prompt = findGrabPrompt(target)
        if not prompt and not findTool("grab") and not (CONFIG.remoteFallback and bestRemote("grab")) then
            if now() - lastNoControl > 6 then
                lastNoControl = now()
                setStatus("AUTO-GRAB — no prompt on " .. showName(target), "warn")
                log("Auto-grab idle: no prompt/tool on " .. showName(target), true)
            end
            return
        end
        grabPlayer(target, { auto = true })
    end

    local function throwTick()
        if STATE.unloaded or not CONFIG.autoThrow then return end
        if STATE.throw.busy or STATE.grab.busy then return end
        local carried = STATE.carry.carrying
        if not carried then
            STATE.throw.fails = 0
            return
        end
        if now() - STATE.grab.carrySince < CONFIG.throwDelay then return end
        if now() < STATE.throw.cooldownUntil then return end
        local before = STATE.stats.throws
        local ok = throwCarried("auto")
        if not ok then
            STATE.throw.fails = (STATE.throw.fails or 0) + 1
            if STATE.throw.fails >= 3 then
                STATE.throw.cooldownUntil = now() + 8
                setStatus("AUTO-THROW PAUSED — no usable throw control", "warn")
                log("Auto-throw paused after 3 failures", true)
            end
        elseif STATE.stats.throws > before then
            STATE.throw.fails = 0
        end
    end

    local function remoteStatus()
        local pieces = {}
        table.insert(pieces, "grab=" .. tostring(#STATE.remote.grabs))
        table.insert(pieces, "throw=" .. tostring(#STATE.remote.throws))
        table.insert(pieces, "escape=" .. tostring(#STATE.remote.escapes))
        if #STATE.remote.list == 0 then
            table.insert(pieces, "none matched")
        else
            local names = {}
            for index = 1, math.min(4, #STATE.remote.list) do
                table.insert(names, STATE.remote.list[index])
            end
            table.insert(pieces, table.concat(names, "; "))
        end
        return table.concat(pieces, "  ·  ")
    end

    local function grabDiagnostics()
        local target = resolveTarget(false)
        local prompt = target and findGrabPrompt(target) or nil
        local tool = findTool("grab")
        local lines = {}
        table.insert(lines, "state: " .. tostring(STATE.grab.state) ..
            (STATE.grab.busy and " (busy)" or ""))
        if target then
            table.insert(lines, "target: " .. showName(target) .. "  ·  " .. round(distanceTo(target)) .. " studs")
        else
            table.insert(lines, "target: none")
        end
        if prompt then
            table.insert(lines, string.format("prompt: %s  ·  %.1f/%.1f studs",
                promptLabel(prompt), promptDistance(prompt), promptMax(prompt)))
        else
            table.insert(lines, "prompt: none on target character")
        end
        table.insert(lines, "grab tool: " .. (tool and tostring(tool.Name) or "none"))
        table.insert(lines, "carry: " .. (STATE.carry.carrying and showName(STATE.carry.carrying) or "none")
            .. "  ·  " .. tostring(STATE.carry.signal))
        table.insert(lines, "carrier: " .. (STATE.carry.carrier and showName(STATE.carry.carrier) or "none"))
        table.insert(lines, "remotes: " .. remoteStatus())
        return table.concat(lines, "\n")
    end

    local function promptAudit()
        local names = {}
        local seen = 0
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LP and player.Character then
                for _, desc in ipairs(player.Character:GetDescendants()) do
                    local ok, isPrompt = pcall(function() return desc:IsA("ProximityPrompt") end)
                    if ok and isPrompt then
                        seen = seen + 1
                        if #names < 12 then
                            table.insert(names, showName(player) .. ": " .. promptLabel(desc))
                        end
                    end
                end
            end
        end
        if seen == 0 then return "character prompts: none visible (0)" end
        return "character prompts: " .. tostring(seen) .. "  ·  " .. table.concat(names, " | ")
    end
    STATE.ui.updateHeroSignature = updateHeroSignature
    STATE.heroSignature = nil

    H.isFriend = isFriend
    H.findGrabPrompt = findGrabPrompt
    H.promptDistance = promptDistance
    H.promptMax = promptMax
    H.promptLabel = promptLabel
    H.findTool = findTool
    H.findGameButton = findGameButton
    H.firePrompt = firePrompt
    H.fireGameButton = fireGameButton
    H.scanRemotes = scanRemotes
    H.bestRemote = bestRemote
    H.remoteStatus = remoteStatus
    H.detectCarryState = detectCarryState
    H.waitForCarry = waitForCarry
    H.waitForRelease = waitForRelease
    H.isInLava = isInLava
    H.grabPlayer = grabPlayer
    H.throwCarried = throwCarried
    H.struggle = struggle
    H.findNearestTarget = findNearestTarget
    H.resolveTarget = resolveTarget
    H.selectTarget = selectTarget
    H.teleportBehind = teleportBehind
    H.aimAtLava = aimAtLava
    H.approachTarget = approachTarget
    H.updateCarryState = updateCarryState
    H.updateHeroSignature = updateHeroSignature
    H.grabTick = grabTick
    H.throwTick = throwTick
    H.grabDiagnostics = grabDiagnostics
    H.promptAudit = promptAudit
    H.clearPromptCache = clearPromptCache
    H.restoreAllPrompts = function()
        for prompt in pairs(promptOriginals) do restorePrompt(prompt) end
    end
end
-- ============================================================
--  FEATURES  //  ESP, DEFENSE, MOVEMENT, TOWER, SERVER, CLEANUP
-- ============================================================
do
    local flyPad
    local flyButtons = {}
    local espGui = nil
    local lastFramePing = 0
    local lastFpsUpdate = 0
    local frameCount = 0
    local lastAlarm = 0
    local lastSafeMessage = 0
    local lastLavaScanLog = 0
    local towerScanning = false
    local serverScanning = false
    local lastDiag = 0
    local lastAimNote = 0
    local updateTowerLabels
    local updateServerLabels
    local updateDiag
    local updateStats
    local updateBeacon
    local updateESP
    local clearESP
    local startFly
    local stopFly
    local applyNoclip
    local applyWalk
    local applyJump
    local antiLavaTick
    local antiFlingTick
    local autoJumpTick
    local flyStep
    local saveSafePos
    local lavaUnderfoot
    local scanLava
    local getNearestLava
    local isLavaPart
    local scanTower
    local teleportHighest
    local stepUp
    local scanServers
    local hopServer
    local rejoinServer
    local copyText
    local startSpectate
    local stopSpectate
    local startAntiAfk
    local stopAntiAfk
    local proximityAlarm
    local updateSpectate
    local selfTest
    local diagText
    local setLavaGlow
    local applyLavaGlow
    local restoreLavaGlow

    local function playerInList(list, player)
        for _, item in ipairs(list) do
            if item == player then return true end
        end
        return false
    end

    local function charSet()
        local set = {}
        for _, player in ipairs(Players:GetPlayers()) do
            if player.Character then set[player.Character] = true end
        end
        return set
    end

    local function ancestorInSet(instance, set, depth)
        local current = instance
        for _ = 1, depth or 5 do
            if not current then return false end
            if set[current] then return true end
            current = current.Parent
        end
        return false
    end

    local function inAnyCharacter(part)
        local current = part
        for _ = 1, 6 do
            if not current then return false end
            local ok, player = pcall(function() return Players:GetPlayerFromCharacter(current) end)
            if ok and player then return true end
            current = current.Parent
        end
        return false
    end

    local function lower(text)
        return string.lower(tostring(text or ""))
    end

    isLavaPart = function(part)
        if not part then return false end
        local okPart, isPart = pcall(function() return part:IsA("BasePart") end)
        if not okPart or not isPart then return false end
        if inAnyCharacter(part) then return false end
        local name = lower(part.Name)
        local parentName = lower(part.Parent and part.Parent.Name or "")
        if string.find(name, "lava", 1, true) or string.find(name, "magma", 1, true)
            or string.find(name, "acid", 1, true) or string.find(name, "hazard", 1, true)
            or string.find(name, "kill", 1, true) or string.find(name, "death", 1, true)
            or string.find(name, "void", 1, true) then
            return true
        end
        if string.find(parentName, "lava", 1, true) or string.find(parentName, "hazard", 1, true)
            or string.find(parentName, "kill", 1, true) then
            return true
        end
        local okMaterial, material = pcall(function() return part.Material end)
        if okMaterial and material == Enum.Material.CrackedLava then return true end
        if CollectionService then
            local okTag, tagged = pcall(function() return CollectionService:HasTag(part, "Lava") end)
            if not okTag then pcall(function() tagged = CollectionService:HasTag(part, "lava") end) end
            if okTag and tagged then return true end
        end
        return false
    end

    local function tilePart(part, characterSet)
        if not part then return false end
        local ok, isPart = pcall(function() return part:IsA("BasePart") end)
        if not ok or not isPart then return false end
        if characterSet and ancestorInSet(part, characterSet, 6) then return false end
        if inAnyCharacter(part) then return false end
        local name = lower(part.Name)
        if string.find(name, "lava", 1, true) or string.find(name, "magma", 1, true)
            or string.find(name, "acid", 1, true) or string.find(name, "hazard", 1, true)
            or string.find(name, "kill", 1, true) or string.find(name, "death", 1, true)
            or string.find(name, "void", 1, true) then
            return false
        end
        local okMaterial, material = pcall(function() return part.Material end)
        if okMaterial and material == Enum.Material.CrackedLava then return false end
        return true
    end

    scanLava = function(waitFor)
        if STATE.unloading or STATE.unloaded then return end
        if STATE.safety.scanning then
            if waitFor then
                local deadline = now() + 12
                while STATE.safety.scanning and now() < deadline do task.wait(0.1) end
            end
            return
        end
        STATE.safety.scanning = true
        task.spawn(function()
            local found = {}
            local lowest = nil
            local chars = charSet()
            local ok, descendants = pcall(function() return workspace:GetDescendants() end)
            if ok then
                for index, desc in ipairs(descendants) do
                    if index % 1500 == 0 then task.wait() end
                    if STATE.unloading then break end
                    local okPart, isPart = pcall(function() return desc:IsA("BasePart") end)
                    if okPart and isPart then
                        local okName, name = pcall(function() return desc.Name end)
                        local candidate = okName and (
                            string.find(lower(name), "lava", 1, true)
                            or string.find(lower(name), "magma", 1, true)
                            or string.find(lower(name), "acid", 1, true)
                            or string.find(lower(name), "hazard", 1, true)
                            or string.find(lower(name), "kill", 1, true)
                            or string.find(lower(name), "death", 1, true)
                        )
                        local okMaterial, material = pcall(function() return desc.Material end)
                        if okMaterial and material == Enum.Material.CrackedLava then candidate = true end
                        if CollectionService then
                            local okTag, tagged = pcall(function() return CollectionService:HasTag(desc, "Lava") end)
                            if not okTag then pcall(function() tagged = CollectionService:HasTag(desc, "lava") end) end
                            if tagged then candidate = true end
                        end
                        if candidate and not ancestorInSet(desc, chars, 6) and not inAnyCharacter(desc) then
                            local okPos, position = pcall(function() return desc.Position end)
                            local okSize, size = pcall(function() return desc.Size end)
                            if okPos and okSize then
                                table.insert(found, { part = desc, position = position, size = size })
                                if not lowest or position.Y < lowest then lowest = position.Y end
                            end
                        end
                    end
                    if #found >= 140 then break end
                end
            end
            STATE.safety.lavaParts = found
            STATE.safety.lowestLavaY = lowest
            STATE.safety.lavaScan = now()
            STATE.safety.scanning = false
            if #found == 0 then
                if now() - lastLavaScanLog > 30 then
                    lastLavaScanLog = now()
                    log("Lava scan found no named/material lava parts. Anti-lava will use raycast names only.", true)
                end
            else
                log("Lava scan: " .. tostring(#found) .. " parts, lowest Y=" ..
                    tostring(round(lowest or 0)))
            end
            if STATE.lavaGlow.on then applyLavaGlow() end
            if updateTowerLabels then updateTowerLabels() end
        end)
        if waitFor then
            local deadline = now() + 12
            while STATE.safety.scanning and now() < deadline do task.wait(0.1) end
        end
    end

    getNearestLava = function()
        if #STATE.safety.lavaParts == 0 or now() - STATE.safety.lavaScan > 20 then
            scanLava(false)
        end
        local mine = getPivot(LP)
        if not mine then return nil end
        local best, bestDistance
        for _, entry in ipairs(STATE.safety.lavaParts) do
            local part = entry.part or entry
            if part and part.Parent then
                local ok, position = pcall(function() return part.Position end)
                if ok and position then
                    local distance = (position - mine).Magnitude
                    if not bestDistance or distance < bestDistance then
                        best = part
                        bestDistance = distance
                    end
                end
            end
        end
        return best
    end

    lavaUnderfoot = function()
        local root = getRoot(LP)
        if not root then return false end
        local params = RaycastParams.new()
        pcall(function()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { getChar(LP) }
        end)
        local ok, hit = pcall(function()
            return workspace:Raycast(root.Position + Vector3.new(0, 1, 0),
                Vector3.new(0, -12, 0), params)
        end)
        if ok and hit and hit.Instance and isLavaPart(hit.Instance) then return true end
        for _, entry in ipairs(STATE.safety.lavaParts) do
            local part = entry.part or entry
            if part and part.Parent then
                local okPosition, position = pcall(function() return part.Position end)
                local okSize, size = pcall(function() return part.Size end)
                if okPosition and okSize then
                    local distance = (position - root.Position).Magnitude
                    local span = math.max(size.X, size.Y, size.Z) / 2 + 3
                    if distance <= span and root.Position.Y <= position.Y + size.Y / 2 + 4 then
                        return true
                    end
                end
            end
        end
        if STATE.safety.lowestLavaY and root.Position.Y < STATE.safety.lowestLavaY + 1.5 then
            return true
        end
        return false
    end

    saveSafePos = function()
        if STATE.unloading or not isAlive(LP) or STATE.fly.on then return end
        if now() - STATE.safety.lastSave < 0.7 then return end
        local root = getRoot(LP)
        local hum = getHum(LP)
        if not root or not hum then return end
        local okVelocity, velocity = pcall(function() return root.AssemblyLinearVelocity end)
        if okVelocity and velocity and math.abs(velocity.Y) > 8 then return end
        if lavaUnderfoot() then return end
        local params = RaycastParams.new()
        pcall(function()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { getChar(LP) }
        end)
        local okGround, ground = pcall(function()
            return workspace:Raycast(root.Position + Vector3.new(0, 2, 0),
                Vector3.new(0, -20, 0), params)
        end)
        if not okGround or not ground or not ground.Instance then return end
        if isLavaPart(ground.Instance) then return end
        STATE.safety.lastSave = now()
        STATE.safety.lastSafe = root.CFrame
        local height = round(root.Position.Y)
        if height > (STATE.tower.best or 0) then
            STATE.tower.best = height
        end
    end

    antiLavaTick = function()
        if not CONFIG.antiLava or STATE.unloading or not isAlive(LP) or STATE.fly.on then return end
        if now() < STATE.safety.guardUntil then return end
        local root = getRoot(LP)
        if not root then return end
        local danger = lavaUnderfoot()
        if not danger then return end
        STATE.safety.guardUntil = now() + 2.6
        local safe = STATE.safety.lastSafe
        if safe then
            pcall(function()
                root.CFrame = safe + Vector3.new(0, 2, 0)
                root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
            end)
            if now() - lastSafeMessage > 3 then
                lastSafeMessage = now()
                if STATE.ui.toast then
                    STATE.ui.toast("LAVA GUARD", "Lava detected underfoot. Returned to the last safe spot.", 3, "warn")
                end
            end
            log("Lava guard rescued the character")
        else
            pcall(function()
                root.CFrame = root.CFrame + Vector3.new(0, 12, 0)
                root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end)
            if now() - lastSafeMessage > 3 then
                lastSafeMessage = now()
                if STATE.ui.toast then
                    STATE.ui.toast("LAVA GUARD", "No saved safe spot yet. Lifted upward instead.", 3, "warn")
                end
            end
        end
    end

    antiVoidTick = function()
        if not CONFIG.antiVoid or STATE.unloading or STATE.fly.on then return end
        if now() < STATE.safety.voidUntil then return end
        local root = getRoot(LP)
        local safe = STATE.safety.lastSafe
        if not root or not safe then return end
        local fallLimit = nil
        local okFall, value = pcall(function() return workspace.FallenPartsDestroyHeight end)
        if okFall and tonumber(value) then fallLimit = tonumber(value) + 30 end
        local belowSafe = root.Position.Y < (safe.Position.Y - 30)
        local belowMap = fallLimit ~= nil and root.Position.Y <= fallLimit
        if not belowSafe and not belowMap then return end
        local params = RaycastParams.new()
        pcall(function()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { getChar(LP) }
        end)
        local ok, hit = pcall(function()
            return workspace:Raycast(root.Position, Vector3.new(0, -500, 0), params)
        end)
        if ok and hit and hit.Instance and not belowMap then return end
        STATE.safety.voidUntil = now() + 3
        pcall(function()
            root.CFrame = safe + Vector3.new(0, 3, 0)
            root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
        end)
        if STATE.ui.toast then
            STATE.ui.toast("VOID GUARD", "Falling below the map. Returned to the last safe spot.", 3.5, "warn")
        end
        log("Void guard recovered the character at Y=" .. round(root.Position.Y))
    end

    autoDodgeTick = function()
        if not CONFIG.autoDodge or STATE.unloading or STATE.fly.on then return end
        local hum = getHum(LP)
        local root = getRoot(LP)
        if not hum or not root or hum.Health <= 0 then return end
        if STATE.carry.carrying or STATE.carry.carrier then return end
        if now() < (STATE.alarms.dodgeUntil or 0) then return end
        local mine = getPivot(LP)
        if not mine then return end
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LP and isAlive(player) then
                local there = getPivot(player)
                if there and (there - mine).Magnitude <= CONFIG.dodgeDistance then
                    STATE.alarms.dodgeUntil = now() + 1.8
                    pcall(function()
                        hum.Jump = true
                        hum:ChangeState(Enum.HumanoidStateType.Jumping)
                    end)
                    pcall(function()
                        local velocity = root.AssemblyLinearVelocity
                        root.AssemblyLinearVelocity = Vector3.new(velocity.X, math.max(velocity.Y, 42), velocity.Z)
                    end)
                    return true
                end
            end
        end
        return false
    end

    antiFlingTick = function()
        if not CONFIG.antiFling or STATE.unloading then return end
        local root = getRoot(LP)
        if not root then return end
        local okA, angular = pcall(function() return root.AssemblyAngularVelocity end)
        local okL, linear = pcall(function() return root.AssemblyLinearVelocity end)
        if okA and angular and angular.Magnitude > 90 then
            pcall(function() root.AssemblyAngularVelocity = Vector3.new(0, 0, 0) end)
        end
        if okL and linear then
            if linear.Magnitude > 340 then
                pcall(function()
                    root.AssemblyLinearVelocity = linear.Unit * 260
                end)
            elseif linear.Y < -420 then
                pcall(function()
                    root.AssemblyLinearVelocity = Vector3.new(linear.X, -300, linear.Z)
                end)
            elseif linear.Y > 420 then
                pcall(function()
                    root.AssemblyLinearVelocity = Vector3.new(linear.X, 300, linear.Z)
                end)
            end
        end
    end

    -- ==================== ESP ====================
    local function espColor(player)
        if STATE.target.userId == player.UserId then return THEME.gold end
        if STATE.carry.carrying == player then return THEME.mint end
        if STATE.carry.carrier == player then return THEME.red end
        local dist = distanceTo(player)
        if dist <= 9 then return THEME.accent2 end
        return Color3.fromRGB(238, 224, 255)
    end

    local function ensureEspGui()
        if espGui and espGui.Parent then return espGui end
        local ok, gui = pcall(function()
            local object = Instance.new("ScreenGui")
            object.Name = "HuggerV3_ESP"
            object.ResetOnSpawn = false
            object.IgnoreGuiInset = true
            object.DisplayOrder = 985
            object.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
            object.Enabled = true
            object.Parent = PlayerGui
            return object
        end)
        if ok then espGui = gui end
        return espGui
    end

    local function createEspFrame(player)
        local gui = ensureEspGui()
        if not gui then return nil end
        local container = make("Frame", {
            Name = "ESP_" .. tostring(player.UserId),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ClipsDescendants = false,
            Visible = false,
            Active = false,
            ZIndex = 4,
        }, gui)
        local box = make("Frame", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ZIndex = 5,
        }, container)
        corner(box, 4)
        local boxStroke = stroke(box, THEME.text, 1, 0.15)
        local nameLabel = make("TextLabel", {
            Text = "",
            Size = UDim2.fromOffset(180, 14),
            Position = UDim2.new(0.5, 0, 0, -17),
            AnchorPoint = Vector2.new(0.5, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 10,
            TextColor3 = THEME.text,
            TextXAlignment = Enum.TextXAlignment.Center,
            TextStrokeTransparency = 0.35,
            ZIndex = 6,
        }, container)
        local metaLabel = make("TextLabel", {
            Text = "",
            Size = UDim2.fromOffset(180, 12),
            Position = UDim2.new(0.5, 0, 1, 3),
            AnchorPoint = Vector2.new(0.5, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.Code,
            TextSize = 8,
            TextColor3 = THEME.dim,
            TextXAlignment = Enum.TextXAlignment.Center,
            TextStrokeTransparency = 0.45,
            ZIndex = 6,
        }, container)
        local hpBack = make("Frame", {
            Size = UDim2.fromOffset(3, 1),
            Position = UDim2.new(0, -7, 0, 0),
            BackgroundColor3 = Color3.fromRGB(20, 12, 26),
            BorderSizePixel = 0,
            BackgroundTransparency = 0.2,
            ZIndex = 6,
        }, container)
        local hpFill = make("Frame", {
            Size = UDim2.new(1, 0, 1, 0),
            Position = UDim2.new(0, 0, 0, 0),
            BackgroundColor3 = THEME.mint,
            BorderSizePixel = 0,
            ZIndex = 7,
        }, hpBack)
        local tracer = make("Frame", {
            Size = UDim2.new(0, 0, 0, 1),
            BackgroundColor3 = THEME.accent,
            BorderSizePixel = 0,
            BackgroundTransparency = 0.45,
            Visible = false,
            ZIndex = 3,
        }, gui)
        local highlight = nil
        pcall(function()
            highlight = Instance.new("Highlight")
            highlight.Name = "HuggerV3_Cham"
            highlight.Adornee = player.Character
            highlight.FillTransparency = 0.82
            highlight.OutlineTransparency = 0.35
            highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            highlight.FillColor = THEME.accent
            highlight.OutlineColor = THEME.accent
            highlight.Parent = gui
        end)
        local frame = {
            container = container,
            box = box,
            stroke = boxStroke,
            name = nameLabel,
            meta = metaLabel,
            hpBack = hpBack,
            hpFill = hpFill,
            tracer = tracer,
            highlight = highlight,
            player = player,
            character = player.Character,
        }
        STATE.esp.frames[player] = frame
        STATE.esp.chams[player] = highlight
        return frame
    end

    local function destroyEspFrame(player)
        local frame = STATE.esp.frames[player]
        if frame then
            pcall(function() frame.container:Destroy() end)
            pcall(function() frame.tracer:Destroy() end)
            STATE.esp.frames[player] = nil
        end
        local highlight = STATE.esp.chams[player]
        if highlight then
            pcall(function() highlight:Destroy() end)
            STATE.esp.chams[player] = nil
        end
    end

    clearESP = function()
        local players = {}
        for player in pairs(STATE.esp.frames) do table.insert(players, player) end
        for _, player in ipairs(players) do destroyEspFrame(player) end
        local chams = {}
        for player in pairs(STATE.esp.chams) do table.insert(chams, player) end
        for _, player in ipairs(chams) do
            local highlight = STATE.esp.chams[player]
            if highlight then pcall(function() highlight:Destroy() end) end
            STATE.esp.chams[player] = nil
        end
        if espGui then pcall(function() espGui.Enabled = false end) end
        STATE.esp.count = 0
    end

    updateESP = function()
        if STATE.unloading then return end
        if not CONFIG.esp then
            if espGui and espGui.Enabled then clearESP() end
            return
        end
        local gui = ensureEspGui()
        if not gui then return end
        gui.Enabled = true
        local camera = currentCamera()
        if not camera then return end
        local okVp, vp = pcall(function() return camera.ViewportSize end)
        if not okVp or not vp then return end
        local centerX = vp.X / 2
        local centerY = vp.Y
        local count = 0
        for _, player in ipairs(Players:GetPlayers()) do
            if player == LP then
                if STATE.esp.frames[player] then destroyEspFrame(player) end
            else
                local root = getRoot(player)
                local head = getChar(player) and getChar(player):FindFirstChild("Head") or root
                local hum = getHum(player)
                if root and head and hum and hum.Health > 0 then
                    local dist = distanceTo(player)
                    local frame = STATE.esp.frames[player]
                    if not frame or frame.character ~= player.Character then
                        if frame then destroyEspFrame(player) end
                        frame = createEspFrame(player)
                    end
                    if frame and dist <= CONFIG.espRange then
                        local headWorld = head.Position + Vector3.new(0, 0.8, 0)
                        local rootWorld = root.Position - Vector3.new(0, 2.6, 0)
                        local headScreen, headOn = camera:WorldToViewportPoint(headWorld)
                        local rootScreen, rootOn = camera:WorldToViewportPoint(rootWorld)
                        if headOn and rootOn and headScreen.Z > 0 and rootScreen.Z > 0 then
                            local height = math.max(rootScreen.Y - headScreen.Y, 22)
                            height = math.min(height, vp.Y * 0.85)
                            local width = clamp(height * 0.56, 18, 110)
                            local x = (headScreen.X + rootScreen.X) / 2
                            local top = headScreen.Y
                            if x > -width and x < vp.X + width and top < vp.Y and top + height > 0 then
                                local color = espColor(player)
                                frame.container.Visible = true
                                frame.container.Position = UDim2.fromOffset(x - width / 2, top)
                                frame.container.Size = UDim2.fromOffset(width, height)
                                frame.stroke.Color = color
                                frame.stroke.Thickness = (STATE.target.userId == player.UserId) and 2 or 1
                                frame.stroke.Transparency = 0.1
                                frame.name.Visible = CONFIG.espNames
                                frame.name.Text = showName(player)
                                frame.name.TextColor3 = color
                                local status = ""
                                if STATE.carry.carrying == player then status = " · CARRY"
                                elseif STATE.carry.carrier == player then status = " · CARRIER" end
                                frame.meta.Visible = CONFIG.espDistance or CONFIG.espHealth
                                local bits = {}
                                if CONFIG.espDistance then table.insert(bits, round(dist) .. "m") end
                                if CONFIG.espHealth then table.insert(bits, round(hum.Health) .. " HP") end
                                frame.meta.Text = table.concat(bits, " · ") .. status
                                frame.meta.Position = UDim2.new(0.5, 0, 1, CONFIG.espNames and 3 or 4)
                                frame.hpBack.Visible = CONFIG.espHealth
                                frame.hpBack.Position = UDim2.new(0, -7, 0, 0)
                                frame.hpBack.Size = UDim2.fromOffset(3, height)
                                local frac = clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                                frame.hpFill.Size = UDim2.new(1, 0, frac, 0)
                                frame.hpFill.Position = UDim2.new(0, 0, 1 - frac, 0)
                                frame.hpFill.BackgroundColor3 = frac > 0.55 and THEME.mint
                                    or (frac > 0.25 and THEME.gold or THEME.red)
                                if CONFIG.espTracers then
                                    local startX, startY = centerX, centerY
                                    local endX, endY = x, top + height
                                    local dx, dy = endX - startX, endY - startY
                                    local length = math.sqrt(dx * dx + dy * dy)
                                    frame.tracer.Visible = true
                                    frame.tracer.Position = UDim2.fromOffset(startX, startY)
                                    frame.tracer.Size = UDim2.new(0, length, 0, 1)
                                    frame.tracer.Rotation = math.deg(math.atan2(dy, dx))
                                    frame.tracer.BackgroundColor3 = color
                                else
                                    frame.tracer.Visible = false
                                end
                                if CONFIG.espChams then
                                    local highlight = frame.highlight
                                    if not highlight then
                                        pcall(function()
                                            highlight = Instance.new("Highlight")
                                            highlight.Name = "HuggerV3_Cham"
                                            highlight.Adornee = player.Character
                                            highlight.FillTransparency = 0.82
                                            highlight.OutlineTransparency = 0.35
                                            highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                                            highlight.Parent = gui
                                        end)
                                        frame.highlight = highlight
                                        STATE.esp.chams[player] = highlight
                                    end
                                    if highlight then
                                        highlight.Adornee = player.Character
                                        highlight.FillColor = color
                                        highlight.OutlineColor = color
                                        highlight.Enabled = true
                                    end
                                elseif frame.highlight then
                                    frame.highlight.Enabled = false
                                end
                                count = count + 1
                            else
                                frame.container.Visible = false
                                frame.tracer.Visible = false
                            end
                        else
                            frame.container.Visible = false
                            frame.tracer.Visible = false
                        end
                    else
                        if frame then
                            frame.container.Visible = false
                            frame.tracer.Visible = false
                            if frame.highlight then frame.highlight.Enabled = false end
                        end
                    end
                elseif STATE.esp.frames[player] then
                    destroyEspFrame(player)
                end
            end
        end
        STATE.esp.count = count
        STATE.esp.last = now()
    end

    -- ==================== BEACON ====================
    updateBeacon = function()
        if STATE.unloading then return end
        local target = H.resolveTarget and H.resolveTarget(false) or nil
        if not CONFIG.beacon or not target or not isAlive(target) then
            if STATE.beacon.gui then
                pcall(function() STATE.beacon.gui:Destroy() end)
                STATE.beacon.gui = nil
                STATE.beacon.player = nil
            end
            return
        end
        if STATE.beacon.gui and STATE.beacon.player == target
            and STATE.beacon.gui.Adornee and STATE.beacon.gui.Adornee.Parent then
            local dist = round(distanceTo(target))
            local label = STATE.beacon.gui:FindFirstChild("TargetLabel")
            if label then label.Text = string.format("▼  %s  ·  %dm", showName(target), dist) end
            return
        end
        if STATE.beacon.gui then pcall(function() STATE.beacon.gui:Destroy() end) end
        local head = getChar(target) and getChar(target):FindFirstChild("Head") or getRoot(target)
        if not head then return end
        local gui = make("BillboardGui", {
            Name = "HuggerV3_Beacon",
            Adornee = head,
            AlwaysOnTop = true,
            MaxDistance = 800,
            Size = UDim2.fromOffset(220, 40),
            StudsOffset = Vector3.new(0, 3.2, 0),
            LightInfluence = 0,
            ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        }, head)
        make("TextLabel", {
            Name = "TargetLabel",
            Text = "▼  " .. showName(target) .. "  ·  " .. round(distanceTo(target)) .. "m",
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBlack,
            TextSize = 14,
            TextColor3 = THEME.gold,
            TextStrokeTransparency = 0.2,
            TextStrokeColor3 = Color3.fromRGB(25, 12, 30),
            TextScaled = true,
        }, gui)
        STATE.beacon.gui = gui
        STATE.beacon.player = target
    end

    -- ==================== LAVA GLOW ====================
    applyLavaGlow = function()
        if STATE.unloading then return end
        for _, entry in ipairs(STATE.safety.lavaParts) do
            local part = entry.part or entry
            if part and part.Parent then
                if not STATE.lavaGlow.saved[part] then
                    STATE.lavaGlow.saved[part] = {
                        material = part.Material,
                        color = part.Color,
                        transparency = part.Transparency,
                        reflectance = part.Reflectance,
                    }
                end
                pcall(function()
                    part.Material = Enum.Material.Neon
                    part.Color = Color3.fromRGB(255, 92, 54)
                    part.Transparency = math.min(part.Transparency, 0.15)
                    part.Reflectance = 0.1
                end)
            end
        end
        STATE.lavaGlow.on = true
    end

    restoreLavaGlow = function()
        for part, saved in pairs(STATE.lavaGlow.saved) do
            if part and part.Parent then
                pcall(function()
                    part.Material = saved.material
                    part.Color = saved.color
                    part.Transparency = saved.transparency
                    part.Reflectance = saved.reflectance
                end)
            end
        end
        STATE.lavaGlow.saved = {}
        STATE.lavaGlow.on = false
    end

    setLavaGlow = function(value)
        CONFIG.lavaGlow = value == true
        if value then
            scanLava(false)
            applyLavaGlow()
        else
            restoreLavaGlow()
        end
    end

    -- ==================== MOVEMENT ====================
    applyWalk = function()
        local hum = getHum(LP)
        if not hum then return end
        STATE.movement = STATE.movement or {}
        if STATE.movement.baseWalk == nil then
            local ok, speed = pcall(function() return hum.WalkSpeed end)
            STATE.movement.baseWalk = ok and tonumber(speed) or 16
        end
        pcall(function()
            hum.WalkSpeed = CONFIG.walkEnabled and CONFIG.walkSpeed
                or STATE.movement.baseWalk or 16
        end)
    end

    applyJump = function()
        local hum = getHum(LP)
        if not hum then return end
        STATE.movement = STATE.movement or {}
        if STATE.movement.baseJump == nil then
            local ok, power = pcall(function() return hum.JumpPower end)
            STATE.movement.baseJump = ok and tonumber(power) or 50
            local okHeight, height = pcall(function() return hum.JumpHeight end)
            if okHeight and tonumber(height) then STATE.movement.baseJumpHeight = tonumber(height) end
            local okPower, usePower = pcall(function() return hum.UseJumpPower end)
            if okPower then STATE.movement.baseUseJumpPower = usePower == true end
        end
        pcall(function()
            -- Restore both saved values first so switching jump modes later
            -- cannot inherit HUGGER's custom number.
            hum.JumpPower = STATE.movement.baseJump or 50
            if STATE.movement.baseJumpHeight then
                hum.JumpHeight = STATE.movement.baseJumpHeight
            end
            if CONFIG.jumpEnabled then
                hum.UseJumpPower = true
                hum.JumpPower = CONFIG.jumpPower
            else
                -- Keep whichever mode the game was using when we first looked.
                hum.UseJumpPower = STATE.movement.baseUseJumpPower ~= false
            end
        end)
    end

    applyGravity = function(force)
        if STATE.unloading and not force then return end
        if STATE.movement.baseGravity == nil then
            local ok, value = pcall(function() return workspace.Gravity end)
            STATE.movement.baseGravity = ok and tonumber(value) or 196.2
        end
        pcall(function()
            workspace.Gravity = CONFIG.lowGravity and CONFIG.gravity
                or STATE.movement.baseGravity or 196.2
        end)
        return true
    end

    applyNoclip = function()
        if not STATE.noclip.on then return end
        local char = getChar(LP)
        if not char then return end
        local ok, descendants = pcall(function() return char:GetDescendants() end)
        if not ok then return end
        for _, desc in ipairs(descendants) do
            local okPart, isPart = pcall(function() return desc:IsA("BasePart") end)
            if okPart and isPart then
                if STATE.noclip.saved[desc] == nil then
                    local okCan, can = pcall(function() return desc.CanCollide end)
                    STATE.noclip.saved[desc] = okCan and can or true
                end
                pcall(function() desc.CanCollide = false end)
            end
        end
    end

    startFly = function()
        if STATE.unloading then return false, "unloading" end
        if STATE.fly.on then return true end
        local root = getRoot(LP)
        local hum = getHum(LP)
        if not root or not hum then return false, "no character" end
        stopFly(true)
        local okV, bv = pcall(function() return Instance.new("BodyVelocity") end)
        local okG, bg = pcall(function() return Instance.new("BodyGyro") end)
        if not okV or not okG then return false, "BodyVelocity unavailable" end
        bv.Name = "HuggerV3_FlyVelocity"
        bv.MaxForce = Vector3.new(1e6, 1e6, 1e6)
        bv.Velocity = Vector3.new(0, 0, 0)
        bv.Parent = root
        bg.Name = "HuggerV3_FlyGyro"
        bg.MaxTorque = Vector3.new(1e6, 1e6, 1e6)
        bg.P = 12000
        bg.D = 600
        bg.CFrame = root.CFrame
        bg.Parent = root
        STATE.fly.bv = bv
        STATE.fly.bg = bg
        STATE.fly.savedPlatform = hum.PlatformStand == true
        pcall(function() hum.PlatformStand = true end)
        STATE.fly.on = true
        STATE.fly.held = {}
        STATE.fly.velocity = Vector3.new(0, 0, 0)
        if flyPad then flyPad.Visible = true end
        return true
    end

    stopFly = function(silent)
        local bv = STATE.fly.bv
        local bg = STATE.fly.bg
        if bv then pcall(function() bv:Destroy() end) end
        if bg then pcall(function() bg:Destroy() end) end
        STATE.fly.bv = nil
        STATE.fly.bg = nil
        STATE.fly.on = false
        STATE.fly.held = {}
        STATE.fly.velocity = Vector3.new(0, 0, 0)
        local hum = getHum(LP)
        if hum then pcall(function() hum.PlatformStand = STATE.fly.savedPlatform == true end) end
        if flyPad then flyPad.Visible = false end
        if not silent then
            for _, button in pairs(flyButtons) do
                pcall(function() button.BackgroundColor3 = THEME.card end)
            end
        end
        return true
    end

    flyStep = function(dt)
        if not STATE.fly.on then return end
        local root = getRoot(LP)
        local hum = getHum(LP)
        if not root or not hum or hum.Health <= 0 then
            stopFly(true)
            return
        end
        local camera = currentCamera()
        if not camera then return end
        local function down(key)
            return UserInput:IsKeyDown(key) == true
        end
        local moveX = 0
        local moveY = 0
        local moveZ = 0
        if down(Enum.KeyCode.D) or STATE.fly.held.D then moveX = moveX + 1 end
        if down(Enum.KeyCode.A) or STATE.fly.held.A then moveX = moveX - 1 end
        if down(Enum.KeyCode.Space) or STATE.fly.held.UP then moveY = moveY + 1 end
        if down(Enum.KeyCode.LeftShift) or down(Enum.KeyCode.RightShift) or STATE.fly.held.DOWN then moveY = moveY - 1 end
        if down(Enum.KeyCode.W) or STATE.fly.held.W then moveZ = moveZ + 1 end
        if down(Enum.KeyCode.S) or STATE.fly.held.S then moveZ = moveZ - 1 end
        local direction = Vector3.new(0, 0, 0)
        if moveX ~= 0 or moveY ~= 0 or moveZ ~= 0 then
            direction = camera.CFrame:VectorToWorldSpace(Vector3.new(moveX, moveY, -moveZ)).Unit
        end
        local target = direction * CONFIG.flySpeed
        local alpha = clamp((dt or 0.016) * 9, 0, 1)
        local current = STATE.fly.velocity or Vector3.new(0, 0, 0)
        current = current + (target - current) * alpha
        STATE.fly.velocity = current
        pcall(function()
            if STATE.fly.bv then STATE.fly.bv.Velocity = current end
            if STATE.fly.bg then STATE.fly.bg.CFrame = camera.CFrame end
            root.AssemblyLinearVelocity = current
        end)
    end

    local function bindFlyButton(button, key)
        button.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                STATE.fly.held[key] = true
                button.BackgroundColor3 = THEME.accent
            end
        end)
        button.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                STATE.fly.held[key] = false
                button.BackgroundColor3 = THEME.card
            end
        end)
    end

    local function buildFlyPad()
        local screen = STATE.ui.screen
        if not screen then return end
        flyPad = make("Frame", {
            Name = "FlyPad",
            Size = UDim2.fromOffset(146, 142),
            Position = UDim2.new(0, 14, 1, -156),
            BackgroundColor3 = THEME.panel,
            BackgroundTransparency = 0.08,
            BorderSizePixel = 0,
            Visible = false,
            ZIndex = 30,
        }, screen)
        corner(flyPad, 14)
        stroke(flyPad, THEME.accent, 1, 0.45)
        local header = make("TextLabel", {
            Text = "3D FLY",
            Size = UDim2.new(1, -34, 0, 16),
            Position = UDim2.fromOffset(10, 5),
            BackgroundTransparency = 1,
            Font = Enum.Font.Code,
            TextSize = 8,
            TextColor3 = THEME.accent2,
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 31,
        }, flyPad)
        local exit = make("TextButton", {
            Text = "×",
            Size = UDim2.fromOffset(20, 20),
            Position = UDim2.new(1, -26, 0, 4),
            BackgroundColor3 = THEME.card,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextColor3 = THEME.dim,
            ZIndex = 32,
        }, flyPad)
        corner(exit, 6)
        exit.MouseButton1Click:Connect(function()
            local sw = STATE.switches.fly
            if sw and sw.Set then
                sw.Set(false)
            else
                CONFIG.flyEnabled = false
                stopFly()
            end
        end)
        local layout = {
            { key = "W", x = 58, y = 26, w = 30, h = 28 },
            { key = "A", x = 24, y = 58, w = 30, h = 28 },
            { key = "S", x = 58, y = 58, w = 30, h = 28 },
            { key = "D", x = 92, y = 58, w = 30, h = 28 },
            { key = "UP", x = 92, y = 26, w = 30, h = 28, label = "▲" },
            { key = "DOWN", x = 92, y = 90, w = 30, h = 28, label = "▼" },
        }
        for _, spec in ipairs(layout) do
            local button = make("TextButton", {
                Text = spec.label or spec.key,
                Size = UDim2.fromOffset(spec.w, spec.h),
                Position = UDim2.fromOffset(spec.x, spec.y),
                BackgroundColor3 = THEME.card,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                Font = Enum.Font.GothamBold,
                TextSize = 10,
                TextColor3 = THEME.text,
                ZIndex = 32,
            }, flyPad)
            corner(button, 8)
            bindFlyButton(button, spec.key)
            flyButtons[spec.key] = button
        end
        make("TextLabel", {
            Text = "HOLD TO MOVE",
            Size = UDim2.fromOffset(64, 14),
            Position = UDim2.fromOffset(24, 122),
            BackgroundTransparency = 1,
            Font = Enum.Font.Code,
            TextSize = 6,
            TextColor3 = THEME.faint,
            TextXAlignment = Enum.TextXAlignment.Center,
            ZIndex = 31,
        }, flyPad)
        if STATE.ui.onLayout then
            STATE.ui.onLayout(function(_, phone)
                if not flyPad then return end
                flyPad.Position = UDim2.new(0, 14, 1, phone and -150 or -156)
                flyPad.Size = UDim2.fromOffset(phone and 132 or 146, phone and 132 or 142)
            end)
        end
    end
    buildFlyPad()

    -- ==================== TOWER ====================
    scanTower = function(blocking)
        if towerScanning then
            if blocking then
                local deadline = now() + 15
                while towerScanning and now() < deadline do task.wait(0.1) end
            end
            return
        end
        towerScanning = true
        task.spawn(function()
            local chars = charSet()
            local found = {}
            local seenPositions = {}
            local ok, descendants = pcall(function() return workspace:GetDescendants() end)
            if ok then
                for index, desc in ipairs(descendants) do
                    if index % 1800 == 0 then task.wait() end
                    if STATE.unloading then break end
                    local okPart, isPart = pcall(function() return desc:IsA("BasePart") end)
                    if okPart and isPart then
                        local okCollide, collide = pcall(function() return desc.CanCollide end)
                        local okSize, size = pcall(function() return desc.Size end)
                        local okPos, position = pcall(function() return desc.Position end)
                        if okCollide and collide and okSize and okPos and size.X >= 7 and size.Z >= 7
                            and position.Y > 8 and position.Y < 1600 and tilePart(desc, chars) then
                            local bucket = math.floor(position.Y / 10)
                            local key = tostring(bucket)
                            local existing = seenPositions[key]
                            if not existing or position.Y > existing.Y then
                                seenPositions[key] = { part = desc, Y = position.Y }
                            end
                        end
                    end
                end
            end
            local sorted = {}
            for _, entry in pairs(seenPositions) do table.insert(sorted, entry) end
            table.sort(sorted, function(a, b) return a.Y > b.Y end)
            local platforms = {}
            for _, entry in ipairs(sorted) do
                local part = entry.part
                local okName, name = pcall(function() return part.Name end)
                local label = okName and tostring(name) or "Surface"
                table.insert(platforms, {
                    part = part,
                    y = entry.Y,
                    name = label,
                    summit = string.find(lower(label), "win", 1, true)
                        or string.find(lower(label), "finish", 1, true)
                        or string.find(lower(label), "summit", 1, true)
                        or string.find(lower(label), "top", 1, true),
                })
                if #platforms >= 12 then break end
            end
            STATE.tower.platforms = platforms
            STATE.tower.highest = platforms[1]
            STATE.tower.scanned = now()
            towerScanning = false
            if updateTowerLabels then updateTowerLabels() end
            if STATE.ui.toast then
                STATE.ui.toast("TOWER SCOUT",
                    string.format("%d surfaces found · highest Y=%d", #platforms,
                        platforms[1] and round(platforms[1].y) or 0),
                    4, "info")
            end
            log("Tower scout: " .. tostring(#platforms) .. " surfaces")
        end)
        if blocking then
            local deadline = now() + 15
            while towerScanning and now() < deadline do task.wait(0.1) end
        end
    end

    teleportHighest = function()
        if not STATE.tower.highest or now() - STATE.tower.scanned > 90 then
            scanTower(true)
        end
        local highest = STATE.tower.highest
        if not highest or not highest.part or not highest.part.Parent then
            return false, "No tower surface found. Run Scout Tower first."
        end
        local root = getRoot(LP)
        local size = highest.part.Size
        local destination = highest.part.Position + Vector3.new(0, size.Y / 2 + 3.5, 0)
        local ok = pcall(function()
            root.CFrame = CFrame.new(destination)
            root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end)
        if not ok then return false, "Position update failed." end
        task.wait(0.2)
        if STATE.ui.toast then
            STATE.ui.toast("SUMMIT MARKER", "Moved to the highest discovered surface (Y="
                .. round(highest.y) .. ").", 3.5, "ok")
        end
        return true
    end

    stepUp = function()
        local root = getRoot(LP)
        if not root then return false, "No character." end
        local params = RaycastParams.new()
        pcall(function()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = { getChar(LP) }
        end)
        local tries = {
            { origin = 45, length = 90 },
            { origin = 16, length = 32 },
        }
        for _, attempt in ipairs(tries) do
            local ok, hit = pcall(function()
                return workspace:Raycast(root.Position + Vector3.new(0, attempt.origin, 0),
                    Vector3.new(0, -attempt.length, 0), params)
            end)
            if ok and hit and hit.Instance and not isLavaPart(hit.Instance) then
                local destination = hit.Position + Vector3.new(0, 3, 0)
                pcall(function()
                    root.CFrame = CFrame.new(destination)
                    root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                end)
                task.wait(0.15)
                if STATE.ui.toast then
                    STATE.ui.toast("STEP UP", "Raycast landed on " .. tostring(hit.Instance.Name) .. ".", 2.5, "ok")
                end
                return true
            end
        end
        return false, "No safe surface found above the character."
    end

    stepDown = function()
        local root = getRoot(LP)
        if not root then return false, "No character." end
        local baseParams = RaycastParams.new()
        pcall(function()
            baseParams.FilterType = Enum.RaycastFilterType.Exclude
            baseParams.FilterDescendantsInstances = { getChar(LP) }
        end)
        local okUnder, under = pcall(function()
            return workspace:Raycast(root.Position + Vector3.new(0, 2, 0),
                Vector3.new(0, -10, 0), baseParams)
        end)
        local exclude = { getChar(LP) }
        if okUnder and under and under.Instance then table.insert(exclude, under.Instance) end
        local params = RaycastParams.new()
        pcall(function()
            params.FilterType = Enum.RaycastFilterType.Exclude
            params.FilterDescendantsInstances = exclude
        end)
        local ok, hit = pcall(function()
            return workspace:Raycast(root.Position + Vector3.new(0, 1, 0),
                Vector3.new(0, -400, 0), params)
        end)
        if not ok or not hit or not hit.Instance then
            return false, "No lower surface found."
        end
        if isLavaPart(hit.Instance) then
            return false, "The surface below is lava."
        end
        local destination = hit.Position + Vector3.new(0, 3, 0)
        pcall(function()
            root.CFrame = CFrame.new(destination)
            root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end)
        task.wait(0.15)
        local after = getPivot(LP)
        if after and (after - destination).Magnitude <= 12 then
            if STATE.ui.toast then
                STATE.ui.toast("STEP DOWN", "Landed on " .. tostring(hit.Instance.Name) .. ".", 2.5, "ok")
            end
            return true, "stepped down"
        end
        return false, "The server did not accept the step-down."
    end

    returnToSpawn = function()
        local spawnCf = STATE.safety.spawn
        if not spawnCf then
            local spawnPart = workspace:FindFirstChildOfClass("SpawnLocation")
            if spawnPart then spawnCf = spawnPart.CFrame end
        end
        if not spawnCf then return false, "No session start position captured yet." end
        local root = getRoot(LP)
        if not root then return false, "No character." end
        local destination = spawnCf + Vector3.new(0, 3, 0)
        pcall(function()
            root.CFrame = destination
            root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
        end)
        task.wait(0.2)
        local after = getPivot(LP)
        if after and (after - destination.Position).Magnitude <= 40 then
            if STATE.ui.toast then
                STATE.ui.toast("SESSION START", "Returned and verified at Y=" .. round(after.Y) .. ".", 3, "ok")
            end
            return true
        end
        return false, "The server rejected the session-start position update."
    end

    -- ==================== SERVER ====================
    local function httpGet(url)
        if game.HttpGet then
            local ok, body = pcall(function() return game:HttpGet(url) end)
            if ok and body then return body end
        end
        local request = rawget(_G, "request") or rawget(_G, "http_request")
        if request then
            local ok, response = pcall(request, { Url = url, Method = "GET" })
            if ok and response and response.Body then return response.Body end
        end
        if syn and syn.request then
            local ok, response = pcall(syn.request, { Url = url, Method = "GET" })
            if ok and response and response.Body then return response.Body end
        end
        return nil
    end
    STATE.httpGet = httpGet

    scanServers = function(blocking)
        if serverScanning then
            if blocking then
                local deadline = now() + 15
                while serverScanning and now() < deadline do task.wait(0.1) end
            end
            return
        end
        serverScanning = true
        STATE.server.busy = true
        task.spawn(function()
            local placeId = game.PlaceId or PLACE_ID
            local url = string.format(
                "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100",
                placeId)
            local body = httpGet(url)
            local list = {}
            local message
            if body then
                local json = HttpService or service("HttpService")
                local okDecode, decoded = pcall(function() return json:JSONDecode(body) end)
                if okDecode and decoded and type(decoded.data) == "table" then
                    for _, entry in ipairs(decoded.data) do
                        if entry.id and entry.id ~= game.JobId then
                            table.insert(list, {
                                id = entry.id,
                                playing = tonumber(entry.playing) or 0,
                                maxPlayers = tonumber(entry.maxPlayers) or 0,
                            })
                        end
                    end
                    table.sort(list, function(a, b) return a.playing < b.playing end)
                    message = string.format("%d public servers visible", #list)
                else
                    message = "Server list could not be decoded."
                end
            else
                message = "HttpGet is blocked or returned no data."
            end
            STATE.server.list = list
            STATE.server.lastScan = now()
            STATE.server.busy = false
            STATE.server.lastMessage = message
            serverScanning = false
            if updateServerLabels then updateServerLabels() end
            if STATE.ui.toast then
                STATE.ui.toast("SERVER SCAN", message, 3.5, #list > 0 and "ok" or "warn")
            end
            log("Server scan: " .. tostring(message))
        end)
        if blocking then
            local deadline = now() + 15
            while serverScanning and now() < deadline do task.wait(0.1) end
        end
    end

    hopServer = function(mode)
        if STATE.server.busy then return false, "A server scan is already running." end
        if #STATE.server.list == 0 or now() - STATE.server.lastScan > 45 then
            scanServers(true)
        end
        local candidates = {}
        for _, entry in ipairs(STATE.server.list) do
            if entry.id ~= game.JobId and (entry.maxPlayers <= 0 or entry.playing < entry.maxPlayers) then
                table.insert(candidates, entry)
            end
        end
        if #candidates == 0 then
            return false, STATE.server.lastMessage ~= "" and STATE.server.lastMessage
                or "No joinable public servers were returned."
        end
        table.sort(candidates, function(a, b) return a.playing < b.playing end)
        local choice
        if mode == "random" then
            local limit = math.min(12, #candidates)
            choice = candidates[math.random(limit)]
        else
            choice = candidates[1]
        end
        if not choice then return false, "No server selected." end
        local ok, err = pcall(function()
            Teleport:TeleportToPlaceInstance(game.PlaceId or PLACE_ID, choice.id, LP)
        end)
        if not ok then return false, "Teleport failed: " .. tostring(err) end
        if STATE.ui.toast then
            STATE.ui.toast("HOPPING", string.format("Requested server %s… (%d/%d players)",
                string.sub(choice.id, 1, 8), choice.playing, choice.maxPlayers), 4, "info")
        end
        log("Server hop requested: " .. choice.id)
        return true
    end

    rejoinServer = function()
        local ok, err = pcall(function()
            Teleport:TeleportToPlaceInstance(game.PlaceId or PLACE_ID, game.JobId, LP)
        end)
        if not ok then return false, "Rejoin failed: " .. tostring(err) end
        if STATE.ui.toast then
            STATE.ui.toast("REJOIN", "Teleport back to this JobId was requested.", 3, "info")
        end
        return true
    end

    copyText = function(text, label)
        local function clipboard(value)
            if setclipboard then
                local ok = pcall(setclipboard, value)
                if ok then return true end
            end
            if toclipboard then
                local ok = pcall(toclipboard, value)
                if ok then return true end
            end
            return false
        end
        if clipboard(text) then
            if STATE.ui.toast then STATE.ui.toast("COPIED", label or "Copied to clipboard.", 2, "ok") end
            return true
        end
        if STATE.ui.toast then
            STATE.ui.toast("NO CLIPBOARD", "This executor does not expose setclipboard.", 3, "warn")
        end
        return false
    end

    -- ==================== SPECTATE ====================
    startSpectate = function(player)
        local camera = currentCamera()
        local hum = getHum(player)
        if not camera or not hum then return false, "No camera or humanoid." end
        if not STATE.spectate.active then
            STATE.spectate.subject = camera.CameraSubject
            STATE.spectate.cameraType = camera.CameraType
        end
        local ok, err = pcall(function()
            camera.CameraSubject = hum
        end)
        if not ok then return false, tostring(err) end
        STATE.spectate.active = true
        STATE.spectate.player = player
        if STATE.ui.toast then
            STATE.ui.toast("SPECTATING", showName(player), 2.5, "info")
        end
        return true
    end

    stopSpectate = function()
        if not STATE.spectate.active then return end
        local camera = currentCamera()
        if camera then
            pcall(function()
                camera.CameraSubject = STATE.spectate.subject
                if STATE.spectate.cameraType then camera.CameraType = STATE.spectate.cameraType end
            end)
        end
        STATE.spectate.active = false
        STATE.spectate.player = nil
        if STATE.ui.toast then
            STATE.ui.toast("SPECTATE OFF", "Camera restored.", 2, "info")
        end
    end

    updateSpectate = function()
        if not STATE.spectate.active then return end
        local player = STATE.spectate.player
        if not player or not isAlive(player) then
            stopSpectate()
        end
    end

    -- ==================== LIGHTING / CAMERA ====================
    setFullbright = function(value)
        CONFIG.fullbright = value == true
        if CONFIG.fullbright then
            if not STATE.lighting.on then
                local saved = {}
                pcall(function()
                    saved.Brightness = Lighting.Brightness
                    saved.Ambient = Lighting.Ambient
                    saved.OutdoorAmbient = Lighting.OutdoorAmbient
                    saved.GlobalShadows = Lighting.GlobalShadows
                end)
                STATE.lighting.saved = saved
                STATE.lighting.on = true
            end
            pcall(function()
                Lighting.Brightness = 3
                Lighting.Ambient = Color3.fromRGB(150, 150, 160)
                Lighting.OutdoorAmbient = Color3.fromRGB(170, 170, 180)
                Lighting.GlobalShadows = false
            end)
            return true
        end
        if STATE.lighting.on then
            local saved = STATE.lighting.saved or {}
            pcall(function()
                if saved.Brightness ~= nil then Lighting.Brightness = saved.Brightness end
                if saved.Ambient ~= nil then Lighting.Ambient = saved.Ambient end
                if saved.OutdoorAmbient ~= nil then Lighting.OutdoorAmbient = saved.OutdoorAmbient end
                if saved.GlobalShadows ~= nil then Lighting.GlobalShadows = saved.GlobalShadows end
            end)
            STATE.lighting.on = false
            STATE.lighting.saved = nil
        end
        return true
    end

    applyFov = function(force)
        if STATE.unloading and not force then return end
        local camera = currentCamera()
        if not camera then return end
        if CONFIG.lockFov then
            if STATE.visual.baseFov == nil or STATE.visual.camera ~= camera then
                local ok, value = pcall(function() return camera.FieldOfView end)
                if ok and tonumber(value) then
                    STATE.visual.baseFov = tonumber(value)
                    STATE.visual.camera = camera
                end
            end
            pcall(function() camera.FieldOfView = CONFIG.fov end)
        elseif STATE.visual.baseFov ~= nil and STATE.visual.camera == camera then
            local base = STATE.visual.baseFov
            pcall(function() camera.FieldOfView = base end)
            STATE.visual.baseFov = nil
            STATE.visual.camera = nil
        end
    end

    -- ==================== ANTI-AFK ====================
    startAntiAfk = function()
        if STATE.afkConn then return end
        STATE.afkConn = connect(LP.Idled, function()
            if not CONFIG.antiAfk or STATE.unloading then return end
            task.spawn(function()
                task.wait(0.5)
                if not CONFIG.antiAfk or STATE.unloading then return end
                if VirtualUser then
                    pcall(function() VirtualUser:CaptureController() end)
                    pcall(function() VirtualUser:ClickButton2(Vector2.new(0.5, 0.5)) end)
                end
                log("Anti-AFK pulse sent")
            end)
        end)
    end

    stopAntiAfk = function()
        if STATE.afkConn then
            pcall(function() STATE.afkConn:Disconnect() end)
            STATE.afkConn = nil
        end
    end

    -- ==================== ALARMS ====================
    proximityAlarm = function()
        if not CONFIG.carryAlarm or STATE.unloading then return end
        local mine = getPivot(LP)
        if not mine then return end
        local stamp = now()
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LP and isAlive(player) then
                local there = getPivot(player)
                if there and (there - mine).Magnitude <= 7 then
                    local record = STATE.alarms.near[player]
                    if not record or stamp > record then
                        STATE.alarms.near[player] = stamp + 8
                        if stamp - lastAlarm > 1.5 and not STATE.carry.carrying then
                            lastAlarm = stamp
                            if STATE.ui.toast then
                                STATE.ui.toast("HUG ALERT",
                                    showName(player) .. " is within 7 studs.", 2.6, "warn")
                            end
                        end
                    end
                end
            end
        end
        for player, expiry in pairs(STATE.alarms.near) do
            if stamp > expiry or player.Parent == nil then
                STATE.alarms.near[player] = nil
            end
        end
    end

    -- ==================== LABELS ====================
    updateStats = function()
        local refs = STATE.ui.stats
        if not refs then return end
        local function set(label, value)
            if label then pcall(function() label.Text = tostring(value) end) end
        end
        set(refs.attempts, STATE.stats.attempts)
        set(refs.carries, STATE.stats.carries)
        set(refs.throws, STATE.stats.throws)
        set(refs.lava, STATE.stats.lava)
        set(refs.failures, STATE.stats.failures)
        set(refs.releases, STATE.stats.releases)
    end

    updateTowerLabels = function()
        local root = getRoot(LP)
        local altitude = root and round(root.Position.Y) or 0
        if altitude > (STATE.tower.best or 0) then STATE.tower.best = altitude end
        local refs = STATE.ui.tower
        if not refs then return end
        local function set(label, value)
            if label then pcall(function() label.Text = tostring(value) end) end
        end
        set(refs.altitude, altitude .. "m")
        set(refs.best, (STATE.tower.best or 0) .. "m")
        set(refs.highest, STATE.tower.highest and (round(STATE.tower.highest.y) .. "m") or "not scanned")
        set(refs.lavaCount, #STATE.safety.lavaParts)
        local safe = STATE.safety.lastSafe
        set(refs.safeSpot, safe and (round(safe.Position.Y) .. "m") or "none")
        set(refs.safeSpot2, safe and (round(safe.Position.Y) .. "m") or "none")
        set(refs.guardState, CONFIG.antiLava and "ON" or "OFF")
        set(refs.espCount, STATE.esp.count or 0)
    end

    updateServerLabels = function()
        local refs = STATE.ui.server
        if not refs then return end
        local function set(label, value)
            if label then pcall(function() label.Text = tostring(value) end) end
        end
        set(refs.players, #Players:GetPlayers() .. "/" .. tostring(Players.MaxPlayers or "?"))
        set(refs.place, tostring(game.PlaceId or PLACE_ID))
        set(refs.job, string.sub(tostring(game.JobId or "?"), 1, 18))
        set(refs.ping, STATE.perf.ping > 0 and (round(STATE.perf.ping) .. "ms") or "--")
        set(refs.servers, string.format("%d visible · best %s", #STATE.server.list,
            #STATE.server.list > 0 and (STATE.server.list[1].playing .. " players") or "n/a"))
        set(refs.message, STATE.server.lastMessage ~= "" and STATE.server.lastMessage or "No scan yet.")
        set(refs.flagged, STATE.server.busy and "SCANNING" or "IDLE")
    end

    diagText = function()
        local caps = {}
        if fireproximityprompt then table.insert(caps, "fireprompt") end
        if firesignal then table.insert(caps, "firesignal") end
        if gethui then table.insert(caps, "gethui") end
        if setclipboard or toclipboard then table.insert(caps, "clipboard") end
        if Drawing then table.insert(caps, "Drawing") end
        if request or http_request or syn then table.insert(caps, "request") end
        local lines = {}
        table.insert(lines, "HUGGER V3  //  version " .. VERSION .. "  //  place " .. tostring(game.PlaceId or "?"))
        table.insert(lines, "executor: " .. (#caps > 0 and table.concat(caps, ", ") or "basic"))
        table.insert(lines, "current camera: " .. (currentCamera() and "live" or "missing"))
        table.insert(lines, "prompt scan: " .. (H.promptAudit and H.promptAudit() or "n/a"))
        table.insert(lines, "remote scan: " .. (H.remoteStatus and H.remoteStatus() or "n/a"))
        table.insert(lines, "grab engine:\n" .. (H.grabDiagnostics and H.grabDiagnostics() or "n/a"))
        table.insert(lines, string.format("carry detection: %s  ·  carrier: %s",
            STATE.carry.carrying and showName(STATE.carry.carrying) or "none",
            STATE.carry.carrier and showName(STATE.carry.carrier) or "none"))
        table.insert(lines, string.format("stats: attempts %d / carries %d / throws %d / lava %d / failures %d",
            STATE.stats.attempts, STATE.stats.carries, STATE.stats.throws,
            STATE.stats.lava, STATE.stats.failures))
        table.insert(lines, string.format("perf: FPS %d  ·  ping %s  ·  errors %d",
            round(STATE.perf.fps or 0),
            STATE.perf.ping > 0 and (round(STATE.perf.ping) .. "ms") or "--",
            STATE.errorCount))
        table.insert(lines, "tool scan: " .. (H.findTool and (H.findTool("grab") and H.findTool("grab").Name or "none") or "n/a"))
        table.insert(lines, "lava cached: " .. tostring(#STATE.safety.lavaParts))
        return table.concat(lines, "\n")
    end

    updateDiag = function()
        if not STATE.ui.diagLabel then return end
        if now() - lastDiag < 1 then return end
        lastDiag = now()
        pcall(function() STATE.ui.diagLabel.Text = diagText() end)
    end

    selfTest = function()
        local checks = {}
        local function check(name, condition, detail)
            table.insert(checks, { name = name, ok = condition == true, detail = detail })
        end
        check("Interface", STATE.ui.screen ~= nil and STATE.ui.screen.Parent ~= nil,
            STATE.ui.screen and "ScreenGui parented" or "ScreenGui missing")
        local pageCount = 0
        for _ in pairs(STATE.pages) do pageCount = pageCount + 1 end
        check("Pages", pageCount == 7, pageCount .. "/7 pages")
        check("Grab engine", type(H.grabPlayer) == "function" and type(H.throwCarried) == "function",
            "pipeline loaded")
        check("Camera", currentCamera() ~= nil, currentCamera() and "live lookup" or "missing")
        check("Character", getRoot(LP) ~= nil and getHum(LP) ~= nil, "root/humanoid")
        check("PlayerGui", PlayerGui.Parent ~= nil, "available")
        check("Lighting", Lighting ~= nil, Lighting and "available" or "missing")
        check("Remotes", true, tostring(#STATE.remote.grabs) .. " grab candidate(s)")
        check("Prompts", true, tostring(select(2, string.gsub(H.promptAudit and H.promptAudit() or "", ":", ""))) .. " prompt text markers")
        local okCount = 0
        local lines = {}
        for _, entry in ipairs(checks) do
            if entry.ok then okCount = okCount + 1 end
            table.insert(lines, string.format("[%s] %s — %s", entry.ok and "PASS" or "FAIL",
                entry.name, entry.detail))
        end
        local summary = string.format("%d/%d checks passed", okCount, #checks)
        table.insert(lines, summary)
        return okCount == #checks, table.concat(lines, "\n"), summary
    end

    H.updateBeacon = updateBeacon
    H.updateESP = updateESP
    H.clearESP = clearESP
    H.updateStats = updateStats
    H.updateTowerLabels = updateTowerLabels
    H.updateServerLabels = updateServerLabels
    H.updateDiag = updateDiag
    H.updateSpectate = updateSpectate
    H.updateCarryLabels = function() if updateTowerLabels then updateTowerLabels() end end
    H.scanLava = scanLava
    H.getNearestLava = getNearestLava
    H.isLavaPart = isLavaPart
    H.lavaUnderfoot = lavaUnderfoot
    H.saveSafePos = saveSafePos
    H.antiLavaTick = antiLavaTick
    H.antiFlingTick = antiFlingTick
    H.autoJumpTick = function()
        if not CONFIG.autoJump or STATE.unloading then return end
        local hum = getHum(LP)
        if hum and hum.Health > 0 then
            local ok, state = pcall(function() return hum:GetState() end)
            if ok and state ~= Enum.HumanoidStateType.Jumping and state ~= Enum.HumanoidStateType.Freefall then
                pcall(function() hum.Jump = true end)
                pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
            end
        end
    end
    H.flyStep = flyStep
    H.startFly = startFly
    H.stopFly = stopFly
    H.applyNoclip = applyNoclip
    H.applyWalk = applyWalk
    H.applyJump = applyJump
    H.scanTower = scanTower
    H.teleportHighest = teleportHighest
    H.stepUp = stepUp
    H.scanServers = scanServers
    H.hopServer = hopServer
    H.rejoinServer = rejoinServer
    H.copyText = copyText
    H.startSpectate = startSpectate
    H.stopSpectate = stopSpectate
    H.setFullbright = setFullbright
    H.applyFov = applyFov
    H.applyGravity = applyGravity
    H.antiVoidTick = antiVoidTick
    H.autoDodgeTick = autoDodgeTick
    H.stepDown = stepDown
    H.returnToSpawn = returnToSpawn
    H.startAntiAfk = startAntiAfk
    H.stopAntiAfk = stopAntiAfk
    H.proximityAlarm = proximityAlarm
    H.selfTest = selfTest
    H.diagText = diagText
    H.setLavaGlow = setLavaGlow
    H.restoreLavaGlow = restoreLavaGlow
    H.applyLavaGlow = applyLavaGlow
    H.espGui = function() return espGui end
    H.flyPad = function() return flyPad end
end
-- ============================================================
--  PAGES  //  every tab wired to a real, reversible callback
-- ============================================================
do
    local function page(id)
        return STATE.pages[id]
    end

    local function toast(title, body, duration, kind)
        if STATE.ui.toast then
            pcall(STATE.ui.toast, title, body, duration, kind)
        end
    end

    local function refreshLog()
        if not STATE.ui.logLabel then return end
        local rows = {}
        local first = math.max(1, #STATE.logLines - 18)
        for index = first, #STATE.logLines do
            local entry = STATE.logLines[index]
            table.insert(rows, string.format("%s %s%s", entry.at,
                entry.err and "[!] " or "    ", entry.text))
        end
        if #rows == 0 then
            STATE.ui.logLabel.Text = "No log entries yet."
        else
            STATE.ui.logLabel.Text = table.concat(rows, "\n")
        end
    end
    STATE.ui.refreshLog = refreshLog

    local function diagnosticsLabel(parent)
        local label = STATE.ui.make("TextLabel", {
            Text = "Run the self-test or open Diagnostics to fill this panel.",
            Size = UDim2.new(1, -4, 0, 120),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = THEME.card,
            BorderSizePixel = 0,
            Font = Enum.Font.Code,
            TextSize = 8,
            TextColor3 = THEME.text,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            LineHeight = 1.2,
        }, parent)
        STATE.ui.corner(label, 8)
        STATE.ui.stroke(label, THEME.line, 1, 0.55)
        STATE.ui.padding(label, 10, 8, 8, 8)
        return label
    end

    -- ==================== HUG ====================
    do
        local p = page("hug")
        STATE.ui.section(p, "Target")
        STATE.ui.buttonRow(p, "Hug nearest player",
            "Prompt first · step-in only when the prompt allows it",
            function()
                local target = H.resolveTarget(true) or H.findNearestTarget(true)
                if not target then
                    return false, "No player with a usable hug control is nearby."
                end
                local ok, err = H.grabPlayer(target, { reason = "manual" })
                if not ok then return false, tostring(err) end
                return true
            end, true)
        STATE.ui.buttonRow(p, "Choose a target",
            "Tap a row in the player picker",
            function()
                if STATE.ui.openPlayerModal then
                    STATE.ui.openPlayerModal()
                    return true
                end
                return false, "Player picker is unavailable."
            end)
        STATE.ui.buttonRow(p, "Step behind target",
            "Verified position update next to the chosen or nearest player",
            function()
                local target = H.resolveTarget(false) or H.findNearestTarget(false)
                if not target then return false, "No player to step behind." end
                local ok, err = H.teleportBehind(target)
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.buttonRow(p, "Throw carried player",
            "Uses the game's throw prompt, tool, or visible button",
            function()
                local ok, err = H.throwCarried("manual")
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.buttonRow(p, "Struggle free",
            "Escape control first, jump only as a fallback",
            function()
                local ok, err = H.struggle("manual")
                if not ok then return false, tostring(err) end
                return true
            end)

        STATE.ui.section(p, "Automation")
        STATE.ui.toggleRow(p, "autoGrab", "Auto hug",
            "Fires only when a prompt or hug tool is present",
            CONFIG.autoGrab, function(value)
                CONFIG.autoGrab = value
                if value then
                    setStatus("AUTO-HUG — armed, waiting for a prompt", "busy")
                else
                    setStatus("Auto-hug off", "idle")
                end
                return true
            end)
        STATE.ui.toggleRow(p, "autoApproach", "Step in when out of range",
            "Limited to " .. tostring(CONFIG.maxApproach) .. " studs and verified after the move",
            CONFIG.autoApproach, function(value)
                CONFIG.autoApproach = value
                return true
            end)
        STATE.ui.toggleRow(p, "autoThrow", "Auto throw after carry",
            "Waits for a verified carry, then uses the game's throw control",
            CONFIG.autoThrow, function(value)
                CONFIG.autoThrow = value
                STATE.throw.fails = 0
                STATE.throw.cooldownUntil = 0
                return true
            end)
        STATE.ui.toggleRow(p, "aimLava", "Face lava before throwing",
            "Looks for lava parts during the throw; never fakes the result",
            CONFIG.aimLava, function(value)
                CONFIG.aimLava = value
                if value and #STATE.safety.lavaParts == 0 then
                    H.scanLava(false)
                end
                return true
            end)
        STATE.ui.sliderRow(p, "Grab reach", 8, 60, CONFIG.grabReach, " studs",
            function(value)
                CONFIG.grabReach = value
                return true
            end)
        STATE.ui.sliderRow(p, "Auto-throw delay", 1, 5, round(CONFIG.throwDelay), "s",
            function(value)
                CONFIG.throwDelay = value
                return true
            end)

        STATE.ui.section(p, "Engine")
        STATE.ui.toggleRow(p, "promptBoost", "Prompt boost",
            "Temporarily extends the real prompt, then restores it",
            CONFIG.promptBoost, function(value)
                CONFIG.promptBoost = value
                if value then
                    toast("PROMPT BOOST", "Real prompt fields are restored after each use.", 3, "info")
                else
                    H.restoreAllPrompts()
                end
                return true
            end)
        STATE.ui.toggleRow(p, "stickyTarget", "Keep the chosen target",
            "Off means the picker clears when that player leaves",
            CONFIG.stickyTarget, function(value)
                CONFIG.stickyTarget = value
                return true
            end)
        STATE.ui.toggleRow(p, "skipFriends", "Skip friends when auto-targeting",
            "Manual picks still work; auto-hug only avoids detected friends",
            CONFIG.skipFriends, function(value)
                CONFIG.skipFriends = value
                return true
            end)
        STATE.ui.toggleRow(p, "skipCarriedTargets", "Skip already-carried players",
            "Avoids grabbing someone who is held by another player",
            CONFIG.skipCarriedTargets, function(value)
                CONFIG.skipCarriedTargets = value
                return true
            end)
        STATE.ui.toggleRow(p, "remoteFallback", "Opt-in remote fallback",
            "UNVERIFIED: fires only the single payload chosen below",
            CONFIG.remoteFallback, function(value)
                CONFIG.remoteFallback = value
                if value then
                    toast("FALLBACK ENABLED",
                        "This is a guess, not the game's guaranteed control. Prompt/tool still comes first.",
                        5, "warn")
                end
                return true
            end)
        STATE.ui.choiceRow(p, "Grab payload", { "Player", "Character", "Hug", "Grab" },
            CONFIG.grabPayload, function(value)
                CONFIG.grabPayload = value
                return true
            end)
        STATE.ui.choiceRow(p, "Throw payload", { "None", "Throw", "Drop", "Release" },
            CONFIG.throwPayload, function(value)
                CONFIG.throwPayload = value
                return true
            end)
        STATE.ui.buttonRow(p, "Scan for hug remotes",
            "Read-only name scan; no remote is fired by this button",
            function()
                H.scanRemotes()
                local counts = string.format("%d grab · %d throw · %d escape candidates",
                    #STATE.remote.grabs, #STATE.remote.throws, #STATE.remote.escapes)
                toast("REMOTE SCAN", counts, 3.5, "info")
                return true
            end)
        STATE.ui.buttonRow(p, "Grab diagnostics",
            "Prompt distance, carry signal, fallback candidates",
            function()
                local text = H.grabDiagnostics()
                if H.copyText then H.copyText(text, "Grab diagnostics copied") end
                toast("GRAB DIAGNOSTICS", string.gsub(text, "\n", "  ·  "), 6, "info")
                return true
            end)
        STATE.ui.disclaimer(p,
            "Hug control comes from the game: a ProximityPrompt, a hug tool, or a visible game button. "
            .. "Remote fallback is off by default and is explicitly unverified. A fire is never reported as a confirmed carry "
            .. "unless a weld, value, tool, or helpless humanoid state is visible.",
            THEME.accent2)
        STATE.ui.spacer(p, 8)
    end

    -- ==================== GUARD ====================
    do
        local p = page("guard")
        STATE.ui.section(p, "Carry defense")
        STATE.ui.toggleRow(p, "carryAlarm", "Hug proximity alarm",
            "Toast when another player enters 7 studs",
            CONFIG.carryAlarm, function(value)
                CONFIG.carryAlarm = value
                return true
            end)
        STATE.ui.toggleRow(p, "autoStruggle", "Auto struggle",
            "Tries the real escape control at most once per second",
            CONFIG.autoStruggle, function(value)
                CONFIG.autoStruggle = value
                return true
            end)
        STATE.ui.toggleRow(p, "antiFling", "Anti-fling",
            "Clamps runaway linear/angular velocity locally",
            CONFIG.antiFling, function(value)
                CONFIG.antiFling = value
                return true
            end)
        STATE.ui.toggleRow(p, "antiLava", "Lava guard",
            "Returns to the last safe surface when lava is underfoot",
            CONFIG.antiLava, function(value)
                CONFIG.antiLava = value
                if value then H.scanLava(false) end
                return true
            end)
        STATE.ui.toggleRow(p, "antiVoid", "Void guard",
            "Recovers when you fall below the map with nothing solid underneath",
            CONFIG.antiVoid, function(value)
                CONFIG.antiVoid = value
                return true
            end)
        STATE.ui.toggleRow(p, "autoDodge", "Auto-dodge rushers",
            "A short jump when another player closes in (never while carrying)",
            CONFIG.autoDodge, function(value)
                CONFIG.autoDodge = value
                STATE.alarms.dodgeUntil = 0
                return true
            end)
        STATE.ui.sliderRow(p, "Dodge distance", 5, 18, CONFIG.dodgeDistance, " studs",
            function(value)
                CONFIG.dodgeDistance = value
                return true
            end)
        STATE.ui.toggleRow(p, "respawnSafe", "Return to safe spot on respawn",
            "One position update after the character reloads",
            CONFIG.respawnSafe, function(value)
                CONFIG.respawnSafe = value
                return true
            end)

        STATE.ui.section(p, "Controls")
        STATE.ui.buttonRow(p, "Struggle now",
            "Game escape control, then a jump impulse only as a warning fallback",
            function()
                local ok, err = H.struggle("manual")
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.buttonRow(p, "Save safe spot",
            "Stores the current surface for lava guard / respawn",
            function()
                if STATE.fly.on then return false, "Turn fly off before saving a safe spot." end
                local root = H.getRoot(LP)
                if not root then return false, "No character root." end
                if H.lavaUnderfoot and H.lavaUnderfoot() then
                    return false, "The current position is over lava."
                end
                STATE.safety.lastSafe = root.CFrame
                STATE.safety.lastSave = now()
                H.updateTowerLabels()
                toast("SAFE SPOT", "Saved at Y=" .. round(root.Position.Y) .. ".", 2.5, "ok")
                return true
            end)
        STATE.ui.buttonRow(p, "Return to safe spot",
            "Position update is verified after it is sent",
            function()
                local ok, err = H.returnToSafeSpot()
                if not ok then return false, tostring(err) end
                return true
            end)

        STATE.ui.section(p, "Session stats")
        local refs = {}
        refs.attempts = STATE.ui.statRow(p, "Grab attempts", tostring(STATE.stats.attempts))
        refs.carries = STATE.ui.statRow(p, "Confirmed carries", tostring(STATE.stats.carries))
        refs.releases = STATE.ui.statRow(p, "Verified releases", tostring(STATE.stats.releases))
        refs.throws = STATE.ui.statRow(p, "Throw controls fired", tostring(STATE.stats.throws))
        refs.lava = STATE.ui.statRow(p, "Lava tosses verified", tostring(STATE.stats.lava))
        refs.failures = STATE.ui.statRow(p, "Failed / unconfirmed", tostring(STATE.stats.failures))
        STATE.ui.stats = refs
        STATE.ui.tower = STATE.ui.tower or {}
        STATE.ui.tower.safeSpot = STATE.ui.statRow(p, "Saved safe spot",
            STATE.safety.lastSafe and (round(STATE.safety.lastSafe.Position.Y) .. "m") or "none")
        STATE.ui.tower.guardState = STATE.ui.statRow(p, "Lava guard",
            CONFIG.antiLava and "ON" or "OFF")

        STATE.ui.disclaimer(p,
            "A server-side carry cannot be cancelled by deleting welds. HUGGER uses the game's escape prompt/tool/button when "
            .. "one is exposed. If none exists, it jumps and tells you the carry may persist instead of pretending you are free.",
            THEME.red)
        STATE.ui.spacer(p, 8)
    end

    -- ==================== CLIMB ====================
    do
        local p = page("climb")
        STATE.ui.section(p, "Tower tools")
        STATE.ui.buttonRow(p, "Scout tower surfaces",
            "Scans tall, flat, walkable parts and sorts them by height",
            function()
                H.scanTower(true)
                local highest = STATE.tower.highest
                if not highest then
                    return false, "No tower surface matched the scout filter."
                end
                toast("TOWER SCOUT",
                    string.format("Highest surface: %s at Y=%d", tostring(highest.name), round(highest.y)),
                    3.5, "info")
                return true
            end, true)
        STATE.ui.buttonRow(p, "Go to highest surface",
            "Verified after the position update",
            function()
                local ok, err = H.teleportHighest()
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.buttonRow(p, "Step up one surface",
            "Short upward raycast; refuses lava hits",
            function()
                local ok, err = H.stepUp()
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.buttonRow(p, "Step down one surface",
            "Casts below the current platform; refuses lava hits",
            function()
                local ok, err = H.stepDown()
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.buttonRow(p, "Return to session start",
            "The captured entry position, verified after the update",
            function()
                local ok, err = H.returnToSpawn()
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.toggleRow(p, "autoJump", "Auto jump",
            "Bunny-hop assist for tower climbs",
            CONFIG.autoJump, function(value)
                CONFIG.autoJump = value
                return true
            end)

        STATE.ui.section(p, "Altitude")
        STATE.ui.tower = STATE.ui.tower or {}
        STATE.ui.tower.altitude = STATE.ui.statRow(p, "Altitude", "0m")
        STATE.ui.tower.best = STATE.ui.statRow(p, "Best altitude", tostring(STATE.tower.best or 0) .. "m")
        STATE.ui.tower.highest = STATE.ui.statRow(p, "Scouted summit",
            STATE.tower.highest and (round(STATE.tower.highest.y) .. "m") or "not scanned")
        STATE.ui.tower.lavaCount = STATE.ui.statRow(p, "Lava parts cached", tostring(#STATE.safety.lavaParts))
        STATE.ui.tower.safeSpot2 = STATE.ui.statRow(p, "Safe spot",
            STATE.safety.lastSafe and (round(STATE.safety.lastSafe.Position.Y) .. "m") or "none")

        STATE.ui.disclaimer(p,
            "Tower scout is a geometric heuristic: it looks for large, collidable, non-lava surfaces between Y=8 and Y=1600. "
            .. "On a decorated tower it can select a roof or balcony instead of the intended finish pad. The result is labeled as a "
            .. "surface, not a guaranteed win.",
            THEME.gold)
        STATE.ui.spacer(p, 8)
    end

    -- ==================== MOVE ====================
    do
        local p = page("move")
        STATE.ui.section(p, "Movement")
        STATE.ui.toggleRow(p, "fly", "3D fly",
            "BodyVelocity + gyro; a touch pad appears on the left",
            CONFIG.flyEnabled, function(value)
                CONFIG.flyEnabled = value
                if value then
                    local ok, err = H.startFly()
                    if not ok then
                        CONFIG.flyEnabled = false
                        return false, tostring(err)
                    end
                    toast("FLY ON", "Use WASD, Space, and Shift. The pad works on touch.", 3, "info")
                else
                    H.stopFly(false)
                end
                return true
            end)
        STATE.ui.toggleRow(p, "noclip", "Noclip",
            "Local CanCollide only; restores every saved part on off",
            CONFIG.noclip, function(value)
                local ok, err = H.setNoclip(value)
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.toggleRow(p, "walkEnabled", "Custom walk speed",
            "Server may clamp speed on its own",
            CONFIG.walkEnabled, function(value)
                CONFIG.walkEnabled = value
                H.applyWalk()
                return true
            end)
        STATE.ui.toggleRow(p, "jumpEnabled", "Custom jump power",
            "Restores the original humanoid values when disabled",
            CONFIG.jumpEnabled, function(value)
                CONFIG.jumpEnabled = value
                H.applyJump()
                return true
            end)
        STATE.ui.sliderRow(p, "Walk speed", 16, 120, CONFIG.walkSpeed, "",
            function(value)
                CONFIG.walkSpeed = value
                if CONFIG.walkEnabled then H.applyWalk() end
                return true
            end)
        STATE.ui.sliderRow(p, "Jump power", 50, 250, CONFIG.jumpPower, "",
            function(value)
                CONFIG.jumpPower = value
                if CONFIG.jumpEnabled then H.applyJump() end
                return true
            end)
        STATE.ui.toggleRow(p, "infiniteJump", "Infinite jump",
            "Each JumpRequest re-enters the jumping state; no extra teleport",
            CONFIG.infiniteJump, function(value)
                CONFIG.infiniteJump = value
                return true
            end)
        STATE.ui.toggleRow(p, "lowGravity", "Low gravity",
            "Client-side Workspace.Gravity change; restored on off and unload",
            CONFIG.lowGravity, function(value)
                CONFIG.lowGravity = value
                H.applyGravity()
                return true
            end)
        STATE.ui.sliderRow(p, "Gravity", 20, 196, CONFIG.gravity, "",
            function(value)
                CONFIG.gravity = value
                if CONFIG.lowGravity then H.applyGravity() end
                return true
            end)
        STATE.ui.sliderRow(p, "Fly speed", 20, 160, CONFIG.flySpeed, "",
            function(value)
                CONFIG.flySpeed = value
                return true
            end)
        STATE.ui.buttonRow(p, "Reset all movement",
            "Turns fly, noclip, walk, and jump mods off and restores values",
            function()
                CONFIG.flyEnabled = false
                CONFIG.noclip = false
                CONFIG.walkEnabled = false
                CONFIG.jumpEnabled = false
                H.stopFly(false)
                H.setNoclip(false)
                H.applyWalk()
                H.applyJump()
                local names = { "fly", "noclip", "walkEnabled", "jumpEnabled" }
                for _, id in ipairs(names) do
                    local sw = STATE.switches[id]
                    if sw and sw.Set then pcall(sw.Set, false, true) end
                end
                return true
            end)
        STATE.ui.disclaimer(p,
            "Movement changes are client-side. The game can reject position updates, clamp WalkSpeed, or reset Humanoid state "
            .. "on respawn. HUGGER reapplies its own values after a respawn and restores saved values when you unload.",
            THEME.blue)
        STATE.ui.spacer(p, 8)
    end

    -- ==================== ESP ====================
    do
        local p = page("esp")
        STATE.ui.section(p, "Overlay")
        STATE.ui.toggleRow(p, "esp", "Player ESP",
            "Boxes, names, health, distance, optional tracers",
            CONFIG.esp, function(value)
                CONFIG.esp = value
                if value then
                    H.updateESP()
                else
                    H.clearESP()
                end
                return true
            end)
        STATE.ui.toggleRow(p, "espNames", "Names", nil, CONFIG.espNames,
            function(value) CONFIG.espNames = value return true end)
        STATE.ui.toggleRow(p, "espHealth", "Health bars", nil, CONFIG.espHealth,
            function(value) CONFIG.espHealth = value return true end)
        STATE.ui.toggleRow(p, "espDistance", "Distance", nil, CONFIG.espDistance,
            function(value) CONFIG.espDistance = value return true end)
        STATE.ui.toggleRow(p, "espTracers", "Tracers",
            "Line from the bottom of the screen",
            CONFIG.espTracers, function(value)
                CONFIG.espTracers = value
                return true
            end)
        STATE.ui.toggleRow(p, "espChams", "Highlight",
            "One Highlight per visible player; disable if the engine caps them",
            CONFIG.espChams, function(value)
                CONFIG.espChams = value
                if not value then
                    for _, highlight in pairs(STATE.esp.chams) do
                        pcall(function() highlight.Enabled = false end)
                    end
                end
                return true
            end)
        STATE.ui.toggleRow(p, "beacon", "Target beacon",
            "Gold billboard above the chosen target",
            CONFIG.beacon, function(value)
                CONFIG.beacon = value
                H.updateBeacon()
                return true
            end)
        STATE.ui.toggleRow(p, "spectate", "Spectate target",
            "Moves the camera to the target humanoid; restored on off or unload",
            false, function(value)
                CONFIG.spectate = value
                if value then
                    local target = H.resolveTarget(false)
                    if not target then
                        CONFIG.spectate = false
                        return false, "No target to spectate."
                    end
                    local ok, err = H.startSpectate(target)
                    if not ok then
                        CONFIG.spectate = false
                        return false, tostring(err)
                    end
                else
                    H.stopSpectate()
                end
                return true
            end)
        STATE.ui.toggleRow(p, "lavaGlow", "Lava glow",
            "Neon tint on cached lava parts; restored on off",
            CONFIG.lavaGlow, function(value)
                H.setLavaGlow(value)
                return true
            end)
        STATE.ui.sliderRow(p, "ESP range", 60, 2000, CONFIG.espRange, "m",
            function(value)
                CONFIG.espRange = value
                return true
            end)
        STATE.ui.buttonRow(p, "Clear ESP overlay",
            "Removes boxes and Highlights immediately",
            function()
                H.clearESP()
                CONFIG.esp = false
                local sw = STATE.switches.esp
                if sw and sw.Set then pcall(sw.Set, false, true) end
                return true
            end)
        STATE.ui.tower = STATE.ui.tower or {}
        STATE.ui.tower.espCount = STATE.ui.statRow(p, "Players drawn", tostring(STATE.esp.count or 0))
        STATE.ui.disclaimer(p,
            "ESP reads only what the client already receives. Distances beyond the streamed world are impossible to draw. "
            .. "Highlight instances are capped by the engine on some clients, so HUGGER lets you turn them off while keeping boxes.",
            THEME.purple)
        STATE.ui.spacer(p, 8)
    end

    -- ==================== SERVER ====================
    do
        local p = page("server")
        STATE.ui.section(p, "Server browser")
        STATE.ui.buttonRow(p, "Scan public servers",
            "Read-only games.roblox.com list, sorted by player count",
            function()
                H.scanServers(true)
                if #STATE.server.list == 0 then
                    return false, STATE.server.lastMessage ~= "" and STATE.server.lastMessage
                        or "No servers returned."
                end
                toast("SERVER SCAN", tostring(#STATE.server.list) .. " servers visible.", 3, "ok")
                return true
            end, true)
        STATE.ui.buttonRow(p, "Hop to lowest-population server",
            "Teleport is requested; the client cannot force a join",
            function()
                local ok, err = H.hopServer("low")
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.buttonRow(p, "Hop to a random server",
            "Random choice among the first 12 joinable entries",
            function()
                local ok, err = H.hopServer("random")
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.buttonRow(p, "Rejoin this server",
            "Same JobId via TeleportToPlaceInstance",
            function()
                local ok, err = H.rejoinServer()
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.buttonRow(p, "Copy JobId",
            "Useful for support and manual rejoin",
            function()
                local copied = H.copyText(tostring(game.JobId or ""), "JobId copied")
                if not copied then return false, "No clipboard executor available." end
                return true
            end)
        STATE.ui.toggleRow(p, "antiAfk", "Anti-AFK",
            "Sends a VirtualUser pulse when Roblox reports Idled",
            CONFIG.antiAfk, function(value)
                CONFIG.antiAfk = value
                if value then
                    H.startAntiAfk()
                else
                    H.stopAntiAfk()
                end
                return true
            end)

        STATE.ui.section(p, "Connection")
        local refs = {}
        refs.players = STATE.ui.statRow(p, "Players", tostring(#Players:GetPlayers()))
        refs.place = STATE.ui.statRow(p, "Place ID", tostring(game.PlaceId or PLACE_ID))
        refs.job = STATE.ui.statRow(p, "JobId", string.sub(tostring(game.JobId or "?"), 1, 18))
        refs.ping = STATE.ui.statRow(p, "Ping", "--")
        refs.servers = STATE.ui.statRow(p, "Visible servers", "0 visible")
        refs.message = STATE.ui.statRow(p, "Last scan", "No scan yet.")
        refs.flagged = STATE.ui.statRow(p, "Scanner", "IDLE")
        STATE.ui.server = refs

        STATE.ui.disclaimer(p,
            "Server listing uses HttpGet or request, so it fails cleanly when an executor blocks HTTP. A teleport request can be "
            .. "refused by Roblox (full server, privacy, rate limit); HUGGER reports the request, not a guaranteed join.",
            THEME.blue)
        STATE.ui.spacer(p, 8)
    end

    -- ==================== SETUP ====================
    do
        local p = page("setup")
        STATE.ui.section(p, "Interface")
        STATE.ui.sliderRow(p, "UI scale", 80, 110, round((STATE.uiScale or 1) * 100), "%",
            function(value)
                STATE.ui.setUIScale(value / 100)
                return true
            end)
        STATE.ui.toggleRow(p, "showPerf", "FPS / ping footer",
            "Live performance readout",
            CONFIG.showPerf, function(value)
                CONFIG.showPerf = value
                STATE.ui.refreshPerf()
                return true
            end)
        STATE.ui.toggleRow(p, "fullbright", "Fullbright",
            "Bright ambient light and no global shadows; restored on off",
            CONFIG.fullbright, function(value)
                local ok, err = H.setFullbright(value)
                if not ok then return false, tostring(err) end
                return true
            end)
        STATE.ui.toggleRow(p, "lockFov", "Lock camera FOV",
            "Client-side field of view, restored on off and unload",
            CONFIG.lockFov, function(value)
                CONFIG.lockFov = value
                H.applyFov()
                return true
            end)
        STATE.ui.sliderRow(p, "Field of view", 60, 120, CONFIG.fov, "",
            function(value)
                CONFIG.fov = value
                if CONFIG.lockFov then H.applyFov() end
                return true
            end)
        STATE.ui.buttonRow(p, "Recenter window",
            "Return the panel to the middle of the viewport",
            function()
                STATE.ui.recenter()
                return true
            end)

        STATE.ui.section(p, "Diagnostics")
        STATE.ui.buttonRow(p, "Run self-test",
            "Interface, pages, camera, character, services, engine",
            function()
                local ok, text, summary = H.selfTest()
                if STATE.ui.diagLabel then STATE.ui.diagLabel.Text = text end
                toast("SELF-TEST", summary, 4, ok and "ok" or "warn")
                return ok, summary
            end, true)
        STATE.ui.buttonRow(p, "Copy full diagnostics",
            "Includes prompt audit, remotes, carry state, stats, perf",
            function()
                local text = H.diagText()
                if STATE.ui.diagLabel then STATE.ui.diagLabel.Text = text end
                if not H.copyText(text, "Diagnostics copied") then
                    return false, "No clipboard executor available."
                end
                return true
            end)
        STATE.ui.buttonRow(p, "Rescan remotes, lava, and tower",
            "Non-destructive scans; no remotes are fired",
            function()
                task.spawn(function()
                    H.scanRemotes()
                    H.scanLava(true)
                    H.scanTower(true)
                    if STATE.ui.diagLabel then STATE.ui.diagLabel.Text = H.diagText() end
                    toast("RESCAN DONE",
                        string.format("%d grab / %d throw / %d lava / %d surfaces",
                            #STATE.remote.grabs, #STATE.remote.throws,
                            #STATE.safety.lavaParts, #STATE.tower.platforms), 4, "ok")
                end)
                return true
            end)
        STATE.ui.diagLabel = diagnosticsLabel(p)

        STATE.ui.section(p, "Activity log")
        STATE.ui.buttonRow(p, "Refresh log",
            "Shows the most recent 18 entries",
            function()
                refreshLog()
                return true
            end)
        local logLabel = STATE.ui.make("TextLabel", {
            Text = "No log entries yet.",
            Size = UDim2.new(1, -4, 0, 110),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = THEME.card,
            BorderSizePixel = 0,
            Font = Enum.Font.Code,
            TextSize = 8,
            TextColor3 = THEME.dim,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            LineHeight = 1.2,
        }, p)
        STATE.ui.corner(logLabel, 8)
        STATE.ui.stroke(logLabel, THEME.line, 1, 0.55)
        STATE.ui.padding(logLabel, 10, 8, 8, 8)
        STATE.ui.logLabel = logLabel
        refreshLog()

        STATE.ui.section(p, "About")
        STATE.ui.disclaimer(p,
            "HUGGER V3 " .. VERSION .. " — a ground-up, prompt-first rebuild of Troll-Hug-Tower v2.0. The original file is preserved "
            .. "separately and is not modified. No server anti-cheat bypass, no gear granting, and no fake success states. "
            .. "Every grab, throw, and release is either verified by a visible signal or labeled UNCONFIRMED.",
            THEME.mint)
        STATE.ui.buttonRow(p, "Unload HUGGER V3",
            "Restores movement, noclip, lighting, ESP, fly, prompts, and GUI",
            function()
                if STATE.ui.confirm then
                    STATE.ui.confirm("UNLOAD HUGGER V3",
                        "This restores every change and removes the interface. You can execute the script again to reopen it.",
                        "UNLOAD", function()
                            if H.unload then H.unload() end
                        end)
                    return true
                end
                return false, "Confirmation dialog is unavailable."
            end)
        STATE.ui.spacer(p, 12)
    end
end
-- ============================================================
--  INIT  //  runtime hooks, loops, keybinds, unload
-- ============================================================
do
    local timers = {}
    local frameCount = 0
    local fpsAt = now()
    local function due(name, interval)
        local stamp = now()
        if not timers[name] or stamp >= timers[name] then
            timers[name] = stamp + interval
            return true
        end
        return false
    end

    local function setNoclip(value)
        value = value == true
        CONFIG.noclip = value
        STATE.noclip.on = value
        if value then
            H.applyNoclip()
            if not STATE.noclip.conn then
                STATE.noclip.conn = connect(RunService.Stepped, function()
                    if STATE.noclip.on and not STATE.unloading then
                        H.applyNoclip()
                    end
                end)
            end
            return true
        end
        if STATE.noclip.conn then
            pcall(function() STATE.noclip.conn:Disconnect() end)
            STATE.noclip.conn = nil
        end
        for part, canCollide in pairs(STATE.noclip.saved) do
            if part and part.Parent then
                pcall(function() part.CanCollide = canCollide end)
            end
        end
        STATE.noclip.saved = {}
        return true
    end
    H.setNoclip = setNoclip

    local function returnToSafeSpot()
        local safe = STATE.safety.lastSafe
        if not safe then return false, "No safe spot saved yet. Use Save safe spot first." end
        local root = getRoot(LP)
        if not root then return false, "No character root." end
        local ok, err = pcall(function()
            root.CFrame = safe + Vector3.new(0, 3, 0)
            root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
        end)
        if not ok then return false, tostring(err) end
        task.wait(0.18)
        local after = getPivot(LP)
        if after and (after - safe.Position).Magnitude <= 30 then
            if STATE.ui.toast then
                STATE.ui.toast("SAFE SPOT", "Returned and verified at Y=" .. round(after.Y) .. ".", 3, "ok")
            end
            H.saveSafePos()
            return true
        end
        return false, "The server rejected the position update."
    end
    H.returnToSafeSpot = returnToSafeSpot

    local function resetCarryTracking()
        STATE.grab.busy = false
        STATE.grab.state = "idle"
        STATE.grab.target = nil
        STATE.grab.prompt = nil
        STATE.grab.cooldownUntil = 0
        STATE.throw.busy = false
        STATE.throw.state = "idle"
        STATE.throw.cooldownUntil = 0
        STATE.throw.fails = 0
        STATE.carry.carrying = nil
        STATE.carry.carrier = nil
        STATE.carry.signal = "none"
        STATE.carry.at = 0
        STATE.grab.carrySince = 0
        H.clearPromptCache()
    end

    local function hookCharacter(character)
        if not character or STATE.unloading then return end
        resetCarryTracking()
        STATE.noclip.saved = {}
        if STATE.fly.on then
            H.stopFly(true)
            local sw = STATE.switches.fly
            if sw and sw.Set then pcall(sw.Set, false, true) end
        end
        task.delay(0.5, function()
            if STATE.unloading or STATE.unloaded then return end
            if getChar(LP) ~= character then return end
            H.applyWalk()
            H.applyJump()
            if CONFIG.lowGravity then H.applyGravity() end
            if CONFIG.lockFov then H.applyFov() end
            if STATE.noclip.on then H.applyNoclip() end
            if CONFIG.respawnSafe and STATE.safety.lastSafe then
                local root = getRoot(LP)
                if root then
                    pcall(function()
                        root.CFrame = STATE.safety.lastSafe + Vector3.new(0, 3, 0)
                        root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                    end)
                    task.wait(0.15)
                    local after = getPivot(LP)
                    if after and (after - STATE.safety.lastSafe.Position).Magnitude <= 25 then
                        if STATE.ui.toast then
                            STATE.ui.toast("RESPAWN RETURN", "Returned to the saved safe spot.", 3, "ok")
                        end
                    else
                        if STATE.ui.toast then
                            STATE.ui.toast("RESPAWN BLOCKED",
                                "The server did not accept the safe-spot position update.", 3.5, "warn")
                        end
                    end
                end
            end
            H.updateHeroSignature()
            H.updateBeacon()
            H.updateTowerLabels()
        end)
    end

    connect(LP.CharacterAdded, hookCharacter)
    if LP.Character then
        task.defer(hookCharacter, LP.Character)
    end
    connect(LP.CharacterRemoving, function()
        STATE.carry.carrying = nil
        STATE.carry.carrier = nil
        STATE.carry.signal = "none"
        STATE.grab.busy = false
        STATE.throw.busy = false
        if STATE.fly.on then H.stopFly(true) end
    end)

    connect(Players.PlayerRemoving, function(player)
        if STATE.target.userId == player.UserId then
            STATE.target.userId = nil
            STATE.target.mode = "nearest"
            STATE.heroSignature = ""
        end
        if STATE.spectate.player == player then H.stopSpectate() end
        if STATE.beacon.player == player and STATE.beacon.gui then
            pcall(function() STATE.beacon.gui:Destroy() end)
            STATE.beacon.gui = nil
            STATE.beacon.player = nil
        end
    end)

    local function bindCamera()
        local camera = currentCamera()
        if not camera or camera == STATE.boundCamera then return end
        STATE.boundCamera = camera
        connect(camera:GetPropertyChangedSignal("ViewportSize"), function()
            if STATE.ui.layout then pcall(STATE.ui.layout) end
        end)
        if STATE.ui.layout then pcall(STATE.ui.layout) end
    end
    connect(workspace:GetPropertyChangedSignal("CurrentCamera"), bindCamera)
    bindCamera()

    -- heartbeat: state, automation, labels, perf
    connect(RunService.Heartbeat, function(dt)
        if STATE.unloading or STATE.unloaded then return end
        frameCount = frameCount + 1
        local stamp = now()
        if stamp - fpsAt >= 1 then
            STATE.perf.fps = frameCount / math.max(stamp - fpsAt, 0.001)
            frameCount = 0
            fpsAt = stamp
            if STATE.ui.refreshPerf then pcall(STATE.ui.refreshPerf) end
        end
        if due("ping", 2) then
            local ok, value = pcall(function()
                return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
            end)
            if ok and tonumber(value) then STATE.perf.ping = tonumber(value) end
        end

        if due("carry", 0.3) then
            H.updateCarryState()
            H.updateHeroSignature()
        end
        if due("safe", 0.9) then
            H.saveSafePos()
            H.updateTowerLabels()
        end
        if CONFIG.antiLava and due("lava", 0.25) then
            H.antiLavaTick()
        end
        if CONFIG.antiVoid and due("void", 0.4) then
            H.antiVoidTick()
        end
        if CONFIG.autoDodge and due("dodge", 0.35) then
            H.autoDodgeTick()
        end
        if CONFIG.antiFling and due("fling", 0.2) then
            H.antiFlingTick()
        end
        if CONFIG.lockFov and due("fov", 1) then
            H.applyFov()
        end
        if CONFIG.carryAlarm and due("alarm", 0.7) then
            H.proximityAlarm()
        end
        if CONFIG.beacon and due("beacon", 1.1) then
            H.updateBeacon()
        end
        if due("stats", 1) then
            H.updateStats()
            if H.updateSpectate then H.updateSpectate() end
        end
        if due("server", 2) then
            H.updateServerLabels()
        end
        if due("diag", 1.5) then
            H.updateDiag()
        end
        if due("modal", 1.2) and STATE.ui.modalOpen and STATE.ui.renderModal then
            pcall(STATE.ui.renderModal)
        end
        if STATE.ui.showPerf and due("perfText", 1) and STATE.ui.refreshPerf then
            pcall(STATE.ui.refreshPerf)
        end

        if CONFIG.autoGrab and due("autograb", 0.4) then
            H.grabTick()
        end
        if CONFIG.autoThrow and due("autothrow", 0.4) then
            H.throwTick()
        end
        if CONFIG.autoStruggle and due("autostruggle", 1.0) and STATE.carry.carrier then
            H.struggle("auto")
        end
        if CONFIG.autoJump and due("autojump", 0.5) then
            H.autoJumpTick()
        end
    end)

    -- render: ESP boxes and fly velocity
    connect(RunService.RenderStepped, function(dt)
        if STATE.unloading or STATE.unloaded then return end
        if CONFIG.esp and due("esp", 0.1) then
            H.updateESP()
        end
        if STATE.fly.on then
            H.flyStep(dt)
        end
    end)

    connect(UserInput.JumpRequest, function()
        if not CONFIG.infiniteJump or STATE.unloading or STATE.unloaded or STATE.fly.on then return end
        local hum = getHum(LP)
        if hum and hum.Health > 0 then
            pcall(function()
                hum.Jump = true
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
            end)
        end
    end)

    -- keybinds
    connect(UserInput.InputBegan, function(input)
        if STATE.unloading or STATE.unloaded then return end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
        local focused = false
        pcall(function() focused = UserInput:GetFocusedTextBox() ~= nil end)
        if focused then return end
        if input.KeyCode == Enum.KeyCode.G then
            if STATE.ui.heroAction then pcall(STATE.ui.heroAction) end
        elseif input.KeyCode == Enum.KeyCode.T then
            local ok, err = H.throwCarried("manual")
            if not ok and err ~= "not carrying" and err ~= "busy" and STATE.ui.toast then
                STATE.ui.toast("THROW", tostring(err), 2.5, "warn")
            end
        elseif input.KeyCode == Enum.KeyCode.R then
            local ok, err = H.struggle("manual")
            if not ok and err ~= "not carried" and STATE.ui.toast then
                STATE.ui.toast("STRUGGLE", tostring(err), 2.5, "warn")
            end
        elseif input.KeyCode == Enum.KeyCode.F then
            local sw = STATE.switches.fly
            if sw and sw.Set then pcall(sw.Set, not sw.Get()) end
        elseif input.KeyCode == Enum.KeyCode.E then
            local sw = STATE.switches.esp
            if sw and sw.Set then pcall(sw.Set, not sw.Get()) end
        end
    end)

    H.unload = function()
        if STATE.unloading or STATE.unloaded then return end
        STATE.unloading = true
        CONFIG.autoGrab = false
        CONFIG.autoThrow = false
        CONFIG.autoStruggle = false
        CONFIG.autoJump = false
        pcall(function() H.restoreAllPrompts() end)
        pcall(function() H.stopAntiAfk() end)
        pcall(function() H.stopSpectate() end)
        pcall(function() H.clearESP() end)
        pcall(function() H.restoreLavaGlow() end)
        pcall(function() H.setFullbright(false) end)
        CONFIG.lockFov = false
        pcall(function() H.applyFov(true) end)
        CONFIG.lowGravity = false
        pcall(function() H.applyGravity(true) end)
        CONFIG.spectate = false
        pcall(function() setNoclip(false) end)
        if STATE.fly.on then pcall(function() H.stopFly(true) end) end
        CONFIG.walkEnabled = false
        CONFIG.jumpEnabled = false
        pcall(function() H.applyWalk() end)
        pcall(function() H.applyJump() end)
        if STATE.beacon.gui then pcall(function() STATE.beacon.gui:Destroy() end) end
        STATE.beacon.gui = nil
        STATE.beacon.player = nil
        disconnectAll()
        local screen = STATE.ui.screen
        if screen then
            pcall(function() screen.Enabled = false end)
            pcall(function() screen:Destroy() end)
        end
        local esp = H.espGui and H.espGui()
        if esp then pcall(function() esp:Destroy() end) end
        local pad = H.flyPad and H.flyPad()
        if pad then pcall(function() pad:Destroy() end) end
        STATE.unloaded = true
        STATE.unloading = false
        if Env.HuggerV3 == H then Env.HuggerV3 = nil end
        print("[HUGGER] Unloaded; prompts, movement, ESP, fly, noclip, and GUI restored.")
    end

    H.export = function()
        return H.diagText()
    end

    -- boot
    if game.PlaceId and game.PlaceId ~= PLACE_ID then
        task.delay(0.6, function()
            if STATE.unloaded then return end
            if STATE.ui.toast then
                STATE.ui.toast("DIFFERENT PLACE",
                    "HUGGER V3 targets TROLL Hug Tower (" .. PLACE_ID .. "). Controls may not exist here.",
                    7, "warn")
            end
        end)
    end

    if CONFIG.antiAfk then H.startAntiAfk() end
    task.spawn(function() H.scanRemotes() end)
    H.scanLava(false)
    H.saveSafePos()
    local bootRoot = getRoot(LP)
    if bootRoot and not STATE.safety.spawn then
        STATE.safety.spawn = bootRoot.CFrame
    end
    H.updateHeroSignature()
    H.updateStats()
    H.updateTowerLabels()
    H.updateServerLabels()
    H.updateBeacon()
    if STATE.ui.diagLabel then
        local ok, text, summary = H.selfTest()
        STATE.ui.diagLabel.Text = text
        log("Self-test: " .. summary, not ok)
    end
    setStatus("READY — prompt-first grab engine", "ok")

    task.delay(0.8, function()
        if STATE.unloading or STATE.unloaded then return end
        if STATE.ui.toast then
            STATE.ui.toast("HUGGER V3 READY",
                "Hug uses the game prompt first. Results are verified, or labeled UNCONFIRMED.",
                5, "ok")
        end
        if STATE.ui.refreshLog then pcall(STATE.ui.refreshLog) end
    end)
end
