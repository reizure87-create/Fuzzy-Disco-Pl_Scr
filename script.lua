-- Prison Life | True Meta Engine v9
-- Correctly hooks ShootEvent, Melee, and handles Tracers/Prediction.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local WS = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local LP = Players.LocalPlayer

-- ----------------------------------------------------------------------------
-- CONFIGURATION
-- ----------------------------------------------------------------------------
local State = {
    -- Aiming
    SilentAim = false, CameraAimbot = false, Triggerbot = false,
    AimKey = Enum.UserInputType.MouseButton2, -- Right Click to aim
    HoldToAim = true, AimbotSmoothness = 0.25, FOV = 150, ShowFOV = true,
    WallCheck = true, AimTargetPart = "Head",
    
    -- Combat
    KillAura = false, ArrestAura = false, HitboxExpander = false,
    
    -- Visuals
    ESP = false, Tracers = false, Chams = false, Fullbright = false,
    
    -- Movement
    Fly = false, Noclip = false, WalkSpeed = 16, JumpPower = 50,
    
    -- Misc
    AntiTaze = false, InfStamina = false, AutoReload = false,
    VirtualKeys = {}, CurrentTab = "Combat", 
    IsAiming = false -- Internal state for hold-to-aim
}

local R = {}
local ESPCache = {}
local Tracers = {}
local LastAction = {}
local Config = { FlySpeed = 70, HitboxSize = 8, AuraRange = 25 }
local OriginalLighting = { Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient, Brightness = Lighting.Brightness }
local CurrentTarget = nil
local TargetExpire = 0
local Camera = workspace.CurrentCamera

-- ----------------------------------------------------------------------------
-- KEYBINDS & METATABLE HOOKING (THE YOUTUBE WAY)
-- ----------------------------------------------------------------------------
UIS.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.UserInputType == State.AimKey then State.IsAiming = true end
end)
UIS.InputEnded:Connect(function(input)
    if input.UserInputType == State.AimKey then State.IsAiming = false end
end)

local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
    local method = getnamecallmethod()
    local args = {...}
    
    if State.SilentAim and (not State.HoldToAim or State.IsAiming) then
        if (method == "FireServer" or method == "InvokeServer") and CurrentTarget then
            -- Handle Melee / Arrest
            if self.Name == "meleeEvent" or self.Name == "ArrestPlayer" then
                args[1] = CurrentTarget.Parent
                return oldNamecall(self, unpack(args))
            end
            -- Handle Guns (Tool, Origin, Direction)
            if self.Name == "ShootEvent" and #args >= 3 then
                local origin = args[2]
                args[3] = (CurrentTarget.Position - origin).Unit
                return oldNamecall(self, unpack(args))
            end
        end
    end
    return oldNamecall(self, ...)
end)

-- ----------------------------------------------------------------------------
-- HELPERS
-- ----------------------------------------------------------------------------
local parentGui = gethui and gethui() or LP:WaitForChild("PlayerGui")
local function getHRP(plr) return plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") end
local function getHum(plr) return plr.Character and plr.Character:FindFirstChildOfClass("Humanoid") end
local function teamName(plr) return plr.TeamColor and plr.TeamColor.Name or "" end
local function isEnemy(plr) return plr ~= LP and teamName(plr) ~= "" and teamName(plr) ~= teamName(LP) end

local function isVisible(part)
    if not State.WallCheck then return true end
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Blacklist
    rayParams.FilterDescendantsInstances = {LP.Character, part.Parent}
    local result = workspace:Raycast(Camera.CFrame.Position, part.Position - Camera.CFrame.Position, rayParams)
    return result == nil or result.Instance:IsDescendantOf(part.Parent)
end

local function getTarget()
    local center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local closest, shortest = nil, State.FOV
    for _, plr in ipairs(Players:GetPlayers()) do
        if isEnemy(plr) and plr.Character then
            local part = plr.Character:FindFirstChild(State.AimTargetPart) or plr.Character:FindFirstChild("Head")
            if part and isVisible(part) then
                local screenPos, onScreen = Camera:WorldToViewportPoint(part.Position)
                if onScreen then
                    local dist = (Vector2.new(screenPos.X, screenPos.Y) - center).Magnitude
                    if dist < shortest then shortest = dist; closest = part end
                end
            end
        end
    end
    return closest
