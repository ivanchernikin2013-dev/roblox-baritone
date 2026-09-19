local Players = game:GetService("Players")
local plr = Players.LocalPlayer

local Baritone = {}
Baritone.Version = "1.3.0"

local DEFAULTS = {
    walkSpeed = 14,
    searchRange = 250,
    avoidWater = false,
    avoidCliffs = true,
    jumpHeight = 3,
    cliffDrop = 6,
    targetReachDistance = 5,
    tickRate = 0.05,
    escapeDuration = 3,
    escapeJumpCooldown = 0.6,
    stuckJumpTime = 1,
    stuckResetTime = 2,
    pendingJumpCooldown = 0.35,
    dirUpdateInterval = 0.25,
    targetSearchInterval = 0.5,
    wanderInterval = 4,
    enabled = false,
    debug = false,
    TREE_NAMES = {
        ["Small Tree"]=true, ["Apple Tree"]=true, ["Orange Tree"]=true,
        ["Lemon Tree"]=true, ["Banana Tree"]=true, ["Coconut Tree"]=true,
        ["Volcanic Tree"]=true, ["Swoll Tree"]=true, ["Palm Tree"]=true,
        ["Jungle Tree"]=true, ["Odd Tree"]=true,
    },
    DIR_ANGLES = { 0, 15, -15, 30, -30, 45, -45, 60, -60, 90, -90, 120, -120, 150, -150, 180 },
}

local Config = {}
for k, v in pairs(DEFAULTS) do
    if type(v) == "table" then
        local c = {}
        for k2, v2 in pairs(v) do c[k2] = v2 end
        Config[k] = c
    else
        Config[k] = v
    end
end

-- ============================================================
-- UTIL
-- ============================================================
local function getRoot()
    local c = plr.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHumanoid()
    local c = plr.Character
    return c and c:FindFirstChildOfClass("Humanoid")
end
local function getPrimaryPart(obj)
    if not obj then return nil end
    if obj:IsA("BasePart") then return obj end
    return obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")
end

local function makeParams()
    local p = RaycastParams.new()
    p.FilterType = Enum.RaycastFilterType.Exclude
    p.IgnoreWater = false
    local list = {}
    local char = plr.Character
    if char then table.insert(list, char) end
    p.FilterDescendantsInstances = list
    return p
end

local function raycast(from, to)
    if not from or not to then return nil end
    local ok, hit = pcall(function()
        return workspace:Raycast(from, to - from, makeParams())
    end)
    return ok and hit or nil
end

local function getGroundY(pos, maxDist)
    if not pos then return nil end
    local from = pos + Vector3.new(0, maxDist / 2, 0)
    local hit = raycast(from, from + Vector3.new(0, -maxDist, 0))
    if hit then return hit.Position.Y end
    return nil
end

local function checkWaterAt(pos)
    local ok, mat = pcall(function()
        return workspace.Terrain:ReadVoxels(
            Region3.new(pos - Vector3.new(1, 0.5, 1), pos + Vector3.new(1, 0.5, 1)), 4)
    end)
    if not ok or not mat then return false end
    for x = 1, mat.Size.X do
        for y = 1, mat.Size.Y do
            for z = 1, mat.Size.Z do
                if mat[x][y][z] == Enum.Material.Water then return true end
            end
        end
    end
    return false
end

local function isInWater(myRoot)
    return myRoot and checkWaterAt(myRoot.Position)
end

-- ============================================================
-- STATE
-- ============================================================
local state = {
    running = false,
    thread = nil,
    currentTarget = nil,
    currentDir = nil,
    pendingJump = false,
    lastJump = 0,
    lastY = nil,
    yDropTimer = 0,
    stuckTimer = 0,
    lastPos = nil,
    lastDirUpdate = 0,
    lastTargetSearch = 0,
    escapeUntil = 0,
    wanderDir = nil,
    wanderChangeAt = 0,
    stopCallbacks = {},
}

local function bd(msg)
    if Config.debug then print("[Baritone]", msg) end
end

-- ============================================================
-- TARGET
-- ============================================================
local function findTree()
    local folder = workspace:FindFirstChild("Resources")
    if not folder then return nil end
    local myRoot = getRoot()
    if not myRoot then return nil end
    local myPos = myRoot.Position
    local best, bestDist = nil, math.huge
    for _, obj in ipairs(folder:GetChildren()) do
        if obj:IsA("Model") and Config.TREE_NAMES[obj.Name] then
            local pp = getPrimaryPart(obj)
            if pp then
                local d = (pp.Position - myPos).Magnitude
                if d <= Config.searchRange and d < bestDist then
                    best, bestDist = obj, d
                end
            end
        end
    end
    return best, bestDist
end

local function isTreeAlive(tree)
    if not tree or not tree.Parent then return false end
    if not tree:IsDescendantOf(workspace) then return false end
    return true
