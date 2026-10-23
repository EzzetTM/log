-- Arizona Auto Pilot - Advanced Moonloader script
-- Relies on GTA SA internal AI for road routing; manual control is only assistive.

script_name("Arizona-AutoPilot")
script_description("Advanced auto-pilot for vehicles on Arizona RP")
script_authors("Arizona Tools")
script_version("2.0")
script_moonloader(026)
script_properties("work-in-pause")

local inicfg = require("inicfg")

local cfg = inicfg.load({
    main = {
        enabled = true,
        speed = 30.0,
        stopDistance = 8.0,
        reissueInterval = 4.0,
        progressTimeout = 6.0,
        maxRecoveries = 5
    }
}, "Arizona-AutoPilot.ini")

inicfg.save(cfg, "Arizona-AutoPilot.ini")

local PREFIX = "[ArizonaAP]"
local function msg(text)
    sampAddChatMessage(PREFIX .. " " .. text, 0xFFDD90)
end

-- State
local active = false
local target = nil          -- current intermediate target
local finalTarget = nil     -- final destination
local speed = cfg.main.speed
local forbidden = {
    { minX = -219.9, maxX = -101.8, minY = 1502.0, maxY = 2073.7 },
}

local serverCheckpoint = nil
local serverMapIcon = nil
local autoMarkerPending = false
local serverRaceCheckpoint = nil
local trackedMapIconId = nil
local obstacleSince = nil
local obstacleRecovered = false

local lastIssue = 0
local lastDistance = nil
local lastProgressTime = 0
local recoveryCount = 0
local detourUntil = nil
local lastMemRefresh = 0
local unlockUntil = nil

-- Utils
local function dist2D(ax, ay, bx, by)
    local dx = ax - bx
    local dy = ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function pointsEqual(a, b, tol)
    tol = tol or 1.0
    if not a or not b then return false end
    return math.abs(a.x - b.x) <= tol and math.abs(a.y - b.y) <= tol and math.abs((a.z or 0) - (b.z or 0)) <= tol
end

local function segmentHitsRect(x1, y1, x2, y2, rect)
    local minX, maxX = rect.minX - 5, rect.maxX + 5
    local minY, maxY = rect.minY - 5, rect.maxY + 5
    local function inside(x, y) return x >= minX and x <= maxX and y >= minY and y <= maxY end
    if inside(x1, y1) or inside(x2, y2) then return true end
    local function segIntersect(ax, ay, bx, by, cx, cy, dx, dy)
        local d = (bx - ax) * (dy - cy) - (by - ay) * (dx - cx)
        if d == 0 then return false end
        local t = ((cx - ax) * (dy - cy) - (cy - ay) * (dx - cx)) / d
        local u = ((cx - ax) * (by - ay) - (cy - ay) * (bx - ax)) / d
        return t >= 0 and t <= 1 and u >= 0 and u <= 1
    end
    if segIntersect(x1, y1, x2, y2, minX, minY, maxX, minY) then return true end
    if segIntersect(x1, y1, x2, y2, maxX, minY, maxX, maxY) then return true end
    if segIntersect(x1, y1, x2, y2, maxX, maxY, minX, maxY) then return true end
    if segIntersect(x1, y1, x2, y2, minX, maxY, minX, minY) then return true end
    return false
end

local function angleDiff(a, b)
    local d = a - b
    while d > math.pi do d = d - 2 * math.pi end
    while d < -math.pi do d = d + 2 * math.pi end
    return d
end