end

local function clearTracers()
    for _, line in pairs(Tracers) do
        if typeof(line) == "Instance" then line:Destroy() elseif typeof(line) == "userdata" then line:Remove() end
    end
    Tracers = {}
end

-- ----------------------------------------------------------------------------
-- WEAPONS & AUTO-RELOAD
-- ----------------------------------------------------------------------------
local function modEquippedGuns()
    local function modTool(tool)
        local gs = tool:FindFirstChild("GunStates")
        if not gs then return end
        local ok, mod = pcall(require, gs)
        if ok and type(mod) == "table" then
            mod["MaxAmmo"] = math.huge; mod["CurrentAmmo"] = math.huge; mod["StoredAmmo"] = math.huge
            mod["FireRate"] = 0.01; mod["Spread"] = 0; mod["Range"] = math.huge
            mod["ReloadTime"] = 0.000001; mod["AutoFire"] = true; mod["Damage"] = 999
        end
    end
    local backpack = LP:FindFirstChild("Backpack")
    if backpack then for _, t in ipairs(backpack:GetChildren()) do if t:IsA("Tool") then modTool(t) end end end
    if LP.Character then for _, t in ipairs(LP.Character:GetChildren()) do if t:IsA("Tool") then modTool(t) end end end
end

local function giveSpecificGun(gunName)
    local giver = WS:FindFirstChild("Prison_ITEMS") and WS.Prison_ITEMS:FindFirstChild("giver")
    if giver and giver:FindFirstChild(gunName) then
        local pickup = giver[gunName]:FindFirstChild("ITEMPICKUP")
        if pickup and R.item then pcall(function() R.item:InvokeServer(pickup) end) end
    end
end

-- ----------------------------------------------------------------------------
-- CORE LOOPS
-- ----------------------------------------------------------------------------
RunService.RenderStepped:Connect(function()
    -- Target Logic
    if State.SilentAim or State.CameraAimbot or State.Triggerbot then
        if not State.HoldToAim or State.IsAiming then
            local target = getTarget()
            if target then
                CurrentTarget = target; TargetExpire = tick() + 0.15
                
                -- Camera Lock
                if State.CameraAimbot then
                    local ping = LP:GetNetworkPing() or 0.05
                    local targetPos = target.Position + (target.AssemblyLinearVelocity * ping)
                    Camera.CFrame = Camera.CFrame:Lerp(CFrame.lookAt(Camera.CFrame.Position, targetPos), State.AimbotSmoothness)
                end
                
                -- Triggerbot (Auto-Shoot)
                if State.Triggerbot then
                    local char = LP.Character
                    local tool = char and char:FindFirstChildOfClass("Tool")
                    if tool and tool:FindFirstChild("GunStates") then
                        pcall(function() tool:Activate() end)
                    end
                end
            else
                if CurrentTarget and tick() > TargetExpire then CurrentTarget = nil end
            end
        else
            CurrentTarget = nil
        end
    else
        CurrentTarget = nil
    end
end)

