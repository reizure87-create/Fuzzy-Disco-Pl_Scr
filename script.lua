-- Prison Life | Ultimate Aesthetic Hub v3 (Complete Edition)
-- Features: Gun Giver, Refined Mods, Glass UI, Full ESP, Aim, Fly, Teleports

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local WS = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local LP = Players.LocalPlayer

-- ----------------------------------------------------------------------------
-- STATE
-- ----------------------------------------------------------------------------
local state = {
    -- Combat
    silentAim = false, aimbot = false, fovCircle = false, aimbotFov = 120,
    hitboxExpander = false, killAura = false, arrestAura = false, autoArrest = false,
    -- Visuals
    esp = false, chams = false, fullbright = false, noFog = false,
    -- Movement
    fly = false, noclip = false, walkSpeed = 16, jumpPower = 50,
    -- Misc
    autoMod = false, antiTaze = false, infStamina = false, teamLock = false, lockTeam = nil,
    virtualKeys = {}, hitboxSize = 8, auraRange = 25
}

local R = {}
local espCache = {}
local lastAction = {}
local originalLighting = { Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient, FogEnd = Lighting.FogEnd, Brightness = Lighting.Brightness }

-- ----------------------------------------------------------------------------
-- REMOTES & HELPERS
-- ----------------------------------------------------------------------------
local function waitFor(parent, name, timeout)
    local elapsed = 0
    repeat
        local child = parent:FindFirstChild(name)
        if child then return child end
        task.wait(0.1); elapsed = elapsed + 0.1
    until elapsed >= (timeout or 15)
    return nil
end

task.spawn(function()
    local wr = waitFor(WS, "Remote", 15)
    local rsRemotes = RS:FindFirstChild("Remotes")
    R.team = wr and wr:FindFirstChild("TeamEvent")
    R.item = wr and wr:FindFirstChild("ItemHandler")
    R.loadChar = wr and wr:FindFirstChild("LoadCharacter")
    R.arrest = (rsRemotes and rsRemotes:FindFirstChild("ArrestPlayer")) or (wr and wr:FindFirstChild("ArrestPlayer"))
    R.melee = RS:FindFirstChild("meleeEvent") or (rsRemotes and rsRemotes:FindFirstChild("meleeEvent"))
end)

local parentGui = gethui and gethui() or LP:WaitForChild("PlayerGui")
local function getHRP(plr) return plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") end
local function getHum(plr) return plr.Character and plr.Character:FindFirstChildOfClass("Humanoid") end
local function teamName(plr) return plr.TeamColor and plr.TeamColor.Name or "" end
local function isEnemy(plr) return plr ~= LP and teamName(plr) ~= "" and teamName(plr) ~= teamName(LP) end
local function isCriminal(plr) return teamName(plr) == "Really red" end

local function tpTo(target, offset)
    local my, their = getHRP(LP), getHRP(target)
    if my and their then my.CFrame = their.CFrame * (offset or CFrame.new(0, 0, 2.5)) return true end
    return false
end

local function setTeam(colorName) if R.team then pcall(function() R.team:FireServer(colorName) end) end end

local function respawn()
    if R.loadChar then pcall(function() R.loadChar:FireServer() end)
    else pcall(function() LP:LoadCharacter() end) end
end

local function punch(target, times)
    if not R.melee then return end
    for _ = 1, (times or 6) do pcall(function() R.melee:FireServer(target) end); task.wait(0.03) end
end

local function arrestTarget(target)
    if not target or target == LP or (os.clock() - (lastAction[target] or 0) < 1) then return end
    lastAction[target] = os.clock()
    tpTo(target, CFrame.new(0, 0, 2.2)); task.wait(0.06)
    if R.arrest then
        pcall(function() if R.arrest:IsA("RemoteFunction") then R.arrest:InvokeServer(target) else R.arrest:FireServer(target) end end)
    end
end

-- ----------------------------------------------------------------------------
-- WEAPONS (GET & MOD)
-- ----------------------------------------------------------------------------
local function giveSpecificGun(gunName)
    local giver = WS:FindFirstChild("Prison_ITEMS") and WS.Prison_ITEMS:FindFirstChild("giver")
    if giver and giver:FindFirstChild(gunName) then
        local pickup = giver[gunName]:FindFirstChild("ITEMPICKUP")
        if pickup and R.item then pcall(function() R.item:InvokeServer(pickup) end) end
    end
end

