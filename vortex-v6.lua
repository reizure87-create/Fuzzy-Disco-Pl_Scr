--[[
    VORTEX V6 // PRISON LIFE
    Single-file, keyless, mobile-first rebuild of Vortex V5.

    What changed
      - responsive UI that actually fits a phone (V5 was a fixed 630x425 window)
      - every toggle has a real callback + a visible ACTIVE / OFF / ERROR state
      - reversible noclip, hitbox, fullbright, ESP, fly, and invisibility
      - touch raycast for Click Kill / Click Arrest (V5 used Mouse.Target only)
      - live camera lookup (V5 cached Camera and broke after respawn)
      - remote schema detection + result verification instead of fake success toasts
      - no destructive CharacterCollision / PlayerTased connection deletion
      - diagnostics tab with remotes, executor capabilities, and a self-test

    Anti-cheat reality
      Prison Life validates the important things on the server. Nothing in a
      client-side script can "bypass" server damage, arrest, or team checks.
      V6 keeps remote rates sane, verifies every action, and labels the few
      client-only features honestly instead of claiming a full AC bypass.
]]

if not game:IsLoaded() then
    local waited = 0
    while not game:IsLoaded() and waited < 20 do
        task.wait(0.25)
        waited = waited + 0.25
    end
end

local VERSION = "6.0"
local Env = (getgenv and getgenv()) or _G
if Env.VortexV6 and Env.VortexV6.Unload then
    pcall(Env.VortexV6.Unload)
end

local cloneref = cloneref or function(o) return o end
local Players       = cloneref(game:GetService("Players"))
local Replicated    = cloneref(game:GetService("ReplicatedStorage"))
local RunService    = cloneref(game:GetService("RunService"))
local UserInput     = cloneref(game:GetService("UserInputService"))
local TweenService  = cloneref(game:GetService("TweenService"))
local Lighting      = cloneref(game:GetService("Lighting"))
local Teleport      = cloneref(game:GetService("TeleportService"))
local VirtualUser   = cloneref(game:GetService("VirtualUser"))
local GuiService    = cloneref(game:GetService("GuiService"))

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
    error("[Vortex] Join Prison Life, then execute the script.", 0)
end

local PlayerGui = LP:FindFirstChild("PlayerGui") or LP:WaitForChild("PlayerGui", 10)
if not PlayerGui then
    error("[Vortex] PlayerGui is not available yet. Rejoin and execute again.", 0)
end

local function currentCamera()
    return workspace.CurrentCamera
end

local function currentMouse()
    local ok, mouse = pcall(function() return LP:GetMouse() end)
    if ok then return mouse end
    return nil
end

-- ============================================================
--  CONFIG
-- ============================================================

local CONFIG = {
    -- combat
    killAura        = true,
    killRange       = 22,
    killRate        = 0.42,
    killMode        = "Auto",        -- "Auto" | "Melee" | "Gun"
    meleeHits       = 3,
    teamCheck       = true,
    guardOnlyHostile = true,
    wallCheck       = true,
    pierceShield    = true,
    -- aim
    aimFov          = 165,
    aimSmooth       = 0.35,
    aimPart         = "Head",
    aimbotAutoFire  = false,
    silentFov       = 999,
    silentChance    = 100,
    silentWall      = true,
    showAimFov      = true,
    -- hitbox
    hitboxSize      = 8,
    hitboxTransparency = 0.35,
    -- arrest
    arrestRadius    = 16,
    arrestSnap      = true,
    clickKill       = false,
    clickArrest     = false,
    clickTp         = false,
    -- guns
    gunChoice       = "M9",
    gunDamage       = 55,
    gunBullets      = 6,
    gunFireRate     = 0.08,
    gunSpread       = 0,
    gunAutoFire     = true,
    gunSchema       = "Auto",        -- "Auto" | "Legacy" | "2026"
    -- movement
    walkSpeed       = 28,
    jumpPower       = 52,
    speedMode       = "Fixed",       -- "Fixed" | "Zone" | "Manual"
    flySpeed        = 62,
    spinSpeed       = 22,
    -- items
    itemPace        = 3.2,
    -- visuals
    espMax          = 40,
    espNames        = true,
    espHealth       = true,
    espDistance     = true,
    espTeamColor    = true,
    espTeamCheck    = false,
    espTracers      = false,
    espChams        = true,
    fullbright      = false,
    -- system
    updateRate      = 0.20,
    logMax          = 80,
}

local STATE = {
    version      = VERSION,
    toggles      = {},
    switches     = {},
    connections  = {},
    unloaded     = false,
    logLines     = {},
    lastAction   = 0,
    lastHeal     = 0,
    lastArrest   = 0,
    lastTrigger  = 0,
    lastAura     = 0,
    lastVisual   = 0,
    lastItem     = 0,
    itemQueue    = {},
    itemBusy     = false,
    target       = nil,
    fov          = 70,
    orig         = {},
    noclip       = {},
    hitbox       = {},
    barriers     = {},
    furniture    = {},
    esp          = {},
    tracers      = {},
    fly          = { bv = nil, bg = nil, savedPlatform = false },
    invis        = { active = false, saved = {}, key = "VortexV6_Invisible" },
    hooks        = { namecall = nil, oldNamecall = nil, castRay = nil, castRayOld = nil, taze = nil, tazeOld = nil, installed = false },
    teleport     = { active = false, target = nil, from = nil, started = 0, duration = 0 },
    mobile       = {},
    ui           = {},
    statusRefs   = {},
    diag         = {},
    savedTP      = nil,
    remotes      = {},
    remotePoll   = 0,
}

Env.VortexV6 = {
    Version = VERSION,
    State = STATE,
    Config = CONFIG,
}

-- ============================================================
--  SMALL UTILITIES
-- ============================================================

local function now()
    return os.clock()
end

local function round(n)
    return math.floor((tonumber(n) or 0) + 0.5)
end

local function clamp(n, lo, hi)
    n = tonumber(n) or lo
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function pack(...)
    return { n = select("#", ...), ... }
end

local function spread(t)
    local n = t.n or #t
    if table.unpack then return table.unpack(t, 1, n) end
    return unpack(t, 1, n)
end

local function safe(label, fn, ...)
    local args = pack(...)
    local ok, err = pcall(function() return fn(spread(args)) end)
    if not ok then
        if STATE.log then
            STATE.log("[" .. label .. "] " .. tostring(err), true)
        else
            warn("[Vortex] " .. label .. ": " .. tostring(err))
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

local function getChar(plr)
    plr = plr or LP
    return plr and plr.Character
end

local function getHum(plr)
    local ch = getChar(plr)
    return ch and ch:FindFirstChildOfClass("Humanoid")
end

local function getRoot(plr)
    local ch = getChar(plr)
    return ch and (ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart)
end

local function getPivot(plr)
    local root = getRoot(plr)
    if root then return root.Position end
    local ch = getChar(plr)
    if ch then
        local ok, cf = pcall(function() return ch:GetPivot() end)
        if ok and cf then return cf.Position end
    end
    return Vector3.new(0, 0, 0)
end

local function teamName(plr)
    if not plr then return "" end
    local ok, team = pcall(function() return plr.Team end)
    if ok and team then return tostring(team.Name) end
    local ok2, color = pcall(function() return plr.TeamColor end)
    if ok2 and color then return tostring(color.Name) end
    return ""
end

local function isNeutral(plr)
    local ok, neutral = pcall(function() return plr.Neutral end)
    return ok and neutral == true
end

local function isAlive(plr)
    local hum = getHum(plr)
    local root = getRoot(plr)
    return hum ~= nil and root ~= nil and hum.Health > 0
end

local function hasForceField(plr)
    local ch = getChar(plr)
    return ch ~= nil and ch:FindFirstChildOfClass("ForceField") ~= nil
end

local function log(msg, isErr)
    local line = tostring(msg)
    if #line > 220 then line = line:sub(1, 217) .. "..." end
    if isErr then
        warn("[Vortex] " .. line)
    else
        print("[Vortex] " .. line)
    end
    table.insert(STATE.logLines, { text = line, err = isErr == true, at = now() })
    while #STATE.logLines > CONFIG.logMax do
        table.remove(STATE.logLines, 1)
    end
    if STATE.ui.logLabel then
        local rows = {}
        for i, entry in ipairs(STATE.logLines) do
            table.insert(rows, string.format("%02d %s%s", i,
                entry.err and "[!] " or "    ", entry.text))
        end
        STATE.ui.logLabel.Text = table.concat(rows, "\n")
    end
end
STATE.log = log

-- ============================================================
--  UI THEME / HELPERS
-- ============================================================

local THEME = {
    bg        = Color3.fromRGB(10, 13, 21),
    panel     = Color3.fromRGB(16, 20, 32),
    card      = Color3.fromRGB(22, 27, 42),
    cardOn    = Color3.fromRGB(27, 38, 58),
    line      = Color3.fromRGB(45, 56, 82),
    text      = Color3.fromRGB(235, 241, 252),
    dim       = Color3.fromRGB(150, 164, 194),
    faint     = Color3.fromRGB(104, 119, 148),
    accent    = Color3.fromRGB(0, 222, 255),
    accent2   = Color3.fromRGB(128, 96, 255),
    green     = Color3.fromRGB(0, 210, 150),
    yellow    = Color3.fromRGB(255, 198, 84),
    red       = Color3.fromRGB(255, 92, 108),
    blue      = Color3.fromRGB(88, 166, 255),
    orange    = Color3.fromRGB(255, 146, 74),
}

local function make(class, props, parent)
    local obj = Instance.new(class)
    if props then
        for key, value in pairs(props) do
            pcall(function() obj[key] = value end)
        end
    end
    if parent then
        pcall(function() obj.Parent = parent end)
    end
    return obj
end

local function corner(obj, radius)
    local c = make("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, obj)
    return c
end

local function stroke(obj, color, thickness, transparency)
    local s = make("UIStroke", {
        Color = color or THEME.line,
        Thickness = thickness or 1,
        Transparency = transparency or 0.5,
    }, obj)
    return s
end

local function tween(obj, goal, duration, style, direction)
    if not obj then return nil end
    local info = TweenInfo.new(duration or 0.18, style or Enum.EasingStyle.Quart,
        direction or Enum.EasingDirection.Out)
    local tw = TweenService:Create(obj, info, goal)
    tw:Play()
    return tw
end

local function addPadding(parent, left, right, top, bottom)
    local p = make("UIPadding", {
        PaddingLeft = UDim.new(0, left or 0),
        PaddingRight = UDim.new(0, right or 0),
        PaddingTop = UDim.new(0, top or 0),
        PaddingBottom = UDim.new(0, bottom or 0),
    }, parent)
    return p
end

-- ============================================================
--  GUI SHELL
-- ============================================================

local function parentCandidates()
    local list = {}
    table.insert(list, PlayerGui)
    if gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then table.insert(list, hui) end
    end
    local ok, core = pcall(function() return game:GetService("CoreGui") end)
    if ok and core then table.insert(list, core) end
    return list
end

local screen
for _, parent in ipairs(parentCandidates()) do
    local ok, gui = pcall(function()
        local g = Instance.new("ScreenGui")
        g.Name = "VortexV6_GUI"
        g.ResetOnSpawn = false
        g.IgnoreGuiInset = true
        g.DisplayOrder = 999
        g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        g.Parent = parent
        return g
    end)
    if ok and gui then
        screen = gui
        break
    end
end
if not screen then
    error("[Vortex] Could not create the GUI (PlayerGui/CoreGui are locked).", 0)
end
STATE.ui.screen = screen

local main = make("Frame", {
    Name = "Main",
    BackgroundColor3 = THEME.bg,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Active = true,
}, screen)
corner(main, 14)
stroke(main, THEME.accent, 1.4, 0.55)

local header = make("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 44),
    BackgroundColor3 = THEME.panel,
    BorderSizePixel = 0,
}, main)
corner(header, 14)

local title = make("TextLabel", {
    Text = "VORTEX V6  //  PRISON LIFE",
    Size = UDim2.new(0, 240, 1, 0),
    Position = UDim2.fromOffset(14, 0),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBlack,
    TextSize = 13,
    TextColor3 = THEME.text,
    TextXAlignment = Enum.TextXAlignment.Left,
}, header)

local subtitle = make("TextLabel", {
    Text = "mobile-first rebuild",
    Size = UDim2.new(0, 160, 0, 14),
    Position = UDim2.new(0, 14, 1, -16),
    BackgroundTransparency = 1,
    Font = Enum.Font.Gotham,
    TextSize = 8,
    TextColor3 = THEME.faint,
    TextXAlignment = Enum.TextXAlignment.Left,
}, header)

local headerStatus = make("TextLabel", {
    Text = "BOOT",
    Size = UDim2.new(0, 190, 0, 18),
    Position = UDim2.new(1, -246, 0.5, -9),
    BackgroundTransparency = 1,
    Font = Enum.Font.Code,
    TextSize = 9,
    TextColor3 = THEME.accent,
    TextXAlignment = Enum.TextXAlignment.Right,
}, header)
STATE.ui.headerStatus = headerStatus

local minimize = make("TextButton", {
    Text = "–",
    Size = UDim2.fromOffset(30, 26),
    Position = UDim2.new(1, -38, 0.5, -13),
    BackgroundColor3 = THEME.card,
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    TextColor3 = THEME.dim,
    AutoButtonColor = false,
}, header)
corner(minimize, 7)

-- tabs
local tabBar = make("ScrollingFrame", {
    Name = "Tabs",
    Size = UDim2.new(1, -12, 0, 36),
    Position = UDim2.fromOffset(6, 50),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = THEME.accent,
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.X,
    ScrollingDirection = Enum.ScrollingDirection.X,
}, main)
local tabLayout = make("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 5),
    SortOrder = Enum.SortOrder.LayoutOrder,
    VerticalAlignment = Enum.VerticalAlignment.Center,
}, tabBar)

local pageHost = make("Frame", {
    Name = "Pages",
    Size = UDim2.new(1, -12, 1, -94),
    Position = UDim2.fromOffset(6, 88),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
}, main)

local pages = {}
local activePage = nil
local tabButtons = {}

local function showPage(id)
    for key, page in pairs(pages) do
        page.Visible = (key == id)
        local btn = tabButtons[key]
        if btn then
            if key == id then
                btn.BackgroundColor3 = Color3.fromRGB(31, 44, 68)
                btn.TextColor3 = THEME.text
            else
                btn.BackgroundColor3 = THEME.card
                btn.TextColor3 = THEME.dim
            end
        end
    end
    activePage = id
end

