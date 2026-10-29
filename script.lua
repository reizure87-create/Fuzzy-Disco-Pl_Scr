-- Prison Life menu — Mobile Hardened
-- Executor required.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local WS = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local LP = Players.LocalPlayer

-- ----------------------------------------------------------------------------
-- state
-- ----------------------------------------------------------------------------
local state = {
    killAura = false,
    arrestAura = false,
    autoArrest = false,
    autoArrestTP = true,
    noclip = false,
    fly = false,
    esp = false,
    teamLock = false,
    autoMod = false,
    auraRange = 22,
    flySpeed = 70,
    aimbot = false,
    aimbotFov = 150,
    virtualKeys = {},
}

local R = {}
local lastAction = {}

-- ----------------------------------------------------------------------------
-- remote resolution (Runs in background so it doesn't freeze UI)
-- ----------------------------------------------------------------------------
local function waitFor(parent, name, timeout)
    local elapsed = 0
    repeat
        local child = parent:FindFirstChild(name)
        if child then return child end
        task.wait(0.1)
        elapsed = elapsed + 0.1
    until elapsed >= (timeout or 15)
    return nil
end

task.spawn(function()
    local wr = waitFor(WS, "Remote", 15)
    local rsRemotes = RS:FindFirstChild("Remotes")
    R.team = wr and wr:FindFirstChild("TeamEvent")
    R.item = wr and wr:FindFirstChild("ItemHandler")
    R.loadChar = wr and wr:FindFirstChild("LoadCharacter")
    R.arrest = (rsRemotes and rsRemotes:FindFirstChild("ArrestPlayer"))
        or (wr and (wr:FindFirstChild("ArrestPlayer") or wr:FindFirstChild("arrest")))
    R.melee = RS:FindFirstChild("meleeEvent")
        or (rsRemotes and rsRemotes:FindFirstChild("meleeEvent"))
    R.shoot = RS:FindFirstChild("ShootEvent")
end)

-- ----------------------------------------------------------------------------
-- UI Parent (gethui bypass for Delta)
-- ----------------------------------------------------------------------------
local parentGui
if gethui then
    parentGui = gethui()
else
    local success, core = pcall(function() return game:GetService("CoreGui") end)
    if success and core then
        parentGui = core
    else
        parentGui = LP:WaitForChild("PlayerGui")
    end
end

-- ----------------------------------------------------------------------------
-- notifications
-- ----------------------------------------------------------------------------
local notifyGui = Instance.new("ScreenGui")
notifyGui.Name = "pl_notify"
notifyGui.ResetOnSpawn = false
notifyGui.IgnoreGuiInset = true
notifyGui.Parent = parentGui

local function notify(text)
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(0, 260, 0, 34)
    frame.Position = UDim2.new(0.5, -130, 0, 12)
    frame.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
    frame.BackgroundTransparency = 0.15
    frame.BorderSizePixel = 0
    frame.Parent = notifyGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = frame

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, -12, 1, 0)
    label.Position = UDim2.new(0, 6, 0, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = Color3.fromRGB(235, 235, 245)
    label.TextSize = 14
    label.Font = Enum.Font.GothamMedium
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = frame

    task.delay(2.5, function()
        for i = 0, 10 do
            frame.BackgroundTransparency = 0.15 + i * 0.085
            label.TextTransparency = i * 0.1
            task.wait(0.03)
        end
        frame:Destroy()
    end)
end

-- ----------------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------------
local function getHRP(plr)
    local char = plr.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHum(plr)
    local char = plr.Character
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function teamName(plr)
    return plr.TeamColor and plr.TeamColor.Name or ""
end

local function isEnemy(plr)
    if plr == LP then return false end
    local other = teamName(plr)
    if other == "" then return false end
    return other ~= teamName(LP)
end

local function isCriminal(plr)
    return teamName(plr) == "Really red"
end

local function tpTo(target, offset)
    local my = getHRP(LP)
    local their = getHRP(target)
    if my and their then
        my.CFrame = their.CFrame * (offset or CFrame.new(0, 0, 2.5))
        return true
    end
    return false
end

local function setTeam(colorName)
    if not R.team then return end
    pcall(function() R.team:FireServer(colorName) end)
end

local function ensureGuard()
    if teamName(LP) == "Bright blue" then return true end
    setTeam("Bright blue")
    task.wait(1.5)
    return teamName(LP) == "Bright blue"
end

local function punch(target, times)
    if not R.melee then return end
    times = times or 6
    for _ = 1, times do
        pcall(function() R.melee:FireServer(target) end)
        task.wait(0.03)
    end
end

local function arrest(target)
    if not R.arrest then return false end
    local ok
    if R.arrest:IsA("RemoteFunction") then
        ok = pcall(function() R.arrest:InvokeServer(target) end)
    else
        ok = pcall(function() R.arrest:FireServer(target) end)
    end
    return ok
end

local function meleeKill(target)
    if not isEnemy(target) then return end
    tpTo(target, CFrame.new(0, 0, 2.2))
    task.wait(0.06)
    punch(target, 8)
end

local function arrestTarget(target)
    if not target or target == LP then return end
    if os.clock() - (lastAction[target] or 0) < 1 then return end
    lastAction[target] = os.clock()
    tpTo(target, CFrame.new(0, 0, 2.2))
    task.wait(0.06)
    arrest(target)
end

local function giveAllGuns()
    local items = WS:FindFirstChild("Prison_ITEMS")
    local giver = items and items:FindFirstChild("giver")
    if not giver or not R.item then
        notify("ItemHandler unavailable")
        return
    end
    for _, item in ipairs(giver:GetChildren()) do
        local pickup = item:FindFirstChild("ITEMPICKUP")
        if pickup then
            pcall(function() R.item:InvokeServer(pickup) end)
            task.wait(0.08)
        end
    end
    notify("Guns issued")
end

local function modTool(tool)
    local gs = tool:FindFirstChild("GunStates")
    if not gs then return end
    local ok, mod = pcall(require, gs)
    if not ok or type(mod) ~= "table" then return end

    for _, key in ipairs({ "Damage", "Range", "MaxAmmo", "Ammo" }) do
        if type(mod[key]) == "number" then mod[key] = 9999 end
    end
    if type(mod.FireRate) == "number" then mod.FireRate = 0.03 end
    if type(mod.Spread) == "number" then mod.Spread = 0 end
    if type(mod.ReloadTime) == "number" then mod.ReloadTime = 0 end
    if type(mod.AutoFire) == "boolean" then mod.AutoFire = true end
end

local function modAllGuns()
    local backpack = LP:FindFirstChild("Backpack")
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if tool:IsA("Tool") then modTool(tool) end
        end
    end
    if LP.Character then
        for _, tool in ipairs(LP.Character:GetChildren()) do
            if tool:IsA("Tool") then modTool(tool) end
        end
    end
end

local flyBV, flyBG, flyControls

local function checkKey(key)
    return UIS:IsKeyDown(key) or state.virtualKeys[key]
end

local function setFly(on)
    local hrp = getHRP(LP)
    local hum = getHum(LP)
    if on and hrp and hum then
        flyBV = Instance.new("BodyVelocity")
        flyBV.MaxForce = Vector3.new(1e5, 1e5, 1e5)
        flyBV.Velocity = Vector3.new(0, 0, 0)
        flyBV.Parent = hrp

        flyBG = Instance.new("BodyGyro")
        flyBG.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
        flyBG.P = 1500
        flyBG.Parent = hrp

        hum.PlatformStand = true
        if flyControls then flyControls.Visible = true end
    else
        if flyBV then flyBV:Destroy() flyBV = nil end
        if flyBG then flyBG:Destroy() flyBG = nil end
        if hum then hum.PlatformStand = false end
        if flyControls then flyControls.Visible = false end
    end
end

RunService.RenderStepped:Connect(function()
    if not state.fly or not flyBV or not flyBG then return end
    local cam = workspace.CurrentCamera
    local move = Vector3.new(0, 0, 0)
    
    if checkKey(Enum.KeyCode.W) then move = move + cam.CFrame.LookVector end
    if checkKey(Enum.KeyCode.S) then move = move - cam.CFrame.LookVector end
    if checkKey(Enum.KeyCode.A) then move = move - cam.CFrame.RightVector end
    if checkKey(Enum.KeyCode.D) then move = move + cam.CFrame.RightVector end
    if checkKey(Enum.KeyCode.Space) then move = move + Vector3.new(0, 1, 0) end
    if checkKey(Enum.KeyCode.LeftControl) then move = move - Vector3.new(0, 1, 0) end
    
    flyBV.Velocity = move * state.flySpeed
    flyBG.CFrame = cam.CFrame
end)

RunService.Stepped:Connect(function()
    if not state.noclip then return end
    local char = LP.Character
    if not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA("BasePart") and part.CanCollide then
            part.CanCollide = false
        end
    end
end)

RunService:BindToRenderStep("pl_aimbot", Enum.RenderPriority.Camera.Value + 1, function()
    if not state.aimbot then return end
    local cam = workspace.CurrentCamera
    local center = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y / 2)
    local closest, shortest = nil, state.aimbotFov

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and isEnemy(plr) then
            local char = plr.Character
            local head = char and char:FindFirstChild("Head")
            if head then
                local screenPos, onScreen = cam:WorldToViewportPoint(head.Position)
                if onScreen then
                    local dist = (Vector2.new(screenPos.X, screenPos.Y) - center).Magnitude
                    if dist < shortest then
                        shortest = dist
                        closest = head
                    end
                end
            end
        end
    end

    if closest then
        cam.CFrame = CFrame.lookAt(cam.CFrame.Position, closest.Position)
    end
end)