local function modEquippedGuns()
    local function modTool(tool)
        local gs = tool:FindFirstChild("GunStates")
        if not gs then return end
        local ok, mod = pcall(require, gs)
        if ok and type(mod) == "table" then
            mod["MaxAmmo"] = math.huge; mod["CurrentAmmo"] = math.huge; mod["StoredAmmo"] = math.huge
            mod["FireRate"] = 0.000001; mod["Spread"] = 0; mod["Range"] = math.huge
            mod["Bullets"] = 10; mod["ReloadTime"] = 0.000001; mod["AutoFire"] = true; mod["Damage"] = 9999
        end
    end
    local backpack = LP:FindFirstChild("Backpack")
    if backpack then for _, t in ipairs(backpack:GetChildren()) do if t:IsA("Tool") then modTool(t) end end end
    if LP.Character then for _, t in ipairs(LP.Character:GetChildren()) do if t:IsA("Tool") then modTool(t) end end end
end

-- ----------------------------------------------------------------------------
-- VISUALS (ESP & CHAMS)
-- ----------------------------------------------------------------------------
local function createESP(plr)
    if plr == LP or not plr.Character then return end
    local char = plr.Character
    if espCache[plr] then espCache[plr]:Destroy() end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "pl_esp"; billboard.Adornee = char:FindFirstChild("Head") or char
    billboard.Size = UDim2.new(0, 200, 0, 50); billboard.StudsOffset = Vector3.new(0, 2.5, 0)
    billboard.AlwaysOnTop = true; billboard.Parent = parentGui

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, 0, 0.4, 0); nameLabel.BackgroundTransparency = 1
    nameLabel.Text = plr.Name; nameLabel.TextColor3 = Color3.fromRGB(200, 150, 255)
    nameLabel.TextStrokeTransparency = 0; nameLabel.TextSize = 14; nameLabel.Font = Enum.Font.GothamBold; nameLabel.Parent = billboard

    local distLabel = Instance.new("TextLabel")
    distLabel.Size = UDim2.new(1, 0, 0.3, 0); distLabel.Position = UDim2.new(0, 0, 0.4, 0)
    distLabel.BackgroundTransparency = 1; distLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    distLabel.TextStrokeTransparency = 0; distLabel.TextSize = 12; distLabel.Font = Enum.Font.GothamMedium; distLabel.Parent = billboard

    local healthBar = Instance.new("Frame")
    healthBar.Size = UDim2.new(0.7, 0, 0.15, 0); healthBar.Position = UDim2.new(0.15, 0, 0.75, 0)
    healthBar.BackgroundColor3 = Color3.fromRGB(0, 255, 0); healthBar.BorderSizePixel = 1
    healthBar.BorderColor3 = Color3.fromRGB(0, 0, 0); healthBar.Parent = billboard

    espCache[plr] = billboard
end

local function clearESP()
    for _, v in pairs(espCache) do if v then v:Destroy() end end
    espCache = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then
            local hl = plr.Character:FindFirstChild("pl_chams")
            if hl then hl:Destroy() end
        end
    end
end

-- ----------------------------------------------------------------------------
-- CORE LOGIC LOOPS
-- ----------------------------------------------------------------------------
-- Aimbot & Silent Aim
RunService.RenderStepped:Connect(function()
    if not state.silentAim and not state.aimbot then return end
    local cam = workspace.CurrentCamera
    local center = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
    local closest, shortest = nil, state.aimbotFov

    for _, plr in ipairs(Players:GetPlayers()) do
        if isEnemy(plr) then
            local head = plr.Character and plr.Character:FindFirstChild("Head")
            if head then
                local screenPos, onScreen = cam:WorldToViewportPoint(head.Position)
                if onScreen then
                    local dist = (Vector2.new(screenPos.X, screenPos.Y) - center).Magnitude
                    if dist < shortest then shortest = dist; closest = head end
                end
            end
        end
    end
    if closest then
        if state.silentAim then cam.CFrame = CFrame.lookAt(cam.CFrame.Position, closest.Position)
        elseif state.aimbot then cam.CFrame = cam.CFrame:Lerp(CFrame.lookAt(cam.CFrame.Position, closest.Position), 0.3) end
    end
end)