-- Visuals & Hitbox
RunService.RenderStepped:Connect(function()
    if State.ESP or State.Chams or State.Tracers then
        for _, plr in ipairs(Players:GetPlayers()) do
            if isEnemy(plr) and plr.Character then
                local head = plr.Character:FindFirstChild("Head")
                
                if not ESPCache[plr] and State.ESP and head then
                    local billboard = Instance.new("BillboardGui", parentGui)
                    billboard.Name = "pl_esp"; billboard.Adornee = head
                    billboard.Size = UDim2.new(0, 200, 0, 50); billboard.StudsOffset = Vector3.new(0, 2.5, 0); billboard.AlwaysOnTop = true
                    local name = Instance.new("TextLabel", billboard); name.Size = UDim2.new(1,0,0.4,0); name.BackgroundTransparency = 1
                    name.Text = plr.Name; name.TextColor3 = Color3.fromRGB(200, 150, 255); name.TextStrokeTransparency = 0; name.TextSize = 14; name.Font = Enum.Font.GothamBold
                    local hb = Instance.new("Frame", billboard); hb.Size = UDim2.new(0.7,0,0.15,0); hb.Position = UDim2.new(0.15,0,0.75,0); hb.BackgroundColor3 = Color3.fromRGB(0,255,0)
                    ESPCache[plr] = billboard
                end
                
                if State.Chams and not plr.Character:FindFirstChild("pl_chams") then
                    local hl = Instance.new("Highlight", plr.Character)
                    hl.Name = "pl_chams"; hl.FillColor = Color3.fromRGB(200, 100, 255); hl.FillTransparency = 0.5; hl.OutlineColor = Color3.fromRGB(255, 255, 255)
                end
                
                -- Tracers (Drawing API)
                if State.Tracers and head and Drawing then
                    local screenPos, onScreen = Camera:WorldToViewportPoint(head.Position)
                    if onScreen then
                        if not Tracers[plr] then
                            Tracers[plr] = Drawing.new("Line")
                            Tracers[plr].Thickness = 1.5; Tracers[plr].Color = Color3.fromRGB(200, 100, 255)
                        end
                        local center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y)
                        Tracers[plr].From = Vector2.new(center.X, center.Y)
                        Tracers[plr].To = Vector2.new(screenPos.X, screenPos.Y)
                        Tracers[plr].Visible = true
                    else
                        if Tracers[plr] then Tracers[plr].Visible = false end
                    end
                elseif Tracers[plr] then
                    Tracers[plr]:Remove(); Tracers[plr] = nil
                end
            end
        end
    end
    
    if State.HitboxExpander then
        for _, plr in ipairs(Players:GetPlayers()) do
            if isEnemy(plr) and plr.Character then
                for _, part in ipairs(plr.Character:GetDescendants()) do
                    if part:IsA("BasePart") and part.CanCollide then
                        part.Size = Vector3.new(Config.HitboxSize, Config.HitboxSize, Config.HitboxSize)
                        part.Transparency = 0.5; part.CanCollide = false; part.BrickColor = BrickColor.new("Really red")
                    end
                end
            end
        end
    end
end)