local espObjects = {}
local function clearESP()
    for _, obj in ipairs(espObjects) do
        if obj and obj.Parent then obj:Destroy() end
    end
    espObjects = {}
end

local function applyESP(plr)
    if plr == LP then return end
    local char = plr.Character
    if not char or char:FindFirstChild("pl_esp") then return end
    local color = Color3.fromRGB(180, 180, 180)
    local team = teamName(plr)
    if team == "Bright blue" then color = Color3.fromRGB(70, 140, 255)
    elseif team == "Bright orange" then color = Color3.fromRGB(255, 150, 40)
    elseif team == "Really red" then color = Color3.fromRGB(255, 60, 60) end

    local hl = Instance.new("Highlight")
    hl.Name = "pl_esp"
    hl.Adornee = char
    hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    hl.FillColor = color
    hl.OutlineColor = Color3.fromRGB(255, 255, 255)
    hl.FillTransparency = 0.65
    hl.OutlineTransparency = 0
    hl.Parent = char
    table.insert(espObjects, hl)
end

local function refreshESP()
    clearESP()
    if not state.esp then return end
    for _, plr in ipairs(Players:GetPlayers()) do applyESP(plr) end
end

local function respawn()
    if R.loadChar then
        pcall(function()
            if R.loadChar:IsA("RemoteFunction") then R.loadChar:InvokeServer()
            else R.loadChar:FireServer() end
        end)
    else
        pcall(function() LP:LoadCharacter() end)
    end