local function newPage(id, label)
    local btn = make("TextButton", {
        Text = label,
        Size = UDim2.fromOffset(84, 28),
        BackgroundColor3 = THEME.card,
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = THEME.dim,
        AutoButtonColor = false,
        LayoutOrder = #tabButtons + 1,
    }, tabBar)
    corner(btn, 7)
    local scroll = make("ScrollingFrame", {
        Name = id,
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = THEME.accent,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false,
    }, pageHost)
    local layout = make("UIListLayout", {
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, scroll)
    addPadding(scroll, 2, 6, 4, 12)
    pages[id] = scroll
    tabButtons[id] = btn
    btn.MouseButton1Click:Connect(function()
        showPage(id)
    end)
    if activePage == id or not activePage then showPage(id) end
    return scroll
end

local function section(page, text)
    local box = make("Frame", {
        Size = UDim2.new(1, -4, 0, 22),
        BackgroundTransparency = 1,
    }, page)
    make("TextLabel", {
        Text = string.upper(text),
        Size = UDim2.new(1, 0, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBlack,
        TextSize = 9,
        TextColor3 = THEME.accent,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, box)
    make("Frame", {
        Size = UDim2.new(1, -116, 0, 1),
        Position = UDim2.new(0, 112, 0.5, 0),
        BackgroundColor3 = THEME.line,
        BorderSizePixel = 0,
        BackgroundTransparency = 0.35,
    }, box)
    return box
end

local function note(page, text, color)
    local label = make("TextLabel", {
        Text = text,
        Size = UDim2.new(1, -4, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextColor3 = color or THEME.faint,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
    }, page)
    return label
end

-- ============================================================
--  TOASTS
-- ============================================================

local toastHolder = make("Frame", {
    Name = "Toasts",
    Size = UDim2.new(0, 270, 1, -24),
    Position = UDim2.new(1, -282, 0, 12),
    BackgroundTransparency = 1,
    ZIndex = 20,
}, screen)
local toastLayout = make("UIListLayout", {
    VerticalAlignment = Enum.VerticalAlignment.Top,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    Padding = UDim.new(0, 7),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, toastHolder)

local function toast(titleText, body, duration, kind)
    if STATE.unloaded then return end
    local card = make("Frame", {
        Size = UDim2.new(0, 260, 0, 54),
        BackgroundColor3 = THEME.panel,
        BorderSizePixel = 0,
        ZIndex = 21,
    }, toastHolder)
    corner(card, 9)
    local color = kind == "err" and THEME.red or (kind == "warn" and THEME.yellow or THEME.green)
    stroke(card, color, 1, 0.15)
    make("TextLabel", {
        Text = titleText,
        Size = UDim2.new(1, -16, 0, 16),
        Position = UDim2.fromOffset(10, 6),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = color,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 22,
    }, card)
    make("TextLabel", {
        Text = body or "",
        Size = UDim2.new(1, -16, 0, 24),
        Position = UDim2.fromOffset(10, 22),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 22,
    }, card)
    task.delay(duration or 3, function()
        if card and card.Parent then
            pcall(function() card:Destroy() end)
        end
    end)
end
STATE.toast = toast

local function flash(text)
    if STATE.ui.flash then
        STATE.ui.flash.Text = text
    end
end

-- ============================================================
--  WIDGETS
-- ============================================================

local function paintSwitch(row, sw, knob, status, on, err)
    if on then
        sw.BackgroundColor3 = THEME.green
        knob.Position = UDim2.new(0, 22, 0.5, -8)
        row.BackgroundColor3 = THEME.cardOn
        if status then
            status.Text = err and "ERROR" or "ACTIVE"
            status.TextColor3 = err and THEME.red or THEME.green
        end
    else
        sw.BackgroundColor3 = Color3.fromRGB(48, 57, 78)
        knob.Position = UDim2.new(0, 4, 0.5, -8)
        row.BackgroundColor3 = THEME.card
        if status then
            status.Text = err and "ERROR" or "OFF"
            status.TextColor3 = err and THEME.red or THEME.faint
        end
    end
end

local function toggleRow(page, id, titleText, desc, default, callback)
    local height = desc and 52 or 42
    local row = make("TextButton", {
        Text = "",
        Size = UDim2.new(1, -4, 0, height),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        ClipsDescendants = true,
    }, page)
    corner(row, 8)
    local rowStroke = stroke(row, THEME.line, 1, 0.55)
    make("TextLabel", {
        Text = titleText,
        Size = UDim2.new(1, -112, 0, 16),
        Position = UDim2.fromOffset(10, desc and 7 or 6),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)
    if desc then
        make("TextLabel", {
            Text = desc,
            Size = UDim2.new(1, -112, 0, 14),
            Position = UDim2.fromOffset(10, 24),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 8,
            TextColor3 = THEME.faint,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
    end
    local status = make("TextLabel", {
        Text = "OFF",
        Size = UDim2.new(0, 42, 0, 10),
        Position = UDim2.new(1, -106, 0, 6),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 8,
        TextColor3 = THEME.faint,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, row)
    local sw = make("Frame", {
        Size = UDim2.fromOffset(42, 22),
        Position = UDim2.new(1, -50, 0.5, -11),
        BackgroundColor3 = Color3.fromRGB(48, 57, 78),
        BorderSizePixel = 0,
    }, row)
    corner(sw, 11)
    local knob = make("Frame", {
        Size = UDim2.fromOffset(16, 16),
        Position = UDim2.new(0, 4, 0.5, -8),
        BackgroundColor3 = Color3.fromRGB(240, 245, 255),
        BorderSizePixel = 0,
    }, sw)
    corner(knob, 8)

    local enabled = default == true
    local busy = false

    local function set(v, silent)
        if STATE.unloaded then return end
        v = v == true
        enabled = v
        STATE.toggles[id] = v
        paintSwitch(row, sw, knob, status, v, false)
        rowStroke.Transparency = v and 0.25 or 0.55
        if not silent then
            flash(titleText .. "  " .. (v and "ON" or "OFF"))
        end
        if callback then
            busy = true
            task.spawn(function()
                local ok, err = pcall(callback, v)
                busy = false
                if not ok then
                    log("toggle " .. id .. ": " .. tostring(err), true)
                    enabled = false
                    STATE.toggles[id] = false
                    paintSwitch(row, sw, knob, status, false, true)
                    toast(titleText, "Failed: " .. tostring(err), 4, "err")
                end
            end)
        end
    end

    row.MouseButton1Click:Connect(function()
        if busy then return end
        set(not enabled)
    end)

    STATE.toggles[id] = enabled
    STATE.switches[id] = { Set = set, Get = function() return enabled end }
    paintSwitch(row, sw, knob, status, enabled, false)
    rowStroke.Transparency = enabled and 0.25 or 0.55
    return { Set = set, Get = function() return enabled end, Row = row }
end

local function buttonRow(page, label, desc, callback, accent)
    local height = desc and 46 or 36
    local row = make("TextButton", {
        Text = "",
        Size = UDim2.new(1, -4, 0, height),
        BackgroundColor3 = accent and Color3.fromRGB(29, 42, 62) or THEME.card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        ClipsDescendants = true,
    }, page)
    corner(row, 8)
    stroke(row, accent and THEME.accent or THEME.line, 1, accent and 0.35 or 0.6)
    make("TextLabel", {
        Text = label,
        Size = UDim2.new(1, -72, 0, 16),
        Position = UDim2.fromOffset(10, desc and 6 or 10),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = accent and THEME.accent or THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)
    if desc then
        make("TextLabel", {
            Text = desc,
            Size = UDim2.new(1, -72, 0, 14),
            Position = UDim2.fromOffset(10, 24),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 8,
            TextColor3 = THEME.faint,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
    end
    make("TextLabel", {
        Text = "RUN",
        Size = UDim2.fromOffset(42, 18),
        Position = UDim2.new(1, -52, 0.5, -9),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 8,
        TextColor3 = accent and THEME.accent or THEME.dim,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, row)
    row.MouseButton1Click:Connect(function()
        flash(label)
        row.BackgroundColor3 = Color3.fromRGB(35, 55, 80)
        task.delay(0.1, function()
            if row and row.Parent then
                row.BackgroundColor3 = accent and Color3.fromRGB(29, 42, 62) or THEME.card
            end
        end)
        task.spawn(function()
            local ok, err = pcall(callback)
            if not ok then
                log("button " .. label .. ": " .. tostring(err), true)
                toast(label, "Failed: " .. tostring(err), 4, "err")
            end
        end)
    end)
    return row
end

local function sliderRow(page, titleText, minV, maxV, default, callback, suffix)
    local box = make("Frame", {
        Size = UDim2.new(1, -4, 0, 48),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
    }, page)
    corner(box, 8)
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
    local track = make("Frame", {
        Size = UDim2.new(1, -20, 0, 8),
        Position = UDim2.fromOffset(10, 29),
        BackgroundColor3 = Color3.fromRGB(40, 49, 70),
        BorderSizePixel = 0,
    }, box)
    corner(track, 4)
    local pct = clamp((default - minV) / math.max(maxV - minV, 1), 0, 1)
    local fill = make("Frame", {
        Size = UDim2.new(pct, 0, 1, 0),
        BackgroundColor3 = THEME.accent,
        BorderSizePixel = 0,
    }, track)
    corner(fill, 4)
    local thumb = make("Frame", {
        Size = UDim2.fromOffset(14, 14),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(pct, 0, 0.5, 0),
        BackgroundColor3 = THEME.text,
        BorderSizePixel = 0,
    }, track)
    corner(thumb, 7)
    local dragging = false

    local function apply(value)
        value = clamp(round(value), minV, maxV)
        local p = (value - minV) / math.max(maxV - minV, 1)
        fill.Size = UDim2.new(p, 0, 1, 0)
        thumb.Position = UDim2.new(p, 0, 0.5, 0)
        label.Text = string.format("%s: %d%s", titleText, value, suffix or "")
        if callback then
            local ok, err = pcall(callback, value)
            if not ok then log("slider " .. titleText .. ": " .. tostring(err), true) end
        end
    end

    local function fromInput(input)
        local x = input.Position.X - track.AbsolutePosition.X
        local width = math.max(track.AbsoluteSize.X, 1)
        apply(minV + (maxV - minV) * clamp(x / width, 0, 1))
    end

    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            fromInput(input)
        end
    end)
    UserInput.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            fromInput(input)
        end
    end)
    UserInput.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    return { Set = apply }
end

local function choiceRow(page, titleText, options, default, callback)
    local index = 1
    for i, option in ipairs(options) do
        if tostring(option) == tostring(default) then index = i break end
    end
    local btn = make("TextButton", {
        Text = titleText .. ": " .. tostring(options[index] or ""),
        Size = UDim2.new(1, -4, 0, 36),
        BackgroundColor3 = THEME.card,
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        AutoButtonColor = false,
    }, page)
    corner(btn, 8)
    stroke(btn, THEME.line, 1, 0.6)
    addPadding(btn, 10, 10, 0, 0)
    local function set(value)
        local found
        for i, option in ipairs(options) do
            if tostring(option) == tostring(value) then found = i break end
        end
        if not found then return end
        index = found
        btn.Text = titleText .. ": " .. tostring(options[index])
        if callback then
            local ok, err = pcall(callback, options[index])
            if not ok then log("choice " .. titleText .. ": " .. tostring(err), true) end
        end
    end
    btn.MouseButton1Click:Connect(function()
        index = (index % #options) + 1
        btn.Text = titleText .. ": " .. tostring(options[index])
        if callback then
            local ok, err = pcall(callback, options[index])
            if not ok then log("choice " .. titleText .. ": " .. tostring(err), true) end
        end
    end)
    return { Set = set, Get = function() return options[index] end }
end

local function statRow(page, label, value)
    local row = make("Frame", {
        Size = UDim2.new(1, -4, 0, 24),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
    }, page)
    corner(row, 7)
    make("TextLabel", {
        Text = label,
        Size = UDim2.new(0.55, -10, 1, 0),
        Position = UDim2.fromOffset(8, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 8,
        TextColor3 = THEME.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)
    local val = make("TextLabel", {
        Text = value or "-",
        Size = UDim2.new(0.45, -10, 1, 0),
        Position = UDim2.new(0.55, 0, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 8,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)
    return val
end

STATE.ui.make = make
STATE.ui.section = section
STATE.ui.note = note
STATE.ui.toggleRow = toggleRow
STATE.ui.buttonRow = buttonRow
STATE.ui.sliderRow = sliderRow
STATE.ui.choiceRow = choiceRow
STATE.ui.statRow = statRow
STATE.ui.toast = toast
STATE.ui.flash = nil

-- ============================================================
--  HEADER / MINIMIZE / DRAG
-- ============================================================

local minimized = false
local function setMinimized(v)
    minimized = v == true
    main.Visible = not minimized
    if STATE.ui.orb then STATE.ui.orb.Visible = minimized end
end

local orb = make("TextButton", {
    Text = "V6",
    Size = UDim2.fromOffset(48, 48),
    Position = UDim2.new(0, 14, 0.5, -24),
    BackgroundColor3 = THEME.panel,
    Font = Enum.Font.GothamBlack,
    TextSize = 15,
    TextColor3 = THEME.accent,
    AutoButtonColor = false,
    Visible = false,
    ZIndex = 30,
}, screen)
corner(orb, 24)
stroke(orb, THEME.accent, 2, 0.2)
STATE.ui.orb = orb
orb.MouseButton1Click:Connect(function() setMinimized(false) end)
minimize.MouseButton1Click:Connect(function() setMinimized(true) end)

local function makeDraggable(handle, target)
    local dragging = false
    local startPos, startInput
    handle.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            startPos = target.Position
            startInput = input.Position
        end
    end)
    UserInput.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - startInput
            target.Position = UDim2.new(startPos.X.Scale,
                startPos.X.Offset + delta.X, startPos.Y.Scale,
                startPos.Y.Offset + delta.Y)
        end
    end)
    UserInput.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end
makeDraggable(header, main)
makeDraggable(orb, orb)

local function layout()
    local cam = currentCamera()
    local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
    local w = clamp(vp.X - 24, 300, 660)
    local h = clamp(vp.Y - 180, 300, 560)
    main.Size = UDim2.fromOffset(w, h)
    main.Position = UDim2.new(0.5, 0, 0.5, -24)
    main.AnchorPoint = Vector2.new(0.5, 0.5)
    subtitle.Visible = w >= 380
    headerStatus.Visible = w >= 430
    toastHolder.Size = UDim2.new(0, math.min(260, vp.X - 24), 1, -24)
    toastHolder.Position = UDim2.new(1, -math.min(272, vp.X - 12), 0, 12)
    if STATE.ui.fov then
        STATE.ui.fov.Position = UDim2.fromOffset(vp.X * 0.5, vp.Y * 0.5)
    end
    if STATE.ui.dock and STATE.ui.dock.Visible then
        STATE.ui.dock.Position = UDim2.new(0.5, -121, 1, -52)
    end
end
layout()

local function bindViewport()
    local cam = currentCamera()
    if cam then
        connect(cam:GetPropertyChangedSignal("ViewportSize"), layout)
    end
end
bindViewport()

-- ============================================================
--  FOV RING
-- ============================================================

local fovScreen
for _, parent in ipairs(parentCandidates()) do
    local ok, gui = pcall(function()
        local g = Instance.new("ScreenGui")
        g.Name = "VortexV6_FOV"
        g.ResetOnSpawn = false
        g.IgnoreGuiInset = true
        g.DisplayOrder = 998
        g.Parent = parent
        return g
    end)
    if ok and gui then fovScreen = gui break end
end
local fovFrame
STATE.ui.fovScreen = fovScreen
if fovScreen then
    fovFrame = make("Frame", {
        Name = "Ring",
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(CONFIG.aimFov * 2, CONFIG.aimFov * 2),
        Visible = false,
    }, fovScreen)
    corner(fovFrame, CONFIG.aimFov)
    local ringStroke = stroke(fovFrame, THEME.accent, 1.4, 0.2)
    STATE.ui.fovStroke = ringStroke
    STATE.ui.fovCorner = fovFrame:FindFirstChildOfClass("UICorner")
end
STATE.ui.fov = fovFrame

-- ============================================================
--  MOBILE DOCK / FLY PAD
-- ============================================================

local dock = make("Frame", {
    Name = "Dock",
    Size = UDim2.fromOffset(242, 38),
    Position = UDim2.new(0.5, -121, 1, -96),
    BackgroundColor3 = THEME.panel,
    BackgroundTransparency = 0.08,
    Visible = false,
    ZIndex = 12,
}, screen)
corner(dock, 10)
stroke(dock, THEME.line, 1, 0.45)
local dockLayout = make("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 5),
    HorizontalAlignment = Enum.HorizontalAlignment.Center,
    VerticalAlignment = Enum.VerticalAlignment.Center,
}, dock)
STATE.ui.dock = dock

local function dockButton(text)
    local b = make("TextButton", {
        Text = text,
        Size = UDim2.fromOffset(44, 28),
        BackgroundColor3 = Color3.fromRGB(28, 35, 52),
        Font = Enum.Font.GothamBold,
        TextSize = 8,
        TextColor3 = THEME.text,
        AutoButtonColor = false,
        ZIndex = 13,
    }, dock)
    corner(b, 7)
    return b
end
STATE.mobile.punch = dockButton("PUNCH")
STATE.mobile.aim = dockButton("AIM")
STATE.mobile.invis = dockButton("INVIS")
STATE.mobile.fly = dockButton("FLY")

local flyPad = make("Frame", {
    Name = "FlyPad",
    Size = UDim2.fromOffset(112, 148),
    Position = UDim2.new(1, -124, 0.5, -74),
    BackgroundColor3 = THEME.panel,
    BackgroundTransparency = 0.1,
    Visible = false,
    ZIndex = 14,
}, screen)
corner(flyPad, 12)
stroke(flyPad, THEME.accent, 1, 0.45)
make("TextLabel", {
    Text = "FLY",
    Size = UDim2.new(1, 0, 0, 18),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBlack,
    TextSize = 8,
    TextColor3 = THEME.accent,
}, flyPad)
STATE.ui.flyPad = flyPad

local function flyButton(text, x, y, w, h)
    local b = make("TextButton", {
        Text = text,
        Size = UDim2.fromOffset(w, h),
        Position = UDim2.fromOffset(x, y),
        BackgroundColor3 = Color3.fromRGB(28, 35, 52),
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = THEME.text,
        AutoButtonColor = false,
        ZIndex = 15,
    }, flyPad)
    corner(b, 7)
    return b
end
STATE.mobile.up = flyButton("^", 38, 20, 36, 30)
STATE.mobile.left = flyButton("<", 4, 54, 36, 30)
STATE.mobile.fwd = flyButton("W", 38, 54, 36, 30)
STATE.mobile.right = flyButton(">", 72, 54, 36, 30)
STATE.mobile.back = flyButton("S", 38, 88, 36, 30)
STATE.mobile.down = flyButton("v", 38, 122, 36, 24)

showPage("combat")
layout()
-- ============================================================
--  REMOTES
-- ============================================================

local function firstChild(container, names)
    if not container then return nil end
    for _, name in ipairs(names) do
        local found = container:FindFirstChild(name)
        if found then return found end
    end
    return nil
end

local function resolveRemotes()
    local R = STATE.remotes
    local wsRemote = workspace:FindFirstChild("Remote")
    local rsRemotes = Replicated:FindFirstChild("Remotes")
    local gunRemotes = Replicated:FindFirstChild("GunRemotes")

    R.item = firstChild(wsRemote, { "ItemHandler", "InteractWithItem" })
        or firstChild(rsRemotes, { "ItemHandler", "InteractWithItem" })
    R.melee = Replicated:FindFirstChild("meleeEvent")
        or Replicated:FindFirstChild("MeleeEvent")
        or firstChild(rsRemotes, { "meleeEvent", "MeleeEvent" })
    R.shoot = firstChild(gunRemotes, { "ShootEvent", "Shoot" })
        or Replicated:FindFirstChild("ShootEvent")
        or firstChild(rsRemotes, { "ShootEvent" })
    R.shootFolder = R.shoot and R.shoot.Parent and R.shoot.Parent.Name or ""
    R.reload = firstChild(gunRemotes, { "FuncReload", "ReloadEvent", "Reload" })
        or Replicated:FindFirstChild("ReloadEvent")
    R.tased = firstChild(gunRemotes, { "PlayerTased" })
        or Replicated:FindFirstChild("PlayerTased")
    R.arrest = firstChild(wsRemote, { "arrest", "Arrest", "ArrestPlayer" })
        or firstChild(rsRemotes, { "ArrestPlayer", "Arrest" })
    R.team = firstChild(wsRemote, { "TeamEvent", "Team" })
        or Replicated:FindFirstChild("TeamEvent")
    R.loadchar = firstChild(wsRemote, { "loadchar", "LoadChar" })
    R.gate = firstChild(wsRemote, { "Gate", "GateEvent", "OpenGate" })
    R.count = 0
    for _, key in ipairs({ "item", "melee", "shoot", "arrest", "team", "loadchar", "gate" }) do
        if R[key] then R.count = R.count + 1 end
    end
    return R
end
resolveRemotes()

local function remoteStatus()
    local R = STATE.remotes
    return string.format("item:%s melee:%s shoot:%s arrest:%s",
        R.item and "Y" or "-", R.melee and "Y" or "-",
        R.shoot and "Y" or "-", R.arrest and "Y" or "-")
end

-- ============================================================
--  TEAM / TARGET VALIDATION
-- ============================================================

local function teamKind(plr)
    local name = string.lower(teamName(plr))
    if name:find("guard", 1, true) or name:find("bright blue", 1, true) then return "guard" end
    if name:find("inmate", 1, true) or name:find("bright orange", 1, true) then return "inmate" end
    if name:find("criminal", 1, true) or name:find("bright red", 1, true) then return "criminal" end
    return "none"
end

local function isArmedHostile(plr)
    local ch = getChar(plr)
    if not ch then return false end
    if ch:GetAttribute("Hostile") == true or ch:GetAttribute("Trespassing") == true then
        return true
    end
    local hostile = ch:FindFirstChild("Hostile")
    if hostile and hostile:IsA("BoolValue") and hostile.Value then return true end
    local tool = ch:FindFirstChildOfClass("Tool")
    if tool then
        local name = string.lower(tool.Name)
        if name:find("knife", 1, true) or name:find("hammer", 1, true)
            or name:find("gun", 1, true) or name:find("m9", 1, true)
            or name:find("ak", 1, true) or name:find("m4", 1, true)
            or name:find("mp5", 1, true) or name:find("fal", 1, true)
            or name:find("remington", 1, true) or name:find("m700", 1, true)
            or name:find("revolver", 1, true) then
            return true
        end
        if tool:FindFirstChild("GunStates") or tool:FindFirstChild("Muzzle", true) then return true end
    end
    return false
end

local function isEnemy(plr)
    if not plr or plr == LP then return false end
    if isNeutral(plr) or isNeutral(LP) then return false end
    local mine, theirs = teamKind(LP), teamKind(plr)
    if mine == "none" or theirs == "none" then return false end
    if not CONFIG.teamCheck then return true end
    if mine == theirs then return false end
    if (mine == "inmate" or mine == "criminal")
        and (theirs == "inmate" or theirs == "criminal") then
        return false
    end
    if mine == "guard" and theirs == "inmate" and CONFIG.guardOnlyHostile then
        return isArmedHostile(plr)
    end
    return true
end

local function isCuffed(plr)
    local ch = getChar(plr)
    if not ch then return false end
    if ch:GetAttribute("Arrested") == true then return true end
    local head = ch:FindFirstChild("Head")
    if head and head:FindFirstChild("handcuffedGui") then return true end
    for _, d in ipairs(ch:GetDescendants()) do
        if d.Name == "handcuffedGui" then return true end
    end
    return false
end

local function hasLineOfSight(targetPart, origin)
    if not targetPart then return false end
    local cam = currentCamera()
    local from = origin or (cam and cam.CFrame.Position)
    if not from then return false end
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local char = getChar()
    local list = {}
    if char then table.insert(list, char) end
    if cam then table.insert(list, cam) end
    params.FilterDescendantsInstances = list
    local result = workspace:Raycast(from, targetPart.Position - from, params)
    if result and result.Instance then
        return result.Instance:IsDescendantOf(targetPart.Parent)
    end
    return true
end

local function isVisible(targetPart, origin)
    if not CONFIG.wallCheck then return true end
    return hasLineOfSight(targetPart, origin)
end

local function targetPartFor(plr)
    local ch = getChar(plr)
    if not ch then return nil end
    local part
    if CONFIG.aimPart == "Random" then
        part = (math.random(1, 100) <= 62 and ch:FindFirstChild("Head"))
            or ch:FindFirstChild("HumanoidRootPart")
    else
        part = ch:FindFirstChild(CONFIG.aimPart) or ch:FindFirstChild("Head")
            or ch:FindFirstChild("HumanoidRootPart")
    end
    return part
end

local function getTarget(pixelRadius, mode)
    local cam = currentCamera()
    if not cam then return nil end
    local viewport = cam.ViewportSize
    local center
    if UserInput.TouchEnabled and not UserInput.MouseEnabled then
        center = Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
    else
        local ok, mousePos = pcall(function() return UserInput:GetMouseLocation() end)
        center = (ok and mousePos) or Vector2.new(viewport.X * 0.5, viewport.Y * 0.5)
    end
    local radius = pixelRadius or CONFIG.aimFov
    local best, bestDist = nil, radius
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and isEnemy(plr) and isAlive(plr) and not hasForceField(plr) then
            local part = targetPartFor(plr)
            local visible = true
            if mode == "silent" then
                visible = (not CONFIG.silentWall) or hasLineOfSight(part)
            else
                visible = isVisible(part)
            end
            if part and visible then
                local world, onScreen = cam:WorldToViewportPoint(part.Position)
                if onScreen and world.Z > 0 then
                    local screen = Vector2.new(world.X, world.Y)
                    local dist = (screen - center).Magnitude
                    if dist < bestDist then
                        best, bestDist = part, dist
                    end
                end
            end
        end
    end
    return best, bestDist
end

local function getNearestEnemy(maxDistance)
    local myPos = getPivot()
    local best, bestDist = nil, maxDistance or CONFIG.killRange
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and isEnemy(plr) and isAlive(plr) and not hasForceField(plr) then
            local root = getRoot(plr)
            if root then
                local d = (root.Position - myPos).Magnitude
                if d < bestDist then best, bestDist = plr, d end
            end
        end
    end
    return best, bestDist
end

-- ============================================================
--  LIGHTING / FOV / FPS
-- ============================================================

local function saveLighting()
    if STATE.orig.lighting then return end
    STATE.orig.lighting = {
        Brightness = Lighting.Brightness,
        Ambient = Lighting.Ambient,
        OutdoorAmbient = Lighting.OutdoorAmbient,
        FogEnd = Lighting.FogEnd,
        FogStart = Lighting.FogStart,
        ClockTime = Lighting.ClockTime,
        GlobalShadows = Lighting.GlobalShadows,
    }
end

local function restoreLighting()
    local s = STATE.orig.lighting
    if not s then return end
    pcall(function()
        Lighting.Brightness = s.Brightness
        Lighting.Ambient = s.Ambient
        Lighting.OutdoorAmbient = s.OutdoorAmbient
        Lighting.FogEnd = s.FogEnd
        Lighting.FogStart = s.FogStart
        Lighting.ClockTime = s.ClockTime
        Lighting.GlobalShadows = s.GlobalShadows
    end)
end

local function setFullbright(on)
    if on then
        saveLighting()
        Lighting.Brightness = 3
        Lighting.Ambient = Color3.fromRGB(175, 175, 175)
        Lighting.OutdoorAmbient = Color3.fromRGB(155, 155, 155)
        Lighting.FogEnd = 100000
        Lighting.FogStart = 0
        Lighting.ClockTime = 14
        Lighting.GlobalShadows = false
    else
        restoreLighting()
    end
end

local function setFov(value)
    local cam = currentCamera()
    if cam then cam.FieldOfView = clamp(value, 40, 120) end
end

local fpsSaved = {}
local function setFpsBoost(on)
    if on then
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke")
                or d:IsA("Fire") or d:IsA("Beam") or d:IsA("Sparkles") then
                if fpsSaved[d] == nil then fpsSaved[d] = d.Enabled end
                pcall(function() d.Enabled = false end)
            end
        end
    else
        for d, enabled in pairs(fpsSaved) do
            if d and d.Parent then pcall(function() d.Enabled = enabled end) end
        end
        fpsSaved = {}
    end
end

-- ============================================================
--  MOVEMENT
-- ============================================================

local function saveMovementDefaults()
    local hum = getHum()
    if hum and not STATE.orig.walkSpeed then
        STATE.orig.walkSpeed = hum.WalkSpeed
        STATE.orig.jumpPower = hum.JumpPower
    end
end

local function zoneSpeed(pos)
    local x, z = pos.X, pos.Z
    local inside = math.abs(x - 773.62) <= 300 and math.abs(z - 2327.43) <= 290
    if not inside then return 64 end
    if pos.Y < 118 then return 31 end
    return 44
end

local walkApplied = false
local jumpApplied = false
local function updateSpeed()
    local hum = getHum()
    if not hum or hum.Health <= 0 then return end
    if STATE.toggles.speedOn then
        local mode = CONFIG.speedMode
        if mode == "Zone" then
            hum.WalkSpeed = zoneSpeed(getPivot())
        else
            hum.WalkSpeed = math.max(CONFIG.walkSpeed, 16)
        end
        walkApplied = true
    elseif walkApplied then
        hum.WalkSpeed = STATE.orig.walkSpeed or 16
        walkApplied = false
    end
    if STATE.toggles.jumpOn then
        hum.JumpPower = CONFIG.jumpPower
        jumpApplied = true
    elseif jumpApplied then
        hum.JumpPower = STATE.orig.jumpPower or 50
        jumpApplied = false
    end
    if STATE.toggles.autoJumpOn then
        local ok, state = pcall(function() return hum:GetState() end)
        if ok and state == Enum.HumanoidStateType.Landed then
            hum.Jump = true
        end
    end
end

local function setNoclip(on)
    local ch = getChar()
    if not ch then return false end
    if on then
        for _, part in ipairs(ch:GetDescendants()) do
            if part:IsA("BasePart") then
                if STATE.noclip[part] == nil then
                    STATE.noclip[part] = part.CanCollide
                end
                if part.CanCollide then
                    pcall(function() part.CanCollide = false end)
                end
            end
        end
    else
        for part, value in pairs(STATE.noclip) do
            if part and part.Parent then
                pcall(function() part.CanCollide = value end)
            end
        end
        STATE.noclip = {}
    end
    return true
end

local function stopFly()
    local f = STATE.fly
    if f.bv then pcall(function() f.bv:Destroy() end) f.bv = nil end
    if f.bg then pcall(function() f.bg:Destroy() end) f.bg = nil end
    local hum = getHum()
    if hum and f.savedPlatform ~= nil then
        pcall(function() hum.PlatformStand = f.savedPlatform end)
    end
    f.savedPlatform = nil
    if STATE.ui.flyPad then STATE.ui.flyPad.Visible = false end
    for _, name in ipairs({ "up", "down", "left", "right", "fwd", "back" }) do
        if STATE.mobile[name] then STATE.mobile[name].BackgroundColor3 = Color3.fromRGB(28, 35, 52) end
    end
    STATE.flyInput = nil
end

local function startFly()
    local hum, root = getHum(), getRoot()
    if not (hum and root) then return false end
    stopFly()
    local bv = Instance.new("BodyVelocity")
    bv.Name = "VortexV6_Fly"
    bv.MaxForce = Vector3.new(100000, 100000, 100000)
    bv.Velocity = Vector3.new(0, 0, 0)
    bv.P = 1250
    bv.Parent = root
    local bg = Instance.new("BodyGyro")
    bg.Name = "VortexV6_Gyro"
    bg.MaxTorque = Vector3.new(100000, 100000, 100000)
    bg.P = 3000
    bg.D = 300
    bg.CFrame = root.CFrame
    bg.Parent = root
    STATE.fly.bv, STATE.fly.bg = bv, bg
    STATE.fly.savedPlatform = hum.PlatformStand
    hum.PlatformStand = true
    if STATE.ui.flyPad and UserInput.TouchEnabled then
        STATE.ui.flyPad.Visible = true
    end
    return true
end

local function updateFly()
    if not STATE.toggles.flyOn then return end
    local f = STATE.fly
    local hum, root = getHum(), getRoot()
    if not (f.bv and f.bg and hum and root) then
        if now() - (STATE.flyRetry or 0) > 1 then
            STATE.flyRetry = now()
            startFly()
        end
        return
    end
    local cam = currentCamera()
    if not cam then return end
    local input = STATE.flyInput or {}
    local fwd = (UserInput:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
        - (UserInput:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
        + (input.fwd or 0) - (input.back or 0)
    local side = (UserInput:IsKeyDown(Enum.KeyCode.D) and 1 or 0)
        - (UserInput:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
        + (input.right or 0) - (input.left or 0)
    local vert = (UserInput:IsKeyDown(Enum.KeyCode.Space) and 1 or 0)
        - ((UserInput:IsKeyDown(Enum.KeyCode.LeftControl)
            or UserInput:IsKeyDown(Enum.KeyCode.LeftShift)) and 1 or 0)
        + (input.up or 0) - (input.down or 0)
    local dir = cam.CFrame.LookVector * fwd
        + cam.CFrame.RightVector * side
        + Vector3.new(0, 1, 0) * vert
    if dir.Magnitude > 0 then dir = dir.Unit end
    pcall(function()
        f.bv.Velocity = dir * CONFIG.flySpeed
        f.bg.CFrame = cam.CFrame
        hum.PlatformStand = true
    end)
end

local function setInvisible(on)
    local ch = getChar()
    if not ch then return false end
    local inv = STATE.invis
    if on == inv.active then
        return true
    end

    if on then
        inv.saved = {}
        inv.active = true
        for _, part in ipairs(ch:GetDescendants()) do
            if part:IsA("BasePart") then
                inv.saved[part] = part.Transparency
                pcall(function() part.Transparency = 1 end)
            end
        end
        log("local ghost ON (visual only; the server still sees your character)")
    else
        inv.active = false
        for part, transparency in pairs(inv.saved) do
            if part and part.Parent then
                pcall(function() part.Transparency = transparency end)
            end
        end
        inv.saved = {}
        log("local ghost OFF")
    end
    return true
end

-- Re-applies the local ghost after a respawn or a late accessory load. Purely
-- visual: no CFrame tricks, no PlatformStand, nothing the server can ban for.
local function updateInvisible()
    local inv = STATE.invis
    if not inv.active then return end
    local ch = getChar()
    if not ch then return end
    for _, part in ipairs(ch:GetDescendants()) do
        if part:IsA("BasePart") then
            if inv.saved[part] == nil then
                inv.saved[part] = part.Transparency
            end
            if part.Transparency < 1 then
                pcall(function() part.Transparency = 1 end)
            end
        end
    end
end

-- Local stun recovery. The server can re-apply the tase at any time, so this
-- is a convenience, not a bypass.
local function updateAntiTaze()
    if not STATE.toggles.antiTazeOn then return end
    local hum = getHum()
    if not hum or hum.Health <= 0 then return end
    if hum.PlatformStand then
        pcall(function() hum.PlatformStand = false end)
    end
    if hum.Sit and not hum.SeatPart then
        pcall(function() hum.Sit = false end)
    end
    local ch = getChar()
    if ch and ch:GetAttribute("Tased") == true then
        pcall(function() ch:SetAttribute("Tased", false) end)
    end
end

local function applyHitbox()
    local on = STATE.toggles.hitboxOn == true
    if on then
        local ch = getChar()
        if not ch then return end
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP and isEnemy(plr) and isAlive(plr) then
                local tch = getChar(plr)
                if tch then
                    for _, name in ipairs({ "Head", "HumanoidRootPart" }) do
                        local part = tch:FindFirstChild(name)
                        if part and part:IsA("BasePart") then
                            if STATE.hitbox[part] == nil then
                                STATE.hitbox[part] = {
                                    Size = part.Size,
                                    Transparency = part.Transparency,
                                    CanCollide = part.CanCollide,
                                    Massless = part.Massless,
                                }
                            end
                            pcall(function()
                                part.Size = Vector3.new(CONFIG.hitboxSize, CONFIG.hitboxSize, CONFIG.hitboxSize)
                                part.Transparency = CONFIG.hitboxTransparency
                                part.CanCollide = false
                                part.Massless = true
                            end)
                        end
                    end
                end
            end
        end
    else
        for part, saved in pairs(STATE.hitbox) do
            if part and part.Parent then
                pcall(function()
                    part.Size = saved.Size
                    part.Transparency = saved.Transparency
                    part.CanCollide = saved.CanCollide
                    part.Massless = saved.Massless
                end)
            end
        end
        STATE.hitbox = {}
    end
end

local function barrierContainers()
    local out = {}
    for _, name in ipairs({ "Doors", "Prison_Fences", "Prison Fences", "Fences" }) do
        local found = workspace:FindFirstChild(name)
        if found then table.insert(out, found) end
    end
    return out
end

local function setWorldBarriers(on)
    if on then
        local found = false
        for _, container in ipairs(barrierContainers()) do
            for _, part in ipairs(container:GetDescendants()) do
                if part:IsA("BasePart") then
                    found = true
                    if STATE.barriers[part] == nil then
                        STATE.barriers[part] = part.CanCollide
                    end
                    pcall(function() part.CanCollide = false end)
                end
            end
        end
        if found then
            log("local doors/fences opened (client CanCollide only)")
        else
            log("no door/fence container found on this map", true)
        end
        return found
    else
        local restored = 0
        for part, value in pairs(STATE.barriers) do
            if part and part.Parent then
                pcall(function() part.CanCollide = value end)
                restored = restored + 1
            end
        end
        STATE.barriers = {}
        log("local doors/fences restored (" .. restored .. " parts)")
        return true
    end
end

-- ============================================================
--  TELEPORT GLIDE (non-yielding)
-- ============================================================

local function startTeleport(cf)
    if not cf then return false end
    local root = getRoot()
    if not root then return false end
    local from = root.CFrame
    local dist = (cf.Position - from.Position).Magnitude
    STATE.teleport.active = true
    STATE.teleport.from = from
    STATE.teleport.target = cf
    STATE.teleport.started = now()
    STATE.teleport.duration = clamp(dist / 380, 0.08, 0.55)
    return true
end

local function updateTeleport()
    local t = STATE.teleport
    if not t.active then return end
    local root = getRoot()
    if not root then t.active = false return end
    local alpha = clamp((now() - t.started) / math.max(t.duration, 0.01), 0, 1)
    local eased = 1 - (1 - alpha) * (1 - alpha)
    local cf = t.from:Lerp(t.target, eased)
    pcall(function()
        root.CFrame = cf
        root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
    end)
    if alpha >= 1 then t.active = false end
end

local function teleportTo(cf, label)
    if startTeleport(cf) then
        if label then toast("Teleport", label, 1.6, "ok") end
        return true
    end
    toast("Teleport", "Character not ready", 2, "warn")
    return false
end

-- ============================================================
--  ESP
-- ============================================================

local espScreen = make("ScreenGui", {
    Name = "VortexV6_ESP",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 997,
}, PlayerGui)

local function clearEspUnit(plr)
    local unit = STATE.esp[plr]
    if not unit then return end
    if unit.bb then pcall(function() unit.bb:Destroy() end) end
    if unit.hl then pcall(function() unit.hl:Destroy() end) end
    STATE.esp[plr] = nil
end

local function clearEsp()
    for plr in pairs(STATE.esp) do clearEspUnit(plr) end
    STATE.esp = {}
    STATE.espCount = 0
end

local function teamColor(plr)
    local kind = teamKind(plr)
    if kind == "guard" then return THEME.blue end
    if kind == "inmate" then return THEME.orange end
    if kind == "criminal" then return THEME.red end
    return Color3.fromRGB(220, 225, 235)
end

local function updateEsp()
    local on = STATE.toggles.espOn == true
    if not on then
        if next(STATE.esp) then clearEsp() end
        return
    end
    local cam = currentCamera()
    local myPos = getPivot()
    local seen = {}
    local count = 0
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and isAlive(plr) then
            local show = not CONFIG.espTeamCheck or isEnemy(plr)
            if show then
                local ch, root, hum = getChar(plr), getRoot(plr), getHum(plr)
                if ch and root and hum then
                    local color = CONFIG.espTeamColor and teamColor(plr) or THEME.text
                    local unit = STATE.esp[plr]
                    if not unit then
                        local bb = make("BillboardGui", {
                            Name = "VortexV6_ESP",
                            Size = UDim2.fromOffset(190, 30),
                            StudsOffset = Vector3.new(0, 3.1, 0),
                            AlwaysOnTop = true,
                            MaxDistance = 500,
                            LightInfluence = 0,
                            Adornee = root,
                            Parent = espScreen,
                        })
                        local label = make("TextLabel", {
                            Text = plr.Name,
                            Size = UDim2.new(1, 0, 0, 16),
                            BackgroundTransparency = 1,
                            Font = Enum.Font.GothamBold,
                            TextSize = 10,
                            TextColor3 = color,
                            TextStrokeColor3 = Color3.new(0, 0, 0),
                            TextStrokeTransparency = 0.25,
                            TextXAlignment = Enum.TextXAlignment.Center,
                        }, bb)
                        local barBg = make("Frame", {
                            Size = UDim2.new(0.7, 0, 0, 3),
                            Position = UDim2.new(0.15, 0, 1, -3),
                            BackgroundColor3 = Color3.fromRGB(18, 20, 28),
                            BorderSizePixel = 0,
                        }, bb)
                        local bar = make("Frame", {
                            Size = UDim2.new(1, 0, 1, 0),
                            BackgroundColor3 = color,
                            BorderSizePixel = 0,
                        }, barBg)
                        local hl = make("Highlight", {
                            Name = "VortexV6_ESP",
                            FillColor = color,
                            FillTransparency = 0.68,
                            OutlineColor = color,
                            OutlineTransparency = 0.1,
                            DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
                            Adornee = ch,
                            Parent = ch,
                        })
                        unit = { bb = bb, label = label, bar = bar, hl = hl, root = root, char = ch }
                        STATE.esp[plr] = unit
                    end
                    if unit.root ~= root then
                        unit.root = root
                        unit.bb.Adornee = root
                    end
                    if unit.char ~= ch then
                        unit.char = ch
                        unit.hl.Adornee = ch
                    end
                    local dist = cam and (root.Position - cam.CFrame.Position).Magnitude or (root.Position - myPos).Magnitude
                    local parts = {}
                    if CONFIG.espNames then table.insert(parts, plr.Name) end
                    if CONFIG.espHealth then
                        table.insert(parts, tostring(math.max(0, round(hum.Health))) .. "hp")
                    end
                    if CONFIG.espDistance then table.insert(parts, tostring(round(dist)) .. "m") end
                    unit.label.Text = table.concat(parts, "  |  ")
                    unit.label.TextColor3 = color
                    unit.bar.Size = UDim2.new(clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1), 0, 1, 0)
                    unit.bar.BackgroundColor3 = color
                    unit.hl.FillColor = color
                    unit.hl.OutlineColor = color
                    unit.hl.Enabled = CONFIG.espChams ~= false
                    seen[plr] = true
                    count = count + 1
                    if count >= CONFIG.espMax then break end
                end
            end
        end
    end
    for plr in pairs(STATE.esp) do
        if not seen[plr] then clearEspUnit(plr) end
    end
    STATE.espCount = count
end

local function updateTracers()
    if not STATE.toggles.tracersOn then
        for _, line in pairs(STATE.tracers) do pcall(function() line:Remove() end) end
        STATE.tracers = {}
        return
    end
    if not Drawing then
        if not STATE.drawingWarned then
            STATE.drawingWarned = true
            log("tracers need the executor Drawing API", true)
        end
        return
    end
    local cam = currentCamera()
    if not cam then return end
    local from = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
    local seen = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and isAlive(plr) and (not CONFIG.espTeamCheck or isEnemy(plr)) then
            local root = getRoot(plr)
            if root then
                local line = STATE.tracers[plr]
                if not line then
                    local ok, obj = pcall(function() return Drawing.new("Line") end)
                    if ok and obj then
                        obj.Thickness = 1.5
                        obj.Transparency = 0.4
                        STATE.tracers[plr] = obj
                        line = obj
                    end
                end
                if line then
                    local screen, onScreen = cam:WorldToViewportPoint(root.Position)
                    line.From = from
                    line.Color = teamColor(plr)
                    line.Visible = onScreen and screen.Z > 0
                    if line.Visible then line.To = Vector2.new(screen.X, screen.Y) end
                    seen[plr] = true
                end
            end
        end
    end
    for plr, line in pairs(STATE.tracers) do
        if not seen[plr] then
            line.Visible = false
        end
    end
end

-- ============================================================
--  GUNS
-- ============================================================

local WeaponFireRate = {
    ["ak-47"] = 0.085, ["m4a1"] = 0.075, ["mp5"] = 0.075,
    ["fal"] = 0.085, ["m9"] = 0.11, ["revolver"] = 0.22,
    ["remington 870"] = 0.72, ["m700"] = 1.05,
}
local function legalCooldown(tool)
    if not tool then return 0.12 end
    return WeaponFireRate[string.lower(tool.Name)] or 0.10
end

local function isFirearm(tool)
    if not tool or not tool:IsA("Tool") then return false end
    local name = string.lower(tool.Name)
    if name == "key card" or name == "crude knife" or name == "hammer"
        or name == "handcuffs" or name == "taser" or name == "riot shield"
        or name == "extinguisher" or name == "breakfast" or name == "dinner"
        or name == "lunch" then
        return false
    end
    return tool:FindFirstChild("GunStates") ~= nil
        or tool:FindFirstChild("Muzzle", true) ~= nil
        or tool:GetAttribute("CurrentAmmo") ~= nil
        or tool:GetAttribute("Local_CurrentAmmo") ~= nil
end

local function findTool(name)
    local containers = { getChar(), LP:FindFirstChild("Backpack") }
    if name then
        for _, c in ipairs(containers) do
            if c then
                local t = c:FindFirstChild(name)
                if t and t:IsA("Tool") then return t end
            end
        end
    end
    for _, c in ipairs(containers) do
        if c then
            for _, t in ipairs(c:GetChildren()) do
                if t:IsA("Tool") and isFirearm(t) then return t end
            end
        end
    end
    return nil
end

local function modGun(tool)
    if not isFirearm(tool) then return false end
    local minRate = legalCooldown(tool)
    local ok = pcall(function()
        local gs = tool:FindFirstChild("GunStates")
        if gs and gs:IsA("ModuleScript") then
            local stats = require(gs)
            if type(stats) == "table" then
                stats.Damage = math.max(tonumber(stats.Damage) or 0, CONFIG.gunDamage)
                stats.Bullets = math.max(tonumber(stats.Bullets) or 0, CONFIG.gunBullets)
                stats.FireRate = math.max(minRate, math.min(tonumber(stats.FireRate) or minRate, CONFIG.gunFireRate))
                stats.Spread = math.min(tonumber(stats.Spread) or 0, CONFIG.gunSpread)
                stats.AutoFire = CONFIG.gunAutoFire
                if stats.ReloadTime and stats.ReloadTime > 0.1 then stats.ReloadTime = 0.1 end
                if stats.MaxAmmo then stats.CurrentAmmo = stats.MaxAmmo end
            end
        end
        for attr, value in pairs(tool:GetAttributes()) do
            local lower = string.lower(attr)
            if type(value) == "number" and (lower:find("spread") or lower:find("recoil")) then
                tool:SetAttribute(attr, 0)
            elseif type(value) == "number" and (lower:find("firerate") or lower:find("cooldown")) then
                tool:SetAttribute(attr, math.max(minRate, value))
            end
        end
    end)
    if not ok then
        log("gun mod failed on " .. tool.Name .. " (GunStates locked?)", true)
    end
    return ok
end

local function buildBullets(targetPart, count)
    local bullets = {}
    for i = 1, count or 1 do
        bullets[i] = {
            -- Mirrors the payload that Prison Life's server actually reads.
            -- Damage is applied from Cframe/HitPart; the RayObject only needs
            -- to be a valid Ray so the server's type checks pass.
            RayObject = Ray.new(Vector3.new(0, 0, 0), Vector3.new(0.1, 0.1, 0.1)),
            Distance = 25,
            Cframe = targetPart.CFrame or CFrame.new(targetPart.Position),
            Color = Color3.fromRGB(255, 210, 80),
            HitPart = targetPart,
            Hit = targetPart,
            Visualize = false,
        }
    end
    return bullets
end

local function fireShoot(targetPart, tool)
    local R = STATE.remotes
    if not (R.shoot and targetPart and tool) then return false, "missing remote/tool" end
    if not (tool:IsA("Tool") and tool:FindFirstChild("GunStates")) then
        return false, "tool has no GunStates"
    end
    local schema = CONFIG.gunSchema
    if schema == "Auto" then
        schema = (R.shootFolder == "GunRemotes") and "2026" or "Legacy"
    end
    local ok, err
    if schema == "2026" then
        local origin = getPivot()
        ok, err = pcall(function()
            R.shoot:FireServer({ { origin, targetPart.Position, targetPart } }, tool)
        end)
    else
        local bullets = buildBullets(targetPart, math.max(1, CONFIG.gunBullets))
        ok, err = pcall(function()
            R.shoot:FireServer(bullets, tool)
        end)
    end
    if not ok then
        log("shoot remote rejected: " .. tostring(err), true)
        return false, tostring(err)
    end
    STATE.lastShotSchema = schema
    return true, schema
end

local function meleeBurst(plr, hits)
    local R = STATE.remotes
    if not R.melee or not isAlive(plr) then return false end
    local hum = getHum(plr)
    local before = hum and hum.Health or 0
    for i = 1, hits or CONFIG.meleeHits do
        pcall(function() R.melee:FireServer(plr) end)
        task.wait(0.055)
    end
    task.delay(0.28, function()
        if hum and hum.Parent and before > 0 and hum.Health >= before then
            log("melee remote did not damage " .. plr.Name .. " (needs fists/range or server rejected)", true)
        end
    end)
    return true
end

local function killTarget(plr)
    if not isAlive(plr) or hasForceField(plr) then return false end
    local mode = CONFIG.killMode
    local root = getRoot()
    local tRoot = getRoot(plr)
    local dist = (root and tRoot) and (root.Position - tRoot.Position).Magnitude or 999
    if mode == "Gun" or (mode == "Auto" and dist > 18) then
        local tool = findTool(CONFIG.gunChoice)
        if tool then
            modGun(tool)
            local part = plr.Character:FindFirstChild("Head") or tRoot
            local ok = fireShoot(part, tool)
            if ok then return true end
        end
    end
    return meleeBurst(plr, CONFIG.meleeHits)
end

local function updateAura()
    if not STATE.toggles.auraOn then return end
    if now() - STATE.lastAura < CONFIG.killRate then return end
    local target = getNearestEnemy(CONFIG.killRange)
    if target then
        STATE.lastAura = now()
        task.spawn(function() killTarget(target) end)
    end
end

local function updateTrigger()
    if not STATE.toggles.triggerOn then return end
    if now() - STATE.lastTrigger < legalCooldown(findTool()) then return end
    local target = getTarget(CONFIG.aimFov)
    if not target then return end
    local tool = findTool(CONFIG.gunChoice)
    if not tool then return end
    STATE.lastTrigger = now()
    fireShoot(target, tool)
end

-- ============================================================
--  AIM / SILENT AIM
-- ============================================================

local function updateAimbot()
    if not STATE.toggles.aimOn then return end
    local cam = currentCamera()
    if not cam then return end
    local should = UserInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
        or STATE.mobileAim
        or (CONFIG.aimbotAutoFire and findTool(CONFIG.gunChoice) ~= nil
            and UserInput:IsMouseButtonPressed(Enum.UserInputType.MouseButton1))
    if not should then return end
    local target = getTarget(CONFIG.aimFov)
    if not target then return end
    local goal = CFrame.lookAt(cam.CFrame.Position, target.Position)
    cam.CFrame = cam.CFrame:Lerp(goal, clamp(CONFIG.aimSmooth, 0.05, 1))
end

local function refreshSilentHooks()
    local H = STATE.hooks
    if not STATE.toggles.silentOn and not H.installed then return end
    if not hookfunction then return end
    local targetHook = nil
    if filtergc then
        local ok, fn = pcall(filtergc, "function", { Name = "castRay" }, true)
        if ok and type(fn) == "function" then targetHook = fn end
    end
    if not targetHook and getgc and debug and debug.info then
        for _, fn in next, getgc(false) do
            if type(fn) == "function" then
                local ok, name = pcall(debug.info, fn, "n")
                if ok and name == "castRay" then targetHook = fn break end
            end
        end
    end
    if targetHook and H.castRay ~= targetHook then
        local ok, old = pcall(hookfunction, targetHook, function(...)
            local target = STATE.target
            if STATE.toggles.silentOn and target and target.Parent
                and target.Parent:FindFirstChildOfClass("Humanoid") then
                local hum = target.Parent:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0
                    and math.random(1, 100) <= CONFIG.silentChance
                    and ((not CONFIG.silentWall) or hasLineOfSight(target)) then
                    return target, target.Position, Vector3.new(0, 1, 0),
                        Enum.Material.Plastic
                end
            end
            return old(...)
        end)
        if ok then
            H.castRay, H.castRayOld = targetHook, old
            H.installed = true
            log("silent aim: castRay hook installed")
        end
    end
end

local function installNamecall()
    local H = STATE.hooks
    if H.namecall or not hookmetamethod or not getnamecallmethod then return end
    local ok, old = pcall(hookmetamethod, game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        if STATE.toggles.silentOn and (method == "FireServer" or method == "InvokeServer")
            and STATE.remotes.shoot and self == STATE.remotes.shoot then
            local target = STATE.target
            if target and target.Parent then
                local hum = target.Parent:FindFirstChildOfClass("Humanoid")
                if hum and hum.Health > 0
                    and math.random(1, 100) <= CONFIG.silentChance
                    and ((not CONFIG.silentWall) or hasLineOfSight(target)) then
                    local args = pack(...)
                    local first = args[1]
                    if type(first) == "table" then
                        -- 2026 schema is a single {origin, hitPos, part} triple.
                        if typeof and typeof(first[1]) == "Vector3" then
                            first[2] = target.Position
                            first[3] = target
                        else
                            -- Legacy schema is an array of bullet tables.
                            for _, bullet in ipairs(first) do
                                if type(bullet) == "table" then
                                    if typeof and typeof(bullet[1]) == "Vector3" then
                                        bullet[2] = target.Position
                                        bullet[3] = target
                                    else
                                        bullet.Cframe = target.CFrame
                                        bullet.HitPart = target
                                        bullet.Hit = target
                                        bullet.Visualize = false
                                    end
                                end
                            end
                        end
                        return old(self, spread(args))
                    end
                end
            end
        end
        return old(self, ...)
    end)
    if ok then
        H.namecall, H.oldNamecall = true, old
        log("silent aim: ShootEvent namecall hook installed")
    else
        log("silent aim: namecall hook failed (" .. tostring(old) .. ")", true)
    end
end

local function setSilentAim(on)
    local H = STATE.hooks
    if on then
        installNamecall()
        refreshSilentHooks()
        if not H.namecall and not H.castRay then
            local why = "executor lacks hookmetamethod/hookfunction"
            log("silent aim: " .. why, true)
            return false, why
        end
        return true
    else
        STATE.target = nil
        return true
    end
end

-- ============================================================
--  ARREST / GUARD
-- ============================================================

local function arrestOnce(plr)
    local R = STATE.remotes
    if not R.arrest or not plr then return false end
    local root = getRoot(plr)
    if not root then return false end
    if CONFIG.arrestSnap then
        local myRoot = getRoot()
        if myRoot then
            pcall(function()
                myRoot.CFrame = root.CFrame * CFrame.new(0, 0, 1.4)
            end)
        end
    end
    local ok, err = pcall(function()
        if R.arrest:IsA("RemoteFunction") then
            R.arrest:InvokeServer(root)
        else
            R.arrest:FireServer(root)
        end
    end)
    if not ok then
        log("arrest remote failed: " .. tostring(err), true)
        return false
    end
    return true
end

local function arrestTarget(plr, attempts)
    if not plr or not isAlive(plr) or isCuffed(plr) then return false end
    for _ = 1, attempts or 8 do
        if not isAlive(plr) or isCuffed(plr) then break end
        arrestOnce(plr)
        task.wait(0.09)
        if isCuffed(plr) then return true end
    end
    return isCuffed(plr)
end

local function findArrestTarget(radius)
    local best, bestDist = nil, radius or CONFIG.arrestRadius
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and isAlive(plr) and not isCuffed(plr) then
            local kind = teamKind(plr)
            if kind == "criminal" or (kind == "inmate" and isArmedHostile(plr)) then
                local root = getRoot(plr)
                if root and isVisible(root) then
                    local d = (root.Position - getPivot()).Magnitude
                    if d < bestDist then best, bestDist = plr, d end
                end
            end
        end
    end
    return best, bestDist
end

local function updateArrestAura()
    if not STATE.toggles.arrestOn then return end
    if STATE.arrestBusy then return end
    if now() - STATE.lastArrest < 0.9 then return end
    if teamKind(LP) ~= "guard" then return end
    local best = findArrestTarget(CONFIG.arrestRadius)
    if not best then return end
    STATE.lastArrest = now()
    STATE.arrestBusy = true
    task.spawn(function()
        local ok = arrestTarget(best, 4)
        STATE.arrestBusy = false
        if not ok and now() - (STATE.lastArrestWarn or 0) > 12 then
            STATE.lastArrestWarn = now()
            log("arrest aura: server did not confirm the cuff (need handcuffs + range)", true)
        end
    end)
end

local function arrestAll(radius)
    task.spawn(function()
        local count = 0
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP and isAlive(plr) and not isCuffed(plr) then
                local kind = teamKind(plr)
                local root = getRoot(plr)
                if root and (kind == "criminal" or kind == "inmate") then
                    local d = (root.Position - getPivot()).Magnitude
                    if d <= (radius or CONFIG.arrestRadius) then
                        if arrestTarget(plr, 6) then count = count + 1 end
                        task.wait(0.35)
                    end
                end
            end
        end
        toast("Arrest All", count .. " player(s) cuffed", 3, count > 0 and "ok" or "warn")
    end)
end

local function switchTeam(kind)
    local R = STATE.remotes
    if not R.team then
        toast("Team", "TeamEvent not found on this server", 3, "err")
        return
    end
    if not R.loadchar then
        toast("Team", "loadchar RemoteFunction not found", 3, "err")
        return
    end

    task.spawn(function()
        local before = teamName(LP)
        if kind == "criminal" then
            pcall(function() R.loadchar:InvokeServer(LP.Name, "Medium stone grey") end)
            teleportTo(CFrame.new(-884.8, 94.1, 2046.9), "Criminal Base")
        else
            local payload = (kind == "guard") and "Bright blue" or "Bright orange"
            pcall(function() R.team:FireServer(payload) end)
            task.wait(0.15)
            pcall(function() R.loadchar:InvokeServer(LP.Name) end)
        end
        task.wait(1.4)
        local after = teamKind(LP)
        if after == kind then
            toast("Team", "Now " .. string.upper(kind) .. " (" .. teamName(LP) .. ")", 2.5, "ok")
        else
            toast("Team", "Request sent, not confirmed (" .. (teamName(LP) ~= "" and teamName(LP) or before) .. ")", 3.5, "warn")
        end
    end)
end

-- ============================================================
--  ITEMS
-- ============================================================

local function findItem(name)
    local root = workspace:FindFirstChild("Prison_ITEMS")
    if not root then return nil end
    local direct = root:FindFirstChild(name, true)
    if direct then return direct end
    for _, d in ipairs(root:GetDescendants()) do
        if string.lower(d.Name) == string.lower(name) then return d end
    end
    return nil
end

local function hasTool(name)
    local ch, bp = getChar(), LP:FindFirstChild("Backpack")
    return (ch and ch:FindFirstChild(name)) or (bp and bp:FindFirstChild(name))
end

local function itemPart(item)
    if not item then return nil end
    local pickup = item:FindFirstChild("ITEMPICKUP", true)
    if pickup and pickup:IsA("BasePart") then return pickup end
    for _, d in ipairs(item:GetDescendants()) do
        if (d:IsA("ClickDetector") or d:IsA("ProximityPrompt")) and d.Parent:IsA("BasePart") then
            return d.Parent
        end
    end
    return item:FindFirstChildWhichIsA("BasePart", true)
end

local function grantItemNow(name)
    local R = STATE.remotes
    if not R.item then
        toast("Items", "ItemHandler not found (wait for the map)", 3, "err")
        return false
    end
    local item = findItem(name)
    if not item then
        toast("Items", name .. " not spawned", 3, "warn")
        return false
    end
    local pivot = getPivot()
    local ok = pcall(function()
        R.item:InvokeServer({ Position = CFrame.new(pivot), Parent = item })
    end)
    if not ok then
        local part = itemPart(item)
        if part then
            pcall(function() R.item:InvokeServer(part) end)
        end
    end
    for _ = 1, 8 do
        task.wait(0.25)
        if hasTool(name) then
            toast("Items", "Acquired " .. name, 2.2, "ok")
            return true
        end
    end
    toast("Items", name .. " was not added (server may be pacing)", 3, "warn")
    return false
end

local function queueItem(name)
    table.insert(STATE.itemQueue, name)
    if STATE.itemBusy then return end
    STATE.itemBusy = true
    task.spawn(function()
        while #STATE.itemQueue > 0 do
            local item = table.remove(STATE.itemQueue, 1)
            local waitLeft = STATE.lastItem + CONFIG.itemPace - now()
            if waitLeft > 0 then task.wait(waitLeft) end
            grantItemNow(item)
            STATE.lastItem = now()
        end
        STATE.itemBusy = false
    end)
end

-- ============================================================
--  WORLD / TELEPORTS
-- ============================================================

local LOCATIONS = {
    { label = "Criminal Base", words = { "criminal", "warehouse" }, cf = CFrame.new(-884.8, 94.1, 2046.9) },
    { label = "Armory", words = { "armory", "gun" }, cf = CFrame.new(820.9, 100.0, 2231.5) },
    { label = "Prison Yard", words = { "yard" }, cf = CFrame.new(780.0, 98.0, 2470.0) },
    { label = "Cafeteria", words = { "cafeteria" }, cf = CFrame.new(918.0, 100.0, 2325.0) },
    { label = "Cell Block", words = { "cell" }, cf = CFrame.new(915.0, 100.0, 2445.0) },
    { label = "Prison Roof", words = { "roof" }, cf = CFrame.new(825.0, 125.0, 2350.0) },
    { label = "Nexus Hall", words = { "nexus" }, cf = CFrame.new(875.0, 100.0, 2387.0) },
    { label = "Sewer Exit", words = { "sewer" }, cf = CFrame.new(916.0, 79.0, 2110.0) },
}

local function teleportLocation(loc)
    if not loc or not loc.cf then return false end
    return teleportTo(loc.cf, loc.label)
end

-- ============================================================
--  DIAGNOSTICS / SELF TEST
-- ============================================================

local function executorReport()
    local features = {
        hookmetamethod = hookmetamethod ~= nil,
        hookfunction = hookfunction ~= nil,
        getgc = getgc ~= nil,
        filtergc = filtergc ~= nil,
        Drawing = Drawing ~= nil,
        fireclickdetector = fireclickdetector ~= nil,
        firetouchinterest = firetouchinterest ~= nil,
        setclipboard = setclipboard ~= nil,
    }
    local out = {}
    for k, v in pairs(features) do table.insert(out, k .. "=" .. (v and "Y" or "-")) end
    table.sort(out)
    return table.concat(out, " ")
end

local function selfTest()
    resolveRemotes()
    local R = STATE.remotes
    local lines = {
        "version=" .. VERSION,
        "player=" .. LP.Name,
        "team=" .. teamName(LP),
        "char=" .. (getChar() and "Y" or "-"),
        "cam=" .. (currentCamera() and "Y" or "-"),
        "remotes=" .. remoteStatus(),
        "guns=" .. (findTool(CONFIG.gunChoice) and findTool(CONFIG.gunChoice).Name or "none"),
        "enemies=" .. tostring(#Players:GetPlayers() - 1),
        "esp=" .. tostring(STATE.espCount or 0),
        "exec=" .. executorReport(),
    }
    local text = table.concat(lines, "\n")
    log("SELF TEST\n" .. text)
    if setclipboard then pcall(setclipboard, text) end
    toast("Self Test", "Report written to the log" .. (setclipboard and " and clipboard" or ""), 3.5, "ok")
end

local function copyLog()
    local lines = {}
    for _, entry in ipairs(STATE.logLines) do
        table.insert(lines, (entry.err and "[!] " or "") .. entry.text)
    end
    local text = table.concat(lines, "\n")
    if setclipboard then
        pcall(setclipboard, text)
        toast("Log", "Copied " .. #lines .. " lines", 2.5, "ok")
    else
        toast("Log", "Executor has no setclipboard", 3, "warn")
    end
end

local function panicReset()
    for id, sw in pairs(STATE.switches) do
        if STATE.toggles[id] then pcall(sw.Set, false) end
    end
    setNoclip(false)
    stopFly()
    setInvisible(false)
    applyHitbox()
    setFullbright(false)
    setFpsBoost(false)
    clearEsp()
    setWorldBarriers(false)
    local hum = getHum()
    if hum then
        hum.WalkSpeed = STATE.orig.walkSpeed or 16
        hum.JumpPower = STATE.orig.jumpPower or 50
        pcall(function() hum.PlatformStand = false end)
    end
    toast("Panic Reset", "All features off; movement restored", 3, "warn")
end

local function unload()
    if STATE.unloaded then return end
    STATE.unloaded = true
    for _, conn in ipairs(STATE.connections) do pcall(function() conn:Disconnect() end) end
    STATE.connections = {}
    pcall(function() setInvisible(false) end)
    pcall(function() setNoclip(false) end)
    pcall(function() stopFly() end)
    pcall(function() applyHitbox() end)
    pcall(function() setFullbright(false) end)
    pcall(function() setFpsBoost(false) end)
    pcall(function() setWorldBarriers(false) end)
    pcall(clearEsp)
    for _, line in pairs(STATE.tracers) do pcall(function() line:Remove() end) end
    STATE.tracers = {}
    if STATE.ui.screen then pcall(function() STATE.ui.screen:Destroy() end) end
    if espScreen then pcall(function() espScreen:Destroy() end) end
    if STATE.ui.fovScreen then pcall(function() STATE.ui.fovScreen:Destroy() end) end
    if Env.VortexV6 then Env.VortexV6.Unloaded = true end
    log("Vortex V6 unloaded")
end
Env.VortexV6.Unload = unload
Env.VortexV6.Panic = panicReset
Env.VortexV6.SelfTest = selfTest

-- forward exports used by pages/init
STATE.api = {
    selfTest = selfTest,
    copyLog = copyLog,
    panicReset = panicReset,
    unload = unload,
    teleportLocation = teleportLocation,
    teleportTo = teleportTo,
    switchTeam = switchTeam,
    switch = switchTeam,
    grantItem = queueItem,
    grantAnywhere = queueItem,
    setFullbright = setFullbright,
    setFpsBoost = setFpsBoost,
    setFov = setFov,
    setNoclip = setNoclip,
    setInvisible = setInvisible,
    stopFly = stopFly,
    updateSpeed = updateSpeed,
    saveMovementDefaults = saveMovementDefaults,
    updateFly = updateFly,
    updateAura = updateAura,
    updateTrigger = updateTrigger,
    updateAimbot = updateAimbot,
    updateEsp = updateEsp,
    updateTracers = updateTracers,
    updateInvisible = updateInvisible,
    updateTeleport = updateTeleport,
    updateHitbox = applyHitbox,
    updateArrest = updateArrestAura,
    updateAntiTaze = updateAntiTaze,
    setSilentAim = setSilentAim,
    refreshSilentHooks = refreshSilentHooks,
    killTarget = killTarget,
    meleeBurst = meleeBurst,
    isEnemy = isEnemy,
    isCuffed = isCuffed,
    getTarget = getTarget,
    getNearestEnemy = getNearestEnemy,
    findTool = findTool,
    modGun = modGun,
    fireShoot = fireShoot,
    buildBullets = buildBullets,
    resolveRemotes = resolveRemotes,
    remoteStatus = remoteStatus,
    executorReport = executorReport,
    arrestOnce = arrestOnce,
    arrestTarget = arrestTarget,
    arrestAll = arrestAll,
    findArrestTarget = findArrestTarget,
    teamKind = teamKind,
    teamName = teamName,
    isAlive = isAlive,
    hasForceField = hasForceField,
    hasLineOfSight = hasLineOfSight,
    findItem = findItem,
    hasTool = hasTool,
    queueItem = queueItem,
    zoneSpeed = zoneSpeed,
    setWorldBarriers = setWorldBarriers,
    L = LOCATIONS,
}
-- ============================================================
--  PAGES
--  Every toggle below either flips a STATE.toggles flag that the runtime
--  loop consumes, or calls an engine function that returns/throws on
--  failure. Nothing is decorative.
-- ============================================================

local function buildPages()
    local API = STATE.api

    local function targetForShot()
        local plr = API.getNearestEnemy(CONFIG.killRange)
        if not plr then return nil end
        local ch = plr.Character
        local part = ch and (ch:FindFirstChild("Head") or ch:FindFirstChild("HumanoidRootPart"))
        return plr, part
    end

    local function fireNearest()
        local plr, part = targetForShot()
        if not (plr and part) then error("no valid target in range", 0) end
        local tool = API.findTool(CONFIG.gunChoice)
        if not tool then error("no GunStates gun in backpack", 0) end
        API.modGun(tool)
        local ok, why = API.fireShoot(part, tool)
        if not ok then error(tostring(why or "shoot remote rejected"), 0) end
        toast("Gun", "Shot sent at " .. plr.Name .. " via " .. tostring(why), 2.2, "ok")
    end

    local function punchNearest()
        local plr = API.getNearestEnemy(CONFIG.killRange)
        if not plr then error("no valid target in range", 0) end
        API.meleeBurst(plr, CONFIG.meleeHits)
        toast("Melee", "Burst sent at " .. plr.Name, 2, "ok")
    end

    local function killNearest()
        local plr = API.getNearestEnemy(CONFIG.killRange)
        if not plr then error("no valid target in range", 0) end
        if not API.killTarget(plr) then error("kill attempt failed (gun mode needs a GunStates tool)", 0) end
        toast("Combat", "Attack sent at " .. plr.Name, 2, "ok")
    end

    local function arrestNearest()
        local plr = API.findArrestTarget(CONFIG.arrestRadius)
        if not plr then error("no cuffable target in range", 0) end
        task.spawn(function()
            local ok = API.arrestTarget(plr, 8)
            toast("Arrest", ok and (plr.Name .. " cuffed") or "server did not confirm the cuff", 3,
                ok and "ok" or "warn")
        end)
    end

    local function nearestPlayer()
        local myRoot = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        local best, bestDist = nil, math.huge
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP and plr.Character then
                local root = plr.Character:FindFirstChild("HumanoidRootPart")
                if root then
                    local d = myRoot and (root.Position - myRoot.Position).Magnitude or 0
                    if d < bestDist then best, bestDist = plr, d end
                end
            end
        end
        return best
    end

    local function tpNearest()
        local plr = nearestPlayer()
        if not plr then error("no other player in the server", 0) end
        local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
        if not root then error("target has no root part", 0) end
        API.teleportTo(root.CFrame * CFrame.new(0, 0, 3), "Near " .. plr.Name)
    end

    local function savePos()
        local root = LP.Character and LP.Character:FindFirstChild("HumanoidRootPart")
        if not root then error("character not ready", 0) end
        STATE.savedTP = root.CFrame
        toast("Teleport", "Position saved", 2, "ok")
    end

    local function returnPos()
        if not STATE.savedTP then error("save a position first", 0) end
        API.teleportTo(STATE.savedTP, "Saved position")
    end

    -- ------------------------------------------------------------
    -- COMBAT
    -- ------------------------------------------------------------
    local combat = newPage("combat", "COMBAT")
    section(combat, "Auras")
    toggleRow(combat, "auraOn", "Kill Aura",
        "Bursts the nearest valid enemy inside the radius",
        false, nil)
    sliderRow(combat, "Kill Radius", 8, 120, CONFIG.killRange, function(v)
        CONFIG.killRange = v
    end, " studs")
    sliderRow(combat, "Kill Pace", 150, 1500, math.floor(CONFIG.killRate * 1000), function(v)
        CONFIG.killRate = v / 1000
    end, " ms")
    choiceRow(combat, "Kill Mode", { "Auto", "Melee", "Gun" }, CONFIG.killMode, function(v)
        CONFIG.killMode = v
    end)
    toggleRow(combat, "clickKill", "Click Kill",
        "Tap or click a player to burst them once",
        false, nil)
    buttonRow(combat, "Kill Nearest Now", "One burst/gun call at the closest valid target", killNearest, true)
    buttonRow(combat, "Punch Nearest", "Melee remote bursts only", punchNearest, false)

    section(combat, "Aim")
    toggleRow(combat, "aimOn", "Camera Aimbot",
        "Hold RMB on PC, hold the AIM dock button on phone",
        false, nil)
    sliderRow(combat, "Aim FOV", 40, 420, CONFIG.aimFov, function(v)
        CONFIG.aimFov = v
    end, " px")
    sliderRow(combat, "Aim Smoothing", 5, 100, math.floor(CONFIG.aimSmooth * 100), function(v)
        CONFIG.aimSmooth = v / 100
    end, "%")
    choiceRow(combat, "Aim Part", { "Head", "HumanoidRootPart", "Random" }, CONFIG.aimPart, function(v)
        CONFIG.aimPart = v
    end)
    toggleRow(combat, "aimbotAutoFire", "Aim Auto-Fire",
        "Also locks while your fire button is held",
        CONFIG.aimbotAutoFire, function(v) CONFIG.aimbotAutoFire = v end)
    toggleRow(combat, "triggerOn", "Trigger Bot",
        "Fires a ShootEvent shot at the crosshair target",
        false, nil)
    toggleRow(combat, "silentOn", "Silent Aim",
        "Rewrites ShootEvent bullets at the target (hookmetamethod)",
        false, function(v)
            local ok, why = API.setSilentAim(v)
            if v and not ok then error(tostring(why or "hook API missing"), 0) end
        end)
    sliderRow(combat, "Silent FOV", 40, 999, CONFIG.silentFov, function(v)
        CONFIG.silentFov = v
    end, " px")
    sliderRow(combat, "Silent Chance", 10, 100, CONFIG.silentChance, function(v)
        CONFIG.silentChance = v
    end, "%")
    toggleRow(combat, "silentWall", "Silent Wall Check",
        "Do not rewrite a shot through a wall",
        CONFIG.silentWall, function(v) CONFIG.silentWall = v end)

    section(combat, "Targeting")
    toggleRow(combat, "teamCheck", "Team Check",
        "Never target teammates or neutral menu players",
        CONFIG.teamCheck, function(v) CONFIG.teamCheck = v end)
    toggleRow(combat, "guardOnlyHostile", "Guard: Hostile Only",
        "As a guard, only target armed or hostile inmates",
        CONFIG.guardOnlyHostile, function(v) CONFIG.guardOnlyHostile = v end)
    toggleRow(combat, "wallCheck", "Line-of-Sight Check",
        "Skip targets hidden behind a wall or object",
        CONFIG.wallCheck, function(v) CONFIG.wallCheck = v end)

    -- ------------------------------------------------------------
    -- GUNS
    -- ------------------------------------------------------------
    local guns = newPage("guns", "GUNS")
    section(guns, "Grant (paced ItemHandler)")
    note(guns, "Prison Life accepts {Position, Parent} item requests but paces them. "
        .. "Requests are queued 3.2s apart and the tool is checked afterwards.", THEME.faint)
    local gunList = { "M9", "MP5", "AK-47", "M4A1", "FAL", "Remington 870", "M700", "Revolver" }
    for _, gunName in ipairs(gunList) do
        local name = gunName
        buttonRow(guns, "Grab " .. name, nil, function() API.grantItem(name) end, false)
    end
    buttonRow(guns, "Grab Handcuffs", "Needed for every arrest feature", function()
        API.grantItem("Handcuffs")
    end, false)
    buttonRow(guns, "Grab Taser", "Guard tool", function()
        API.grantItem("Taser")
    end, false)
    buttonRow(guns, "Grab Full Kit", "All guns + cuffs + taser, paced", function()
        for _, name in ipairs(gunList) do API.grantItem(name) end
        API.grantItem("Handcuffs")
        API.grantItem("Taser")
        toast("Items", "Kit queued; watch the log for each result", 3, "ok")
    end, true)

    section(guns, "Gun Mods (GunStates)")
    toggleRow(guns, "gunAutoModOn", "Auto-Mod Held Gun",
        "Rewrites the local GunStates before firing",
        false, function(v)
            if v then
                local tool = API.findTool(CONFIG.gunChoice)
                if tool then API.modGun(tool) else log("auto-mod: no gun in backpack yet", true) end
            end
        end)
    sliderRow(guns, "Damage", 10, 100, CONFIG.gunDamage, function(v) CONFIG.gunDamage = v end, "")
    sliderRow(guns, "Bullets", 1, 10, CONFIG.gunBullets, function(v) CONFIG.gunBullets = v end, "")
    sliderRow(guns, "Fire Rate", 30, 500, math.floor(CONFIG.gunFireRate * 1000), function(v)
        CONFIG.gunFireRate = v / 1000
    end, " ms")
    sliderRow(guns, "Spread", 0, 20, CONFIG.gunSpread, function(v) CONFIG.gunSpread = v end, "")
    toggleRow(guns, "gunAutoFire", "Auto Fire", "GunStates AutoFire flag",
        CONFIG.gunAutoFire, function(v) CONFIG.gunAutoFire = v end)
    choiceRow(guns, "Preferred Gun", gunList, CONFIG.gunChoice, function(v) CONFIG.gunChoice = v end)
    choiceRow(guns, "Wire Schema", { "Auto", "Legacy", "2026" }, CONFIG.gunSchema, function(v)
        CONFIG.gunSchema = v
    end)
    buttonRow(guns, "Mod Held Gun Now", "Applies damage, bullets and fire-rate", function()
        local tool = API.findTool(CONFIG.gunChoice)
        if not tool then error("no GunStates gun in backpack", 0) end
        if not API.modGun(tool) then error("GunStates module is locked", 0) end
        toast("Gun", tool.Name .. " modded", 2, "ok")
    end, false)
    buttonRow(guns, "Fire at Nearest", "Sends one ShootEvent volley", fireNearest, true)
    note(guns, "Server side: damage, ammo and hit registration are validated. "
        .. "A mod that the server ignores will simply do nothing; the log says so.", THEME.yellow)

    -- ------------------------------------------------------------
    -- PLAYER
    -- ------------------------------------------------------------
    local player = newPage("player", "PLAYER")
    section(player, "Movement")
    toggleRow(player, "speedOn", "Speed", "Applies the WalkSpeed below every heartbeat", false, nil)
    choiceRow(player, "Speed Mode", { "Fixed", "Zone" }, CONFIG.speedMode, function(v)
        CONFIG.speedMode = v
    end)
    sliderRow(player, "WalkSpeed", 16, 80, CONFIG.walkSpeed, function(v) CONFIG.walkSpeed = v end, "")
    toggleRow(player, "jumpOn", "Jump Power", "Overrides Humanoid.JumpPower", false, nil)
    sliderRow(player, "Jump Power", 50, 120, CONFIG.jumpPower, function(v) CONFIG.jumpPower = v end, "")
    toggleRow(player, "autoJumpOn", "Auto-Jump",
        "Jumps again whenever the humanoid lands",
        false, nil)
    toggleRow(player, "flyOn", "Fly",
        "BodyVelocity flight; uses the phone fly pad automatically",
        false, function(v)
            if v and not LP.Character then error("character not ready", 0) end
            if not v then API.stopFly() end
        end)
    sliderRow(player, "Fly Speed", 20, 150, CONFIG.flySpeed, function(v) CONFIG.flySpeed = v end, "")

    section(player, "Collision & Visuals")
    toggleRow(player, "noclipOn", "Noclip",
        "Turns CanCollide off locally; restores every saved part",
        false, function(v)
            local ok = API.setNoclip(v)
            if v and not ok then error("character not ready", 0) end
        end)
    toggleRow(player, "invisOn", "Local Ghost",
        "Hides your character on this device only; server still sees you",
        false, function(v)
            local ok = API.setInvisible(v)
            if v and not ok then error("character not ready", 0) end
        end)
    toggleRow(player, "hitboxOn", "Hitbox Expander",
        "Grows enemy head/root locally; very high detection risk",
        false, function(v)
            if v and not LP.Character then error("character not ready", 0) end
            API.updateHitbox()
        end)
    sliderRow(player, "Hitbox Size", 4, 14, CONFIG.hitboxSize, function(v)
        CONFIG.hitboxSize = v
        if STATE.toggles.hitboxOn then API.updateHitbox() end
    end, "")
    toggleRow(player, "worldBarriersOn", "Ghost Doors & Fences",
        "Client-side CanCollide off; restores on toggle/unload",
        false, function(v)
            local ok = API.setWorldBarriers(v)
            if v and not ok then error("no Doors/Prison_Fences in Workspace yet", 0) end
        end)
    toggleRow(player, "antiTazeOn", "Tase Recovery",
        "Clears stun/sit on this client; the server may re-apply",
        false, nil)

    section(player, "Interface")
    toggleRow(player, "dockOn", "Mobile Action Dock",
        "Punch / Aim / Ghost / Fly quick buttons",
        UserInput.TouchEnabled == true, nil)
    buttonRow(player, "Respawn", "Sets Humanoid.Health to 0", function()
        local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
        if not hum then error("character not ready", 0) end
        hum.Health = 0
    end, false)

    -- ------------------------------------------------------------
    -- GUARD
    -- ------------------------------------------------------------
    local guard = newPage("guard", "GUARD")
    section(guard, "Arrest")
    note(guard, "Arrest requires the Guards team, Handcuffs, and a target inside the server's range. "
        .. "The hub verifies the handcuff GUI before reporting success.", THEME.faint)
    toggleRow(guard, "arrestOn", "Arrest Aura",
        "Cuffs the nearest criminal/hostile inmate on a 0.9s cycle",
        false, nil)
    sliderRow(guard, "Arrest Radius", 6, 60, CONFIG.arrestRadius, function(v)
        CONFIG.arrestRadius = v
    end, " studs")
    toggleRow(guard, "arrestSnap", "Snap Behind Target",
        "Moves you to the cuff position before invoking",
        CONFIG.arrestSnap, function(v) CONFIG.arrestSnap = v end)
    toggleRow(guard, "clickArrest", "Click Arrest",
        "Tap or click a non-guard player to cuff them",
        false, nil)
    buttonRow(guard, "Arrest Nearest", "One verified arrest attempt", arrestNearest, true)
    buttonRow(guard, "Arrest All in Range", "Loops the radius with a 0.35s gap", function()
        API.arrestAll(CONFIG.arrestRadius)
    end, false)

    section(guard, "Team")
    buttonRow(guard, "Join Guards (Bright blue)", nil, function() API.switch("guard") end, false)
    buttonRow(guard, "Join Inmates (Bright orange)", nil, function() API.switch("inmate") end, false)
    buttonRow(guard, "Go Criminal (loadchar)", "Sends the grey/loadchar route and glides to the base", function()
        API.switch("criminal")
    end, false)
    note(guard, "Team changes are server-approved. If the server ignores the request, "
        .. "the hub says so instead of faking a success toast.", THEME.yellow)

    -- ------------------------------------------------------------
    -- TELEPORTS
    -- ------------------------------------------------------------
    local tp = newPage("tp", "TP")
    section(tp, "Map Teleports")
    for _, loc in ipairs(API.L) do
        local entry = loc
        buttonRow(tp, entry.label, nil, function() API.teleportLocation(entry) end, false)
    end
    note(tp, "Coordinates are the classic Prison Life landmarks. If the map is updated "
        .. "they can drift; the glide is capped at 0.55s to reduce rubber-banding.", THEME.faint)

    section(tp, "Players")
    buttonRow(tp, "Teleport to Nearest Player", nil, tpNearest, false)
    buttonRow(tp, "Teleport Behind Nearest Enemy", nil, function()
        local plr = API.getNearestEnemy(9999)
        if not plr then error("no enemy found", 0) end
        local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
        if not root then error("target has no root", 0) end
        API.teleportTo(root.CFrame * CFrame.new(0, 0, 3), "Behind " .. plr.Name)
    end, false)
    buttonRow(tp, "Save Position", nil, savePos, false)
    buttonRow(tp, "Return to Saved", nil, returnPos, false)
    toggleRow(tp, "clickTpOn", "Click Teleport",
        "Tap a surface to glide to it (ignores GUI taps)",
        false, nil)

    -- ------------------------------------------------------------
    -- VISUAL
    -- ------------------------------------------------------------
    local visual = newPage("visual", "VISUAL")
    section(visual, "ESP")
    toggleRow(visual, "espOn", "Player ESP", "Billboard labels + role-colored highlight", false, nil)
    toggleRow(visual, "espNames", "Names", nil, CONFIG.espNames, function(v) CONFIG.espNames = v end)
    toggleRow(visual, "espHealth", "Health", nil, CONFIG.espHealth, function(v) CONFIG.espHealth = v end)
    toggleRow(visual, "espDistance", "Distance", nil, CONFIG.espDistance, function(v) CONFIG.espDistance = v end)
    toggleRow(visual, "espTeamColor", "Role Colors", nil, CONFIG.espTeamColor, function(v) CONFIG.espTeamColor = v end)
    toggleRow(visual, "espChams", "Highlight Chams", nil, CONFIG.espChams, function(v) CONFIG.espChams = v end)
    toggleRow(visual, "espTeamCheck", "Enemies Only", "Hide teammates and neutrals",
        CONFIG.espTeamCheck, function(v) CONFIG.espTeamCheck = v end)
    sliderRow(visual, "Max ESP Units", 5, 40, CONFIG.espMax, function(v) CONFIG.espMax = v end, "")
    toggleRow(visual, "tracersOn", "Tracers", "Needs the executor Drawing API", false, function(v)
        if v and not Drawing then error("executor has no Drawing API", 0) end
    end)

    section(visual, "World")
    toggleRow(visual, "fullbrightOn", "Fullbright", "Reversible Lighting preset", false, function(v)
        API.setFullbright(v)
    end)
    toggleRow(visual, "fpsBoostOn", "FPS Boost", "Disables particles/trails/beams; restores on off", false, function(v)
        API.setFpsBoost(v)
    end)
    sliderRow(visual, "Camera FOV", 40, 120, 70, function(v) API.setFov(v) end, "")
    toggleRow(visual, "showAimFov", "Show Aim Ring", "Draws the aimbot FOV circle", CONFIG.showAimFov, function(v)
        CONFIG.showAimFov = v
    end)
    note(visual, "ESP, tracers, fullbright and the aim ring are client-side only. "
        .. "They are visibility aids, not anti-cheat bypasses.", THEME.faint)

    -- ------------------------------------------------------------
    -- DIAGNOSTICS
    -- ------------------------------------------------------------
    local diag = newPage("diag", "DIAG")
    section(diag, "Live State")
    STATE.diag.version = statRow(diag, "Version", "v" .. VERSION)
    STATE.diag.player = statRow(diag, "Player", LP.Name)
    STATE.diag.team = statRow(diag, "Team", teamName(LP) ~= "" and teamName(LP) or "none")
    STATE.diag.char = statRow(diag, "Character", "checking")
    STATE.diag.remotes = statRow(diag, "Remotes", API.remoteStatus())
    STATE.diag.enemies = statRow(diag, "Other players", "0")
    STATE.diag.esp = statRow(diag, "ESP units", "0")
    STATE.diag.exec = note(diag, "executor: checking", THEME.faint)

    section(diag, "Actions")
    buttonRow(diag, "Run Self Test", "Writes remotes, character and executor report to the log",
        API.selfTest, true)
    buttonRow(diag, "Resolve Remotes", "Re-scans Workspace/ReplicatedStorage", function()
        API.resolveRemotes()
        toast("Remotes", API.remoteStatus(), 3, "ok")
    end, false)
    buttonRow(diag, "Copy Log", "Uses setclipboard when available", API.copyLog, false)
    buttonRow(diag, "Panic Reset", "Turns every toggle off and restores movement", API.panicReset, false)
    buttonRow(diag, "Unload Hub", "Removes the UI and restores client state", API.unload, false)

    section(diag, "Log")
    local logBox = make("ScrollingFrame", {
        Size = UDim2.new(1, -4, 0, 210),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = THEME.accent,
        CanvasSize = UDim2.new(0, 0, 0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, diag)
    corner(logBox, 8)
    local logLabel = make("TextLabel", {
        Size = UDim2.new(1, -12, 0, 0),
        Position = UDim2.fromOffset(6, 4),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 8,
        TextColor3 = THEME.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true,
        Text = "",
    }, logBox)
    STATE.ui.logLabel = logLabel
    local backlog = {}
    for i, entry in ipairs(STATE.logLines) do
        table.insert(backlog, string.format("%02d %s%s", i, entry.err and "[!] " or "    ", entry.text))
    end
    logLabel.Text = #backlog > 0 and table.concat(backlog, "\n") or "log empty"

    note(diag, "Honest anti-cheat level: LOW-MEDIUM. Every working feature here is a client action "
        .. "or a remote the server still validates. There is no server-side damage, arrest, team or "
        .. "item bypass. Speed 80, hitbox 14, ghost fences and arrest snaps are the most detectable.",
        THEME.yellow)

    showPage("combat")
    layout()
end

buildPages()
-- ============================================================
--  RUNTIME / BOOT
-- ============================================================

local function startRuntime()
    local API = STATE.api
    local timers = {}

    local function every(key, dt, interval, fn)
        timers[key] = (timers[key] or 0) + dt
        if timers[key] >= interval then
            timers[key] = 0
            fn()
        end
    end

    local function pressInput(input)
        local t = input and input.UserInputType
        return t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1
    end

    local function flip(id)
        local sw = STATE.switches[id]
        if sw then sw.Set(not STATE.toggles[id]) end
    end

    -- ------------------------------------------------------------
    -- character lifecycle
    -- ------------------------------------------------------------
    local function onCharacter(char)
        if not char then return end
        local hum = char:FindFirstChildOfClass("Humanoid")
            or char:WaitForChild("Humanoid", 5)
        API.saveMovementDefaults()
        STATE.noclip = {}
        STATE.invis.saved = {}
        if STATE.toggles.noclipOn then API.setNoclip(true) end
        if STATE.toggles.invisOn then API.updateInvisible() end
        API.stopFly()
        if hum then
            connect(hum.Died, function()
                STATE.target = nil
                API.stopFly()
            end)
        end
        layout()
        log("character ready: " .. tostring(char.Name))
    end

    connect(LP.CharacterAdded, onCharacter)
    connect(LP.CharacterRemoving, function()
        STATE.target = nil
        API.stopFly()
    end)

    -- ------------------------------------------------------------
    -- click gestures (touch + mouse), raycast based
    -- ------------------------------------------------------------
    local function playerFromPart(part)
        local node = part
        while node and node ~= workspace do
            if node:IsA("Model") then
                local plr = Players:GetPlayerFromCharacter(node)
                if plr then return plr end
            end
            node = node.Parent
        end
        return nil
    end

    local function tapRay(input)
        local cam = currentCamera()
        if not cam then return nil end
        local ok, ray = pcall(function()
            return cam:ViewportPointToRay(input.Position.X, input.Position.Y)
        end)
        if not ok or not ray then return nil end
        local params = RaycastParams.new()
        params.FilterType = Enum.RaycastFilterType.Exclude
        local ignore = {}
        if LP.Character then table.insert(ignore, LP.Character) end
        table.insert(ignore, cam)
        params.FilterDescendantsInstances = ignore
        local found = workspace:Raycast(ray.Origin, ray.Direction * 5000, params)
        return found
    end

    connect(UserInput.InputBegan, function(input, processed)
        if processed or STATE.unloaded then return end
        if not (input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1) then
            return
        end
        if now() - (STATE.lastClick or 0) < 0.25 then return end

        local hit = tapRay(input)
        local target = hit and hit.Instance and playerFromPart(hit.Instance) or nil
        if target == LP then target = nil end

        if target and STATE.toggles.clickKill then
            STATE.lastClick = now()
            task.spawn(function() API.killTarget(target) end)
            return
        end

        if target and STATE.toggles.clickArrest then
            STATE.lastClick = now()
            task.spawn(function()
                if API.teamKind(target) == "guard" then
                    toast("Arrest", "That player is a guard", 2.5, "warn")
                    return
                end
                local ok = API.arrestTarget(target, 5)
                toast("Arrest", ok and (target.Name .. " cuffed") or "server rejected / out of range", 3,
                    ok and "ok" or "warn")
            end)
            return
        end

        if STATE.toggles.clickTpOn and hit and hit.Position then
            STATE.lastClick = now()
            API.teleportTo(CFrame.new(hit.Position + Vector3.new(0, 3, 0)), "Tap target")
        end
    end)

    -- ------------------------------------------------------------
    -- PC hotkeys
    -- ------------------------------------------------------------
    connect(UserInput.InputBegan, function(input, processed)
        if processed or STATE.unloaded then return end
        local key = input.KeyCode
        if key == Enum.KeyCode.RightControl or key == Enum.KeyCode.U then
            setMinimized(main.Visible)
        elseif key == Enum.KeyCode.G then
            flip("auraOn")
        elseif key == Enum.KeyCode.H then
            flip("arrestOn")
        elseif key == Enum.KeyCode.J then
            flip("silentOn")
        elseif key == Enum.KeyCode.F then
            flip("flyOn")
        elseif key == Enum.KeyCode.V then
            flip("invisOn")
        end
    end)

    -- ------------------------------------------------------------
    -- mobile dock
    -- ------------------------------------------------------------
    local function paint(button, active)
        if not button then return end
        button.BackgroundColor3 = active and Color3.fromRGB(0, 150, 135)
            or Color3.fromRGB(28, 35, 52)
    end

    local punch = STATE.mobile.punch
    if punch then
        connect(punch.MouseButton1Click, function()
            local plr = API.getNearestEnemy(CONFIG.killRange)
            if not plr then
                toast("Melee", "No target in range", 2, "warn")
                return
            end
            task.spawn(function() API.meleeBurst(plr, CONFIG.meleeHits) end)
        end)
    end

    local aimBtn = STATE.mobile.aim
    if aimBtn then
        connect(aimBtn.InputBegan, function(input)
            if pressInput(input) then
                STATE.mobileAim = true
                paint(aimBtn, true)
            end
        end)
        connect(aimBtn.InputEnded, function(input)
            if pressInput(input) then
                STATE.mobileAim = false
                paint(aimBtn, false)
            end
        end)
    end

    local invisBtn = STATE.mobile.invis
    if invisBtn then
        connect(invisBtn.MouseButton1Click, function() flip("invisOn") end)
    end
    local flyBtn = STATE.mobile.fly
    if flyBtn then
        connect(flyBtn.MouseButton1Click, function() flip("flyOn") end)
    end

    -- fly pad hold buttons
    for _, entry in ipairs({
        { "up", STATE.mobile.up }, { "down", STATE.mobile.down },
        { "left", STATE.mobile.left }, { "right", STATE.mobile.right },
        { "fwd", STATE.mobile.fwd }, { "back", STATE.mobile.back },
    }) do
        local direction, button = entry[1], entry[2]
        if button then
            connect(button.InputBegan, function(input)
                if pressInput(input) then
                    STATE.flyInput = STATE.flyInput or {}
                    STATE.flyInput[direction] = 1
                    button.BackgroundColor3 = Color3.fromRGB(0, 150, 135)
                end
            end)
            connect(button.InputEnded, function(input)
                if pressInput(input) then
                    if STATE.flyInput then STATE.flyInput[direction] = 0 end
                    button.BackgroundColor3 = Color3.fromRGB(28, 35, 52)
                end
            end)
        end
    end

    -- ------------------------------------------------------------
    -- camera / FOV ring
    -- ------------------------------------------------------------
    local boundCamera = nil
    local function watchCamera()
        local cam = currentCamera()
        if cam and cam ~= boundCamera then
            boundCamera = cam
            connect(cam:GetPropertyChangedSignal("ViewportSize"), function()
                layout()
            end)
            layout()
        end
    end

    local function updateAimRing()
        local ring = STATE.ui.fov
        if not ring then return end
        local show = CONFIG.showAimFov and STATE.toggles.aimOn and not STATE.unloaded
        ring.Visible = show == true
        if not show then return end
        local cam = currentCamera()
        local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
        local radius = clamp(CONFIG.aimFov, 20, 500)
        ring.Size = UDim2.fromOffset(radius * 2, radius * 2)
        ring.Position = UDim2.fromOffset(vp.X * 0.5, vp.Y * 0.5)
        if STATE.ui.fovCorner then
            STATE.ui.fovCorner.CornerRadius = UDim.new(0, radius)
        end
    end

    -- ------------------------------------------------------------
    -- HUD refresh
    -- ------------------------------------------------------------
    local function refreshHud()
        local cam = currentCamera()
        local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
        local dock = STATE.ui.dock
        if dock then
            dock.Visible = STATE.toggles.dockOn == true and vp.Y >= 420 and not STATE.unloaded
            dock.Position = UDim2.new(0.5, -121, 1, -52)
        end
        local flyPad = STATE.ui.flyPad
        if flyPad then
            flyPad.Visible = STATE.toggles.flyOn == true and UserInput.TouchEnabled == true
                and not STATE.unloaded
        end
        paint(STATE.mobile.invis, STATE.toggles.invisOn == true)
        paint(STATE.mobile.fly, STATE.toggles.flyOn == true)
        paint(STATE.mobile.aim, STATE.mobileAim == true)

        if STATE.ui.headerStatus then
            STATE.ui.headerStatus.Text = "V6 • " .. API.remoteStatus()
        end
        if STATE.diag.team then
            STATE.diag.team.Text = teamName(LP) ~= "" and teamName(LP) or "none"
        end
        if STATE.diag.char then
            local hum = getHum()
            STATE.diag.char.Text = hum and (hum.Health > 0 and "alive" or "dead") or "none"
        end
        if STATE.diag.remotes then
            STATE.diag.remotes.Text = API.remoteStatus()
        end
        if STATE.diag.enemies then
            STATE.diag.enemies.Text = tostring(math.max(0, #Players:GetPlayers() - 1))
        end
        if STATE.diag.esp then
            STATE.diag.esp.Text = tostring(STATE.espCount or 0)
        end
        if STATE.diag.exec then
            STATE.diag.exec.Text = "executor: " .. API.executorReport()
        end
    end

    -- ------------------------------------------------------------
    -- loops
    -- ------------------------------------------------------------
    local silentClock = 0
    local function renderStep(dt)
        if STATE.unloaded then return end
        API.updateAimbot()
        API.updateTeleport()
        updateAimRing()
        silentClock = silentClock + dt
        if silentClock >= 0.12 then
            silentClock = 0
            if STATE.toggles.silentOn then
                STATE.target = API.getTarget(CONFIG.silentFov, "silent")
            else
                STATE.target = nil
            end
        end
    end

    local function heartbeat(dt)
        if STATE.unloaded then return end
        API.updateSpeed()
        API.updateFly()
        API.updateAura()
        API.updateTrigger()
        API.updateArrest()
        API.updateAntiTaze()

        every("esp", dt, 0.22, function()
            if STATE.toggles.espOn or next(STATE.esp) then API.updateEsp() end
        end)
        every("tracers", dt, 0.12, function()
            if STATE.toggles.tracersOn or next(STATE.tracers) then API.updateTracers() end
        end)
        every("hitbox", dt, 0.45, function()
            if STATE.toggles.hitboxOn then API.updateHitbox() end
        end)
        every("noclip", dt, 1.0, function()
            if STATE.toggles.noclipOn then API.setNoclip(true) end
        end)
        every("ghost", dt, 0.5, function()
            if STATE.toggles.invisOn then API.updateInvisible() end
        end)
        every("automod", dt, 3.0, function()
            if STATE.toggles.gunAutoModOn then
                local tool = API.findTool(CONFIG.gunChoice)
                if tool then API.modGun(tool) end
            end
        end)
        every("fps", dt, 5.0, function()
            if STATE.toggles.fpsBoostOn then API.setFpsBoost(true) end
        end)
        every("remotes", dt, 6.0, function()
            local R = STATE.remotes
            if not (R.item and R.shoot and R.melee) then
                API.resolveRemotes()
            end
        end)
        every("camera", dt, 1.5, watchCamera)
        every("hud", dt, 0.5, refreshHud)
    end

    -- ------------------------------------------------------------
    -- boot
    -- ------------------------------------------------------------
    API.resolveRemotes()
    API.saveMovementDefaults()
    if LP.Character then onCharacter(LP.Character) end
    watchCamera()
    layout()
    refreshHud()

    connect(RunService.RenderStepped, renderStep)
    connect(RunService.Heartbeat, heartbeat)

    STATE.ui.headerStatus.Text = "V6 • " .. API.remoteStatus()
    log("V6 boot complete — " .. API.remoteStatus())
    if not STATE.remotes.shoot then
        toast("Remotes", "ShootEvent not found yet; gun/trigger features stay idle", 4.5, "warn")
    end
    toast("VORTEX V6", "Loaded. Client-side features only; the server still validates.", 4.5, "ok")
end

startRuntime()