-- Auras, Fly, Anti-Reload
RunService.Stepped:Connect(function()
    local my = getHRP(LP)
    if State.Fly and my then
        local move = Vector3.new(0, 0, 0)
        local function check(k) return UIS:IsKeyDown(k) or State.VirtualKeys[k] end
        if check(Enum.KeyCode.W) then move = move + Camera.CFrame.LookVector end
        if check(Enum.KeyCode.S) then move = move - Camera.CFrame.LookVector end
        if check(Enum.KeyCode.A) then move = move - Camera.CFrame.RightVector end
        if check(Enum.KeyCode.D) then move = move + Camera.CFrame.RightVector end
        if check(Enum.KeyCode.Space) then move = move + Vector3.new(0, 1, 0) end
        
        if not my:FindFirstChild("pl_flyv") then
            local bv = Instance.new("BodyVelocity", my); bv.Name = "pl_flyv"; bv.MaxForce = Vector3.new(1e5,1e5,1e5)
            local bg = Instance.new("BodyGyro", my); bg.Name = "pl_flyg"; bg.MaxTorque = Vector3.new(1e5,1e5,1e5); bg.P = 1500
            getHum(LP).PlatformStand = true
        end
        my.pl_flyv.Velocity = move * Config.FlySpeed
        my.pl_flyg.CFrame = Camera.CFrame
    else
        if my then
            local bv = my:FindFirstChild("pl_flyv"); local bg = my:FindFirstChild("pl_flyg")
            if bv then bv:Destroy() end; if bg then bg:Destroy() end
            local hum = getHum(LP); if hum then hum.PlatformStand = false end
        end
    end

    if State.Noclip and LP.Character then
        for _, p in ipairs(LP.Character:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide = false end end
    end

    if my then
        if State.KillAura then
            for _, plr in ipairs(Players:GetPlayers()) do
                if isEnemy(plr) and getHRP(plr) and (my.Position - getHRP(plr).Position).Magnitude <= Config.AuraRange then
                    if R.melee then pcall(function() R.melee:FireServer(plr) end) end
                end
            end
        end
    end
end)

-- Anti-Taze, Stamina, Auto-Reload
RunService.Heartbeat:Connect(function()
    if LP.Character then
        if State.AntiTaze then
            for _, v in ipairs(LP.Character:GetChildren()) do
                if v.Name == "TazeEffect" or v.Name == "Ragdoll" or v.Name == "Taser" then v:Destroy() end
            end
        end
        if State.AutoReload then
            local tool = LP.Character:FindFirstChildOfClass("Tool")
            if tool and tool:FindFirstChild("GunStates") then
                local ok, mod = pcall(require, tool.GunStates)
                if ok and mod.CurrentAmmo == 0 then tool:Activate() end
            end
        end
    end
    if State.InfStamina and LP.Character then
        local stam = LP.Character:FindFirstChild("Stamina")
        if stam and stam:IsA("NumberValue") then stam.Value = 100 end
    end
end)

-- ----------------------------------------------------------------------------
-- UI SETUP
-- ----------------------------------------------------------------------------
local gui = Instance.new("ScreenGui"); gui.Name = "pl_meta"; gui.ResetOnSpawn = false; gui.Parent = parentGui
local fovGui = Instance.new("Frame", gui); fovGui.Size = UDim2.new(0, State.FOV, 0, State.FOV); fovGui.Position = UDim2.new(0.5, -State.FOV/2, 0.5, -State.FOV/2)
fovGui.BackgroundTransparency = 1; fovGui.Visible = State.ShowFOV
Instance.new("UICorner", fovGui).CornerRadius = UDim.new(1, 0); Instance.new("UIStroke", fovGui).Color = Color3.fromRGB(180, 100, 255)

local main = Instance.new("Frame", gui); main.Size = UDim2.new(0, 440, 0, 380); main.Position = UDim2.new(0.5, -220, 0.5, -190)
main.BackgroundColor3 = Color3.fromRGB(18, 18, 28); main.BackgroundTransparency = 0.25; main.Active = true
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 12); Instance.new("UIStroke", main).Color = Color3.fromRGB(140, 100, 255)

local titleBar = Instance.new("Frame", main); titleBar.Size = UDim2.new(1, 0, 0, 44); titleBar.BackgroundColor3 = Color3.fromRGB(25, 22, 40); titleBar.BackgroundTransparency = 0.4
Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 12)
local title = Instance.new("TextLabel", titleBar); title.Size = UDim2.new(1, -50, 1, 0); title.Position = UDim2.new(0, 15, 0, 0); title.BackgroundTransparency = 1
title.Text = "⚡ META v9 ⚡"; title.TextColor3 = Color3.fromRGB(210, 140, 255); title.TextSize = 15; title.Font = Enum.Font.GothamBlack; title.TextXAlignment = Enum.TextXAlignment.Left

local closeBtn = Instance.new("TextButton", titleBar); closeBtn.Size = UDim2.new(0, 30, 0, 30); closeBtn.Position = UDim2.new(1, -38, 0, 7)
closeBtn.BackgroundTransparency = 1; closeBtn.Text = "✕"; closeBtn.TextColor3 = Color3.fromRGB(255, 100, 100); closeBtn.TextSize = 16; closeBtn.Font = Enum.Font.GothamBold
closeBtn.MouseButton1Click:Connect(function() main.Visible = false end)

local toggleBtn = Instance.new("TextButton", gui); toggleBtn.Size = UDim2.new(0, 45, 0, 45); toggleBtn.Position = UDim2.new(0, 15, 0, 15)
toggleBtn.BackgroundColor3 = Color3.fromRGB(18, 18, 28); toggleBtn.BackgroundTransparency = 0.35; toggleBtn.Text = "M"; toggleBtn.TextColor3 = Color3.fromRGB(210, 140, 255); toggleBtn.TextSize = 20; toggleBtn.Font = Enum.Font.GothamBlack
Instance.new("UICorner", toggleBtn).CornerRadius = UDim.new(0, 10); Instance.new("UIStroke", toggleBtn).Color = Color3.fromRGB(140, 100, 255)
toggleBtn.MouseButton1Click:Connect(function() main.Visible = not main.Visible end)