end

local function onCharacter(char)
    task.wait(0.8)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then
        hum.WalkSpeed = state.walkSpeed or 16
        hum.JumpPower = state.jumpPower or 50
        hum.UseJumpPower = true
    end
    if state.autoMod then task.wait(0.5) modAllGuns() end
    if state.fly then task.wait(0.2) setFly(true) end
    if state.esp then task.wait(0.5) applyESP(LP) end
end

LP.CharacterAdded:Connect(onCharacter)
Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(function()
        task.wait(1)
        if state.esp then applyESP(plr) end
    end)
end)
LP.CharacterRemoving:Connect(function() setFly(false) end)

task.spawn(function()
    while true do
        task.wait(0.12)
        local my = getHRP(LP)

        if state.killAura and my then
            for _, plr in ipairs(Players:GetPlayers()) do
                if isEnemy(plr) then
                    local hrp = getHRP(plr)
                    if hrp and (my.Position - hrp.Position).Magnitude <= state.auraRange then
                        punch(plr, 2)
                    end
                end
            end
        end

        if state.arrestAura and my and teamName(LP) == "Bright blue" then
            for _, plr in ipairs(Players:GetPlayers()) do
                if isEnemy(plr) then
                    local hrp = getHRP(plr)
                    if hrp and (my.Position - hrp.Position).Magnitude <= state.auraRange then
                        arrestTarget(plr)
                    end
                end
            end
        end

        if state.autoArrest and teamName(LP) == "Bright blue" then
            for _, plr in ipairs(Players:GetPlayers()) do
                if isCriminal(plr) and getHRP(plr) then
                    if state.autoArrestTP then tpTo(plr, CFrame.new(0, 0, 2.2)) end
                    arrestTarget(plr)
                end
            end
        end

        if state.teamLock and state.lockTeam then
            if teamName(LP) ~= state.lockTeam then setTeam(state.lockTeam) end
        end
    end
end)

-- ----------------------------------------------------------------------------
-- GUI (Sized for Mobile)
-- ----------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "pl_menu"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = parentGui

local menuToggleBtn = Instance.new("TextButton")
menuToggleBtn.Size = UDim2.new(0, 45, 0, 45)
menuToggleBtn.Position = UDim2.new(0, 10, 0, 10)
menuToggleBtn.BackgroundColor3 = Color3.fromRGB(16, 16, 22)
menuToggleBtn.Text = "M"
menuToggleBtn.TextColor3 = Color3.fromRGB(230, 230, 245)
menuToggleBtn.TextSize = 20
menuToggleBtn.Font = Enum.Font.GothamBold
menuToggleBtn.Parent = gui
local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 8)
toggleCorner.Parent = menuToggleBtn

