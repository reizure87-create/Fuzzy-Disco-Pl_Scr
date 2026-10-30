--[[
    RiotHub x Break In 2 (Story)
    Single-file, keyless, mobile-first hub for Delta / Android.

    Built for the actual Break In 2 loop:
      - story objectives & interaction prompts
      - team recruitment, upgrades, puzzles, waves and bosses
      - lobby roles (Guest / Hacker claim helpers)
      - ESP, teleport, movement, survival and server tools

    Every game-specific action is defensive: if a remote or prompt is not
    present, the hub logs it instead of throwing. Use the SCAN button and
    send the log if something on your build is named differently.

    v1.0
]]

local Players        = game:GetService("Players")
local Replicated     = game:GetService("ReplicatedStorage")
local TweenService   = game:GetService("TweenService")
local RunService     = game:GetService("RunService")
local UserInput      = game:GetService("UserInputService")
local Lighting       = game:GetService("Lighting")
local Teleport       = game:GetService("TeleportService")
local HttpService    = game:GetService("HttpService")
local VirtualUser    = game:GetService("VirtualUser")

local LP = Players.LocalPlayer
local CAM = workspace.CurrentCamera

-- ============================================================
--  CONFIG  (persisted when the executor supports writefile)
-- ============================================================

local CONFIG_FILE = "RiotHub_BreakIn2.json"

local CONFIG = {
    walkSpeed      = 24,
    jumpPower      = 55,
    flySpeed       = 70,
    gravity        = 196.2,
    fov            = 70,
    uiScale        = 1,
    reduceAnim     = false,

    healThreshold  = 45,
    healCooldown   = 2.5,

    auraRange      = 16,
    auraRate       = 0.22,
    auraTargets    = "NPCs",

    aimRange       = 220,
    dodgeRange     = 16,

    hitboxSize     = 7,

    questRadius    = 18,
    questPace      = 0.5,
    collectRadius  = 22,

    espMax         = 60,

    waypoints      = {},
}

-- merge a saved config before the theme/UI is built
do
    if isfile and readfile then
        local ok, raw = pcall(function() return readfile(CONFIG_FILE) end)
        if ok and type(raw) == "string" and #raw > 0 then
            local ok2, data = pcall(function() return HttpService:JSONDecode(raw) end)
            if ok2 and type(data) == "table" then
                for k, v in pairs(data) do
                    if CONFIG[k] ~= nil and type(v) == type(CONFIG[k]) then
                        CONFIG[k] = v
                    end
                end
            end
        end
    end
    CONFIG.walkSpeed = math.clamp(tonumber(CONFIG.walkSpeed) or 24, 8, 300)
    CONFIG.jumpPower = math.clamp(tonumber(CONFIG.jumpPower) or 55, 10, 300)
    CONFIG.flySpeed  = math.clamp(tonumber(CONFIG.flySpeed) or 70, 10, 300)
    CONFIG.gravity   = math.clamp(tonumber(CONFIG.gravity) or 196.2, 20, 300)
    CONFIG.fov       = math.clamp(tonumber(CONFIG.fov) or 70, 40, 120)
    CONFIG.uiScale   = math.clamp(tonumber(CONFIG.uiScale) or 1, 0.7, 1.3)
    CONFIG.espMax    = math.clamp(tonumber(CONFIG.espMax) or 60, 10, 120)

    CONFIG.healThreshold = math.clamp(tonumber(CONFIG.healThreshold) or 45, 10, 90)
    CONFIG.healCooldown  = math.clamp(tonumber(CONFIG.healCooldown) or 2.5, 0.5, 10)
    CONFIG.auraRange     = math.clamp(tonumber(CONFIG.auraRange) or 16, 5, 80)
    CONFIG.auraRate      = math.clamp(tonumber(CONFIG.auraRate) or 0.22, 0.05, 1)
    CONFIG.aimRange      = math.clamp(tonumber(CONFIG.aimRange) or 220, 20, 600)
    CONFIG.dodgeRange    = math.clamp(tonumber(CONFIG.dodgeRange) or 16, 5, 40)
    CONFIG.hitboxSize    = math.clamp(tonumber(CONFIG.hitboxSize) or 7, 2, 20)
    CONFIG.questRadius   = math.clamp(tonumber(CONFIG.questRadius) or 18, 8, 60)
    CONFIG.questPace     = math.clamp(tonumber(CONFIG.questPace) or 0.5, 0.1, 1.2)
    CONFIG.collectRadius = math.clamp(tonumber(CONFIG.collectRadius) or 22, 8, 80)

    if CONFIG.auraTargets ~= "Players" and CONFIG.auraTargets ~= "Both" then
        CONFIG.auraTargets = "NPCs"
    end
    if type(CONFIG.waypoints) ~= "table" then CONFIG.waypoints = {} end
end

-- ============================================================
--  THEME
-- ============================================================

local ACCENT = Color3.fromRGB(255, 62, 94)

local THEME = {
    bg        = Color3.fromRGB(13, 14, 20),
    panel     = Color3.fromRGB(19, 21, 30),
    card      = Color3.fromRGB(27, 30, 41),
    cardUp    = Color3.fromRGB(38, 42, 56),
    line      = Color3.fromRGB(44, 48, 63),
    text      = Color3.fromRGB(240, 242, 248),
    dim       = Color3.fromRGB(146, 152, 170),
    faint     = Color3.fromRGB(96, 102, 120),
    accent    = ACCENT,
    accentDim = Color3.fromRGB(160, 40, 60),
    green     = Color3.fromRGB(58, 214, 138),
    red       = Color3.fromRGB(255, 84, 96),
    yellow    = Color3.fromRGB(255, 198, 84),
    blue      = Color3.fromRGB(92, 168, 255),
    switchOff = Color3.fromRGB(52, 56, 70),
}

-- ============================================================
--  STATE
-- ============================================================

local STATE = {
    unloaded     = false,
    toggles      = {},
    switches     = {},
    conns        = {},

    logLines     = {},
    fps          = 0,
    fpsFrames    = 0,
    fpsClock     = 0,

    prompts      = {},
    npcs         = {},
    items        = {},
    remotes      = {},

    espPlayers   = {},
    espNpcs      = {},
    espItems     = {},

    tracers      = {},
    drawingOk    = true,

    noclipSaved  = {},
    hitboxSaved  = {},
    flyBV        = nil,
    flyBG        = nil,

    lastPrompt   = nil,
    lastPromptAt = 0,
    lastAction   = 0,
    lastHeal     = 0,
    lastDialogue = 0,

    touch        = { fwd = 0, back = 0, left = 0, right = 0, up = 0, down = 0 },

    savedLighting = nil,
    savedFx       = {},
    perfOn        = false,
    fullbrightOn  = false,

    statusRefs   = {},
    accentStrokes = {},
}

local function now()
    return os.clock()
end

-- ============================================================
--  SMALL UTILITIES
-- ============================================================

local function make(class, props, parent)
    local obj = Instance.new(class)
    if props then
        for k, v in pairs(props) do
            obj[k] = v
        end
    end
    if parent then obj.Parent = parent end
    return obj
end

local function corner(obj, radius)
    return make("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, obj)
end

local function stroke(obj, color, thickness, transparency)
    return make("UIStroke", {
        Color = color or THEME.line,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, obj)
end

local function gradient(obj, c1, c2, rotation)
    return make("UIGradient", {
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, c1),
            ColorSequenceKeypoint.new(1, c2),
        }),
        Rotation = rotation or 90,
    }, obj)
end