local drag, dStart, sPos
titleBar.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then drag = true; dStart = i.Position; sPos = main.Position end end)
UIS.InputChanged:Connect(function(i) if drag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then local d = i.Position - dStart; main.Position = UDim2.new(sPos.X.Scale, sPos.X.Offset + d.X, sPos.Y.Scale, sPos.Y.Offset + d.Y) end end)
UIS.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then drag = false end end)

local navBar = Instance.new("Frame", main); navBar.Size = UDim2.new(1, -20, 0, 35); navBar.Position = UDim2.new(0, 10, 0, 50); navBar.BackgroundTransparency = 1
Instance.new("UIListLayout", navBar).FillDirection = Enum.FillDirection.Horizontal; Instance.new("UIListLayout", navBar).Padding = UDim.new(0, 5)

local scroll = Instance.new("ScrollingFrame", main); scroll.Size = UDim2.new(1, -20, 1, -100); scroll.Position = UDim2.new(0, 10, 0, 90)
scroll.BackgroundTransparency = 1; scroll.ScrollBarThickness = 4; scroll.ScrollBarImageColor3 = Color3.fromRGB(140, 100, 255); scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
Instance.new("UIListLayout", scroll).Padding = UDim.new(0, 6)

local tabs = {}
local function createTab(name)
    local b = Instance.new("TextButton", navBar); b.Size = UDim2.new(0, 90, 1, 0); b.BackgroundColor3 = Color3.fromRGB(30, 30, 45); b.BackgroundTransparency = 0.3
    b.Text = name; b.TextColor3 = Color3.fromRGB(200, 200, 220); b.TextSize = 12; b.Font = Enum.Font.GothamBold; Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6); tabs[name] = b
    b.MouseButton1Click:Connect(function()
        State.CurrentTab = name
        for n, btn in pairs(tabs) do
            btn.BackgroundColor3 = (n == name) and Color3.fromRGB(60, 45, 90) or Color3.fromRGB(30, 30, 45)
            btn.TextColor3 = (n == name) and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(200, 200, 220)
        end
        for _, child in ipairs(scroll:GetChildren()) do if child:IsA("GuiObject") and child:GetAttribute("Tab") then child.Visible = (child:GetAttribute("Tab") == name) end end
    end)
end

local function addElement(e) e:SetAttribute("Tab", State.CurrentTab); e.Parent = scroll end
local function section(n) local f = Instance.new("Frame"); f.Size = UDim2.new(1, 0, 0, 24); f.BackgroundTransparency = 1; local l = Instance.new("TextLabel", f); l.Size = UDim2.new(1, 0, 1, 0); l.BackgroundTransparency = 1; l.Text = n; l.TextColor3 = Color3.fromRGB(180, 180, 220); l.TextSize = 12; l.Font = Enum.Font.GothamBold; l.TextXAlignment = Enum.TextXAlignment.Left; addElement(f) end
local function toggle(t, k, cb) 
    local b = Instance.new("TextButton"); b.Size = UDim2.new(1, 0, 0, 32); b.BackgroundColor3 = Color3.fromRGB(30, 30, 45); b.BackgroundTransparency = 0.3
    b.Text = "  [OFF] " .. t; b.TextColor3 = Color3.fromRGB(210, 210, 225); b.TextSize = 13; b.Font = Enum.Font.GothamMedium; b.TextXAlignment = Enum.TextXAlignment.Left; Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
    b.MouseButton1Click:Connect(function() State[k] = not State[k]; b.Text = "  " .. (State[k] and "[ON] " or "[OFF] ") .. t; b.BackgroundColor3 = State[k] and Color3.fromRGB(40, 100, 60) or Color3.fromRGB(30, 30, 45); if cb then cb(State[k]) end end); addElement(b) 