local main = Instance.new("Frame")
main.Name = "main"
-- Responsive size (max 380x360, but fits smaller screens)
local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
main.Size = UDim2.new(0, math.min(380, vp.X - 30), 0, math.min(360, vp.Y - 30))
main.Position = UDim2.new(0, 20, 0.5, -main.Size.Y.Offset / 2)
main.BackgroundColor3 = Color3.fromRGB(16, 16, 22)
main.BackgroundTransparency = 0.05
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui

menuToggleBtn.MouseButton1Click:Connect(function()
    main.Visible = not main.Visible
end)

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 10)
mainCorner.Parent = main

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(70, 70, 95)
stroke.Thickness = 1
stroke.Parent = main

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 34)
titleBar.BackgroundColor3 = Color3.fromRGB(26, 26, 36)
titleBar.BorderSizePixel = 0
titleBar.Parent = main

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 10)
titleCorner.Parent = titleBar

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -80, 1, 0)
title.Position = UDim2.new(0, 12, 0, 0)
title.BackgroundTransparency = 1
title.Text = "PRISON LIFE"
title.TextColor3 = Color3.fromRGB(230, 230, 245)
title.TextSize = 14
title.Font = Enum.Font.GothamBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 22)
closeBtn.Position = UDim2.new(1, -32, 0, 6)
closeBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 30)
closeBtn.BorderSizePixel = 0
closeBtn.Text = "X"
closeBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
closeBtn.TextSize = 13
closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = titleBar
closeBtn.MouseButton1Click:Connect(function() main.Visible = false end)

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, -16, 1, -46)
scroll.Position = UDim2.new(0, 8, 0, 40)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4
scroll.ScrollBarImageColor3 = Color3.fromRGB(90, 90, 120)
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent = main

local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 5)
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Parent = scroll

do
    local dragging, dragStart, startPos
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
end

flyControls = Instance.new("Frame")
flyControls.Size = UDim2.new(0, 150, 0, 150)
flyControls.Position = UDim2.new(0.5, -75, 1, -170)
flyControls.BackgroundTransparency = 1
flyControls.Visible = false
flyControls.Parent = gui

local function makeFlyBtn(txt, pos, key)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 40, 0, 40)
    b.Position = pos
    b.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
    b.BackgroundTransparency = 0.3
    b.Text = txt
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.TextSize = 14
    b.Font = Enum.Font.GothamBold
    b.Parent = flyControls
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 6)
    c.Parent = b
    b.InputBegan:Connect(function(i) 
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then state.virtualKeys[key] = true end 
    end)
    b.InputEnded:Connect(function(i) 
        if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then state.virtualKeys[key] = false end 
    end)
end
makeFlyBtn("W", UDim2.new(0,55,0,0), Enum.KeyCode.W)
makeFlyBtn("A", UDim2.new(0,0,0,55), Enum.KeyCode.A)
makeFlyBtn("S", UDim2.new(0,55,0,55), Enum.KeyCode.S)
makeFlyBtn("D", UDim2.new(0,110,0,55), Enum.KeyCode.D)
makeFlyBtn("Up", UDim2.new(0,0,0,110), Enum.KeyCode.Space)
makeFlyBtn("Dn", UDim2.new(0,110,0,110), Enum.KeyCode.LeftControl)

local function section(text)
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 24)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = Color3.fromRGB(120, 130, 180)
    lbl.TextSize = 11
    lbl.Font = Enum.Font.GothamBold
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = scroll
end

local function button(text, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 34)
    btn.BackgroundColor3 = Color3.fromRGB(32, 32, 44)
    btn.BorderSizePixel = 0
    btn.Text = text
    btn.TextColor3 = Color3.fromRGB(225, 225, 240)
    btn.TextSize = 13
    btn.Font = Enum.Font.GothamMedium
    btn.Parent = scroll
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 5)
    c.Parent = btn
    btn.MouseButton1Click:Connect(function()
        local ok, err = pcall(callback)
        if not ok then notify("Error: " .. tostring(err)) end
    end)
end