local function tw(obj, goal, dur)
    if CONFIG.reduceAnim then dur = 0.01 end
    local info = TweenInfo.new(dur or 0.14, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
    local tween = TweenService:Create(obj, info, goal)
    tween:Play()
    return tween
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

local function connect(signal, fn)
    local c = signal:Connect(fn)
    table.insert(STATE.conns, c)
    return c
end

local logList
local function log(msg, isErr)
    local ok, stamp = pcall(os.date, "%H:%M:%S")
    if not ok then stamp = "??:??:??" end
    table.insert(STATE.logLines, 1, { text = tostring(stamp) .. "  " .. tostring(msg), err = isErr == true })
    while #STATE.logLines > 70 do table.remove(STATE.logLines) end

    if logList then
        for _, child in ipairs(logList:GetChildren()) do
            if child:IsA("TextLabel") then child:Destroy() end
        end
        for i, entry in ipairs(STATE.logLines) do
            make("TextLabel", {
                Text = entry.text,
                Size = UDim2.new(1, -6, 0, 16),
                Position = UDim2.new(0, 3, 0, (i - 1) * 16),
                BackgroundTransparency = 1,
                Font = Enum.Font.Code,
                TextSize = 11,
                TextColor3 = entry.err and THEME.red or THEME.dim,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
            }, logList)
        end
        logList.CanvasSize = UDim2.new(0, 0, 0, #STATE.logLines * 16 + 8)
    end

    if isErr then
        pcall(warn, "[RiotHub] " .. tostring(msg))
    end
end

local function safe(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        log(tostring(label) .. " failed: " .. tostring(err), true)
    end
    return ok, err
end

-- ============================================================
--  CHARACTER HELPERS
-- ============================================================

local function getChar()
    return LP.Character
end

local function getHum()
    local ch = LP.Character
    return ch and ch:FindFirstChildOfClass("Humanoid")
end

local function getRoot()
    local ch = LP.Character
    if not ch then return nil end
    return ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart
end

local function getPivot()
    local root = getRoot()
    return root and root.Position or Vector3.new(0, 0, 0)
end

local function characterParts(ch)
    local list = {}
    for _, d in ipairs(ch:GetDescendants()) do
        if d:IsA("BasePart") then table.insert(list, d) end
    end
    return list
end

local function teleportTo(cf)
    local root = getRoot()
    if not root then
        log("teleport skipped: no character", true)
        return false
    end
    local ok = safe("teleport", function()
        if STATE.flyBV then STATE.flyBV.Velocity = Vector3.new(0, 0, 0) end
        root.CFrame = cf + Vector3.new(0, 3, 0)
        root.Velocity = Vector3.new(0, 0, 0)
        root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    end)
    return ok
end

local function teleportToPos(pos)
    return teleportTo(CFrame.new(pos))
end

-- ============================================================
--  UI SHELL
-- ============================================================

local gui = make("ScreenGui", {
    Name = "RiotHub_BreakIn2",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 500,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, LP:WaitForChild("PlayerGui"))

local view = CAM and CAM.ViewportSize or Vector2.new(1280, 720)
if view.X < 400 or view.Y < 300 then view = Vector2.new(1280, 720) end

local winW = clamp(view.X - 190, 330, 560)
local winH = clamp(view.Y - 54, 300, 450)

local main = make("Frame", {
    Name = "Main",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Active = false,
}, gui)

local window = make("Frame", {
    Name = "Window",
    Size = UDim2.fromOffset(winW, winH),
    Position = UDim2.new(0.5, 0, 0.5, 0),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = THEME.bg,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Active = true,
}, main)
corner(window, 12)
stroke(window, THEME.line, 1, 0.25)

local uiScale = make("UIScale", {
    Scale = math.min(CONFIG.uiScale, (view.X - 8) / winW, (view.Y - 8) / winH),
}, window)

-- top bar -----------------------------------------------------
local topBar = make("Frame", {
    Name = "TopBar",
    Size = UDim2.new(1, 0, 0, 42),
    BackgroundColor3 = THEME.panel,
    BorderSizePixel = 0,
}, window)
gradient(topBar, Color3.fromRGB(26, 28, 40), THEME.panel, 90)
make("Frame", {
    Size = UDim2.new(1, 0, 0, 2),
    Position = UDim2.new(0, 0, 1, -2),
    BackgroundColor3 = THEME.accent,
    BorderSizePixel = 0,
}, topBar)

make("Frame", {
    Size = UDim2.fromOffset(4, 20),
    Position = UDim2.new(0, 12, 0, 11),
    BackgroundColor3 = THEME.accent,
    BorderSizePixel = 0,
}, topBar)

make("TextLabel", {
    Text = "RIOTHUB",
    Size = UDim2.new(0, 90, 0, 17),
    Position = UDim2.new(0, 22, 0, 7),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBlack,
    TextSize = 14,
    TextColor3 = THEME.text,
    TextXAlignment = Enum.TextXAlignment.Left,
}, topBar)
make("TextLabel", {
    Text = "BREAK IN 2",
    Size = UDim2.new(0, 120, 0, 12),
    Position = UDim2.new(0, 22, 0, 22),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextColor3 = THEME.accent,
    TextXAlignment = Enum.TextXAlignment.Left,
}, topBar)

local function topButton(text, x, color)
    return make("TextButton", {
        Text = text,
        Size = UDim2.fromOffset(32, 30),
        Position = UDim2.new(1, x, 0, 6),
        BackgroundColor3 = THEME.card,
        BackgroundTransparency = 0.35,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = text == "X" and 13 or 16,
        TextColor3 = color or THEME.dim,
        AutoButtonColor = false,
    }, topBar)
end

local hideBtn = topButton("-", -76, THEME.dim)
local closeBtn = topButton("X", -40, THEME.accent)
corner(hideBtn, 7)
corner(closeBtn, 7)

-- status bar --------------------------------------------------
local statusBar = make("Frame", {
    Name = "StatusBar",
    Size = UDim2.new(1, 0, 0, 24),
    Position = UDim2.new(0, 0, 1, -24),
    BackgroundColor3 = THEME.panel,
    BorderSizePixel = 0,
    ZIndex = 8,
}, window)

local statusLabel = make("TextLabel", {
    Text = "booting...",
    Size = UDim2.new(1, -104, 1, 0),
    Position = UDim2.new(0, 10, 0, 0),
    BackgroundTransparency = 1,
    Font = Enum.Font.Code,
    TextSize = 10,
    TextColor3 = THEME.dim,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
}, statusBar)

local activeLabel = make("TextLabel", {
    Text = "0 ON",
    Size = UDim2.fromOffset(44, 24),
    Position = UDim2.new(1, -100, 0, 0),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextColor3 = THEME.dim,
    TextXAlignment = Enum.TextXAlignment.Right,
}, statusBar)

local logBtn = make("TextButton", {
    Text = "LOG +",
    Size = UDim2.fromOffset(46, 18),
    Position = UDim2.new(1, -52, 0, 3),
    BackgroundColor3 = THEME.card,
    BorderSizePixel = 0,
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextColor3 = THEME.accent,
    AutoButtonColor = false,
}, statusBar)
corner(logBtn, 5)

-- content / pages ---------------------------------------------
local TABS = {
    { id = "home",    label = "HOME" },
    { id = "player",  label = "PLAYER" },
    { id = "combat",  label = "COMBAT" },
    { id = "auto",    label = "AUTO" },
    { id = "visual",  label = "VISUAL" },
    { id = "tp",      label = "TELEPORT" },
    { id = "server",  label = "SERVER" },
    { id = "config",  label = "SETUP" },
}

local content = make("ScrollingFrame", {
    Name = "Content",
    Size = UDim2.new(1, -124, 1, -66),
    Position = UDim2.new(0, 116, 0, 42),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = THEME.accent,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    CanvasSize = UDim2.new(0, 0, 0, 0),
}, window)

local pages = {}
for _, tab in ipairs(TABS) do
    local page = make("Frame", {
        Name = tab.id,
        Size = UDim2.new(1, -6, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Visible = false,
    }, content)
    make("UIListLayout", {
        Padding = UDim.new(0, 7),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, page)
    pages[tab.id] = page
end

-- sidebar -----------------------------------------------------
local sidebar = make("ScrollingFrame", {
    Name = "Sidebar",
    Size = UDim2.new(0, 108, 1, -66),
    Position = UDim2.new(0, 6, 0, 42),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = THEME.line,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    CanvasSize = UDim2.new(0, 0, 0, #TABS * 32 + 10),
}, window)
make("UIListLayout", {
    Padding = UDim.new(0, 2),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, sidebar)
make("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 2) }, sidebar)

local tabButtons = {}
local activeTab = nil

local function updateCanvas()
    if not activeTab then return end
    local page = pages[activeTab.id]
    local layout = page and page:FindFirstChildOfClass("UIListLayout")
    content.CanvasSize = UDim2.new(0, 0, 0, (layout and layout.AbsoluteContentSize.Y or 0) + 26)
end

local function showTab(id)
    for _, tab in ipairs(TABS) do
        local page = pages[tab.id]
        local btn = tabButtons[tab.id]
        local on = (tab.id == id)
        page.Visible = on
        if btn then
            btn.bg.BackgroundColor3 = on and THEME.card or THEME.panel
            btn.bg.BackgroundTransparency = on and 0 or 0.55
            btn.label.TextColor3 = on and THEME.text or THEME.dim
            btn.bar.BackgroundTransparency = on and 0 or 1
            btn.label.Font = on and Enum.Font.GothamBold or Enum.Font.Gotham
        end
        if on then activeTab = tab end
    end
    content.CanvasPosition = Vector2.new(0, 0)
    task.defer(updateCanvas)
end

for i, tab in ipairs(TABS) do
    local btn = make("TextButton", {
        Text = "",
        Size = UDim2.new(1, -2, 0, 30),
        BackgroundColor3 = THEME.panel,
        BackgroundTransparency = 0.55,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        LayoutOrder = i,
    }, sidebar)
    corner(btn, 7)
    local bar = make("Frame", {
        Size = UDim2.fromOffset(3, 18),
        Position = UDim2.new(0, 5, 0.5, -9),
        BackgroundColor3 = THEME.accent,
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
    }, btn)
    corner(bar, 2)
    local label = make("TextLabel", {
        Text = tab.label,
        Size = UDim2.new(1, -14, 1, 0),
        Position = UDim2.new(0, 13, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 11,
        TextColor3 = THEME.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, btn)
    tabButtons[tab.id] = { bg = btn, label = label, bar = bar }
    btn.MouseButton1Click:Connect(function()
        showTab(tab.id)
    end)
end

-- log overlay -------------------------------------------------
local logPanel = make("Frame", {
    Name = "LogPanel",
    Size = UDim2.new(1, -16, 0, 132),
    Position = UDim2.new(0, 8, 1, -162),
    BackgroundColor3 = THEME.panel,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 30,
}, window)
corner(logPanel, 9)
stroke(logPanel, THEME.line, 1, 0.2)

make("TextLabel", {
    Text = "SESSION LOG",
    Size = UDim2.new(0, 120, 0, 22),
    Position = UDim2.new(0, 10, 0, 0),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBold,
    TextSize = 9,
    TextColor3 = THEME.accent,
    TextXAlignment = Enum.TextXAlignment.Left,
}, logPanel)

local clearLogBtn = make("TextButton", {
    Text = "CLEAR",
    Size = UDim2.fromOffset(44, 16),
    Position = UDim2.new(1, -98, 0, 3),
    BackgroundColor3 = THEME.card,
    BorderSizePixel = 0,
    Font = Enum.Font.GothamBold,
    TextSize = 8,
    TextColor3 = THEME.dim,
    AutoButtonColor = false,
}, logPanel)
corner(clearLogBtn, 4)

local copyLogBtn = make("TextButton", {
    Text = "COPY",
    Size = UDim2.fromOffset(44, 16),
    Position = UDim2.new(1, -50, 0, 3),
    BackgroundColor3 = THEME.card,
    BorderSizePixel = 0,
    Font = Enum.Font.GothamBold,
    TextSize = 8,
    TextColor3 = THEME.dim,
    AutoButtonColor = false,
}, logPanel)
corner(copyLogBtn, 4)

logList = make("ScrollingFrame", {
    Size = UDim2.new(1, -12, 1, -26),
    Position = UDim2.new(0, 6, 0, 22),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = THEME.line,
    CanvasSize = UDim2.new(0, 0, 0, 0),
}, logPanel)

local logOpen = false
local function setLogOpen(open)
    logOpen = open
    logPanel.Visible = open
    logBtn.Text = open and "LOG -" or "LOG +"
end

logBtn.MouseButton1Click:Connect(function()
    setLogOpen(not logOpen)
end)
clearLogBtn.MouseButton1Click:Connect(function()
    STATE.logLines = {}
    if logList then
        for _, c in ipairs(logList:GetChildren()) do
            if c:IsA("TextLabel") then c:Destroy() end
        end
        logList.CanvasSize = UDim2.new(0, 0, 0, 0)
    end
end)
copyLogBtn.MouseButton1Click:Connect(function()
    local lines = {}
    for i = #STATE.logLines, 1, -1 do
        table.insert(lines, STATE.logLines[i].text)
    end
    local text = table.concat(lines, "\n")
    if setclipboard then
        pcall(setclipboard, text)
        log("log copied to clipboard")
    else
        log("executor has no setclipboard", true)
    end
end)

-- toast host --------------------------------------------------
local toastHost = make("Frame", {
    Name = "ToastHost",
    Size = UDim2.new(0, 236, 1, -32),
    Position = UDim2.new(1, -14, 0, 14),
    AnchorPoint = Vector2.new(1, 0),
    BackgroundTransparency = 1,
    ZIndex = 60,
}, gui)
make("UIListLayout", {
    Padding = UDim.new(0, 6),
    SortOrder = Enum.SortOrder.LayoutOrder,
    HorizontalAlignment = Enum.HorizontalAlignment.Right,
    VerticalAlignment = Enum.VerticalAlignment.Top,
}, toastHost)

local toastOrder = 0
local function toast(title, body, duration, kind)
    toastOrder = toastOrder + 1
    local color = THEME.accent
    if kind == "ok" then color = THEME.green end
    if kind == "warn" then color = THEME.yellow end
    if kind == "err" then color = THEME.red end

    local holder = make("Frame", {
        Size = UDim2.new(1, 0, 0, 46),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        BackgroundTransparency = 0.06,
        LayoutOrder = -toastOrder,
        ZIndex = 61,
    }, toastHost)
    corner(holder, 8)
    stroke(holder, color, 1, 0.25)
    make("Frame", {
        Size = UDim2.fromOffset(3, 30),
        Position = UDim2.new(0, 6, 0, 8),
        BackgroundColor3 = color,
        BorderSizePixel = 0,
        ZIndex = 62,
    }, holder)
    make("TextLabel", {
        Text = tostring(title or "RiotHub"),
        Size = UDim2.new(1, -22, 0, 16),
        Position = UDim2.new(0, 14, 0, 5),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = color,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 62,
    }, holder)
    make("TextLabel", {
        Text = tostring(body or ""),
        Size = UDim2.new(1, -22, 0, 18),
        Position = UDim2.new(0, 14, 0, 21),
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextColor3 = THEME.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        ZIndex = 62,
    }, holder)

    holder.BackgroundTransparency = 1
    tw(holder, { BackgroundTransparency = 0.06 }, 0.16)
    task.delay(duration or 2.2, function()
        if holder and holder.Parent then
            tw(holder, { BackgroundTransparency = 1 }, 0.2)
            task.delay(0.22, function()
                if holder then holder:Destroy() end
            end)
        end
    end)
end

-- floating action button --------------------------------------
local fab = make("TextButton", {
    Name = "Fab",
    Text = "R",
    Size = UDim2.fromOffset(50, 50),
    Position = UDim2.new(0, 12, 0, 64),
    BackgroundColor3 = THEME.accent,
    BorderSizePixel = 0,
    Font = Enum.Font.GothamBlack,
    TextSize = 20,
    TextColor3 = Color3.new(1, 1, 1),
    AutoButtonColor = false,
    ZIndex = 90,
}, gui)
corner(fab, 25)
stroke(fab, Color3.new(1, 1, 1), 1.5, 0.65)

local fabDragging = false
local fabMoved = 0
local fabStart = nil

fab.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        fabDragging = true
        fabMoved = 0
        fabStart = { pos = fab.Position, input = input.Position }
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                fabDragging = false
                if fabMoved <= 8 then
                    window.Visible = not window.Visible
                    if window.Visible then
                        window.BackgroundTransparency = 1
                        tw(window, { BackgroundTransparency = 0 }, 0.14)
                    end
                end
            end
        end)
    end
end)

UserInput.InputChanged:Connect(function(input)
    if not fabDragging then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local delta = input.Position - fabStart.input
    fabMoved = math.max(fabMoved, delta.Magnitude)
    fab.Position = UDim2.new(fabStart.pos.X.Scale, fabStart.pos.X.Offset + delta.X,
        fabStart.pos.Y.Scale, fabStart.pos.Y.Offset + delta.Y)
end)

-- window dragging ---------------------------------------------
local winDrag = false
local winStart = nil
local winPosStart = nil

topBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        winDrag = true
        winStart = input.Position
        winPosStart = window.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                winDrag = false
            end
        end)
    end
end)

UserInput.InputChanged:Connect(function(input)
    if not winDrag then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
    local delta = input.Position - winStart
    window.Position = UDim2.new(winPosStart.X.Scale, winPosStart.X.Offset + delta.X,
        winPosStart.Y.Scale, winPosStart.Y.Offset + delta.Y)
end)

hideBtn.MouseButton1Click:Connect(function()
    window.Visible = false
    toast("RiotHub", "Tap the R button to reopen", 1.6)
end)
closeBtn.MouseButton1Click:Connect(function()
    window.Visible = false
end)

-- ============================================================
--  WIDGETS
-- ============================================================

local queueSave = function() end

local function flash(text)
    if statusLabel then
        statusLabel.Text = text
        statusLabel.TextColor3 = THEME.accent
        task.delay(0.7, function()
            if statusLabel then statusLabel.TextColor3 = THEME.dim end
        end)
    end
end

local function section(page, title)
    local holder = make("Frame", {
        Size = UDim2.new(1, -10, 0, 28),
        BackgroundTransparency = 1,
    }, page)
    make("TextLabel", {
        Text = string.upper(title),
        Size = UDim2.new(0, 120, 1, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = THEME.accent,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, holder)
    make("Frame", {
        Size = UDim2.new(1, -128, 0, 1),
        Position = UDim2.new(0, 124, 0.5, 0),
        BackgroundColor3 = THEME.line,
        BorderSizePixel = 0,
        BackgroundTransparency = 0.3,
    }, holder)
    return holder
end

local function toggleRow(page, id, title, desc, default, callback)
    local h = desc and 52 or 42
    local row = make("TextButton", {
        Text = "",
        Size = UDim2.new(1, -10, 0, h),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        ClipsDescendants = true,
    }, page)
    corner(row, 8)

    local rowStroke = stroke(row, THEME.accent, 1.2, 1)
    table.insert(STATE.accentStrokes, rowStroke)

    make("TextLabel", {
        Text = title,
        Size = UDim2.new(1, -100, 0, 17),
        Position = UDim2.new(0, 12, 0, desc and 8 or 7),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)

    if desc then
        make("TextLabel", {
            Text = desc,
            Size = UDim2.new(1, -100, 0, 14),
            Position = UDim2.new(0, 12, 0, 26),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 9,
            TextColor3 = THEME.dim,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
    end

    local sw = make("Frame", {
        Size = UDim2.fromOffset(38, 20),
        Position = UDim2.new(1, -48, 0.5, -10),
        BackgroundColor3 = THEME.switchOff,
        BorderSizePixel = 0,
    }, row)
    corner(sw, 10)
    local knob = make("Frame", {
        Size = UDim2.fromOffset(14, 14),
        Position = UDim2.new(0, 3, 0, 3),
        BackgroundColor3 = Color3.fromRGB(235, 238, 245),
        BorderSizePixel = 0,
    }, sw)
    corner(knob, 7)

    local enabled = (default == true)

    local function set(v)
        enabled = (v == true)
        STATE.toggles[id] = enabled

        -- instant paint first: never depend on a tween for state legibility
        sw.BackgroundColor3 = enabled and THEME.green or THEME.switchOff
        knob.Position = UDim2.new(0, enabled and 21 or 3, 0, 3)
        rowStroke.Transparency = enabled and 0.32 or 1
        row.BackgroundColor3 = enabled and THEME.cardUp or THEME.card
        flash(title .. "  ->  " .. (enabled and "ON" or "OFF"))

        if callback then
            task.spawn(function()
                local ok, err = pcall(callback, enabled)
                if not ok then
                    log("toggle [" .. id .. "]: " .. tostring(err), true)
                end
            end)
        end
        queueSave()
    end

    row.MouseButton1Click:Connect(function()
        set(not enabled)
    end)

    STATE.toggles[id] = enabled
    STATE.switches[id] = { Set = set }
    rowStroke.Transparency = enabled and 0.32 or 1
    row.BackgroundColor3 = enabled and THEME.cardUp or THEME.card
    return { Set = set }
end

local function buttonRow(page, label, desc, callback, accent)
    local h = desc and 46 or 38
    local row = make("TextButton", {
        Text = "",
        Size = UDim2.new(1, -10, 0, h),
        BackgroundColor3 = accent and Color3.fromRGB(44, 24, 32) or THEME.card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        ClipsDescendants = true,
    }, page)
    corner(row, 8)
    stroke(row, accent and THEME.accent or THEME.line, 1, accent and 0.35 or 0.55)

    make("TextLabel", {
        Text = label,
        Size = UDim2.new(1, -84, 0, 17),
        Position = UDim2.new(0, 12, 0, desc and 6 or 10),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = accent and THEME.accent or THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, row)

    if desc then
        make("TextLabel", {
            Text = desc,
            Size = UDim2.new(1, -84, 0, 14),
            Position = UDim2.new(0, 12, 0, 24),
            BackgroundTransparency = 1,
            Font = Enum.Font.Gotham,
            TextSize = 9,
            TextColor3 = THEME.dim,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
        }, row)
    end

    make("TextLabel", {
        Text = "RUN",
        Size = UDim2.fromOffset(50, 20),
        Position = UDim2.new(1, -62, 0.5, -10),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = accent and THEME.accent or THEME.faint,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, row)

    row.MouseButton1Click:Connect(function()
        row.BackgroundColor3 = THEME.cardUp
        task.delay(0.08, function()
            if row and row.Parent then
                row.BackgroundColor3 = accent and Color3.fromRGB(44, 24, 32) or THEME.card
            end
        end)
        flash(label .. "  ->  fired")
        local ok, err = pcall(callback)
        if not ok then log("button [" .. label .. "]: " .. tostring(err), true) end
    end)

    return row
end

local function sliderRow(page, title, minV, maxV, value, callback, suffix)
    local row = make("Frame", {
        Size = UDim2.new(1, -10, 0, 46),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
    }, page)
    corner(row, 8)

    make("TextLabel", {
        Text = title,
        Size = UDim2.new(0.62, -10, 0, 17),
        Position = UDim2.new(0, 12, 0, 6),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local valueLbl = make("TextLabel", {
        Text = tostring(round(value)) .. (suffix and (" " .. suffix) or ""),
        Size = UDim2.new(0.36, -10, 0, 17),
        Position = UDim2.new(0.64, 0, 0, 6),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 10,
        TextColor3 = THEME.accent,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, row)

    local bar = make("Frame", {
        Size = UDim2.new(1, -24, 0, 20),
        Position = UDim2.new(0, 12, 0, 23),
        BackgroundTransparency = 1,
        Active = true,
    }, row)

    local track = make("Frame", {
        Size = UDim2.new(1, 0, 0, 6),
        Position = UDim2.new(0, 0, 0.5, -3),
        BackgroundColor3 = Color3.fromRGB(45, 49, 62),
        BorderSizePixel = 0,
    }, bar)
    corner(track, 3)

    local fill = make("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = THEME.accent,
        BorderSizePixel = 0,
    }, track)
    corner(fill, 3)

    local knob = make("Frame", {
        Size = UDim2.fromOffset(14, 14),
        Position = UDim2.new(0, 0, 0.5, -7),
        BackgroundColor3 = Color3.fromRGB(245, 247, 252),
        BorderSizePixel = 0,
        ZIndex = 3,
    }, bar)
    corner(knob, 7)

    local current = value
    local dragging = false

    local function paint(v)
        local alpha = 0
        if maxV > minV then alpha = (v - minV) / (maxV - minV) end
        alpha = clamp(alpha, 0, 1)
        fill.Size = UDim2.new(alpha, 0, 1, 0)
        knob.Position = UDim2.new(alpha, -7, 0.5, -7)
        valueLbl.Text = tostring(round(v)) .. (suffix and (" " .. suffix) or "")
    end

    local function setValue(v, fire)
        current = clamp(v, minV, maxV)
        paint(current)
        if fire then
            local ok, err = pcall(callback, current)
            if not ok then log("slider [" .. title .. "]: " .. tostring(err), true) end
            queueSave()
        end
    end

    local function fromX(x)
        local alpha = clamp((x - bar.AbsolutePosition.X) / math.max(bar.AbsoluteSize.X, 1), 0, 1)
        setValue(minV + (maxV - minV) * alpha, true)
    end

    bar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            fromX(input.Position.X)
        end
    end)

    connect(UserInput.InputChanged, function(input)
        if not dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            fromX(input.Position.X)
        end
    end)

    connect(UserInput.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)

    paint(current)
    return { Set = setValue }
end

local function dropdownRow(page, title, options, default, callback)
    local baseH = 38
    local row = make("TextButton", {
        Text = "",
        Size = UDim2.new(1, -10, 0, baseH),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        ClipsDescendants = true,
    }, page)
    corner(row, 8)
    stroke(row, THEME.line, 1, 0.55)

    make("TextLabel", {
        Text = title,
        Size = UDim2.new(0.52, -10, 1, 0),
        Position = UDim2.new(0, 12, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local chosen = make("TextLabel", {
        Text = tostring(default or "-"),
        Size = UDim2.new(0.4, -22, 1, 0),
        Position = UDim2.new(0.6, 0, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = THEME.accent,
        TextXAlignment = Enum.TextXAlignment.Right,
    }, row)

    local indicator = make("TextLabel", {
        Text = "+",
        Size = UDim2.fromOffset(16, 16),
        Position = UDim2.new(1, -20, 0.5, -8),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = THEME.dim,
        TextXAlignment = Enum.TextXAlignment.Center,
    }, row)

    local listH = math.min(#options, 8) * 25 + 6
    local list = make("Frame", {
        Size = UDim2.new(1, -6, 0, listH),
        Position = UDim2.new(0, 3, 0, baseH + 2),
        BackgroundColor3 = THEME.panel,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 5,
    }, row)
    corner(list, 7)
    stroke(list, THEME.line, 1, 0.3)

    local open = false
    local function setOpen(v)
        open = v
        list.Visible = v
        indicator.Text = v and "-" or "+"
        row.Size = UDim2.new(1, -10, 0, baseH + (v and (listH + 6) or 0))
        row.ZIndex = v and 6 or 1
        task.defer(updateCanvas)
    end

    for i, opt in ipairs(options) do
        local optBtn = make("TextButton", {
            Text = tostring(opt),
            Size = UDim2.new(1, -6, 0, 23),
            Position = UDim2.new(0, 3, 0, 3 + (i - 1) * 25),
            BackgroundColor3 = THEME.panel,
            BorderSizePixel = 0,
            Font = Enum.Font.Gotham,
            TextSize = 10,
            TextColor3 = THEME.text,
            TextXAlignment = Enum.TextXAlignment.Left,
            AutoButtonColor = false,
            ZIndex = 6,
        }, list)
        corner(optBtn, 5)
        optBtn.MouseEnter:Connect(function()
            optBtn.BackgroundColor3 = THEME.cardUp
        end)
        optBtn.MouseLeave:Connect(function()
            optBtn.BackgroundColor3 = THEME.panel
        end)
        optBtn.MouseButton1Click:Connect(function()
            chosen.Text = tostring(opt)
            if callback then
                local ok, err = pcall(callback, opt)
                if not ok then log("dropdown [" .. title .. "]: " .. tostring(err), true) end
            end
            setOpen(false)
            queueSave()
        end)
    end

    row.MouseButton1Click:Connect(function()
        setOpen(not open)
    end)

    return { Set = function(v)
        chosen.Text = tostring(v)
    end }
end

local function waypointRow(page, slot)
    local row = make("Frame", {
        Size = UDim2.new(1, -10, 0, 34),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
    }, page)
    corner(row, 7)

    make("TextLabel", {
        Text = "SLOT " .. slot,
        Size = UDim2.new(0, 60, 1, 0),
        Position = UDim2.new(0, 10, 0, 0),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = THEME.dim,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, row)

    local setBtn = make("TextButton", {
        Text = "SAVE",
        Size = UDim2.fromOffset(56, 22),
        Position = UDim2.new(1, -128, 0.5, -11),
        BackgroundColor3 = THEME.cardUp,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = THEME.dim,
        AutoButtonColor = false,
    }, row)
    corner(setBtn, 5)

    local goBtn = make("TextButton", {
        Text = "GO",
        Size = UDim2.fromOffset(56, 22),
        Position = UDim2.new(1, -66, 0.5, -11),
        BackgroundColor3 = Color3.fromRGB(44, 24, 32),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = THEME.accent,
        AutoButtonColor = false,
    }, row)
    corner(goBtn, 5)

    setBtn.MouseButton1Click:Connect(function()
        local root = getRoot()
        if not root then return end
        CONFIG.waypoints[slot] = { x = root.Position.X, y = root.Position.Y, z = root.Position.Z }
        queueSave()
        toast("Waypoint " .. slot, "Saved at " .. round(root.Position.X) .. ", "
            .. round(root.Position.Y) .. ", " .. round(root.Position.Z), 1.8, "ok")
    end)

    goBtn.MouseButton1Click:Connect(function()
        local wp = CONFIG.waypoints[slot]
        if type(wp) == "table" and wp.x and wp.y and wp.z then
            teleportToPos(Vector3.new(wp.x, wp.y, wp.z))
            toast("Waypoint " .. slot, "Teleported", 1.2, "ok")
        else
            toast("Waypoint " .. slot, "Empty - save one first", 1.8, "warn")
        end
    end)

    return row
end
-- ============================================================
--  FLY PAD (mobile)
-- ============================================================

local flyPad = make("Frame", {
    Name = "FlyPad",
    Size = UDim2.fromOffset(144, 144),
    Position = UDim2.new(1, -158, 1, -158),
    BackgroundColor3 = THEME.panel,
    BackgroundTransparency = 0.25,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 70,
}, gui)
corner(flyPad, 14)
stroke(flyPad, THEME.line, 1, 0.35)

local function flyButton(text, col, row, key)
    local b = make("TextButton", {
        Text = text,
        Size = UDim2.fromOffset(42, 42),
        Position = UDim2.fromOffset(3 + col * 47, 3 + row * 47),
        BackgroundColor3 = Color3.fromRGB(30, 33, 44),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = THEME.text,
        AutoButtonColor = false,
        ZIndex = 71,
    }, flyPad)
    corner(b, 9)
    stroke(b, THEME.line, 1, 0.45)

    local function press()
        STATE.touch[key] = 1
        b.BackgroundColor3 = THEME.accent
    end
    local function release()
        STATE.touch[key] = 0
        b.BackgroundColor3 = Color3.fromRGB(30, 33, 44)
    end

    b.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            press()
        end
    end)
    b.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            release()
        end
    end)
    b.MouseLeave:Connect(release)
    return b
end

flyButton("UP", 0, 0, "up")
flyButton("W",  1, 0, "fwd")
flyButton("DN", 2, 0, "down")
flyButton("A",  0, 1, "left")
flyButton("D",  2, 1, "right")
flyButton("S",  1, 2, "back")

make("TextLabel", {
    Text = "FLY",
    Size = UDim2.fromOffset(42, 42),
    Position = UDim2.fromOffset(50, 50),
    BackgroundTransparency = 1,
    Font = Enum.Font.GothamBlack,
    TextSize = 9,
    TextColor3 = THEME.faint,
    ZIndex = 71,
}, flyPad)

-- ============================================================
--  SCANNING
-- ============================================================

local ITEM_WORDS = {
    "coin", "cash", "money", "key", "item", "pizza", "apple", "wire", "fuse",
    "battery", "package", "delivery", "box", "med", "bandage", "food", "tool",
    "weapon", "crowbar", "bat", "knife", "gun", "ammo", "scrap", "gear",
    "upgrade", "button", "lever", "switch", "valve", "card", "ticket", "egg",
}

local FRIENDLY_WORDS = {
    "twado", "bradley", "pete", "friend", "teammate", "ally", "dog", "cat", "pet",
    "mom", "dad", "mother", "father", "sister", "brother", "family", "survivor",
    "civilian", "agent", "uncle", "aunt", "baby", "child", "kid",
}

local BOSS_WORDS = {
    "mary", "pizza", "brute", "boss", "guest",
}

local HEAL_WORDS = {
    "heal", "med", "bandage", "food", "pizza", "apple", "water", "drink", "health", "potion",
}

local WEAPON_WORDS = {
    "sword", "bat", "crowbar", "knife", "axe", "gun", "pistol", "shotgun", "rifle",
    "weapon", "wrench", "pipe", "mop", "spear", "bow", "slingshot", "taser", "pizza",
}

local UPGRADE_WORDS = {
    "upgrade", "strong", "speed", "health", "damage", "power", "stat", "train",
    "buy", "purchase", "tool", "improve", "level",
}

local RECRUIT_WORDS = {
    "recruit", "join", "follow", "talk", "speak", "help", "rescue", "pet", "team",
    "friend", "wake", "untie", "free", "bring", "deliver",
}

local REVIVE_WORDS = {
    "revive", "wake", "help", "heal", "rescue", "untie", "free",
}

local QUEST_BLOCK = {
    "leave", "quit", "reset", "kick", "report", "sell", "delete", "sacrifice",
    "betray", "ban", "remove", "buy", "purchase",
}

local DIALOG_WORDS = {
    "continue", "next", "skip", "ok", "okay", "yes", "start", "begin", "accept",
    "claim", "proceed", "done", "talk", "play",
}

local DIALOG_BLOCK = {
    "no", "cancel", "decline", "leave", "quit", "back", "close", "delete",
}

local function matches(text, words)
    local lower = string.lower(tostring(text or ""))
    for _, w in ipairs(words) do
        if lower:find(w, 1, true) then return true end
    end
    return false
end

local function belongsToCharacter(inst)
    local model = inst:FindFirstAncestorOfClass("Model")
    local depth = 0
    while model and depth < 5 do
        if Players:GetPlayerFromCharacter(model) then
            return true
        end
        model = model:FindFirstAncestorOfClass("Model")
        depth = depth + 1
    end
    return false
end

local function getPromptPos(prompt)
    local parent = prompt and prompt.Parent
    if not parent then return nil end
    if parent:IsA("Attachment") then
        return parent.WorldPosition
    elseif parent:IsA("BasePart") then
        return parent.Position
    elseif parent:IsA("Model") and parent.PrimaryPart then
        return parent.PrimaryPart.Position
    end
    return nil
end

local function promptLabel(prompt)
    local action = tostring(prompt.ActionText or "")
    local object = tostring(prompt.ObjectText or "")
    if action ~= "" and object ~= "" then
        return action .. ": " .. object
    elseif action ~= "" then
        return action
    elseif object ~= "" then
        return object
    end
    return prompt.Parent and prompt.Parent.Name or "Interact"
end

local function refreshWorld()
    local prompts, npcs, items = {}, {}, {}
    local seenModels, seenItems = {}, {}
    local pivot = getPivot()

    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and d.Enabled then
            local pos = getPromptPos(d)
            if pos and not belongsToCharacter(d) then
                table.insert(prompts, {
                    prompt = d,
                    pos = pos,
                    text = promptLabel(d),
                    name = d.Parent and d.Parent.Name or "?",
                })
            end
        end

        if d:IsA("Humanoid") and d.Health > 0 then
            local model = d.Parent
            if model and not seenModels[model] and model ~= LP.Character then
                local isPlayer = Players:GetPlayerFromCharacter(model) ~= nil
                if not isPlayer then
                    local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
                    if root and root:IsA("BasePart") then
                        seenModels[model] = true
                        local lower = string.lower(model.Name)
                        local hasPrompt = model:FindFirstChildWhichIsA("ProximityPrompt", true) ~= nil
                        local boss = matches(lower, BOSS_WORDS)
                        local friendly = not boss and (hasPrompt or matches(lower, FRIENDLY_WORDS))
                        table.insert(npcs, {
                            model = model,
                            hum = d,
                            root = root,
                            pos = root.Position,
                            name = model.Name,
                            friendly = friendly,
                            boss = boss,
                        })
                    end
                end
            end
        end

        local isPart = d:IsA("BasePart")
        local isTool = d:IsA("Tool")
        if isPart or isTool then
            local part = isPart and d or d:FindFirstChild("Handle")
            if part and part:IsA("BasePart") and not seenItems[part] then
                local lower = string.lower(d.Name)
                local prompt = d:FindFirstChildOfClass("ProximityPrompt")
                local click = d:FindFirstChildOfClass("ClickDetector")
                if not prompt then prompt = part:FindFirstChildOfClass("ProximityPrompt") end
                if not click then click = part:FindFirstChildOfClass("ClickDetector") end
                local named = false
                if #lower >= 3 then
                    for _, w in ipairs(ITEM_WORDS) do
                        if lower:find(w, 1, true) then
                            named = true
                            break
                        end
                    end
                end
                if (named or prompt or click) and not belongsToCharacter(d) then
                    seenItems[part] = true
                    table.insert(items, {
                        part = part,
                        obj = d,
                        name = d.Name,
                        pos = part.Position,
                        prompt = prompt,
                        cd = click,
                    })
                end
            end
        end
    end

    table.sort(npcs, function(a, b)
        return (a.pos - pivot).Magnitude < (b.pos - pivot).Magnitude
    end)
    table.sort(items, function(a, b)
        return (a.pos - pivot).Magnitude < (b.pos - pivot).Magnitude
    end)

    while #npcs > 90 do table.remove(npcs) end
    while #items > 160 do table.remove(items) end
    while #prompts > 420 do table.remove(prompts) end

    STATE.prompts = prompts
    STATE.npcs = npcs
    STATE.items = items
end

local function findNearestPrompt(filter, radius)
    local best, bestD = nil, nil
    local pivot = getPivot()
    for _, entry in ipairs(STATE.prompts) do
        local ok = true
        if filter then
            ok = filter(entry)
        end
        if ok then
            local d = (entry.pos - pivot).Magnitude
            if d <= (radius or 400) and (bestD == nil or d < bestD) then
                best, bestD = entry, d
            end
        end
    end
    return best, bestD
end

local function findNearestItem(filter, radius)
    local best, bestD = nil, nil
    local pivot = getPivot()
    for _, entry in ipairs(STATE.items) do
        local ok = true
        if filter then ok = filter(entry) end
        if ok then
            local d = (entry.pos - pivot).Magnitude
            if d <= (radius or 400) and (bestD == nil or d < bestD) then
                best, bestD = entry, d
            end
        end
    end
    return best, bestD
end

local function getNearestTarget(range, mode)
    local best, bestD = nil, nil
    local pivot = getPivot()

    if mode ~= "Players" then
        for _, n in ipairs(STATE.npcs) do
            if not n.friendly and n.hum and n.hum.Parent
                and n.root and n.root.Parent and n.hum.Health > 0 then
                local d = (n.pos - pivot).Magnitude
                if d <= range and (bestD == nil or d < bestD) then
                    best, bestD = n, d
                end
            end
        end
    end

    if mode ~= "NPCs" then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP and plr.Character then
                local hum = plr.Character:FindFirstChildOfClass("Humanoid")
                local root = plr.Character:FindFirstChild("HumanoidRootPart")
                if hum and hum.Parent and root and root.Parent and hum.Health > 0 then
                    local sameTeam = LP.Team ~= nil and plr.Team == LP.Team
                    if not sameTeam then
                        local d = (root.Position - pivot).Magnitude
                        if d <= range and (bestD == nil or d < bestD) then
                            best = {
                                model = plr.Character,
                                hum = hum,
                                root = root,
                                pos = root.Position,
                                name = plr.Name,
                                friendly = false,
                                boss = false,
                            }
                            bestD = d
                        end
                    end
                end
            end
        end
    end

    return best, bestD
end

-- ============================================================
--  ESP
-- ============================================================

STATE.espPrompts = {}

local function wallMode()
    return STATE.toggles.espWalls and Enum.HighlightDepthMode.AlwaysOnTop
        or Enum.HighlightDepthMode.Occluded
end

local function makeUnit(tbl, key, adornee, hlTarget, color, text, withHealth)
    if not adornee then return nil end

    local unit = {
        key = key,
        adornee = adornee,
        hlTarget = hlTarget,
        color = color,
        text = text,
    }

    if hlTarget then
        local hl = make("Highlight", {
            FillColor = color,
            FillTransparency = STATE.toggles.espWalls and 0.38 or 0.62,
            OutlineColor = color,
            OutlineTransparency = 0.15,
            DepthMode = wallMode(),
        }, gui)
        hl.Adornee = hlTarget
        unit.hl = hl
    end

    local bb = make("BillboardGui", {
        Size = UDim2.fromOffset(190, withHealth and 30 or 20),
        StudsOffset = Vector3.new(0, 2.9, 0),
        AlwaysOnTop = STATE.toggles.espWalls == true,
        MaxDistance = 320,
        LightInfluence = 0,
    }, gui)
    bb.Adornee = adornee
    unit.bb = bb

    unit.label = make("TextLabel", {
        Text = text,
        Size = UDim2.new(1, 0, 0, 18),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 10,
        TextColor3 = color,
        TextStrokeColor3 = Color3.new(0, 0, 0),
        TextStrokeTransparency = 0.35,
        TextXAlignment = Enum.TextXAlignment.Center,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, bb)

    if withHealth then
        local barBg = make("Frame", {
            Size = UDim2.new(0.72, 0, 0, 4),
            Position = UDim2.new(0.14, 0, 1, -2),
            BackgroundColor3 = Color3.fromRGB(20, 22, 30),
            BorderSizePixel = 0,
        }, bb)
        corner(barBg, 2)
        unit.barFill = make("Frame", {
            Size = UDim2.new(1, 0, 1, 0),
            BackgroundColor3 = color,
            BorderSizePixel = 0,
        }, barBg)
        corner(unit.barFill, 2)
    end

    tbl[key] = unit
    return unit
end

local function retargetUnit(unit, adornee, hlTarget)
    if not unit or not adornee then return end
    if unit.adornee ~= adornee then
        unit.adornee = adornee
        if unit.bb then unit.bb.Adornee = adornee end
    end
    if unit.hl and hlTarget and unit.hlTarget ~= hlTarget then
        unit.hlTarget = hlTarget
        unit.hl.Adornee = hlTarget
    end
end

local function updateUnit(unit, name, pos, health, maxHealth)
    if not unit or not unit.label then return end
    local cam = workspace.CurrentCamera
    local dist = cam and (pos - cam.CFrame.Position).Magnitude or 0
    unit.label.Text = tostring(name) .. "  |  " .. tostring(round(dist)) .. "m"
    unit.label.TextColor3 = unit.color
    if unit.barFill and health and maxHealth and maxHealth > 0 then
        unit.barFill.Size = UDim2.new(clamp(health / maxHealth, 0, 1), 0, 1, 0)
    end
end

local function cleanupUnits(tbl, seen)
    for key, unit in pairs(tbl) do
        if not seen[key] then
            if unit.hl then unit.hl:Destroy() end
            if unit.bb then unit.bb:Destroy() end
            tbl[key] = nil
        end
    end
end

local function clearUnits(tbl)
    for key, unit in pairs(tbl) do
        if unit.hl then unit.hl:Destroy() end
        if unit.bb then unit.bb:Destroy() end
        tbl[key] = nil
    end
end

local function applyWallMode()
    local mode = wallMode()
    local fill = STATE.toggles.espWalls and 0.38 or 0.62
    local tables = { STATE.espPlayers, STATE.espNpcs, STATE.espPrompts, STATE.espItems }
    for _, tbl in ipairs(tables) do
        for _, unit in pairs(tbl) do
            if unit.hl then
                unit.hl.DepthMode = mode
                unit.hl.FillTransparency = fill
            end
            if unit.bb then
                unit.bb.AlwaysOnTop = STATE.toggles.espWalls == true
            end
        end
    end
end

local function applyEsp()
    -- players
    if STATE.toggles.playerEsp then
        local seen = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP and plr.Character then
                local hum = plr.Character:FindFirstChildOfClass("Humanoid")
                local head = plr.Character:FindFirstChild("Head") or plr.Character.PrimaryPart
                if hum and head and hum.Health > 0 then
                    seen[plr] = true
                    local unit = STATE.espPlayers[plr]
                    if not unit then
                        local color = THEME.blue
                        if LP.Team and plr.Team and LP.Team == plr.Team then
                            color = THEME.green
                        end
                        unit = makeUnit(STATE.espPlayers, plr, head, plr.Character, color, plr.Name, true)
                    end
                    retargetUnit(unit, head, plr.Character)
                    updateUnit(unit, plr.Name, head.Position, hum.Health, hum.MaxHealth)
                end
            end
        end
        cleanupUnits(STATE.espPlayers, seen)
    else
        clearUnits(STATE.espPlayers)
    end

    -- NPCs
    if STATE.toggles.npcEsp then
        local seen = {}
        local count = 0
        for _, n in ipairs(STATE.npcs) do
            if count >= CONFIG.espMax then break end
            local head = n.model and n.model.Parent
                and (n.model:FindFirstChild("Head") or n.root) or nil
            if head and n.hum and n.hum.Parent then
                local color = n.friendly and THEME.green
                    or (n.boss and THEME.red or Color3.fromRGB(255, 145, 70))
                local unit = STATE.espNpcs[n.model]
                if not unit then
                    unit = makeUnit(STATE.espNpcs, n.model, head, n.model, color, n.name, true)
                end
                if unit then
                    retargetUnit(unit, head, n.model)
                    unit.color = color
                    if unit.hl then unit.hl.FillColor = color end
                    if unit.hl then unit.hl.OutlineColor = color end
                    if unit.barFill then unit.barFill.BackgroundColor3 = color end
                    updateUnit(unit, n.name, head.Position, n.hum.Health, n.hum.MaxHealth)
                    seen[n.model] = true
                    count = count + 1
                end
            end
        end
        cleanupUnits(STATE.espNpcs, seen)
    else
        clearUnits(STATE.espNpcs)
    end

    -- objective prompts
    if STATE.toggles.promptEsp then
        local seen = {}
        local count = 0
        for _, p in ipairs(STATE.prompts) do
            if count >= 40 then break end
            local adornee = p.prompt.Parent
            if adornee and (adornee:IsA("BasePart") or adornee:IsA("Attachment")) then
                local unit = STATE.espPrompts[p.prompt]
                if not unit then
                    unit = makeUnit(STATE.espPrompts, p.prompt, adornee, nil, THEME.yellow, "[!] " .. p.text, false)
                end
                if unit then
                    retargetUnit(unit, adornee, nil)
                    updateUnit(unit, "[!] " .. p.text, p.pos, nil, nil)
                    seen[p.prompt] = true
                    count = count + 1
                end
            end
        end
        cleanupUnits(STATE.espPrompts, seen)
    else
        clearUnits(STATE.espPrompts)
    end

    -- loose items (skip ones already shown by prompt ESP)
    if STATE.toggles.itemEsp then
        local seen = {}
        local count = 0
        for _, item in ipairs(STATE.items) do
            if count >= 34 then break end
            local dup = item.prompt and STATE.toggles.promptEsp
            if not dup then
                local unit = STATE.espItems[item.part]
                if not unit then
                    unit = makeUnit(STATE.espItems, item.part, item.part, nil, THEME.blue, item.name, false)
                end
                if unit then
                    retargetUnit(unit, item.part, nil)
                    updateUnit(unit, item.name, item.pos, nil, nil)
                    seen[item.part] = true
                    count = count + 1
                end
            end
        end
        cleanupUnits(STATE.espItems, seen)
    else
        clearUnits(STATE.espItems)
    end
end

-- ============================================================
--  TRACERS
-- ============================================================

local function clearTracers()
    for _, line in pairs(STATE.tracers) do
        pcall(function() line:Remove() end)
    end
    STATE.tracers = {}
end

local function updateTracers()
    if not STATE.toggles.tracers then
        if next(STATE.tracers) then clearTracers() end
        return
    end
    if not Drawing then
        if STATE.drawingOk then
            STATE.drawingOk = false
            log("tracers need the executor Drawing API", true)
        end
        return
    end

    local cam = workspace.CurrentCamera
    if not cam then return end
    local from = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)
    local seen = {}

    local function lineFor(key, pos, color)
        local line = STATE.tracers[key]
        if not line then
            local ok, obj = pcall(function() return Drawing.new("Line") end)
            if not ok or not obj then return end
            line = obj
            line.Thickness = 1.6
            line.Transparency = 0.35
            STATE.tracers[key] = line
        end
        seen[key] = true
        line.Color = color
        line.From = from
        local screen, onScreen = cam:WorldToViewportPoint(pos)
        if onScreen and screen.Z > 0 then
            line.To = Vector2.new(screen.X, screen.Y)
            line.Visible = true
        else
            line.Visible = false
        end
    end

    for _, n in ipairs(STATE.npcs) do
        if not n.friendly then
            lineFor(n.model, n.pos, n.boss and THEME.red or THEME.yellow)
        end
    end

    if STATE.toggles.playerEsp then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP and plr.Character then
                local root = plr.Character:FindFirstChild("HumanoidRootPart")
                if root then
                    lineFor(plr, root.Position, THEME.blue)
                end
            end
        end
    end

    for key, line in pairs(STATE.tracers) do
        if not seen[key] then line.Visible = false end
    end
end

-- ============================================================
--  MOVEMENT / LIGHTING / PERF
-- ============================================================

STATE.origGravity = workspace.Gravity
STATE.baseShadows = Lighting.GlobalShadows
STATE.origFov = CAM and CAM.FieldOfView or 70

local function stopFly()
    if STATE.flyBV then
        pcall(function() STATE.flyBV:Destroy() end)
        STATE.flyBV = nil
    end
    if STATE.flyBG then
        pcall(function() STATE.flyBG:Destroy() end)
        STATE.flyBG = nil
    end
    local hum = getHum()
    if hum then
        pcall(function() hum.PlatformStand = false end)
    end
    local root = getRoot()
    if root then
        pcall(function() root.Velocity = Vector3.new(0, 0, 0) end)
    end
    if flyPad then flyPad.Visible = false end
end

local function startFly()
    stopFly()
    local hum, root = getHum(), getRoot()
    if not (hum and root) then return false end

    pcall(function() hum.PlatformStand = true end)

    local bv = make("BodyVelocity", {
        MaxForce = Vector3.new(100000, 100000, 100000),
        Velocity = Vector3.new(0, 0, 0),
        P = 1250,
    }, root)
    local bg = make("BodyGyro", {
        MaxTorque = Vector3.new(100000, 100000, 100000),
        P = 3000,
        D = 300,
        CFrame = root.CFrame,
    }, root)

    STATE.flyBV = bv
    STATE.flyBG = bg
    flyPad.Visible = STATE.toggles.flyPad ~= false
    return true
end

local function setFly(on)
    if on then
        local ok = startFly()
        if not ok then
            log("fly: character is not ready", true)
            if STATE.switches.flyOn then STATE.switches.flyOn.Set(false) end
        end
    else
        stopFly()
    end
end

local function setNoclip(on)
    local ch = getChar()
    if not ch then return end
    if on then
        for _, p in ipairs(characterParts(ch)) do
            if p.CanCollide then
                STATE.noclipSaved[p] = true
                pcall(function() p.CanCollide = false end)
            end
        end
    else
        for p in pairs(STATE.noclipSaved) do
            if p and p.Parent then
                pcall(function() p.CanCollide = true end)
            end
        end
        STATE.noclipSaved = {}
    end
end

local function updateFly()
    if not STATE.toggles.flyOn then return end
    local bv, bg = STATE.flyBV, STATE.flyBG
    local hum, root = getHum(), getRoot()

    if not (bv and bg and hum and root) then
        -- ready again after a respawn without spamming the log
        if now() - (STATE.flyRetry or 0) > 1 then
            STATE.flyRetry = now()
            startFly()
        end
        return
    end

    pcall(function() hum.PlatformStand = true end)

    local cam = workspace.CurrentCamera
    if not cam then return end

    local fwd = (UserInput:IsKeyDown(Enum.KeyCode.W) and 1 or 0)
        - (UserInput:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
        + STATE.touch.fwd - STATE.touch.back
    local side = (UserInput:IsKeyDown(Enum.KeyCode.D) and 1 or 0)
        - (UserInput:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
        + STATE.touch.right - STATE.touch.left
    local vert = (UserInput:IsKeyDown(Enum.KeyCode.Space) and 1 or 0)
        - ((UserInput:IsKeyDown(Enum.KeyCode.LeftControl) or UserInput:IsKeyDown(Enum.KeyCode.LeftShift)) and 1 or 0)
        + STATE.touch.up - STATE.touch.down

    local dir = cam.CFrame.LookVector * fwd
        + cam.CFrame.RightVector * side
        + Vector3.new(0, 1, 0) * vert

    if dir.Magnitude > 0 then
        dir = dir.Unit
    end

    pcall(function()
        bv.Velocity = dir * CONFIG.flySpeed
        bg.CFrame = cam.CFrame
    end)
end

local function refreshShadows()
    local base = STATE.baseShadows
    if base == nil then base = Lighting.GlobalShadows end
    Lighting.GlobalShadows = base ~= false
        and not (STATE.fullbrightOn or STATE.perfOn)
end

local function applyLighting(on)
    STATE.fullbrightOn = on == true
    if on then
        if not STATE.savedLighting then
            STATE.savedLighting = {
                Brightness = Lighting.Brightness,
                Ambient = Lighting.Ambient,
                OutdoorAmbient = Lighting.OutdoorAmbient,
                FogEnd = Lighting.FogEnd,
                FogStart = Lighting.FogStart,
                ClockTime = Lighting.ClockTime,
            }
        end
        Lighting.Brightness = 3
        Lighting.Ambient = Color3.fromRGB(170, 170, 170)
        Lighting.OutdoorAmbient = Color3.fromRGB(150, 150, 150)
        Lighting.FogEnd = 100000
        Lighting.FogStart = 0
        Lighting.ClockTime = 14
    elseif STATE.savedLighting then
        local s = STATE.savedLighting
        pcall(function()
            Lighting.Brightness = s.Brightness
            Lighting.Ambient = s.Ambient
            Lighting.OutdoorAmbient = s.OutdoorAmbient
            Lighting.FogEnd = s.FogEnd
            Lighting.FogStart = s.FogStart
            Lighting.ClockTime = s.ClockTime
        end)
        STATE.savedLighting = nil
    end
    refreshShadows()
end

local function applyPerf(on)
    STATE.perfOn = on == true
    if on then
        for _, d in ipairs(workspace:GetDescendants()) do
            if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke")
                or d:IsA("Fire") or d:IsA("Beam") or d:IsA("Sparkles") then
                if STATE.savedFx[d] == nil then
                    STATE.savedFx[d] = d.Enabled
                end
                pcall(function() d.Enabled = false end)
            end
        end
    else
        for obj, was in pairs(STATE.savedFx) do
            if obj and obj.Parent then
                pcall(function() obj.Enabled = was end)
            end
        end
        STATE.savedFx = {}
    end
    refreshShadows()
end

local function applyFov()
    local cam = workspace.CurrentCamera
    if cam then cam.FieldOfView = CONFIG.fov end
end

local function applyGravity(on)
    if on then
        workspace.Gravity = CONFIG.gravity
    else
        workspace.Gravity = STATE.origGravity or 196.2
    end
end

-- ============================================================
--  TOOL HELPERS
-- ============================================================

local function findTool(words)
    local containers = { LP:FindFirstChild("Backpack"), getChar() }
    for _, container in ipairs(containers) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") then
                    if matches(tool.Name, words) then
                        return tool
                    end
                end
            end
        end
    end
    return nil
end

local function equipTool(tool)
    local hum = getHum()
    if not (hum and tool and tool.Parent) then return false end
    if tool.Parent == getChar() then return true end
    local ok = pcall(function() hum:EquipTool(tool) end)
    return ok
end

local function findBestWeapon()
    local containers = { LP:FindFirstChild("Backpack"), getChar() }
    local best, bestScore = nil, 0
    for _, container in ipairs(containers) do
        if container then
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") then
                    local lower = string.lower(tool.Name)
                    local score = 0
                    for _, w in ipairs(WEAPON_WORDS) do
                        if lower:find(w, 1, true) then score = score + 10 end
                    end
                    if score > bestScore then
                        best, bestScore = tool, score
                    end
                end
            end
        end
    end
    return best
end

-- ============================================================
--  COMBAT
-- ============================================================

local function applyHitbox()
    if STATE.toggles.hitboxOn then
        for _, n in ipairs(STATE.npcs) do
            local hrp = n.model and n.model.Parent
                and n.model:FindFirstChild("HumanoidRootPart") or nil
            if hrp and not STATE.hitboxSaved[hrp] then
                STATE.hitboxSaved[hrp] = hrp.Size
                pcall(function()
                    hrp.Size = Vector3.new(CONFIG.hitboxSize, CONFIG.hitboxSize, CONFIG.hitboxSize)
                end)
            end
        end
    else
        for part, size in pairs(STATE.hitboxSaved) do
            if part and part.Parent then
                pcall(function() part.Size = size end)
            end
        end
        STATE.hitboxSaved = {}
    end
end

local function updateAim()
    if not STATE.toggles.aimOn then return end
    local target = getNearestTarget(CONFIG.aimRange, CONFIG.auraTargets)
    if not target then return end
    local cam = workspace.CurrentCamera
    if not cam then return end
    local look = target.pos + Vector3.new(0, 1.2, 0)
    pcall(function()
        cam.CFrame = CFrame.lookAt(cam.CFrame.Position, look)
    end)
end

local auraWarnAt = 0
local function updateAura()
    if not STATE.toggles.auraOn then return end
    local target = getNearestTarget(CONFIG.auraRange, CONFIG.auraTargets)
    if not target then return end

    if STATE.toggles.autoEquip then
        local weapon = findBestWeapon()
        if weapon then equipTool(weapon) end
    end

    local root = getRoot()
    if root and not STATE.toggles.flyOn then
        local flat = Vector3.new(target.pos.X, root.Position.Y, target.pos.Z)
        if (flat - root.Position).Magnitude > 0.1 then
            pcall(function() root.CFrame = CFrame.lookAt(root.Position, flat) end)
        end
    end

    local ch = getChar()
    local tool = ch and ch:FindFirstChildOfClass("Tool")
    if tool then
        pcall(function() tool:Activate() end)
    elseif now() - auraWarnAt > 8 then
        auraWarnAt = now()
        log("kill aura: equip a weapon (or enable Auto Equip)", true)
    end
end

local function updateDodge()
    if not STATE.toggles.autoDodgeOn or STATE.toggles.flyOn then return end
    local target = getNearestTarget(CONFIG.dodgeRange, "NPCs")
    if not target then return end
    local hum, root = getHum(), getRoot()
    if not (hum and root) then return end
    local away = root.Position - target.pos
    away = Vector3.new(away.X, 0, away.Z)
    if away.Magnitude < 0.1 then away = Vector3.new(1, 0, 0) end
    local dest = root.Position + away.Unit * 14
    pcall(function()
        hum:MoveTo(dest)
        if hum.FloorMaterial ~= Enum.Material.Air then hum.Jump = true end
    end)
end

-- ============================================================
--  INTERACTION / AUTOMATION
-- ============================================================

local function firePrompt(prompt)
    if not prompt or not prompt.Parent then return false end
    local ok = pcall(function() prompt:InputHoldBegin() end)
    if not ok then return false end
    local hold = tonumber(prompt.HoldDuration) or 0
    STATE.promptBusyUntil = now() + math.max(hold, 0.05) + 0.18
    task.delay(math.max(hold, 0.05) + 0.08, function()
        pcall(function() prompt:InputHoldEnd() end)
    end)
    STATE.lastPrompt = prompt
    STATE.lastPromptAt = now()
    return true
end

local function fireClick(detector)
    if not detector then return false end
    if fireclickdetector then
        pcall(fireclickdetector, detector)
        return true
    end
    return false
end

local function touchPart(part)
    if not firetouchinterest then return false end
    local root = getRoot()
    if not (root and part) then return false end
    pcall(firetouchinterest, root, part, 0)
    task.delay(0.09, function()
        pcall(firetouchinterest, root, part, 1)
    end)
    return true
end

local function moveTo(pos)
    local hum = getHum()
    if hum then
        pcall(function() hum:MoveTo(pos) end)
    end
end

local function tryPrompt(entry, radius, walk)
    if not entry then return false end
    local pivot = getPivot()
    local dist = (entry.pos - pivot).Magnitude
    if dist > radius then
        if walk and STATE.toggles.questWalk then moveTo(entry.pos) end
        return false
    end
    if dist > 7 and walk and STATE.toggles.questWalk then
        moveTo(entry.pos)
        return false
    end
    if firePrompt(entry.prompt) then
        STATE.lastAction = now()
        return true
    end
    return false
end

local function collectItem(entry)
    if not entry then return false end
    local pivot = getPivot()
    local dist = (entry.pos - pivot).Magnitude

    if entry.prompt and dist <= 10 then
        if firePrompt(entry.prompt) then
            STATE.lastAction = now()
            return true
        end
    end
    if entry.cd and dist <= 12 then
        if fireClick(entry.cd) then
            STATE.lastAction = now()
            return true
        end
    end

    if dist <= 5 then
        if touchPart(entry.part) then
            STATE.lastAction = now()
            return true
        end
        return false
    end

    if STATE.toggles.collectTp then
        local dir = (pivot - entry.pos)
        dir = Vector3.new(dir.X, 0, dir.Z)
        if dir.Magnitude < 0.1 then dir = Vector3.new(0, 0, 1) end
        teleportToPos(entry.pos + dir.Unit * 2.2)
        task.delay(0.15, function() touchPart(entry.part) end)
        STATE.lastAction = now()
        return true
    end

    if STATE.toggles.questWalk then
        moveTo(entry.pos)
    end
    return false
end

local function isQuestPrompt(p)
    local lower = string.lower(p.text)
    if STATE.toggles.skipGuest and lower:find("guest", 1, true) then
        return false
    end
    for _, w in ipairs(QUEST_BLOCK) do
        if lower:find(w, 1, true) then return false end
    end
    return true
end

local function runAutoStep()
    if now() < (STATE.promptBusyUntil or 0) then return end
    if now() - STATE.lastAction < CONFIG.questPace then return end

    if STATE.toggles.autoUpgradeOn then
        local entry = findNearestPrompt(function(p)
            return matches(p.text, UPGRADE_WORDS) and not matches(p.text, { "sell" })
        end, 80)
        if tryPrompt(entry, 80, true) then return end
    end

    if STATE.toggles.autoReviveOn then
        local entry = findNearestPrompt(function(p)
            return matches(p.text, REVIVE_WORDS)
        end, 80)
        if tryPrompt(entry, 80, true) then return end
    end

    if STATE.toggles.autoRecruitOn then
        local entry = findNearestPrompt(function(p)
            return matches(p.text, RECRUIT_WORDS) and not matches(p.text, REVIVE_WORDS)
        end, 100)
        if tryPrompt(entry, 100, true) then return end
    end

    if STATE.toggles.autoQuestOn then
        local entry = findNearestPrompt(isQuestPrompt, 220)
        if tryPrompt(entry, 220, true) then return end
    end

    if STATE.toggles.autoCollectOn then
        local entry = findNearestItem(nil, 220)
        if collectItem(entry) then return end
    end
end

-- ============================================================
--  AUTO HEAL / DIALOGUE / ANTI-AFK
-- ============================================================

local function fullHeal()
    local hum = getHum()
    if not (hum and hum.Health > 0) then return false end
    pcall(function() hum.Health = hum.MaxHealth end)
    local tool = findTool(HEAL_WORDS)
    if tool then
        task.spawn(function()
            equipTool(tool)
            task.wait(0.12)
            pcall(function() tool:Activate() end)
        end)
    end
    return true
end

local function tryHeal()
    if not STATE.toggles.autoHealOn then return end
    local hum = getHum()
    if not (hum and hum.Health > 0) then return end
    if hum.Health / math.max(hum.MaxHealth, 1) >= (CONFIG.healThreshold / 100) then return end
    if now() - STATE.lastHeal < CONFIG.healCooldown then return end

    STATE.lastHeal = now()
    local tool = findTool(HEAL_WORDS)
    if tool then
        task.spawn(function()
            equipTool(tool)
            task.wait(0.12)
            pcall(function() tool:Activate() end)
        end)
    end

    local entry = findNearestPrompt(function(p)
        return matches(p.text, HEAL_WORDS)
    end, 24)
    if entry then firePrompt(entry.prompt) end
end

local function tryDialogue()
    if not STATE.toggles.autoDialogOn then return end
    if now() - STATE.lastDialogue < 0.7 then return end

    local playerGui = LP:FindFirstChild("PlayerGui")
    if not playerGui then return end

    for _, btn in ipairs(playerGui:GetDescendants()) do
        if (btn:IsA("TextButton") or btn:IsA("ImageButton")) and btn.Visible then
            if not btn:IsDescendantOf(gui) then
                local rawText = btn:IsA("TextButton") and btn.Text or ""
                local text = string.lower(tostring(rawText))
                if #text > 0 and matches(text, DIALOG_WORDS) and not matches(text, DIALOG_BLOCK) then
                    local size = btn.AbsoluteSize
                    if size.X > 4 and size.Y > 4 then
                        STATE.lastDialogue = now()
                        if firesignal then
                            pcall(firesignal, btn.MouseButton1Click)
                        else
                            pcall(function()
                                VirtualUser:CaptureController()
                                VirtualUser:ClickButton1(btn.AbsolutePosition + size / 2)
                            end)
                        end
                        return
                    end
                end
            end
        end
    end
end

local function antiAfkTick()
    if not STATE.toggles.antiAfkOn then return end
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton1(Vector2.new(0, 0))
    end)
end

connect(LP.Idled, antiAfkTick)

-- ============================================================
--  TELEPORT ACTIONS
-- ============================================================

local function tpNearestPrompt()
    refreshWorld()
    local entry, dist = findNearestPrompt(nil, 2000)
    if entry then
        teleportToPos(entry.pos)
        toast("Teleport", "Quest object (" .. round(dist) .. "m)", 1.6, "ok")
    else
        toast("Teleport", "No interaction prompts found", 2, "warn")
        log("no ProximityPrompt in workspace - press SCAN", true)
    end
end

local function tpNearestNpc()
    refreshWorld()
    local target = getNearestTarget(3000, "NPCs")
    if not target then
        for _, n in ipairs(STATE.npcs) do
            if n.root and n.root.Parent then
                target = n
                break
            end
        end
    end
    if target then
        teleportToPos(target.pos)
        toast("Teleport", "Nearest NPC: " .. target.name, 1.6, "ok")
    else
        toast("Teleport", "No NPCs detected", 2, "warn")
    end
end

local function tpNearestItem()
    refreshWorld()
    local entry = findNearestItem(nil, 3000)
    if entry then
        teleportToPos(entry.pos)
        toast("Teleport", "Item: " .. entry.name, 1.6, "ok")
    else
        toast("Teleport", "No items detected", 2, "warn")
    end
end

local function findPlace(words)
    local best, bestScore = nil, 0
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("BasePart") then
            local name = string.lower(d.Name)
            local hit = false
            for _, w in ipairs(words) do
                if name:find(w, 1, true) then hit = true; break end
            end
            if hit then
                local score = d.Size.Magnitude
                if score > bestScore then
                    best, bestScore = d, score
                end
            end
        end
    end
    return best
end

local function tpPlace(words, label)
    local part = findPlace(words)
    if part then
        teleportToPos(part.Position + Vector3.new(0, 4, 0))
        toast("Teleport", label or "Location found", 1.6, "ok")
    else
        toast("Teleport", (label or "Location") .. " not found", 2, "warn")
        log("location not found: " .. table.concat(words, ", "), true)
    end
end

local function tpNpcName(words, label)
    refreshWorld()
    for _, n in ipairs(STATE.npcs) do
        if matches(n.name, words) then
            teleportToPos(n.pos)
            toast("Teleport", label or n.name, 1.6, "ok")
            return
        end
    end
    toast("Teleport", (label or "NPC") .. " not found", 2, "warn")
    log("npc not found: " .. table.concat(words, ", "), true)
end

local function tpNearestPlayer()
    local myRoot = getRoot()
    if not myRoot then return end
    local best, bestD = nil, nil
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and plr.Character then
            local root = plr.Character:FindFirstChild("HumanoidRootPart")
            if root then
                local d = (root.Position - myRoot.Position).Magnitude
                if bestD == nil or d < bestD then best, bestD = root, d end
            end
        end
    end
    if best then
        teleportToPos(best.Position + Vector3.new(0, 0, 3))
        toast("Teleport", "Nearest player", 1.4, "ok")
    else
        toast("Teleport", "No other players", 1.8, "warn")
    end
end

local function tpSpawn()
    local spawnPart = nil
    local folder = workspace:FindFirstChild("Spawns")
    if folder then
        spawnPart = folder:FindFirstChildWhichIsA("SpawnLocation", true)
    end
    if not spawnPart then
        spawnPart = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
    end
    if spawnPart then
        teleportToPos(spawnPart.Position + Vector3.new(0, 4, 0))
        toast("Teleport", "Spawn / lobby", 1.4, "ok")
    else
        toast("Teleport", "No spawn found - rejoining is safer", 2, "warn")
    end
end

local function interactNearest()
    refreshWorld()
    local entry, dist = findNearestPrompt(isQuestPrompt, 800)
    if not entry then
        toast("Interact", "No safe objective prompt found", 2.2, "warn")
        log("interact: no matching prompt - press SCAN", true)
        return
    end
    if dist > 9 then
        teleportToPos(entry.pos)
        task.wait(0.28)
    end
    if firePrompt(entry.prompt) then
        toast("Interact", entry.text, 2, "ok")
    else
        toast("Interact", "Prompt did not accept input", 2.2, "warn")
    end
end

local function claimRole(word)
    refreshWorld()
    local entry = findNearestPrompt(function(p)
        return string.lower(p.text):find(word, 1, true) ~= nil
            or string.lower(p.name):find(word, 1, true) ~= nil
    end, 3000)
    if not entry then
        local target = nil
        for _, item in ipairs(STATE.items) do
            if string.lower(item.name):find(word, 1, true) then
                target = item
                break
            end
        end
        if target then
            teleportToPos(target.pos)
            task.wait(0.45)
            local fired = false
            if target.prompt then
                fired = firePrompt(target.prompt)
            elseif target.cd then
                fired = fireClick(target.cd)
            end
            if not fired then touchPart(target.part) end
            toast("Role", "Claiming " .. word, 2, "ok")
            return
        end
        toast("Role", "No '" .. word .. "' prompt found", 2.4, "warn")
        log("role prompt not found: " .. word .. " (press SCAN)", true)
        return
    end
    teleportToPos(entry.pos)
    task.wait(0.45)
    firePrompt(entry.prompt)
    toast("Role", "Claiming " .. word, 2, "ok")
end

-- ============================================================
--  SERVER
-- ============================================================

local function rejoin()
    toast("Server", "Rejoining...", 2, "ok")
    task.delay(0.4, function()
        pcall(function() Teleport:Teleport(game.PlaceId, LP) end)
    end)
end

local function httpGet(url)
    local ok, res = pcall(function() return game:HttpGet(url, true) end)
    if ok and type(res) == "string" and #res > 0 then return res end
    if request then
        local ok2, res2 = pcall(request, { Url = url, Method = "GET" })
        if ok2 and type(res2) == "string" and #res2 > 0 then return res2 end
    end
    return nil
end

local function serverHop()
    toast("Server", "Finding a fresh server...", 2, "ok")
    task.spawn(function()
        local url = "https://games.roblox.com/v1/games/" .. tostring(game.PlaceId)
            .. "/servers/Public?sortOrder=Asc&limit=100"
        local body = httpGet(url)
        if not body then
            log("server hop: HTTP request blocked by executor", true)
            return
        end
        local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
        if not ok or type(data) ~= "table" or type(data.data) ~= "table" then
            log("server hop: bad server list", true)
            return
        end
        local pool = {}
        for _, s in ipairs(data.data) do
            if s.id and s.playing and s.maxPlayers
                and s.playing < s.maxPlayers and s.id ~= game.JobId then
                table.insert(pool, s.id)
            end
        end
        if #pool == 0 then
            log("server hop: no open servers", true)
            return
        end
        local pick = pool[math.random(1, #pool)]
        local ok2 = pcall(function()
            Teleport:TeleportToPlaceInstance(game.PlaceId, pick, LP)
        end)
        if ok2 then
            toast("Server", "Hopping...", 2, "ok")
        else
            log("server hop teleport failed", true)
        end
    end)
end

local function copyJobId()
    local id = game.JobId
    if id == nil or id == "" then
        log("job id is empty (private/studio server)", true)
        return
    end
    if setclipboard then
        pcall(setclipboard, id)
        toast("Server", "Job ID copied", 1.6, "ok")
    else
        log("job id: " .. tostring(id))
        toast("Server", "No clipboard - see log", 2, "warn")
    end
end

local function respawn()
    local hum = getHum()
    if hum then
        pcall(function() hum.Health = 0 end)
    end
end

-- ============================================================
--  SCANNER / DIAGNOSTICS
-- ============================================================

local function scanRemotes()
    local list = {}
    local containers = { Replicated, workspace }
    for _, container in ipairs(containers) do
        for _, d in ipairs(container:GetDescendants()) do
            if d:IsA("RemoteEvent") or d:IsA("RemoteFunction")
                or d:IsA("UnreliableRemoteEvent") then
                table.insert(list, d)
            end
        end
    end
    STATE.remotes = list
    return list
end

local function doScan()
    refreshWorld()
    scanRemotes()

    local lines = {}
    local function add(text) table.insert(lines, tostring(text)) end

    add("=== RiotHub Break In 2 scan v1.0 ===")
    add("place=" .. tostring(game.PlaceId) .. " job=" .. tostring(game.JobId))
    add("players=" .. tostring(#Players:GetPlayers()) .. " npcs=" .. tostring(#STATE.npcs)
        .. " prompts=" .. tostring(#STATE.prompts) .. " items=" .. tostring(#STATE.items)
        .. " remotes=" .. tostring(#STATE.remotes))

    add("-- remotes --")
    for i, r in ipairs(STATE.remotes) do
        if i > 70 then add("...") break end
        add(r:GetFullName() .. " [" .. r.ClassName .. "]")
    end

    add("-- prompts --")
    for i, p in ipairs(STATE.prompts) do
        if i > 45 then add("...") break end
        add(tostring(p.name) .. " :: " .. tostring(p.text))
    end

    add("-- npcs --")
    for i, n in ipairs(STATE.npcs) do
        if i > 30 then add("...") break end
        add(tostring(n.name) .. " :: hp " .. tostring(round(n.hum.Health))
            .. (n.friendly and " friendly" or "") .. (n.boss and " boss" or ""))
    end

    add("-- items --")
    for i, it in ipairs(STATE.items) do
        if i > 30 then add("...") break end
        add(tostring(it.name) .. (it.prompt and " [prompt]" or "") .. (it.cd and " [click]" or ""))
    end

    add("-- backpack --")
    local bp = LP:FindFirstChild("Backpack")
    if bp then
        for _, t in ipairs(bp:GetChildren()) do
            if t:IsA("Tool") then add(t.Name) end
        end
    end

    local report = table.concat(lines, "\n")
    print(report)

    if setclipboard then
        pcall(setclipboard, report)
    end
    if writefile then
        pcall(writefile, "RiotHub_BI2_scan.txt", report)
    end

    log("SCAN: " .. #STATE.remotes .. " remotes, " .. #STATE.prompts .. " prompts, "
        .. #STATE.npcs .. " NPCs, " .. #STATE.items .. " items")
    for i = 1, math.min(#STATE.remotes, 12) do
        log("remote: " .. STATE.remotes[i]:GetFullName())
    end
    for i = 1, math.min(#STATE.prompts, 10) do
        log("prompt: " .. STATE.prompts[i].text)
    end

    if setclipboard then
        toast("Scan complete", "Report copied to clipboard", 2.4, "ok")
    else
        toast("Scan complete", "Open LOG + for the report", 2.4, "ok")
    end
end

-- ============================================================
--  CONFIG / UNLOAD
-- ============================================================

local saveQueued = false

local function saveConfigNow()
    if not writefile then return false end
    local ok = pcall(function()
        writefile(CONFIG_FILE, HttpService:JSONEncode(CONFIG))
    end)
    if ok then
        flash("config saved")
    else
        log("config save failed", true)
    end
    return ok
end

queueSave = function()
    if saveQueued then return end
    saveQueued = true
    task.delay(1.2, function()
        saveQueued = false
        saveConfigNow()
    end)
end

local function panicReset()
    local ids = {
        "flyOn", "noclipOn", "infJumpOn", "speedOn", "lowGravOn",
        "auraOn", "aimOn", "hitboxOn", "autoDodgeOn", "autoEquip",
        "autoQuestOn", "autoCollectOn", "autoUpgradeOn", "autoRecruitOn",
        "autoReviveOn", "autoDialogOn",
        "playerEsp", "npcEsp", "itemEsp", "promptEsp", "espWalls", "tracers",
        "fullbrightOn", "fpsBoostOn", "antiFlingOn", "godOn", "autoHealOn",
    }
    for _, id in ipairs(ids) do
        if STATE.switches[id] then
            pcall(function() STATE.switches[id].Set(false) end)
        end
    end

    pcall(function() setFly(false) end)
    pcall(function() setNoclip(false) end)
    pcall(function() applyPerf(false) end)
    pcall(function() applyLighting(false) end)
    STATE.toggles.hitboxOn = false
    pcall(function() applyHitbox() end)

    pcall(function()
        local hum = getHum()
        if hum then
            hum.WalkSpeed = 16
            hum.JumpPower = 50
            hum.PlatformStand = false
        end
        workspace.Gravity = STATE.origGravity or 196.2
    end)

    CONFIG.walkSpeed = 16
    CONFIG.jumpPower = 50
    task.delay(0.3, tpSpawn)
    toast("Panic reset", "Features off, movement restored", 2.4, "warn")
    log("panic reset executed")
end

local unload

local function buildReportShort()
    return "RiotHub BI2 | " .. #STATE.remotes .. " remotes | "
        .. #STATE.prompts .. " prompts | " .. #STATE.npcs .. " NPCs"
end

unload = function()
    if STATE.unloaded then return end
    STATE.unloaded = true

    pcall(function() setFly(false) end)
    pcall(function() setNoclip(false) end)
    pcall(function() applyPerf(false) end)
    pcall(function() applyLighting(false) end)
    pcall(clearTracers)
    STATE.toggles.hitboxOn = false
    pcall(function() applyHitbox() end)

    pcall(function()
        local hum = getHum()
        if hum then
            hum.WalkSpeed = 16
            hum.JumpPower = 50
            hum.PlatformStand = false
        end
    end)
    pcall(function() workspace.Gravity = STATE.origGravity or 196.2 end)
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then cam.FieldOfView = STATE.origFov or 70 end
    end)

    for _, c in ipairs(STATE.conns) do
        pcall(function() c:Disconnect() end)
    end
    STATE.conns = {}

    pcall(function() gui:Destroy() end)
    if _G.RiotHub_BI2_Loaded == unload then
        _G.RiotHub_BI2_Loaded = nil
    end
    print("[RiotHub] Break In 2 hub unloaded")
end

if _G.RiotHub_BI2_Loaded and type(_G.RiotHub_BI2_Loaded) == "function" then
    pcall(_G.RiotHub_BI2_Loaded)
end
_G.RiotHub_BI2_Loaded = unload
-- ============================================================
--  PAGE CONTENT
-- ============================================================

local pageHome   = pages.home
local pagePlayer = pages.player
local pageCombat = pages.combat
local pageAuto   = pages.auto
local pageVisual = pages.visual
local pageTp     = pages.tp
local pageServer = pages.server
local pageConfig = pages.config

local function note(page, text, color)
    return make("TextLabel", {
        Text = text,
        Size = UDim2.new(1, -10, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        Font = Enum.Font.Gotham,
        TextSize = 9,
        TextColor3 = color or THEME.faint,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextWrapped = true,
    }, page)
end

local function quickOn(id)
    local sw = STATE.switches[id]
    if sw then
        sw.Set(true)
        toast("Quick start", "Enabled - see its tab for settings", 1.8, "ok")
    end
end

-- HOME --------------------------------------------------------
section(pageHome, "Quick start")
note(pageHome, "One tap enables the feature with safe defaults. Tune everything in the other tabs.")

buttonRow(pageHome, "Run Objectives", "Auto Quest: walks to prompts and interacts", function()
    quickOn("autoQuestOn")
end, true)

buttonRow(pageHome, "Enable Kill Aura", "Auto Equip + attack nearby hostiles", function()
    quickOn("auraOn")
end)

buttonRow(pageHome, "Show NPC ESP", "Names, distance and health through walls", function()
    quickOn("npcEsp")
end)

buttonRow(pageHome, "Enable Fly", "Opens the touch fly pad", function()
    quickOn("flyOn")
end)

section(pageHome, "Live status")

local cardHolder = make("Frame", {
    Size = UDim2.new(1, -10, 0, 82),
    BackgroundTransparency = 1,
}, pageHome)

local function statCard(col, row, title)
    local card = make("Frame", {
        Size = UDim2.new(0.5, -3, 0, 38),
        Position = UDim2.new(0.5, col == 0 and 0 or 3, 0, row * 42),
        BackgroundColor3 = THEME.card,
        BorderSizePixel = 0,
    }, cardHolder)
    corner(card, 7)
    make("TextLabel", {
        Text = title,
        Size = UDim2.new(1, -12, 0, 12),
        Position = UDim2.new(0, 8, 0, 4),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 8,
        TextColor3 = THEME.faint,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, card)
    local value = make("TextLabel", {
        Text = "-",
        Size = UDim2.new(1, -12, 0, 16),
        Position = UDim2.new(0, 8, 0, 17),
        BackgroundTransparency = 1,
        Font = Enum.Font.Code,
        TextSize = 12,
        TextColor3 = THEME.text,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, card)
    return value
end

STATE.statusRefs.health = statCard(0, 0, "HEALTH")
STATE.statusRefs.speed  = statCard(1, 0, "WALK SPEED")
STATE.statusRefs.npcs   = statCard(0, 1, "NPCS")
STATE.statusRefs.prompts = statCard(1, 1, "OBJECTIVES")

section(pageHome, "Session tools")
buttonRow(pageHome, "Scan Game", "Dumps remotes, prompts, NPCs, items to LOG + clipboard", function()
    task.spawn(doScan)
end, true)
buttonRow(pageHome, "Teleport to Objective", "Nearest ProximityPrompt in the map", function()
    task.spawn(tpNearestPrompt)
end)
buttonRow(pageHome, "Panic Reset", "Everything off, movement restored, teleport to spawn", function()
    panicReset()
end, true)

note(pageHome, "v1.0 EXPERIMENTAL - Break In 2 updates regularly. "
    .. "If a button does nothing, press SCAN and send me the log: "
    .. "it tells me the real prompt/remote names on your build.", THEME.yellow)

-- PLAYER ------------------------------------------------------
section(pagePlayer, "Movement")
toggleRow(pagePlayer, "speedOn", "Speed Override",
    "Keeps your Walk Speed and Jump Power applied after respawns", true, function(v)
    local hum = getHum()
    if hum then
        hum.WalkSpeed = v and CONFIG.walkSpeed or 16
        hum.JumpPower = v and CONFIG.jumpPower or 50
    end
end)
sliderRow(pagePlayer, "Walk Speed", 8, 300, CONFIG.walkSpeed, function(v)
    CONFIG.walkSpeed = v
    if STATE.toggles.speedOn then
        local hum = getHum()
        if hum then hum.WalkSpeed = v end
    end
end)
sliderRow(pagePlayer, "Jump Power", 10, 300, CONFIG.jumpPower, function(v)
    CONFIG.jumpPower = v
    if STATE.toggles.speedOn then
        local hum = getHum()
        if hum then hum.JumpPower = v end
    end
end)

toggleRow(pagePlayer, "flyOn", "Fly", "Camera-relative flight + touch pad", false, function(v)
    setFly(v)
end)
sliderRow(pagePlayer, "Fly Speed", 10, 300, CONFIG.flySpeed, function(v)
    CONFIG.flySpeed = v
end)
toggleRow(pagePlayer, "flyPad", "Fly Pad", "On-screen W/A/S/D + up/down buttons", true, function(v)
    if flyPad then
        flyPad.Visible = v and STATE.toggles.flyOn == true
    end
end)

toggleRow(pagePlayer, "noclipOn", "Noclip", "Walk through walls (collisions restored when off)", false, function(v)
    setNoclip(v)
end)
toggleRow(pagePlayer, "infJumpOn", "Infinite Jump", "Jump again while airborne", false, nil)

toggleRow(pagePlayer, "lowGravOn", "Low Gravity", "Client-side gravity change", false, function(v)
    applyGravity(v)
end)
sliderRow(pagePlayer, "Gravity", 20, 300, CONFIG.gravity, function(v)
    CONFIG.gravity = v
    if STATE.toggles.lowGravOn then workspace.Gravity = v end
end, "g")

section(pagePlayer, "Survival")
toggleRow(pagePlayer, "antiFlingOn", "Anti-Fling", "Cancels extreme horizontal knockback", true, nil)
toggleRow(pagePlayer, "godOn", "God Mode (client)",
    "Refills your own health bar; server damage can still kill", false, nil)
toggleRow(pagePlayer, "autoHealOn", "Auto Heal", "Uses healing tools / heal prompts when low", false, nil)
sliderRow(pagePlayer, "Heal At", 10, 90, CONFIG.healThreshold, function(v)
    CONFIG.healThreshold = v
end, "%")

section(pagePlayer, "Actions")
buttonRow(pagePlayer, "Full Heal", "Refill health and use a healing item if you have one", function()
    if fullHeal() then
        toast("Player", "Health refilled", 1.6, "ok")
    else
        toast("Player", "No living character", 1.8, "warn")
    end
end, true)
buttonRow(pagePlayer, "Reset Character", "Respawn immediately", function()
    respawn()
end)
buttonRow(pagePlayer, "Stop All Movement Hacks", "Turns off fly, noclip, speed overrides", function()
    if STATE.switches.flyOn then STATE.switches.flyOn.Set(false) end
    if STATE.switches.noclipOn then STATE.switches.noclipOn.Set(false) end
    if STATE.switches.lowGravOn then STATE.switches.lowGravOn.Set(false) end
    local hum = getHum()
    if hum then
        hum.WalkSpeed = 16
        hum.JumpPower = 50
    end
    CONFIG.walkSpeed = 16
    CONFIG.jumpPower = 50
    toast("Movement", "Restored to default speeds", 1.8, "ok")
end, true)

-- COMBAT ------------------------------------------------------
section(pageCombat, "Targeting")
toggleRow(pageCombat, "auraOn", "Kill Aura", "Activates your equipped weapon at nearby targets", false, nil)
sliderRow(pageCombat, "Aura Range", 5, 80, CONFIG.auraRange, function(v)
    CONFIG.auraRange = v
end, "studs")
sliderRow(pageCombat, "Attack Delay", 50, 1000, math.floor(CONFIG.auraRate * 1000), function(v)
    CONFIG.auraRate = math.max(v / 1000, 0.05)
end, "ms")
dropdownRow(pageCombat, "Targets", { "NPCs", "Players", "Both" }, CONFIG.auraTargets, function(choice)
    CONFIG.auraTargets = choice
end)
toggleRow(pageCombat, "autoEquip", "Auto Equip", "Picks the best weapon in your backpack", true, nil)

section(pageCombat, "Aim")
toggleRow(pageCombat, "aimOn", "Aim Assist", "Locks the camera onto the nearest target", false, nil)
sliderRow(pageCombat, "Aim Range", 20, 600, CONFIG.aimRange, function(v)
    CONFIG.aimRange = v
end, "studs")
toggleRow(pageCombat, "autoDodgeOn", "Auto Dodge", "Steps away from nearby hostiles", false, nil)
sliderRow(pageCombat, "Dodge Range", 5, 40, CONFIG.dodgeRange, function(v)
    CONFIG.dodgeRange = v
end, "studs")

section(pageCombat, "Hitboxes")
toggleRow(pageCombat, "hitboxOn", "Hitbox Expander", "Enlarges NPC hitboxes locally (client-side)", false, function()
    applyHitbox()
end)
sliderRow(pageCombat, "Hitbox Size", 2, 20, CONFIG.hitboxSize, function(v)
    CONFIG.hitboxSize = v
    if STATE.toggles.hitboxOn then
        for part in pairs(STATE.hitboxSaved) do
            if part and part.Parent then
                pcall(function()
                    part.Size = Vector3.new(v, v, v)
                end)
            end
        end
    end
end, "studs")
note(pageCombat, "Hitbox expansion is visual/client-side; "
    .. "the server may still use the original size for damage.", THEME.faint)

-- AUTO --------------------------------------------------------
section(pageAuto, "Objectives")
buttonRow(pageAuto, "Use Nearest Prompt", "Warps to a safe objective prompt and interacts", function()
    task.spawn(interactNearest)
end, true)
toggleRow(pageAuto, "autoQuestOn", "Auto Quest", "Walks to the nearest prompt and interacts", false, nil)
sliderRow(pageAuto, "Quest Radius", 8, 60, CONFIG.questRadius, function(v)
    CONFIG.questRadius = v
end, "studs")
sliderRow(pageAuto, "Interaction Pace", 100, 1200, math.floor(CONFIG.questPace * 1000), function(v)
    CONFIG.questPace = math.max(v / 1000, 0.1)
end, "ms")
toggleRow(pageAuto, "questWalk", "Walk to Objectives", "Move to prompts that are out of reach", true, nil)
toggleRow(pageAuto, "skipGuest", "Skip Guest Role", "Don't trigger lobby Guest-role prompts", true, nil)

section(pageAuto, "Collecting")
toggleRow(pageAuto, "autoCollectOn", "Auto Collect", "Picks up nearby items, coins and pickups", false, nil)
sliderRow(pageAuto, "Collect Radius", 8, 80, CONFIG.collectRadius, function(v)
    CONFIG.collectRadius = v
end, "studs")
toggleRow(pageAuto, "collectTp", "Teleport Pickup", "Warps onto items without prompts (aggressive)", false, nil)

section(pageAuto, "Progression")
toggleRow(pageAuto, "autoUpgradeOn", "Auto Upgrade", "Buys / triggers stat and tool upgrade prompts", false, nil)
toggleRow(pageAuto, "autoRecruitOn", "Auto Recruit", "Talks to / frees / recruits story NPCs", false, nil)
toggleRow(pageAuto, "autoReviveOn", "Auto Revive", "Uses revive, wake and rescue prompts", false, nil)
toggleRow(pageAuto, "autoDialogOn", "Auto Dialogue", "Clicks Continue / Next / Skip buttons (experimental)", false, nil)

section(pageAuto, "Lobby roles")
buttonRow(pageAuto, "Claim Guest Role", "Finds the Guest prompt in the lobby and claims it", function()
    task.spawn(function() claimRole("guest") end)
end, true)
buttonRow(pageAuto, "Claim Hacker Role", "Finds a Hacker prompt and claims it", function()
    task.spawn(function() claimRole("hacker") end)
end)
note(pageAuto, "Auto Quest intentionally ignores sell / leave / buy prompts. "
    .. "Auto Upgrade handles purchases.", THEME.faint)

-- VISUAL ------------------------------------------------------
section(pageVisual, "ESP")
toggleRow(pageVisual, "playerEsp", "Player ESP", "Teammates and other players", false, function()
    applyEsp()
end)
toggleRow(pageVisual, "npcEsp", "NPC ESP", "Enemies, bosses, teammates and the dog", false, function()
    applyEsp()
end)
toggleRow(pageVisual, "itemEsp", "Item ESP", "Pickups, keys, puzzle parts and coins", false, function()
    applyEsp()
end)
toggleRow(pageVisual, "promptEsp", "Objective ESP", "Labels every ProximityPrompt in the map", false, function()
    applyEsp()
end)
toggleRow(pageVisual, "espWalls", "Through Walls", "ESP draws on top of geometry", false, function()
    applyWallMode()
    applyEsp()
end)
toggleRow(pageVisual, "tracers", "Tracers", "Lines from your camera to hostile NPCs", false, nil)

section(pageVisual, "World")
toggleRow(pageVisual, "fullbrightOn", "Fullbright", "Bright world, no fog, shadows off", false, function(v)
    applyLighting(v)
end)
toggleRow(pageVisual, "fpsBoostOn", "FPS Boost",
    "Disables particles/trails/smoke (existing effects only)", false, function(v)
    applyPerf(v)
end)
sliderRow(pageVisual, "Camera FOV", 40, 120, CONFIG.fov, function(v)
    CONFIG.fov = v
    applyFov()
end, "deg")

section(pageVisual, "Limits")
sliderRow(pageVisual, "Max NPC ESP", 10, 120, CONFIG.espMax, function(v)
    CONFIG.espMax = v
    applyEsp()
end)

-- TELEPORT ----------------------------------------------------
section(pageTp, "Nearest")
buttonRow(pageTp, "Quest Object", "Nearest ProximityPrompt", function()
    task.spawn(tpNearestPrompt)
end, true)
buttonRow(pageTp, "NPC / Enemy", "Nearest hostile or story NPC", function()
    task.spawn(tpNearestNpc)
end)
buttonRow(pageTp, "Item", "Nearest pickup or puzzle part", function()
    task.spawn(tpNearestItem)
end)
buttonRow(pageTp, "Player", "Nearest other player", function()
    tpNearestPlayer()
end)
buttonRow(pageTp, "Spawn / Lobby", "Game spawn location", function()
    task.spawn(tpSpawn)
end)

section(pageTp, "Story locations")
buttonRow(pageTp, "Maintenance Room", "Wire puzzle area", function()
    task.spawn(function() tpPlace({ "maintenance" }, "Maintenance Room") end)
end)
buttonRow(pageTp, "Security Room", "Colour puzzle area", function()
    task.spawn(function() tpPlace({ "security" }, "Security Room") end)
end)
buttonRow(pageTp, "Cafeteria", "Rainbow Pizza / food area", function()
    task.spawn(function() tpPlace({ "cafeteria", "cafe" }, "Cafeteria") end)
end)
buttonRow(pageTp, "Fight Area", "Upstairs wave arena", function()
    task.spawn(function() tpPlace({ "fight" }, "Fight Area") end)
end)
buttonRow(pageTp, "Outside", "Dog rescue / deliveries", function()
    task.spawn(function() tpPlace({ "outside", "yard", "garden" }, "Outside") end)
end)

section(pageTp, "NPC shortcuts")
buttonRow(pageTp, "Scary Mary", "Final boss", function()
    task.spawn(function() tpNpcName({ "mary" }, "Scary Mary") end)
end)
buttonRow(pageTp, "Pizza Boss", "Defeat the pizza boss", function()
    task.spawn(function() tpNpcName({ "pizza" }, "Pizza Boss") end)
end)
buttonRow(pageTp, "Brute", "Wave 3 crowbar brute", function()
    task.spawn(function() tpNpcName({ "brute" }, "Brute") end)
end)
buttonRow(pageTp, "Twado (dog)", "Bring the dog inside", function()
    task.spawn(function() tpNpcName({ "twado", "dog" }, "Twado") end)
end)
buttonRow(pageTp, "Bradley", "Wake up Secret Agent Bradley", function()
    task.spawn(function() tpNpcName({ "bradley" }, "Bradley") end)
end)
buttonRow(pageTp, "Uncle Pete", "He needs help again", function()
    task.spawn(function() tpNpcName({ "pete" }, "Uncle Pete") end)
end)

section(pageTp, "Waypoints")
waypointRow(pageTp, "A")
waypointRow(pageTp, "B")
waypointRow(pageTp, "C")
waypointRow(pageTp, "D")
note(pageTp, "Location buttons match workspace names. If one is not found, "
    .. "the game renamed it - scan and tell me the real name.", THEME.faint)

-- SERVER ------------------------------------------------------
section(pageServer, "Session")
buttonRow(pageServer, "Copy Job ID", "Share or rejoin the same server", function()
    copyJobId()
end)
buttonRow(pageServer, "Rejoin Server", "Teleport back to this place", function()
    rejoin()
end)
buttonRow(pageServer, "Server Hop", "Find a different public server", function()
    serverHop()
end, true)
buttonRow(pageServer, "Respawn", "Kill your character to respawn", function()
    respawn()
end)

section(pageServer, "Automation")
toggleRow(pageServer, "antiAfkOn", "Anti-AFK", "Never idle-kicked while farming", true, nil)
note(pageServer, "Server Hop uses the Roblox public server list through game:HttpGet. "
    .. "If your executor blocks it, the log says so.", THEME.faint)

section(pageServer, "Diagnostics")
buttonRow(pageServer, "Scan Game", "Copy a full report for debugging", function()
    task.spawn(doScan)
end)
buttonRow(pageServer, "Copy Session Log", "Copy the LOG panel contents", function()
    local lines = {}
    for i = #STATE.logLines, 1, -1 do
        table.insert(lines, STATE.logLines[i].text)
    end
    if setclipboard then
        pcall(setclipboard, table.concat(lines, "\n"))
        toast("Log", "Copied", 1.2, "ok")
    else
        toast("Log", "No clipboard support", 1.6, "warn")
    end
end)

-- SETUP -------------------------------------------------------
section(pageConfig, "Interface")
sliderRow(pageConfig, "UI Scale", 70, 130, math.floor(CONFIG.uiScale * 100), function(v)
    CONFIG.uiScale = v / 100
    local fit = math.min((view.X - 8) / winW, (view.Y - 8) / winH)
    uiScale.Scale = math.min(CONFIG.uiScale, fit)
end, "%")
toggleRow(pageConfig, "reduceAnim", "Reduce Animations", "Snappier UI on low-end phones", CONFIG.reduceAnim, function(v)
    CONFIG.reduceAnim = v
end)

section(pageConfig, "Saving")
buttonRow(pageConfig, "Save Config", "Write settings to the executor's folder", function()
    saveConfigNow()
end, true)
note(pageConfig, "Config auto-saves 1.2s after a change when writefile is available.", THEME.faint)

section(pageConfig, "Diagnostics")
buttonRow(pageConfig, "Copy Loadstring", "Copy the one-line Delta command for this hub", function()
    local code = 'loadstring(game:HttpGet("'
        .. 'https://raw.githubusercontent.com/reizure87-create/Fuzzy-Disco-Pl_Scr/main/breakin2.lua'
        .. '"))()'
    if setclipboard then
        pcall(setclipboard, code)
        toast("Setup", "Loadstring copied", 1.8, "ok")
    else
        log("loadstring: " .. code)
        toast("Setup", "No clipboard - check LOG", 2, "warn")
    end
end)
buttonRow(pageConfig, "Scan Game", "Full remotes/prompts/NPCs/items report", function()
    task.spawn(doScan)
end, true)
buttonRow(pageConfig, "Copy Log", "Copy the session log", function()
    local lines = {}
    for i = #STATE.logLines, 1, -1 do
        table.insert(lines, STATE.logLines[i].text)
    end
    if setclipboard then
        pcall(setclipboard, table.concat(lines, "\n"))
        toast("Log", "Copied", 1.2, "ok")
    end
end)

section(pageConfig, "About")
note(pageConfig, "RiotHub x Break In 2 v1.0\n"
    .. "Single file. Keyless. No external libraries. Mobile-first.\n"
    .. "Built from the game's actual story/badge structure: waves, Brute, "
    .. "Scary Mary, Pizza Boss, wire + colour puzzles, team recruitment, "
    .. "dog rescue and stat upgrades.", THEME.dim)
note(pageConfig, "Unload restores lighting, gravity, FOV, collisions and movement.", THEME.faint)
buttonRow(pageConfig, "Unload Hub", "Remove the GUI and restore every override", function()
    unload()
end, true)
-- ============================================================
--  LIVE LOOPS / INIT
-- ============================================================

local function refreshStatus()
    local hum = getHum()
    local refs = STATE.statusRefs

    if refs.health then
        if hum and hum.Health > 0 then
            refs.health.Text = tostring(round(hum.Health)) .. " / " .. tostring(round(hum.MaxHealth))
            refs.health.TextColor3 = hum.Health / math.max(hum.MaxHealth, 1) < 0.35 and THEME.red or THEME.text
        else
            refs.health.Text = "DEAD"
            refs.health.TextColor3 = THEME.red
        end
    end
    if refs.speed then
        refs.speed.Text = hum and tostring(round(hum.WalkSpeed)) or "-"
    end
    if refs.npcs then
        refs.npcs.Text = tostring(#STATE.npcs)
    end
    if refs.prompts then
        refs.prompts.Text = tostring(#STATE.prompts)
    end

    local active = 0
    for _, v in pairs(STATE.toggles) do
        if v == true then active = active + 1 end
    end
    activeLabel.Text = tostring(active) .. " ON"

    statusLabel.Text = "v1.0 | " .. tostring(STATE.fps) .. " fps | "
        .. tostring(#Players:GetPlayers()) .. " plr | "
        .. tostring(#STATE.npcs) .. " npc | "
        .. tostring(#STATE.prompts) .. " obj | "
        .. tostring(#STATE.remotes) .. " rem"
end

-- FPS + per-frame work
local fpsAccum = 0
connect(RunService.RenderStepped, function(dt)
    if STATE.unloaded then return end
    fpsAccum = fpsAccum + dt
    STATE.fpsFrames = STATE.fpsFrames + 1
    if fpsAccum >= 1 then
        STATE.fps = round(STATE.fpsFrames / fpsAccum)
        STATE.fpsFrames = 0
        fpsAccum = 0
    end

    updateAim()
    updateFly()
    updateTracers()
end)

-- movement / survival maintenance
task.spawn(function()
    while not STATE.unloaded do
        task.wait(0.35)
        if not STATE.unloaded then
            local hum = getHum()
            if STATE.toggles.speedOn and hum and hum.Health > 0 and not STATE.toggles.flyOn then
                if hum.WalkSpeed ~= CONFIG.walkSpeed then hum.WalkSpeed = CONFIG.walkSpeed end
                if hum.JumpPower ~= CONFIG.jumpPower then hum.JumpPower = CONFIG.jumpPower end
            end

            if STATE.toggles.infJumpOn and hum and hum.Health > 0 and not STATE.toggles.flyOn then
                if hum.FloorMaterial == Enum.Material.Air
                    and hum:GetState() == Enum.HumanoidStateType.Freefall then
                    pcall(function()
                        hum:ChangeState(Enum.HumanoidStateType.Jumping)
                    end)
                end
            end

            if STATE.toggles.noclipOn then
                local ch = getChar()
                if ch then
                    for _, p in ipairs(characterParts(ch)) do
                        if p.CanCollide then
                            STATE.noclipSaved[p] = true
                            pcall(function() p.CanCollide = false end)
                        end
                    end
                end
            elseif next(STATE.noclipSaved) then
                setNoclip(false)
            end

            if STATE.toggles.antiFlingOn and not STATE.toggles.flyOn then
                local root = getRoot()
                if root then
                    local v = root.AssemblyLinearVelocity
                    local horiz = Vector3.new(v.X, 0, v.Z).Magnitude
                    if horiz > 350 then
                        pcall(function()
                            root.AssemblyLinearVelocity = Vector3.new(0, math.min(v.Y, 60), 0)
                        end)
                    end
                end
            end

            if STATE.toggles.godOn then
                local h = getHum()
                if h and h.Health > 0 and h.Health < h.MaxHealth then
                    pcall(function() h.Health = h.MaxHealth end)
                end
            end
        end
    end
end)

-- world scan + ESP refresh
task.spawn(function()
    while not STATE.unloaded do
        task.wait(3)
        if not STATE.unloaded then
            refreshWorld()

            local anyEsp = STATE.toggles.playerEsp or STATE.toggles.npcEsp
                or STATE.toggles.itemEsp or STATE.toggles.promptEsp
            if anyEsp then applyEsp() end
            if STATE.toggles.hitboxOn then applyHitbox() end

            if STATE.toggles.fullbrightOn then applyLighting(true) end
            if STATE.toggles.fpsBoostOn then applyPerf(true) end
        end
    end
end)

-- lightweight ESP distance refresh
task.spawn(function()
    while not STATE.unloaded do
        task.wait(1.1)
        if not STATE.unloaded then
            local anyEsp = STATE.toggles.playerEsp or STATE.toggles.npcEsp
                or STATE.toggles.itemEsp or STATE.toggles.promptEsp
            if anyEsp then applyEsp() end
        end
    end
end)

-- auto objectives
task.spawn(function()
    while not STATE.unloaded do
        task.wait(0.2)
        if not STATE.unloaded then runAutoStep() end
    end
end)

-- kill aura (dynamic pace)
task.spawn(function()
    while not STATE.unloaded do
        task.wait(math.max(CONFIG.auraRate or 0.22, 0.05))
        if not STATE.unloaded and STATE.toggles.auraOn then updateAura() end
    end
end)

-- dodge
task.spawn(function()
    while not STATE.unloaded do
        task.wait(0.35)
        if not STATE.unloaded then updateDodge() end
    end
end)

-- heal
task.spawn(function()
    while not STATE.unloaded do
        task.wait(0.5)
        if not STATE.unloaded then tryHeal() end
    end
end)

-- dialogue
task.spawn(function()
    while not STATE.unloaded do
        task.wait(0.8)
        if not STATE.unloaded then tryDialogue() end
    end
end)

-- anti-afk safety net
task.spawn(function()
    while not STATE.unloaded do
        task.wait(55)
        if not STATE.unloaded then antiAfkTick() end
    end
end)

-- status bar
task.spawn(function()
    while not STATE.unloaded do
        task.wait(1)
        if not STATE.unloaded then refreshStatus() end
    end
end)

-- ============================================================
--  CHARACTER / PLAYER HOOKS
-- ============================================================

local function onCharacter(ch)
    STATE.flyBV = nil
    STATE.flyBG = nil
    STATE.noclipSaved = {}
    STATE.hitboxSaved = {}

    if STATE.toggles.flyOn then
        task.delay(0.7, function()
            if not STATE.unloaded and STATE.toggles.flyOn then startFly() end
        end)
    end
    if STATE.toggles.noclipOn then
        task.delay(0.3, function()
            if not STATE.unloaded and STATE.toggles.noclipOn then setNoclip(true) end
        end)
    end

    local hum = ch:WaitForChild("Humanoid", 5)
    if hum then
        connect(hum.Died, function()
            stopFly()
        end)
    end

    task.delay(0.8, function()
        if not STATE.unloaded then
            local anyEsp = STATE.toggles.playerEsp or STATE.toggles.npcEsp
            if anyEsp then applyEsp() end
        end
    end)
end

connect(LP.CharacterAdded, onCharacter)
if LP.Character then onCharacter(LP.Character) end

connect(Players.PlayerAdded, function()
    task.delay(1.2, function()
        if not STATE.unloaded and STATE.toggles.playerEsp then applyEsp() end
    end)
end)

connect(Players.PlayerRemoving, function(plr)
    local unit = STATE.espPlayers[plr]
    if unit then
        if unit.hl then unit.hl:Destroy() end
        if unit.bb then unit.bb:Destroy() end
        STATE.espPlayers[plr] = nil
    end
    local line = STATE.tracers[plr]
    if line then
        pcall(function() line:Remove() end)
        STATE.tracers[plr] = nil
    end
end)

-- keep FPS boost applied to effects created after the toggle
connect(workspace.DescendantAdded, function(d)
    if STATE.unloaded or not STATE.toggles.fpsBoostOn then return end
    if d:IsA("ParticleEmitter") or d:IsA("Trail") or d:IsA("Smoke")
        or d:IsA("Fire") or d:IsA("Beam") or d:IsA("Sparkles") then
        if STATE.savedFx[d] == nil then
            STATE.savedFx[d] = d.Enabled
        end
        pcall(function() d.Enabled = false end)
    end
end)

-- ============================================================
--  BOOT
-- ============================================================

refreshWorld()
scanRemotes()
applyFov()
applyEsp()
refreshStatus()
showTab("home")

log("RiotHub Break In 2 v1.0 loaded")
log(buildReportShort())
log("tip: press SCAN and send the LOG output if a feature does nothing on your build")

if #STATE.remotes == 0 then
    log("no remotes detected yet - wait for the game to load, then SCAN", true)
end
if #STATE.prompts == 0 then
    log("no ProximityPrompts yet - join a round, then press SCAN")
end

toast("RiotHub v1.0", "Break In 2 loaded - tap SCAN if anything fails", 3.2, "ok")
toast("Mobile tip", "The R button hides/shows the hub. Fly pad appears when Fly is ON.", 3.6)

print("[RiotHub] Break In 2 v1.0 loaded | " .. buildReportShort())