end

local function getTargetDirection(tree)
    if not tree then return nil, 0 end
    local myRoot = getRoot()
    if not myRoot then return nil, 0 end
    local pp = getPrimaryPart(tree)
    if not pp then return nil, 0 end
    local flat = Vector3.new(pp.Position.X - myRoot.Position.X, 0, pp.Position.Z - myRoot.Position.Z)
    local dist = flat.Magnitude
    if dist < 0.5 then return nil, 0 end
    return flat.Unit, dist
end

-- ============================================================
-- DIRECTION EVALUATION
-- ============================================================
local function evaluateDirection(myRoot, dir, inWater)
    local myY = myRoot.Position.Y
    local origin = myRoot.Position + Vector3.new(0, 1, 0)
    local score = 10
    local needJump = false

    local hit1 = raycast(origin, origin + dir * 2)
    if hit1 then
        local diff = hit1.Position.Y - myY
        if diff > Config.jumpHeight + 1 then
            score = score - 25
        elseif diff > 0.5 then
            needJump = true
            score = score - 4
        else
            score = score - 12
        end
    end

    if Config.avoidCliffs then
        local ahead = myRoot.Position + dir * 3
        local groundY = getGroundY(ahead, 25)
        if groundY then
            local drop = myY - groundY
            if drop > Config.cliffDrop then
                score = score - 30
            elseif drop > 3 then
                score = score - 8
            end
        else
            score = score - 40
        end
    end

    -- Штраф за воду ТОЛЬКО если уже НЕ в воде
    if Config.avoidWater and not inWater then
        local ahead = myRoot.Position + dir * 2
        if checkWaterAt(ahead) then
            score = score - 20
        end
    end

    return score, needJump
end

local function findBestDirection(myRoot, goalDir)
    if not goalDir then return nil, false end
    local inWater = isInWater(myRoot)
    local bestDir = nil
    local bestScore = -math.huge
    local bestJump = false

    for _, deg in ipairs(Config.DIR_ANGLES) do
        local rad = math.rad(deg)
        local cos, sin = math.cos(rad), math.sin(rad)
        local testDir = Vector3.new(
            goalDir.X * cos - goalDir.Z * sin, 0,
            goalDir.X * sin + goalDir.Z * cos
        ).Unit
        local score, needJump = evaluateDirection(myRoot, testDir, inWater)
        score = score - math.abs(deg) * 0.1
        if score > bestScore then
            bestScore = score
            bestDir = testDir
            bestJump = needJump
        end
    end

    -- Никогда не возвращаем nil — всегда едем хоть куда-то
    if not bestDir then return goalDir, false end
    return bestDir, bestJump
end

-- ============================================================
-- ESCAPE
-- ============================================================
local function findEscapeDirection(myRoot)
    local bestDir = nil
    local bestY = myRoot.Position.Y
    for i = 0, 15 do
        local angle = i * math.pi / 8
        local dir = Vector3.new(math.cos(angle), 0, math.sin(angle)).Unit
        local ahead = myRoot.Position + dir * 4
        local gY = getGroundY(ahead, 25)
        if gY then
            local hit = raycast(myRoot.Position + Vector3.new(0, 1, 0),
                                myRoot.Position + Vector3.new(0, 1, 0) + dir * 3)
            local blocked = hit ~= nil and (hit.Position.Y - myRoot.Position.Y) > Config.jumpHeight + 1
            if not blocked and gY > bestY then
                bestY = gY
                bestDir = dir
            end
        end
    end
    return bestDir
end

-- ============================================================
-- MOVE
-- ============================================================
local function moveHumanoid(humanoid, myRoot, dir)
    if not humanoid or not myRoot or not dir then return end
    local hs = humanoid:GetState()
    if hs == Enum.HumanoidStateType.Swimming
        or hs == Enum.HumanoidStateType.Freefall
        or hs == Enum.HumanoidStateType.FallingDown
        or hs == Enum.HumanoidStateType.Climbing then
        humanoid:MoveTo(myRoot.Position + dir * 12)
    else
        humanoid:Move(dir, false)
    end
end