-- Visuals, Hitbox, Lighting, Noclip, Stamina
RunService.RenderStepped:Connect(function()
    if state.esp or state.chams then
        for _, plr in ipairs(Players:GetPlayers()) do
            if isEnemy(plr) and plr.Character then
                if not espCache[plr] and state.esp then createESP(plr) end
                if state.chams and not plr.Character:FindFirstChild("pl_chams") then
                    local hl = Instance.new("Highlight")
                    hl.Name = "pl_chams"; hl.Adornee = plr.Character
                    hl.FillColor = Color3.fromRGB(200, 100, 255); hl.FillTransparency = 0.5
                    hl.OutlineColor = Color3.fromRGB(255, 255, 255); hl.Parent = plr.Character
                end
                if espCache[plr] and espCache[plr].Adornee and getHRP(LP) and plr.Character.Head then
                    local d = math.floor((getHRP(LP).Position - plr.Character.Head.Position).Magnitude)
                    local labels = espCache[plr]:GetChildren()
                    for _, l in ipairs(labels) do if l:IsA("TextLabel") and l.Text ~= plr.Name then l.Text = tostring(d) .. " studs" end end
                    local hb = espCache[plr]:FindFirstChild("Frame")
                    if hb then hb.Size = UDim2.new(0.7 * (plr.Character.Humanoid.Health / 100), 0, 0.15, 0) end
                end
            end
        end
    end
    
    if state.hitboxExpander then
        for _, plr in ipairs(Players:GetPlayers()) do
            if isEnemy(plr) and plr.Character then
                for _, part in ipairs(plr.Character:GetDescendants()) do
                    if part:IsA("BasePart") and part.CanCollide then
                        part.Size = Vector3.new(state.hitboxSize, state.hitboxSize, state.hitboxSize)
                        part.Transparency = 0.5; part.CanCollide = false; part.BrickColor = BrickColor.new("Really red")
                    end
                end
            end
        end
    end

    -- Lighting
    if state.fullbright then
        Lighting.Ambient = Color3.fromRGB(255, 255, 255); Lighting.OutdoorAmbient = Color3.fromRGB(255, 255, 255); Lighting.Brightness = 2
    else
        Lighting.Ambient = originalLighting.Ambient; Lighting.OutdoorAmbient = originalLighting.OutdoorAmbient; Lighting.Brightness = originalLighting.Brightness
    end
    Lighting.FogEnd = state.noFog and 100000 or originalLighting.FogEnd

    -- Noclip & Stamina
    if state.noclip and LP.Character then
        for _, p in ipairs(LP.Character:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide = false end end
    end
    if state.infStamina and LP.Character then
        local stam = LP.Character:FindFirstChild("Stamina")
        if stam and stam:IsA("NumberValue") then stam.Value = 100 end
    end
end)

-- Fly, Auras, Auto-Arrest, Team Lock
RunService.Stepped:Connect(function()
    local my = getHRP(LP)
    if state.fly and my then
        local cam = workspace.CurrentCamera
        local move = Vector3.new(0, 0, 0)
        local function check(k) return UIS:IsKeyDown(k) or state.virtualKeys[k] end
        if check(Enum.KeyCode.W) then move = move + cam.CFrame.LookVector end
        if check(Enum.KeyCode.S) then move = move - cam.CFrame.LookVector end
        if check(Enum.KeyCode.A) then move = move - cam.CFrame.RightVector end
        if check(Enum.KeyCode.D) then move = move + cam.CFrame.RightVector end
        if check(Enum.KeyCode.Space) then move = move + Vector3.new(0, 1, 0) end
        if check(Enum.KeyCode.LeftControl) then move = move - Vector3.new(0, 1, 0) end
        
        if not my:FindFirstChild("pl_flyv") then
            local bv = Instance.new("BodyVelocity", my); bv.Name = "pl_flyv"; bv.MaxForce = Vector3.new(1e5,1e5,1e5)
            local bg = Instance.new("BodyGyro", my); bg.Name = "pl_flyg"; bg.MaxTorque = Vector3.new(1e5,1e5,1e5); bg.P = 1500
            getHum(LP).PlatformStand = true
        end
        my.pl_flyv.Velocity = move * 70
        my.pl_flyg.CFrame = cam.CFrame
    else
        if my then
            local bv = my:FindFirstChild("pl_flyv"); local bg = my:FindFirstChild("pl_flyg")
            if bv then bv:Destroy() end; if bg then bg:Destroy() end
            local hum = getHum(LP); if hum then hum.PlatformStand = false end
        end
    end

    if my then
        if state.killAura then
            for _, plr in ipairs(Players:GetPlayers()) do
                if isEnemy(plr) and getHRP(plr) and (my.Position - getHRP(plr).Position).Magnitude <= state.auraRange then punch(plr, 2) end
            end
        end
        if state.arrestAura and teamName(LP) == "Bright blue" then
            for _, plr in ipairs(Players:GetPlayers()) do
                if isEnemy(plr) and getHRP(plr) and (my.Position - getHRP(plr).Position).Magnitude <= state.auraRange then arrestTarget(plr) end
            end
        end
        if state.autoArrest and teamName(LP) == "Bright blue" then
            for _, plr in ipairs(Players:GetPlayers()) do
                if isCriminal(plr) and getHRP(plr) then arrestTarget(plr) end
            end
        end
    end

    if state.teamLock and state.lockTeam and teamName(LP) ~= state.lockTeam then setTeam(state.lockTeam) end
end)

-- Anti-Taze
RunService.Heartbeat:Connect(function()
    if state.antiTaze and LP.Character then
        for _, v in ipairs(LP.Character:GetChildren()) do
            if v.Name == "TazeEffect" or v.Name == "Ragdoll" or v.Name == "Taser" then v:Destroy() end
        end
    end
end)

-- ----------------------------------------------------------------------------
-- FANCY UI (GLASSMORPHISM)
-- ----------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "pl_aesthetic"; gui.ResetOnSpawn = false; gui.Parent = parentGui

-- FOV Circle Object
local fovGui = Instance.new("Frame")
fovGui.Name = "FOVCircle"; fovGui.Size = UDim2.new(0, 120, 0, 120); fovGui.Position = UDim2.new(0.5, -60, 0.5, -60)
fovGui.BackgroundTransparency = 1; fovGui.Visible = false; fovGui.Parent = gui
Instance.new("UICorner", fovGui).CornerRadius = UDim.new(1, 0)
local fovS = Instance.new("UIStroke", fovGui); fovS.Color = Color3.fromRGB(180, 100, 255); fovS.Thickness = 2

-- Main Window
local main = Instance.new("Frame")
main.Size = UDim2.new(0, 420, 0, 380)
main.Position = UDim2.new(0.5, -210, 0.5, -190)
main.BackgroundColor3 = Color3.fromRGB(18, 18, 28); main.BackgroundTransparency = 0.35
main.BorderSizePixel = 0; main.Active = true; main.Parent = gui
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 14)