end
local function button(t, cb) local b = Instance.new("TextButton"); b.Size = UDim2.new(1, 0, 0, 32); b.BackgroundColor3 = Color3.fromRGB(40, 35, 60); b.BackgroundTransparency = 0.3; b.Text = "  " .. t; b.TextColor3 = Color3.fromRGB(220, 210, 245); b.TextSize = 13; b.Font = Enum.Font.GothamMedium; b.TextXAlignment = Enum.TextXAlignment.Left; Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8); b.MouseButton1Click:Connect(function() pcall(cb) end); addElement(b) end
local function input(t, d, cb) local row = Instance.new("Frame"); row.Size = UDim2.new(1, 0, 0, 32); row.BackgroundTransparency = 1; local l = Instance.new("TextLabel", row); l.Size = UDim2.new(0.55, 0, 1, 0); l.BackgroundTransparency = 1; l.Text = "  "..t; l.TextColor3 = Color3.fromRGB(210, 210, 225); l.TextSize = 13; l.Font = Enum.Font.GothamMedium; l.TextXAlignment = Enum.TextXAlignment.Left; local b = Instance.new("TextBox", row); b.Size = UDim2.new(0.4, 0, 0, 26); b.Position = UDim2.new(0.58, 0, 0, 3); b.BackgroundColor3 = Color3.fromRGB(30, 30, 45); b.BackgroundTransparency = 0.3; b.Text = tostring(d); b.TextColor3 = Color3.fromRGB(225, 225, 240); b.TextSize = 13; b.Font = Enum.Font.GothamMedium; b.ClearTextOnFocus = false; Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8); b.FocusLost:Connect(function() local n = tonumber(b.Text); if n then pcall(cb, n) else b.Text = tostring(d) end end); addElement(row) end

createTab("Combat"); createTab("Visuals"); createTab("Weapons")

State.CurrentTab = "Combat"
section("AIMBOT (META)")
toggle("Silent Aim", "SilentAim")
toggle("Camera Aim", "CameraAimbot")
toggle("Triggerbot", "Triggerbot")
toggle("Hold to Aim (RMB)", "HoldToAim")
input("Smoothness", 0.25, function(n) State.AimbotSmoothness = n end)
input("FOV", 150, function(n) State.FOV = n; fovGui.Size = UDim2.new(0, n, 0, n); fovGui.Position = UDim2.new(0.5, -n/2, 0.5, -n/2) end)
toggle("Show FOV", "ShowFOV", function(v) fovGui.Visible = v end)
section("MELEE")
toggle("Kill Aura", "KillAura")
toggle("Hitbox Expander", "HitboxExpander")

State.CurrentTab = "Visuals"
section("RENDERING")
toggle("ESP", "ESP", function(v) if not v then for _, o in pairs(ESPCache) do o:Destroy() end; ESPCache = {} end end)
toggle("Tracers", "Tracers", function(v) if not v then clearTracers() end end)
toggle("Chams", "Chams", function(v) if not v then for _, p in ipairs(Players:GetPlayers()) do if p.Character then local hl = p.Character:FindFirstChild("pl_chams"); if hl then hl:Destroy() end end end end end)
toggle("Fullbright", "Fullbright")

State.CurrentTab = "Weapons"
section("WEAPONS")
button("🔫 AK-47", function() giveSpecificGun("AK-47") end)
button("🔫 M4A1", function() giveSpecificGun("M4A1") end)
button("🔫 Remington", function() giveSpecificGun("Remington 870") end)
button("🔫 M9", function() giveSpecificGun("M9") end)
button("⚡ Mod Guns", function() modEquippedGuns() end)
section("EXPLOITS")
toggle("Anti-Taze", "AntiTaze")
toggle("Auto Reload", "AutoReload")
toggle("Infinite Stamina", "InfStamina")

tabs["Combat"].BackgroundColor3 = Color3.fromRGB(60, 45, 90)
for _, child in ipairs(scroll:GetChildren()) do if child:IsA("GuiObject") and child:GetAttribute("Tab") ~= "Combat" then child.Visible = false end end

print("Prison Life Meta Engine v9 Loaded.")