-- ============================================================
-- MAIN TICK
-- ============================================================
local function tick()
    if not Config.enabled then return end

    local myRoot = getRoot()
    local humanoid = getHumanoid()
    if not myRoot or not humanoid then return end
    if humanoid.Health <= 0 then return end

    local now = tick()
    local myY = myRoot.Position.Y

    -- Falling detection
    if state.lastY then
        local dY = state.lastY - myY
        if dY > 0.3 then
            state.yDropTimer = state.yDropTimer + Config.tickRate
        else
            state.yDropTimer = math.max(0, state.yDropTimer - 0.05)
        end
    end
    state.lastY = myY

    if state.yDropTimer > 0.4 then
        bd("falling detected -> escape")
        state.escapeUntil = now + Config.escapeDuration
        state.yDropTimer = 0
    end

    -- Escape mode
    if now < state.escapeUntil then
        local escapeDir = findEscapeDirection(myRoot)
        if escapeDir then
            humanoid.WalkSpeed = Config.walkSpeed + 2
            moveHumanoid(humanoid, myRoot, escapeDir)
        else
            humanoid:Move(Vector3.zero, false)
        end
        if tick() - state.lastJump > Config.escapeJumpCooldown then
            humanoid.Jump = true
            state.lastJump = tick()
        end
        return
    end

    humanoid.WalkSpeed = Config.walkSpeed

    -- Update target
    if now - state.lastTargetSearch > Config.targetSearchInterval then
        state.lastTargetSearch = now
        if state.currentTarget and not isTreeAlive(state.currentTarget) then
            state.currentTarget = nil
        end
        if not state.currentTarget then
            local tree, dist = findTree()
            if tree then
                state.currentTarget = tree
                bd(string.format("target: %s (%.0fm)", tree.Name, dist or 0))
            end
        end
    end

    -- НЕТ ЦЕЛИ — бродим
    if not state.currentTarget then
        if not state.wanderDir or now - state.wanderChangeAt > Config.wanderInterval then
            local angle = math.random() * math.pi * 2
            state.wanderDir = Vector3.new(math.cos(angle), 0, math.sin(angle))
            state.wanderChangeAt = now
        end
        moveHumanoid(humanoid, myRoot, state.wanderDir)
        return
    end

    local goalDir, dist = getTargetDirection(state.currentTarget)
    if not goalDir or dist < Config.targetReachDistance then
        humanoid:Move(Vector3.zero, false)
        return
    end

    -- Recalculate direction
    if now - state.lastDirUpdate > Config.dirUpdateInterval or not state.currentDir then
        state.lastDirUpdate = now
        local bestDir, needJump = findBestDirection(myRoot, goalDir)
        state.currentDir = bestDir or goalDir
        state.pendingJump = needJump
    end

    if state.currentDir then
        moveHumanoid(humanoid, myRoot, state.currentDir)
        if state.pendingJump then
            if tick() - state.lastJump > Config.pendingJumpCooldown then
                humanoid.Jump = true
                state.lastJump = tick()
            end
        end
    end

    -- Anti-stuck
    if state.lastPos then
        local moved = (myRoot.Position - state.lastPos).Magnitude
        state.lastPos = myRoot.Position

        if moved < 0.15 then
            state.stuckTimer = state.stuckTimer + Config.tickRate
            if state.stuckTimer > Config.stuckJumpTime then
                if tick() - state.lastJump > 0.5 then
                    humanoid.Jump = true
                    state.lastJump = tick()
                end
            end
            if state.stuckTimer > Config.stuckResetTime then
                state.currentDir = nil
                state.stuckTimer = 0
                state.wanderDir = nil
                state.wanderChangeAt = 0
            end
        else
            state.stuckTimer = math.max(0, state.stuckTimer - 0.1)
        end
    else
        state.lastPos = myRoot.Position
    end
end

-- ============================================================
-- PUBLIC API
-- ============================================================
function Baritone.Start()
    if state.running then return end
    state.running = true
    Config.enabled = true
    state.lastY = nil
    state.yDropTimer = 0
    state.stuckTimer = 0
    state.escapeUntil = 0
    state.wanderDir = nil
    state.wanderChangeAt = 0
    state.currentDir = nil
    state.lastPos = nil
    bd("started v" .. Baritone.Version)

    state.thread = task.spawn(function()
        while state.running do
            local ok, err = pcall(tick)
            if not ok then bd("tick error: " .. tostring(err)) end
            task.wait(Config.tickRate)
        end
        local h = getHumanoid()
        if h then h:Move(Vector3.zero, false) end
    end)
end

function Baritone.Stop()
    if not state.running then return end
    state.running = false
    Config.enabled = false
    state.currentTarget = nil
    state.currentDir = nil
    if state.thread then
        pcall(task.cancel, state.thread)
        state.thread = nil
    end
    local h = getHumanoid()
    if h then h:Move(Vector3.zero, false) end
    for _, cb in ipairs(state.stopCallbacks) do pcall(cb) end
end

function Baritone.IsRunning() return state.running end
function Baritone.Set(key, value)
    if Config[key] == nil then return false end
    Config[key] = value
    return true
end
function Baritone.Get(key) return Config[key] end
function Baritone.GetCurrentTarget() return state.currentTarget end
function Baritone.GetAllConfig()
    local out = {}
    for k, v in pairs(Config) do out[k] = v end
    return out
end
function Baritone.OnStop(cb)
    table.insert(state.stopCallbacks, cb)
end

return Baritone