local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = Color3.fromRGB(140, 100, 255); mainStroke.Thickness = 1.5; mainStroke.Transparency = 0.3

-- Title Bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 44); titleBar.BackgroundColor3 = Color3.fromRGB(25, 22, 40)
titleBar.BackgroundTransparency = 0.4; titleBar.Parent = main
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 14)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -50, 1, 0); title.Position = UDim2.new(0, 15, 0, 0); title.BackgroundTransparency = 1
title.Text = "⚡ AESTHETIC PRISON ⚡"; title.TextColor3 = Color3.fromRGB(210, 140, 255)
title.TextSize = 15; title.Font = Enum.Font.GothamBlack; title.TextXAlignment = Enum.TextXAlignment.Left; title.Parent = titleBar

task.spawn(function()
    while title.Parent do
        TweenService:Create(title, TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {TextTransparency = 0.1}):Play()
        task.wait(1.5)
    end
end)

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 30, 0, 30); closeBtn.Position = UDim2.new(1, -38, 0, 7)
closeBtn.BackgroundTransparency = 1; closeBtn.Text = "✕"; closeBtn.TextColor3 = Color3.fromRGB(255, 100, 100)
closeBtn.TextSize = 16; closeBtn.Font = Enum.Font.GothamBold; closeBtn.Parent = titleBar
closeBtn.MouseButton1Click:Connect(function() main.Visible = false end)

-- Toggle Button
local toggleBtn = Instance.new("TextButton")
toggleBtn.Size = UDim2.new(0, 45, 0, 45); toggleBtn.Position = UDim2.new(0, 15, 0, 15)
toggleBtn.BackgroundColor3 = Color3.fromRGB(18, 18, 28); toggleBtn.BackgroundTransparency = 0.35
toggleBtn.Text = "M"; toggleBtn.TextColor3 = Color3.fromRGB(210, 140, 255); toggleBtn.TextSize = 20; toggleBtn.Font = Enum.Font.GothamBlack; toggleBtn.Parent = gui
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 10)
Instance.new("UIStroke", toggleBtn).Color = Color3.fromRGB(140, 100, 255)

toggleBtn.MouseButton1Click:Connect(function() 
    main.Visible = not main.Visible 
    if main.Visible then
        main.Position = UDim2.new(0.5, -210, 0.5, -160)
        TweenService:Create(main, TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {Position = UDim2.new(0.5, -210, 0.5, -190)}):Play()
    end
end)