local function toggle(text, key, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, 0, 0, 34)
    btn.BackgroundColor3 = Color3.fromRGB(32, 32, 44)
    btn.BorderSizePixel = 0
    btn.Text = "[OFF] " .. text
    btn.TextColor3 = Color3.fromRGB(210, 210, 225)
    btn.TextSize = 13
    btn.Font = Enum.Font.GothamMedium
    btn.Parent = scroll
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 5)
    c.Parent = btn

    btn.MouseButton1Click:Connect(function()
        state[key] = not state[key]
        btn.Text = (state[key] and "[ON] " or "[OFF] ") .. text
        btn.BackgroundColor3 = state[key] and Color3.fromRGB(34, 78, 48) or Color3.fromRGB(32, 32, 44)
        if callback then
            local ok, err = pcall(callback, state[key])
            if not ok then notify("Error: " .. tostring(err)) end
        end
    end)
end

local function input(text, default, callback)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, 0, 0, 34)
    row.BackgroundTransparency = 1
    row.Parent = scroll

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.55, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = text
    lbl.TextColor3 = Color3.fromRGB(200, 200, 215)
    lbl.TextSize = 13
    lbl.Font = Enum.Font.GothamMedium
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Parent = row

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(0.4, 0, 0, 26)
    box.Position = UDim2.new(0.58, 0, 0, 4)
    box.BackgroundColor3 = Color3.fromRGB(32, 32, 44)
    box.BorderSizePixel = 0
    box.Text = tostring(default)
    box.TextColor3 = Color3.fromRGB(225, 225, 240)
    box.TextSize = 13
    box.Font = Enum.Font.GothamMedium
    box.ClearTextOnFocus = false
    box.Parent = row

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 5)
    c.Parent = box

    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then
            local ok, err = pcall(callback, n)
            if not ok then notify("Error: " .. tostring(err)) end
        else
            box.Text = tostring(default)
        end
    end)
end

section("COMBAT")
button("Kill All", function()
    for _, plr in ipairs(Players:GetPlayers()) do
        if isEnemy(plr) then task.spawn(meleeKill, plr) task.wait(0.08) end
    end
end)
button("Arrest All Criminals", function()
    if not ensureGuard() then notify("Could not switch to Guard") return end
    for _, plr in ipairs(Players:GetPlayers()) do
        if isCriminal(plr) then task.spawn(arrestTarget, plr) task.wait(0.12) end
    end
end)
toggle("Aimbot", "aimbot")
toggle("Kill Aura", "killAura")
toggle("Arrest Aura", "arrestAura")
toggle("Auto Arrest Criminals", "autoArrest")
button("Give All Guns", giveAllGuns)
button("Mod All Guns", function() modAllGuns() notify("Weapons modified") end)
toggle("Auto Mod Guns on Spawn", "autoMod")

section("MOVEMENT")
input("WalkSpeed", 16, function(n)
    state.walkSpeed = math.clamp(n, 1, 200)
    local hum = getHum(LP) if hum then hum.WalkSpeed = state.walkSpeed end
end)
input("JumpPower", 50, function(n)
    state.jumpPower = math.clamp(n, 1, 300)
    local hum = getHum(LP) if hum then hum.UseJumpPower = true hum.JumpPower = state.jumpPower end
end)
toggle("Noclip", "noclip")
toggle("Fly", "fly", function(on) setFly(on) end)
button("Teleport to Nearest Player", function()
    local my = getHRP(LP) if not my then return end
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
    if best then tpTo(best, CFrame.new(0, 0, 3)) notify("Teleported to " .. best.Name) end
end)
button("Teleport to Random Criminal", function()
    local criminals = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if isCriminal(plr) and getHRP(plr) then table.insert(criminals, plr) end
    end
    if #criminals > 0 then
        local target = criminals[math.random(1, #criminals)]
        tpTo(target, CFrame.new(0, 0, 3))
        notify("Teleported to " .. target.Name)
    else notify("No criminals") end
end)

section("PLAYER")
button("Become Guard", function() setTeam("Bright blue") end)
button("Become Inmate", function() setTeam("Bright orange") end)
button("Become Criminal", function() setTeam("Really red") end)
button("Become Neutral", function() setTeam("Medium stone grey") end)
toggle("Team Lock", "teamLock")
button("Lock to Guard", function()
    state.lockTeam = "Bright blue"
    state.teamLock = true
    notify("Team locked: Guard")
end)
toggle("ESP", "esp", function(on) if on then refreshESP() else clearESP() end end)

section("MISC")
button("Respawn", respawn)
button("Panic", function()
    for k in pairs(state) do
        if type(state[k]) == "boolean" then state[k] = false end
    end
    clearESP()
    setFly(false)
    main.Visible = false
    notify("All features disabled")
end)

notify("Loaded — Tap 'M' to toggle menu")
print("Prison Life Script Loaded Successfully.")