local function applyMemoryAutopilot(car)
    local mem_ok, mem = pcall(require, "SAMemory.init")
    if not mem_ok or not mem then return false end
    local ok = pcall(function()
        mem.require("CVehicle")
        mem.require("CAutoPilot")
        local ptr = getCarPointer(car)
        if not ptr then error("no ptr") end
        local v = mem.cast("CVehicle *", ptr)
        local ap = v.autoPilot
        if target then
            ap.vecDestinationCoors.x = target.x
            ap.vecDestinationCoors.y = target.y
            ap.vecDestinationCoors.z = target.z
        end
        ap.nCarMission = 7
        ap.nCarDrivingStyle = 1
        ap.nCruiseSpeed = math.floor(speed)
        if ap.nCruiseSpeed > 127 then ap.nCruiseSpeed = 127 end
        if ap.nCruiseSpeed < 1 then ap.nCruiseSpeed = 1 end
        ap.nStraightLineDistance = 0
        ap.nTimeToStartMission = 0
        ap.nTempAction = 0
        ap.nTempActionTime = 0
        v.nFlags.bEngineOn = 1
        v.nFlags.bIsHandbrakeOn = 0
        v.fBreakPedal = 0
        v.fGasPedal = 1.0
    end)
    return ok
end

local function issueTask(car, resetProgress)
    if not target then return false end
    if not car then
        msg("Cannot issue task: no vehicle")
        return false
    end
    clearCharTasks(PLAYER_PED)
    local ok = false
    local errors = {}
    local variants = {
        function() taskCarDriveToCoord(PLAYER_PED, car, target.x, target.y, target.z, speed, 0) end,
        function() taskCarDriveToCoord(PLAYER_PED, car, target.x, target.y, target.z, speed, 1) end,
        function() taskCarDriveToCoord(PLAYER_PED, car, target.x, target.y, target.z, speed) end,
    }
    for i, fn in ipairs(variants) do
        local s, e = pcall(fn)
        if s then
            ok = true
            msg("Drive task started, variant " .. i)
            break
        else
            table.insert(errors, "v" .. i .. ": " .. tostring(e))
        end
    end
    if not ok then
        msg("Cannot start autopilot: " .. table.concat(errors, " | "))
        active = false
        target = nil
        finalTarget = nil
        return false
    end
    lastIssue = os.clock()
    if resetProgress ~= false then
        lastDistance = nil
        lastProgressTime = os.clock()
    end
    local memOk, memRes = pcall(applyMemoryAutopilot, car)
    if memOk and memRes then msg("Memory autopilot applied") else msg("Memory autopilot failed") end
    return true
end

local function stopAutopilot(reason)
    local wasActive = active
    active = false
    target = nil
    finalTarget = nil
    detourUntil = nil
    obstacleSince = nil
    obstacleRecovered = false
    recoveryCount = 0
    lastDistance = nil
    lastProgressTime = 0
    lastIssue = 0
    lastMemRefresh = 0
    local car = nil
    pcall(function() car = getCarCharIsUsing(PLAYER_PED) end)
    pcall(clearCharTasks, PLAYER_PED)
    if car then
        pcall(setCarCruiseSpeed, car, 0)
        pcall(function()
            local mem = require("SAMemory.init")
            if not mem then return end
            mem.require("CVehicle")
            mem.require("CAutoPilot")
            local ptr = getCarPointer(car)
            if not ptr then return end
            local v = mem.cast("CVehicle *", ptr)
            local ap = v.autoPilot
            ap.nCarMission = 0
            ap.nCruiseSpeed = 0
        end)
    end
    pcall(lockPlayerControl, false)
    pcall(setPlayerControl, PLAYER_PED, true)
    pcall(setPlayerControl, PLAYER_HANDLE, true)
    unlockUntil = nil
    if reason then
        msg(reason)
    elseif wasActive then
        msg("Autopilot stopped")
    else
        msg("Autopilot was not active")
    end
end

local function getMarkerCoords()
    if serverRaceCheckpoint then
        return serverRaceCheckpoint.x, serverRaceCheckpoint.y, serverRaceCheckpoint.z
    end
    if serverCheckpoint then
        return serverCheckpoint.x, serverCheckpoint.y, serverCheckpoint.z
    end
    if serverMapIcon then
        return serverMapIcon.x, serverMapIcon.y, serverMapIcon.z
    end
    local ok, x, y, z = pcall(getTargetBlipCoordinates)
    if ok and x and (x ~= 0 or y ~= 0) then
        return x, y, z
    end
    return nil