-- Dragging
local drag, dStart, sPos
titleBar.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then drag = true; dStart = i.Position; sPos = main.Position end end)
UIS.InputChanged:Connect(function(i) if drag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then local d = i.Position - dStart; main.Position = UDim2.new(sPos.X.Scale, sPos.X.Offset + d.X, sPos.Y.Scale, sPos.Y.Offset + d.Y) end end)
UIS.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then drag = false end end)

-- Scrolling
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -20, 1, -56); scroll.Position = UDim2.new(0, 10, 0, 48)
scroll.BackgroundTransparency = 1; scroll.ScrollBarThickness = 4; scroll.ScrollBarImageColor3 = Color3.fromRGB(140, 100, 255)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y; scroll.Parent = main
Instance.new("UIListLayout", scroll).Padding = UDim.new(0, 6)

-- UI Helpers
local function section(name)
    local f = Instance.new("Frame"); f.Size = UDim2.new(1, 0, 0, 28); f.BackgroundTransparency = 1; f.Parent = scroll
    local l = Instance.new("TextLabel"); l.Size = UDim2.new(1, 0, 1, 0); l.BackgroundTransparency = 1
    l.Text = name; l.TextColor3 = Color3.fromRGB(180, 180, 220); l.TextSize = 12; l.Font = Enum.Font.GothamBold
    l.TextXAlignment = Enum.TextXAlignment.Left; l.Parent = f
end

local function toggle(text, key, cb)
    local b = Instance.new("TextButton"); b.Size = UDim2.new(1, 0, 0, 32)
    b.BackgroundColor3 = Color3.fromRGB(30, 30, 45); b.BackgroundTransparency = 0.3
    b.Text = "  [OFF] " .. text; b.TextColor3 = Color3.fromRGB(210, 210, 225); b.TextSize = 13
    b.Font = Enum.Font.GothamMedium; b.TextXAlignment = Enum.TextXAlignment.Left; b.Parent = scroll
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
    b.MouseButton1Click:Connect(function()
        state[key] = not state[key]
        b.Text = "  " .. (state[key] and "[ON] " or "[OFF] ") .. text
        b.BackgroundColor3 = state[key] and Color3.fromRGB(40, 100, 60) or Color3.fromRGB(30, 30, 45)
        if cb then cb(state[key]) end
    end)
end

local function button(text, cb)
    local b = Instance.new("TextButton"); b.Size = UDim2.new(1, 0, 0, 32)
    b.BackgroundColor3 = Color3.fromRGB(40, 35, 60); b.BackgroundTransparency = 0.3
    b.Text = "  " .. text; b.TextColor3 = Color3.fromRGB(220, 210, 245); b.TextSize = 13
    b.Font = Enum.Font.GothamMedium; b.TextXAlignment = Enum.TextXAlignment.Left; b.Parent = scroll
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
    b.MouseButton1Click:Connect(function() pcall(cb) end)
end

local function input(text, default, cb)
    local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 32); row.BackgroundTransparency = 1; row.Parent = scroll
    local lbl = Instance.new("TextLabel"); lbl.Size = UDim2.new(0.55, 0, 1, 0); lbl.BackgroundTransparency = 1
    lbl.Text = "  "..text; lbl.TextColor3 = Color3.fromRGB(210, 210, 225); lbl.TextSize = 13; lbl.Font = Enum.Font.GothamMedium; lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = row
    local box = Instance.new("TextBox"); box.Size = UDim2.new(0.4, 0, 0, 26); box.Position = UDim2.new(0.58, 0, 0, 3)
    box.BackgroundColor3 = Color3.fromRGB(30, 30, 45); box.BackgroundTransparency = 0.3; box.Text = tostring(default)
    box.TextColor3 = Color3.fromRGB(225, 225, 240); box.TextSize = 13; box.Font = Enum.Font.GothamMedium; box.ClearTextOnFocus = false; box.Parent = row
    Instance.new("UICorner", box).CornerRadius = UDim.new(0, 8)
    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then pcall(cb, n) else box.Text = tostring(default) end
    end)
end

-- Fly D-Pad
local flyGui = Instance.new("Frame")
flyGui.Size = UDim2.new(0, 150, 0, 150); flyGui.Position = UDim2.new(0.5, -75, 1, -170)
flyGui.BackgroundTransparency = 1; flyGui.Visible = false; flyGui.Parent = gui
local function fBtn(t, p, k)
    local b = Instance.new("TextButton"); b.Size = UDim2.new(0,40,0,40); b.Position = p
    b.BackgroundColor3 = Color3.fromRGB(18,18,28); b.BackgroundTransparency = 0.35; b.Text = t; b.TextColor3 = Color3.fromRGB(255,255,255); b.Font = Enum.Font.GothamBold; b.Parent = flyGui
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,6)
    Instance.new("UIStroke", b).Color = Color3.fromRGB(140, 100, 255)
    b.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then state.virtualKeys[k] = true end end)
    b.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then state.virtualKeys[k] = false end end)
end
fBtn("W", UDim2.new(0,55,0,0), Enum.KeyCode.W); fBtn("A", UDim2.new(0,0,0,55), Enum.KeyCode.A)
fBtn("S", UDim2.new(0,55,0,55), Enum.KeyCode.S); fBtn("D", UDim2.new(0,110,0,55), Enum.KeyCode.D)
fBtn("Up", UDim2.new(0,0,0,110), Enum.KeyCode.Space); fBtn("Dn", UDim2.new(0,110,0,110), Enum.KeyCode.LeftControl)

-- ----------------------------------------------------------------------------
-- UI CONTENT
-- ----------------------------------------------------------------------------
section("COMBAT & AIM")
toggle("Silent Aim", "silentAim")
toggle("Aimbot", "aimbot")
toggle("Show FOV Circle", "fovCircle", function(v) fovGui.Visible = v end)
toggle("Hitbox Expander", "hitboxExpander")
toggle("Kill Aura", "killAura")
toggle("Arrest Aura", "arrestAura")
toggle("Auto Arrest Criminals", "autoArrest")
button("Kill All", function() for _, p in ipairs(Players:GetPlayers()) do if isEnemy(p) then task.spawn(punch, p, 10) end end end)

section("WEAPONS (GET & MOD)")
button("🔫 Give AK-47", function() giveSpecificGun("AK-47") end)
button("🔫 Give M4A1", function() giveSpecificGun("M4A1") end)
button("🔫 Give Remington 870", function() giveSpecificGun("Remington 870") end)
button("🔫 Give M9", function() giveSpecificGun("M9") end)
button("⚡ Mod Equipped Guns (Max)", function() modEquippedGuns() end)
toggle("Auto Mod Guns on Spawn", "autoMod")

section("VISUALS")
toggle("ESP (Box + Distance)", "esp", function(v) if not v then clearESP() end end)
toggle("Chams (Highlight)", "chams", function(v) if not v then clearESP() end end)
toggle("Fullbright", "fullbright")
toggle("No Fog", "noFog")

section("MOVEMENT")
input("WalkSpeed", 16, function(n) state.walkSpeed = math.clamp(n, 1, 200); getHum(LP).WalkSpeed = state.walkSpeed end)
input("JumpPower", 50, function(n) state.jumpPower = math.clamp(n, 1, 300); getHum(LP).UseJumpPower = true; getHum(LP).JumpPower = state.jumpPower end)
toggle("Fly", "fly", function(v) flyGui.Visible = v end)
toggle("Noclip", "noclip")

section("PLAYER & MISC")
toggle("Anti-Taze", "antiTaze")
toggle("Infinite Stamina", "infStamina")
button("Become Guard", function() setTeam("Bright blue") end)
button("Become Criminal", function() setTeam("Really red") end)
toggle("Team Lock", "teamLock")
button("Lock to Guard", function() state.lockTeam = "Bright blue"; state.teamLock = true end)
button("Teleport to Nearest Player", function()
    local my = getHRP(LP); if not my then return end
    local best, bestDist
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local hrp = getHRP(plr)
            if hrp then
                local d = (my.Position - hrp.Position).Magnitude
                if not bestDist or d < bestDist then best, bestDist = plr, d end
            end
        end
    end
    if best then tpTo(best, CFrame.new(0, 0, 3)) end
end)
button("Teleport to Random Criminal", function()
    local c = {}
    for _, p in ipairs(Players:GetPlayers()) do if isCriminal(p) and getHRP(p) then table.insert(c, p) end end
    if #c > 0 then tpTo(c[math.random(1, #c)], CFrame.new(0,0,3)) end
end)
button("Respawn", respawn)
button("Panic (Turn Everything Off)", function()
    for k, v in pairs(state) do if type(v) == "boolean" then state[k] = false end end
    clearESP(); flyGui.Visible = false; main.Visible = false
end)

print("Prison Life Aesthetic Hub v3 Loaded Successfully.")