end

local function startAutopilot(x, y, z, spd)
    if not cfg.main.enabled then
        msg("Autopilot disabled in config")
        return false
    end
    if not isCharInAnyCar(PLAYER_PED) then
        msg("Get into a vehicle")
        return false
    end
    x = tonumber(x); y = tonumber(y); z = tonumber(z)
    if not x or not y or not z then
        msg("Invalid coordinates")
        return false
    end
    if z == 0 then
        local car = getCarCharIsUsing(PLAYER_PED)
        if car then
            local _, _, cz = getCarCoordinates(car)
            if cz then z = cz end
        end
    end
    finalTarget = { x = x, y = y, z = z }
    target = { x = x, y = y, z = z }
    detourUntil = nil
    recoveryCount = 0
    lastDistance = nil
    lastProgressTime = 0
    lastMemRefresh = 0
    -- Route around forbidden rectangle if direct path crosses it
    local car = getCarCharIsUsing(PLAYER_PED)
    if not car then
        msg("Cannot access vehicle")
        active = false
        target = nil
        finalTarget = nil
        return false
    end
    local cx, cy, cz = getCarCoordinates(car)
    if not cx then
        msg("Cannot read vehicle coordinates")
        active = false
        target = nil
        finalTarget = nil
        return false
    end
    for _, rect in ipairs(forbidden) do
        if segmentHitsRect(cx, cy, x, y, rect) then
            local rcy = (rect.minY + rect.maxY) / 2
            local wp
            if cy < rcy then
                wp = { x = (rect.minX + rect.maxX) / 2, y = rect.minY - 20.0, z = cz }
            else
                wp = { x = (rect.minX + rect.maxX) / 2, y = rect.maxY + 20.0, z = cz }
            end
            target = { x = wp.x, y = wp.y, z = wp.z }
            msg("Routing around restricted area")
            break
        end
    end
    speed = tonumber(spd) or cfg.main.speed
    local car2 = getCarCharIsUsing(PLAYER_PED)
    local taskOk = issueTask(car2)
    if not taskOk then
        active = false
        target = nil
        finalTarget = nil
        msg("Autopilot failed to start")
        return false
    end
    active = true
    pcall(lockPlayerControl, false)
    pcall(setPlayerControl, PLAYER_PED, true)
    pcall(setPlayerControl, PLAYER_HANDLE, true)
    local engineOk, engineRes = pcall(setCarEngineOn, car2, true)
    if not engineOk then
        engineOk, engineRes = pcall(setCarEngineOn, car2, 1)
    end
    local flagOk, flagVal = pcall(function()
        local mem = require("SAMemory.init")
        if not mem then return nil end
        mem.require("CVehicle")
        local ptr = getCarPointer(car2)
        if not ptr then return nil end
        local v = mem.cast("CVehicle *", ptr)
        return v.nFlags.bEngineOn
    end)
    msg("Engine on command: " .. tostring(engineOk) .. ", flag=" .. tostring(flagVal))
    msg(string.format("Route set: %.1f, %.1f, %.1f (speed %.0f)", x, y, z, speed))
    return true
end

-- Commands
function cmd_ap(arg)
    arg = arg or ""
    arg = arg:match("^%s*(.-)%s*$") or ""
    if arg == "" or arg:lower() == "marker" then
        local x, y, z = getMarkerCoords()
        if not x then
            msg("Place a map marker first: /ap marker")
            return
        end
        if x == 0 and y == 0 and z == 0 then
            msg("Marker not found")
            return
        end
        msg(string.format("Marker: %.1f, %.1f, %.1f", x, y, z))
        startAutopilot(x, y, z, nil)
        return
    end
    local tokens = {}
    for token in arg:gmatch("%S+") do
        table.insert(tokens, token)
    end
    if #tokens >= 3 then
        startAutopilot(tokens[1], tokens[2], tokens[3], tokens[4])
    else
        msg("Usage: /ap x y z [speed] or /ap marker")
    end
end

function cmd_apstop()
    stopAutopilot("Autopilot stopped")
end

function main()
    repeat wait(0) until isSampAvailable()
    sampRegisterChatCommand("ap", cmd_ap)
    sampRegisterChatCommand("apstop", cmd_apstop)

    local sampev = require("lib.samp.events")
    sampev.onSetCheckpoint = function(position, radius)
        if position and type(position) == "table" then
            serverCheckpoint = { x = position.x or position[1], y = position.y or position[2], z = position.z or position[3] }
            autoMarkerPending = true
        end
    end
    sampev.onDisableCheckpoint = function()
        serverCheckpoint = nil
    end
    sampev.onSetMapIcon = function(iconId, position, iconType, color, style)
        if position and type(position) == "table" then
            serverMapIcon = { x = position.x or position[1], y = position.y or position[2], z = position.z or position[3], id = iconId }
            trackedMapIconId = iconId
            autoMarkerPending = true
        end
    end
    sampev.onRemoveMapIcon = function(iconId)
        if trackedMapIconId and iconId == trackedMapIconId then
            serverMapIcon = nil
            trackedMapIconId = nil
        end
    end
    sampev.onSetRaceCheckpoint = function(cpType, position, nextPosition, size)
        if position and type(position) == "table" then
            serverRaceCheckpoint = { x = position.x or position[1], y = position.y or position[2], z = position.z or position[3], next = nextPosition }
            autoMarkerPending = true
        end
    end
    sampev.onDisableRaceCheckpoint = function()
        serverRaceCheckpoint = nil
    end

    msg("Loaded v2. Commands: /ap x y z [speed], /ap marker, /apstop")

    while true do
        wait(0)
        if unlockUntil and os.clock() < unlockUntil then
            pcall(lockPlayerControl, false)
            pcall(setPlayerControl, PLAYER_PED, true)
            pcall(setPlayerControl, PLAYER_HANDLE, true)
        else
            unlockUntil = nil
        end

        -- Auto-start on server marker placement
        if (not active) and autoMarkerPending then
            autoMarkerPending = false
            if isCharInAnyCar(PLAYER_PED) then
                local mx, my, mz = getMarkerCoords()
                if mx then startAutopilot(mx, my, mz) end
            end
        end

        -- Redirect to new server marker while active
        if active and autoMarkerPending then
            autoMarkerPending = false
            local mx, my, mz = getMarkerCoords()
            if mx then
                finalTarget = { x = mx, y = my, z = mz }
                target = { x = mx, y = my, z = mz }
                msg("New server marker, redirecting")
                local car = getCarCharIsUsing(PLAYER_PED)
                if car then
                    local ok = issueTask(car)
                    if not ok then msg("Redirect failed") end
                else
                    msg("No vehicle for redirect")
                end
            end
        end

        if active then
            if not isCharInAnyCar(PLAYER_PED) then
                stopAutopilot("Left the vehicle")
            else
                local car = getCarCharIsUsing(PLAYER_PED)
                if not car then
                    stopAutopilot("Vehicle lost")
                    goto continue_loop
                end
                local cx, cy, cz = getCarCoordinates(car)
                if not cx then
                    stopAutopilot("Cannot read vehicle position")
                    goto continue_loop
                end
                if os.clock() - lastMemRefresh > 2.0 then
                    lastMemRefresh = os.clock()
                    local mOk, mRes = pcall(applyMemoryAutopilot, car)
                    if not (mOk and mRes) then
                        msg("Memory autopilot refresh failed")
                    end
                end

                -- Assistive manual control: engine on, gas/brake for turns, no steering override
                pcall(function()
                    local mem = require("SAMemory.init")
                    if not mem then return end
                    mem.require("CVehicle")
                    local ptr = getCarPointer(car)
                    if not ptr then return end
                    local v = mem.cast("CVehicle *", ptr)
                    v.nFlags.bEngineOn = 1
                    v.nFlags.bIsHandbrakeOn = 0
                    if target then
                        local dx = target.x - cx
                        local dy = target.y - cy
                        local desired = math.atan2(dx, dy)
                        local cur = v.nPlacement.fHeading
                        local diff = angleDiff(desired, cur)
                        if math.abs(diff) > 0.6 then
                            v.fGasPedal = 0.4
                            v.fBreakPedal = 0.35
                        else
                            v.fGasPedal = 1.0
                            v.fBreakPedal = 0.0
                        end
                    else
                        v.fGasPedal = 1.0
                        v.fBreakPedal = 0.0
                    end
                end)

                local obstacleAhead = false
                pcall(function()
                    local fx = getCarForwardX(car)
                    local fy = getCarForwardY(car)
                    local x1, y1, z1 = cx, cy, cz + 1.0
                    local x2, y2, z2 = cx + fx * 4.0, cy + fy * 4.0, cz + 1.0
                    local x3, y3, z3 = cx + fx * 4.0, cy + fy * 4.0, cz + 2.5
                    local c1 = isLineOfSightClear(x1, y1, z1, x2, y2, z2)
                    local c2 = isLineOfSightClear(x1, y1, z1, x3, y3, z3)
                    if c1 == false or c2 == false then obstacleAhead = true end
                end)

                -- Obstacle state handling
                if obstacleAhead then
                    if not obstacleSince then obstacleSince = os.clock() end
                    pcall(function()
                        local mem = require("SAMemory.init")
                        if not mem then return end
                        mem.require("CVehicle")
                        local ptr = getCarPointer(car)
                        if not ptr then return end
                        local v = mem.cast("CVehicle *", ptr)
                        v.fGasPedal = 0.0
                        v.fBreakPedal = 1.0
                    end)
                    if os.clock() - obstacleSince > 3.0 and not obstacleRecovered then
                        obstacleRecovered = true
                        msg("Obstacle persists, reissuing route")
                        issueTask(car)
                    end
                    if os.clock() - obstacleSince > 6.0 then
                        stopAutopilot("Obstacle ahead, cannot proceed")
                    end
                else
                    obstacleSince = nil
                    obstacleRecovered = false
                end

                if target then
                        local d = dist2D(cx, cy, target.x, target.y)
                        if d <= (cfg.main.stopDistance or 8.0) then
                            if finalTarget and not pointsEqual(target, finalTarget, 1.0) then
                                target = { x = finalTarget.x, y = finalTarget.y, z = finalTarget.z }
                                local ok = issueTask(car)
                                if not ok then
                                    msg("Failed to issue route to final target")
                                end
                            else
                                if serverRaceCheckpoint and pointsEqual(target, serverRaceCheckpoint, 5.0) then
                                    serverRaceCheckpoint = nil
                                end
                                stopAutopilot("Arrived")
                            end
                        else
                            -- Stuck detection by progress toward target
                            if lastDistance == nil then
                                lastDistance = d
                                lastProgressTime = os.clock()
                            elseif d <= lastDistance - 2.0 then
                                lastDistance = d
                                lastProgressTime = os.clock()
                            elseif os.clock() - lastProgressTime > (cfg.main.progressTimeout or 6.0) then
                                if recoveryCount < (cfg.main.maxRecoveries or 5) then
                                    recoveryCount = recoveryCount + 1
                                    msg("Stuck, reissuing route (" .. recoveryCount .. ")")
                                    local ok = issueTask(car, true)
                                    if not ok then
                                        msg("Recovery failed")
                                    end
                                else
                                    stopAutopilot("Too many recoveries")
                                end
                            end

                            -- Periodic reissue without resetting stuck timer
                            if os.clock() - lastIssue >= (cfg.main.reissueInterval or 4.0) then
                                issueTask(car, false)
                            end
                        end
                    end
                end
            end
        end
        ::continue_loop::
    end
end

