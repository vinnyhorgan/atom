-- Atom
-- A detailed simulation of U-235 fission chain reactions
-- made with <3 by vinny

local flux = require "flux"

---------------------------------------------------------------------
-- Constants & tuning
---------------------------------------------------------------------
local W, H = 1280, 780
local SIDEBAR_W = 340
local MARGIN = 15
local REACTOR_X = SIDEBAR_W + MARGIN
local REACTOR_Y = MARGIN
local REACTOR_W = W - REACTOR_X - MARGIN
local REACTOR_H = H - MARGIN * 2
local BOTTOM_Y = REACTOR_Y + REACTOR_H + 12

-- Physics
local NEUTRON_SPEED       = 220   -- px/s base speed
local NEUTRON_RADIUS      = 3
local ATOM_RADIUS         = 18
local FISSION_PRODUCT_R   = 12
local CAPTURE_RADIUS      = ATOM_RADIUS + NEUTRON_RADIUS
local FISSION_ENERGY      = 200   -- MeV per fission event
local NEUTRONS_PER_FISSION = {2, 3} -- random range

-- Control rod geometry
local NUM_CONTROL_RODS    = 5
local ROD_WIDTH           = 14
local ROD_COLOR           = {0.35, 0.35, 0.40, 0.85}

-- Colors
local COLOR_BG            = {0.05, 0.06, 0.08}
local COLOR_REACTOR_BG    = {0.08, 0.09, 0.12}
local COLOR_REACTOR_WALL  = {0.25, 0.28, 0.35}
local COLOR_URANIUM       = {0.15, 0.75, 0.25}
local COLOR_URANIUM_GLOW  = {0.2, 1.0, 0.35, 0.15}
local COLOR_NEUTRON       = {0.95, 0.85, 0.3}
local COLOR_NEUTRON_FAST  = {1.0, 0.5, 0.15}
local COLOR_FISSION_PROD  = {0.6, 0.3, 0.9}
local COLOR_ENERGY_FLASH  = {1, 1, 0.8}
local COLOR_TEXT           = {0.85, 0.88, 0.92}
local COLOR_ACCENT         = {0.3, 0.7, 1.0}
local COLOR_DANGER         = {1.0, 0.3, 0.25}
local COLOR_SIDEBAR_BG     = {0.07, 0.08, 0.10}

---------------------------------------------------------------------
-- State
---------------------------------------------------------------------
local atoms       = {}   -- {x, y, radius, alive, glow, pulsePhase}
local neutrons    = {}   -- {x, y, vx, vy, alive, age}
local fragments   = {}   -- fission products {x, y, vx, vy, radius, alive, alpha, r, g, b}
local flashes     = {}   -- {x, y, radius, alpha}
local trails      = {}   -- neutron trails {x, y, alpha}

local totalEnergy     = 0
local fissionCount    = 0
local neutronsFired   = 0
local peakNeutrons    = 0
local simSpeed        = 1.0
local paused          = false

-- Control rods
local controlRodInserted = 0.0  -- 0 = fully withdrawn, 1 = fully inserted
local controlRodTarget   = 0.0
local controlRodObj      = { value = 0.0 }

-- Camera shake
local shakeAmount = 0
local shakeObj = { value = 0 }

-- UI animation targets
local energyDisplay = { value = 0 }
local tempDisplay   = { value = 0 }
local reactorTemp   = 0
local meltdown      = false

-- Particle systems
local glowPS, sparkPS, flashPS

-- Fonts
local fontSmall, fontMed, fontLarge, fontHuge

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function dist(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return math.sqrt(dx*dx + dy*dy)
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function inReactor(x, y, margin)
    margin = margin or 0
    return x > REACTOR_X + margin and x < REACTOR_X + REACTOR_W - margin
       and y > REACTOR_Y + margin and y < REACTOR_Y + REACTOR_H - margin
end

local function randomAngle()
    return love.math.random() * math.pi * 2
end

local function lerp(a, b, t) return a + (b - a) * t end

---------------------------------------------------------------------
-- Initialization
---------------------------------------------------------------------
function love.load()
    love.window.setTitle("Atom")
    love.graphics.setBackgroundColor(unpack(COLOR_BG))

    fontSmall = love.graphics.newFont(14)
    fontMed   = love.graphics.newFont(16)
    fontLarge = love.graphics.newFont(22)
    fontHuge  = love.graphics.newFont(36)

    initParticleSystems()
    spawnAtoms(30)
end

function initParticleSystems()
    -- Glow particles for fission events
    local glowImg = love.graphics.newCanvas(32, 32)
    love.graphics.setCanvas(glowImg)
    love.graphics.clear(0, 0, 0, 0)
    for r = 16, 1, -1 do
        local a = (1 - r/16) * 0.6
        love.graphics.setColor(1, 1, 1, a)
        love.graphics.circle("fill", 16, 16, r)
    end
    love.graphics.setCanvas()
    love.graphics.setColor(1, 1, 1, 1)

    glowPS = love.graphics.newParticleSystem(glowImg, 500)
    glowPS:setParticleLifetime(0.3, 0.8)
    glowPS:setEmissionRate(0)
    glowPS:setSpeed(80, 200)
    glowPS:setSizes(0.8, 0.3)
    glowPS:setColors(
        1, 0.9, 0.4, 0.9,
        1, 0.5, 0.1, 0.5,
        1, 0.2, 0.05, 0
    )
    glowPS:setSpread(math.pi * 2)
    glowPS:setLinearAcceleration(-20, -20, 20, 20)

    -- Spark particles for neutron trails
    local sparkImg = love.graphics.newCanvas(8, 8)
    love.graphics.setCanvas(sparkImg)
    love.graphics.clear(0, 0, 0, 0)
    for r = 4, 1, -1 do
        local a = (1 - r/4) * 1.0
        love.graphics.setColor(1, 1, 1, a)
        love.graphics.circle("fill", 4, 4, r)
    end
    love.graphics.setCanvas()
    love.graphics.setColor(1, 1, 1, 1)

    sparkPS = love.graphics.newParticleSystem(sparkImg, 2000)
    sparkPS:setParticleLifetime(0.1, 0.4)
    sparkPS:setEmissionRate(0)
    sparkPS:setSpeed(10, 40)
    sparkPS:setSizes(0.6, 0.1)
    sparkPS:setColors(
        1, 0.9, 0.5, 0.7,
        1, 0.6, 0.2, 0.0
    )
    sparkPS:setSpread(math.pi * 2)
end

function spawnAtoms(count)
    atoms = {}
    local margin = ATOM_RADIUS * 3
    for i = 1, count do
        local placed = false
        local attempts = 0
        while not placed and attempts < 200 do
            local ax = REACTOR_X + margin + love.math.random() * (REACTOR_W - margin * 2)
            local ay = REACTOR_Y + margin + love.math.random() * (REACTOR_H - margin * 2)
            -- Check no overlap with existing atoms
            local ok = true
            for _, a in ipairs(atoms) do
                if dist(ax, ay, a.x, a.y) < ATOM_RADIUS * 3 then
                    ok = false
                    break
                end
            end
            if ok then
                table.insert(atoms, {
                    x = ax, y = ay,
                    radius = ATOM_RADIUS,
                    alive = true,
                    glow = 0,
                    pulsePhase = love.math.random() * math.pi * 2,
                    wobble = { x = 0, y = 0 },
                })
                placed = true
            end
            attempts = attempts + 1
        end
    end
end

---------------------------------------------------------------------
-- Fission event
---------------------------------------------------------------------
function triggerFission(atom, neutron)
    atom.alive = false
    fissionCount = fissionCount + 1

    -- Energy
    totalEnergy = totalEnergy + FISSION_ENERGY
    flux.to(energyDisplay, 0.5, { value = totalEnergy }):ease("expoout")

    -- Temperature rises
    reactorTemp = reactorTemp + 15
    flux.to(tempDisplay, 0.8, { value = reactorTemp }):ease("expoout")

    -- Camera shake
    shakeAmount = math.min(shakeAmount + 3, 15)
    shakeObj.value = shakeAmount
    flux.to(shakeObj, 0.6, { value = 0 }):ease("expoout")
        :onupdate(function() shakeAmount = shakeObj.value end)

    -- Flash
    table.insert(flashes, { x = atom.x, y = atom.y, radius = 5, alpha = 1.0 })
    local fl = flashes[#flashes]
    flux.to(fl, 0.6, { radius = 80, alpha = 0 }):ease("expoout")

    -- Particle burst
    glowPS:setPosition(atom.x, atom.y)
    glowPS:emit(30)

    -- Spawn fission products (two daughter nuclei)
    local angle = randomAngle()
    local speed = 60 + love.math.random() * 40
    for i = 0, 1 do
        local a = angle + i * math.pi
        local hues = {
            {0.55, 0.3, 0.85},
            {0.85, 0.35, 0.55},
        }
        table.insert(fragments, {
            x = atom.x, y = atom.y,
            vx = math.cos(a) * speed,
            vy = math.sin(a) * speed,
            radius = FISSION_PRODUCT_R,
            alive = true,
            alpha = 1.0,
            r = hues[i+1][1], g = hues[i+1][2], b = hues[i+1][3],
            life = 4.0,
        })
    end

    -- Spawn new neutrons (chain reaction!)
    local numNew = love.math.random(NEUTRONS_PER_FISSION[1], NEUTRONS_PER_FISSION[2])
    for i = 1, numNew do
        local a = randomAngle()
        local spd = NEUTRON_SPEED * (0.8 + love.math.random() * 0.6)
        table.insert(neutrons, {
            x = atom.x + math.cos(a) * ATOM_RADIUS,
            y = atom.y + math.sin(a) * ATOM_RADIUS,
            vx = math.cos(a) * spd,
            vy = math.sin(a) * spd,
            alive = true,
            age = 0,
            generation = (neutron.generation or 0) + 1,
        })
    end
end

---------------------------------------------------------------------
-- Fire neutron (user action)
---------------------------------------------------------------------
function fireNeutron(tx, ty)
    local sx = REACTOR_X + 10
    local sy = REACTOR_Y + REACTOR_H / 2
    local angle = math.atan2(ty - sy, tx - sx)
    local spd = NEUTRON_SPEED * 1.2
    table.insert(neutrons, {
        x = sx, y = sy,
        vx = math.cos(angle) * spd,
        vy = math.sin(angle) * spd,
        alive = true,
        age = 0,
        generation = 0,
    })
    neutronsFired = neutronsFired + 1

    sparkPS:setPosition(sx, sy)
    sparkPS:emit(8)
end

---------------------------------------------------------------------
-- Control rod logic
---------------------------------------------------------------------
function getControlRodPositions()
    local rods = {}
    local spacing = REACTOR_W / (NUM_CONTROL_RODS + 1)
    local maxDepth = REACTOR_H - 20
    local depth = controlRodObj.value * maxDepth
    for i = 1, NUM_CONTROL_RODS do
        local rx = REACTOR_X + spacing * i
        table.insert(rods, {
            x = rx - ROD_WIDTH / 2,
            y = REACTOR_Y,
            w = ROD_WIDTH,
            h = depth,
        })
    end
    return rods
end

function neutronHitsRod(nx, ny)
    local rods = getControlRodPositions()
    for _, rod in ipairs(rods) do
        if nx > rod.x and nx < rod.x + rod.w and ny > rod.y and ny < rod.y + rod.h then
            return true
        end
    end
    return false
end

---------------------------------------------------------------------
-- Update
---------------------------------------------------------------------
function love.update(dt)
    if paused then
        flux.update(dt) -- still animate UI
        glowPS:update(dt)
        sparkPS:update(dt)
        return
    end

    local sdt = dt * simSpeed
    flux.update(dt)

    -- Particle systems
    glowPS:update(sdt)
    sparkPS:update(sdt)

    -- Cool reactor slowly
    reactorTemp = math.max(0, reactorTemp - 2 * sdt)
    flux.to(tempDisplay, 0.5, { value = reactorTemp }):ease("linear")

    -- Check meltdown
    if reactorTemp > 500 and not meltdown then
        meltdown = true
    end

    -- Update neutrons
    local aliveCount = 0
    for i = #neutrons, 1, -1 do
        local n = neutrons[i]
        if n.alive then
            n.x = n.x + n.vx * sdt
            n.y = n.y + n.vy * sdt
            n.age = n.age + sdt

            -- Trail
            if love.math.random() < 0.5 then
                table.insert(trails, { x = n.x, y = n.y, alpha = 0.6 })
            end

            -- Neutron spark particles
            if love.math.random() < 0.15 then
                sparkPS:setPosition(n.x, n.y)
                sparkPS:emit(1)
            end

            -- Bounce off reactor walls
            if n.x < REACTOR_X + NEUTRON_RADIUS then
                n.x = REACTOR_X + NEUTRON_RADIUS
                n.vx = math.abs(n.vx)
            elseif n.x > REACTOR_X + REACTOR_W - NEUTRON_RADIUS then
                n.x = REACTOR_X + REACTOR_W - NEUTRON_RADIUS
                n.vx = -math.abs(n.vx)
            end
            if n.y < REACTOR_Y + NEUTRON_RADIUS then
                n.y = REACTOR_Y + NEUTRON_RADIUS
                n.vy = math.abs(n.vy)
            elseif n.y > REACTOR_Y + REACTOR_H - NEUTRON_RADIUS then
                n.y = REACTOR_Y + REACTOR_H - NEUTRON_RADIUS
                n.vy = -math.abs(n.vy)
            end

            -- Absorbed by control rod?
            if neutronHitsRod(n.x, n.y) then
                n.alive = false
                -- Small absorption spark
                sparkPS:setPosition(n.x, n.y)
                sparkPS:emit(3)
            end

            -- Collide with atoms?
            if n.alive then
                for _, atom in ipairs(atoms) do
                    if atom.alive and dist(n.x, n.y, atom.x, atom.y) < CAPTURE_RADIUS then
                        n.alive = false
                        triggerFission(atom, n)
                        break
                    end
                end
            end

            -- Max age
            if n.age > 10 then n.alive = false end

            if n.alive then aliveCount = aliveCount + 1 end
        end
    end
    peakNeutrons = math.max(peakNeutrons, aliveCount)

    -- Clean dead neutrons periodically
    if #neutrons > 500 then
        local fresh = {}
        for _, n in ipairs(neutrons) do
            if n.alive then table.insert(fresh, n) end
        end
        neutrons = fresh
    end

    -- Update fragments
    for _, f in ipairs(fragments) do
        if f.alive then
            f.x = f.x + f.vx * sdt
            f.y = f.y + f.vy * sdt
            f.vx = f.vx * (1 - 1.5 * sdt) -- drag
            f.vy = f.vy * (1 - 1.5 * sdt)
            f.life = f.life - sdt
            f.alpha = clamp(f.life / 2, 0, 1)
            if f.life <= 0 then f.alive = false end

            -- Bounce inside reactor
            if f.x < REACTOR_X + f.radius then f.vx = math.abs(f.vx) * 0.5 end
            if f.x > REACTOR_X + REACTOR_W - f.radius then f.vx = -math.abs(f.vx) * 0.5 end
            if f.y < REACTOR_Y + f.radius then f.vy = math.abs(f.vy) * 0.5 end
            if f.y > REACTOR_Y + REACTOR_H - f.radius then f.vy = -math.abs(f.vy) * 0.5 end
        end
    end

    -- Fade trails
    for i = #trails, 1, -1 do
        trails[i].alpha = trails[i].alpha - 4 * sdt
        if trails[i].alpha <= 0 then
            table.remove(trails, i)
        end
    end

    -- Fade flashes
    for i = #flashes, 1, -1 do
        if flashes[i].alpha <= 0 then
            table.remove(flashes, i)
        end
    end

    -- Atom wobble
    for _, atom in ipairs(atoms) do
        if atom.alive then
            atom.pulsePhase = atom.pulsePhase + sdt * 2
        end
    end
end

---------------------------------------------------------------------
-- Draw
---------------------------------------------------------------------
function love.draw()
    local sx = (love.math.random() - 0.5) * shakeAmount * 2
    local sy = (love.math.random() - 0.5) * shakeAmount * 2
    love.graphics.push()
    love.graphics.translate(sx, sy)

    drawReactor()
    drawControlRods()
    drawTrails()
    drawAtoms()
    drawFragments()
    drawNeutrons()
    drawFlashes()
    drawParticles()

    love.graphics.pop()

    drawSidebar()

    if paused then
        drawPauseOverlay()
    end
    if meltdown then
        drawMeltdownOverlay()
    end
end

function drawReactor()
    -- Reactor vessel background
    love.graphics.setColor(COLOR_REACTOR_BG)
    love.graphics.rectangle("fill", REACTOR_X, REACTOR_Y, REACTOR_W, REACTOR_H, 8, 8)

    -- Grid lines (subtle)
    love.graphics.setColor(0.12, 0.14, 0.18, 0.5)
    for gx = REACTOR_X, REACTOR_X + REACTOR_W, 40 do
        love.graphics.line(gx, REACTOR_Y, gx, REACTOR_Y + REACTOR_H)
    end
    for gy = REACTOR_Y, REACTOR_Y + REACTOR_H, 40 do
        love.graphics.line(REACTOR_X, gy, REACTOR_X + REACTOR_W, gy)
    end

    -- Border
    local wallAlpha = 0.6 + 0.15 * math.sin(love.timer.getTime() * 2)
    love.graphics.setColor(COLOR_REACTOR_WALL[1], COLOR_REACTOR_WALL[2], COLOR_REACTOR_WALL[3], wallAlpha)
    love.graphics.setLineWidth(3)
    love.graphics.rectangle("line", REACTOR_X, REACTOR_Y, REACTOR_W, REACTOR_H, 8, 8)
    love.graphics.setLineWidth(1)

    -- Temperature glow on walls
    if reactorTemp > 50 then
        local intensity = clamp(reactorTemp / 500, 0, 1)
        love.graphics.setColor(1, 0.2, 0.05, intensity * 0.15)
        love.graphics.rectangle("fill", REACTOR_X, REACTOR_Y, REACTOR_W, REACTOR_H, 8, 8)
    end
end

function drawControlRods()
    local rods = getControlRodPositions()
    for _, rod in ipairs(rods) do
        if rod.h > 1 then
            -- Rod shadow
            love.graphics.setColor(0, 0, 0, 0.3)
            love.graphics.rectangle("fill", rod.x + 2, rod.y + 2, rod.w, rod.h, 3, 3)
            -- Rod body
            love.graphics.setColor(ROD_COLOR)
            love.graphics.rectangle("fill", rod.x, rod.y, rod.w, rod.h, 3, 3)
            -- Rod highlight
            love.graphics.setColor(0.5, 0.5, 0.55, 0.3)
            love.graphics.rectangle("fill", rod.x + 2, rod.y, 3, rod.h, 1, 1)
            -- Rod cap
            love.graphics.setColor(0.45, 0.45, 0.5, 0.9)
            love.graphics.rectangle("fill", rod.x - 2, rod.y + rod.h - 4, rod.w + 4, 6, 2, 2)
        end
    end
end

function drawAtoms()
    for _, atom in ipairs(atoms) do
        if atom.alive then
            local pulse = math.sin(atom.pulsePhase) * 0.08
            local r = atom.radius * (1 + pulse)

            -- Outer glow
            love.graphics.setColor(COLOR_URANIUM_GLOW)
            love.graphics.circle("fill", atom.x, atom.y, r * 2.2)

            -- Nucleus
            love.graphics.setColor(COLOR_URANIUM[1] * 0.6, COLOR_URANIUM[2] * 0.6, COLOR_URANIUM[3] * 0.6, 1)
            love.graphics.circle("fill", atom.x, atom.y, r)
            love.graphics.setColor(COLOR_URANIUM)
            love.graphics.circle("fill", atom.x, atom.y, r * 0.8)

            -- Inner highlight
            love.graphics.setColor(0.4, 1, 0.5, 0.4)
            love.graphics.circle("fill", atom.x - r * 0.2, atom.y - r * 0.2, r * 0.35)

            -- Electron orbits
            love.graphics.setColor(0.3, 0.8, 0.5, 0.25)
            love.graphics.setLineWidth(1)
            local t = love.timer.getTime() * 1.5 + atom.pulsePhase
            for orb = 1, 2 do
                love.graphics.push()
                love.graphics.translate(atom.x, atom.y)
                love.graphics.rotate(t * (0.8 + orb * 0.3))
                love.graphics.ellipse("line", 0, 0, r * (1.4 + orb * 0.4), r * (0.5 + orb * 0.15))
                -- Electron dot
                local eAngle = t * 3 + orb * 2
                local ex = math.cos(eAngle) * r * (1.4 + orb * 0.4)
                local ey = math.sin(eAngle) * r * (0.5 + orb * 0.15)
                love.graphics.setColor(0.6, 1, 0.7, 0.8)
                love.graphics.circle("fill", ex, ey, 2)
                love.graphics.pop()
            end

            -- Label
            love.graphics.setColor(0.8, 1, 0.85, 0.6)
            love.graphics.setFont(fontSmall)
            love.graphics.printf("U-235", atom.x - 20, atom.y + r + 4, 40, "center")
        end
    end
end

function drawNeutrons()
    for _, n in ipairs(neutrons) do
        if n.alive then
            -- Speed-based color
            local speed = math.sqrt(n.vx * n.vx + n.vy * n.vy)
            local t = clamp(speed / (NEUTRON_SPEED * 1.5), 0, 1)
            local nr = lerp(COLOR_NEUTRON[1], COLOR_NEUTRON_FAST[1], t)
            local ng = lerp(COLOR_NEUTRON[2], COLOR_NEUTRON_FAST[2], t)
            local nb = lerp(COLOR_NEUTRON[3], COLOR_NEUTRON_FAST[3], t)

            -- Glow
            love.graphics.setColor(nr, ng, nb, 0.2)
            love.graphics.circle("fill", n.x, n.y, NEUTRON_RADIUS * 4)

            -- Core
            love.graphics.setColor(nr, ng, nb, 0.9)
            love.graphics.circle("fill", n.x, n.y, NEUTRON_RADIUS)

            -- Bright center
            love.graphics.setColor(1, 1, 0.9, 1)
            love.graphics.circle("fill", n.x, n.y, NEUTRON_RADIUS * 0.5)
        end
    end
end

function drawFragments()
    for _, f in ipairs(fragments) do
        if f.alive then
            -- Glow
            love.graphics.setColor(f.r, f.g, f.b, f.alpha * 0.2)
            love.graphics.circle("fill", f.x, f.y, f.radius * 2)

            -- Body
            love.graphics.setColor(f.r, f.g, f.b, f.alpha * 0.8)
            love.graphics.circle("fill", f.x, f.y, f.radius)

            -- Highlight
            love.graphics.setColor(1, 1, 1, f.alpha * 0.3)
            love.graphics.circle("fill", f.x - f.radius * 0.2, f.y - f.radius * 0.2, f.radius * 0.4)
        end
    end
end

function drawTrails()
    for _, t in ipairs(trails) do
        love.graphics.setColor(1, 0.9, 0.5, t.alpha * 0.4)
        love.graphics.circle("fill", t.x, t.y, 2)
    end
end

function drawFlashes()
    love.graphics.setBlendMode("add")
    for _, fl in ipairs(flashes) do
        if fl.alpha > 0 then
            love.graphics.setColor(1, 0.95, 0.7, fl.alpha * 0.6)
            love.graphics.circle("fill", fl.x, fl.y, fl.radius)
            love.graphics.setColor(1, 1, 0.9, fl.alpha * 0.3)
            love.graphics.circle("fill", fl.x, fl.y, fl.radius * 0.5)
        end
    end
    love.graphics.setBlendMode("alpha")
end

function drawParticles()
    love.graphics.setBlendMode("add")
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(glowPS)
    love.graphics.draw(sparkPS)
    love.graphics.setBlendMode("alpha")
end

---------------------------------------------------------------------
-- Sidebar UI
---------------------------------------------------------------------
function drawSidebar()
    -- Background
    love.graphics.setColor(COLOR_SIDEBAR_BG)
    love.graphics.rectangle("fill", 0, 0, SIDEBAR_W, H)
    love.graphics.setColor(0.15, 0.17, 0.22, 1)
    love.graphics.setLineWidth(2)
    love.graphics.line(SIDEBAR_W, 0, SIDEBAR_W, H)
    love.graphics.setLineWidth(1)

    local y = 20
    local pad = 15

    -- Title
    love.graphics.setFont(fontLarge)
    love.graphics.setColor(COLOR_ACCENT)
    love.graphics.printf("ATOM", pad, y, SIDEBAR_W - pad * 2, "center")
    y = y + 35
    love.graphics.setFont(fontSmall)
    love.graphics.setColor(0.5, 0.55, 0.65)
    love.graphics.printf("REACTOR CONTROL PANEL", pad, y, SIDEBAR_W - pad * 2, "center")
    y = y + 30

    -- Divider
    love.graphics.setColor(0.2, 0.22, 0.28)
    love.graphics.line(pad, y, SIDEBAR_W - pad, y)
    y = y + 15

    -- Stats
    love.graphics.setFont(fontMed)

    -- Energy
    drawStatLabel("ENERGY RELEASED", y, pad)
    y = y + 18
    love.graphics.setColor(1, 0.85, 0.2)
    love.graphics.setFont(fontLarge)
    love.graphics.printf(string.format("%.1f MeV", energyDisplay.value), pad, y, SIDEBAR_W - pad * 2, "center")
    y = y + 32

    -- Temperature
    drawStatLabel("CORE TEMPERATURE", y, pad)
    y = y + 18
    local tempColor = reactorTemp > 300 and COLOR_DANGER or (reactorTemp > 150 and {1, 0.7, 0.2} or COLOR_TEXT)
    love.graphics.setColor(tempColor)
    love.graphics.setFont(fontLarge)
    love.graphics.printf(string.format("%.0f C", tempDisplay.value), pad, y, SIDEBAR_W - pad * 2, "center")
    y = y + 32

    -- Fission count
    drawStatLabel("FISSION EVENTS", y, pad)
    y = y + 18
    love.graphics.setColor(COLOR_URANIUM)
    love.graphics.setFont(fontLarge)
    love.graphics.printf(tostring(fissionCount), pad, y, SIDEBAR_W - pad * 2, "center")
    y = y + 32

    -- Active neutrons
    local activeNeutrons = 0
    for _, n in ipairs(neutrons) do if n.alive then activeNeutrons = activeNeutrons + 1 end end
    drawStatLabel("ACTIVE NEUTRONS", y, pad)
    y = y + 18
    love.graphics.setColor(COLOR_NEUTRON)
    love.graphics.setFont(fontLarge)
    love.graphics.printf(tostring(activeNeutrons), pad, y, SIDEBAR_W - pad * 2, "center")
    y = y + 32

    -- Remaining atoms
    local aliveAtoms = 0
    for _, a in ipairs(atoms) do if a.alive then aliveAtoms = aliveAtoms + 1 end end
    drawStatLabel("U-235 REMAINING", y, pad)
    y = y + 18
    love.graphics.setColor(COLOR_URANIUM)
    love.graphics.setFont(fontLarge)
    love.graphics.printf(tostring(aliveAtoms) .. " / " .. tostring(#atoms), pad, y, SIDEBAR_W - pad * 2, "center")
    y = y + 35

    -- Divider
    love.graphics.setColor(0.2, 0.22, 0.28)
    love.graphics.line(pad, y, SIDEBAR_W - pad, y)
    y = y + 15

    -- Control rods slider visual
    drawStatLabel("CONTROL RODS", y, pad)
    y = y + 20
    local barX = pad + 10
    local barW = SIDEBAR_W - pad * 2 - 20
    local barH = 18
    love.graphics.setColor(0.15, 0.16, 0.2)
    love.graphics.rectangle("fill", barX, y, barW, barH, 4, 4)
    local fillW = controlRodObj.value * barW
    if fillW > 2 then
        local rodColor = controlRodObj.value > 0.7 and {0.3, 0.8, 0.4} or
                         (controlRodObj.value > 0.3 and {0.9, 0.8, 0.2} or COLOR_DANGER)
        love.graphics.setColor(rodColor)
        love.graphics.rectangle("fill", barX, y, fillW, barH, 4, 4)
    end
    love.graphics.setColor(COLOR_TEXT)
    love.graphics.setFont(fontSmall)
    love.graphics.printf(string.format("%.0f%%", controlRodObj.value * 100), barX, y + 2, barW, "center")
    y = y + 30

    -- Speed
    drawStatLabel("SIM SPEED", y, pad)
    y = y + 18
    love.graphics.setColor(COLOR_TEXT)
    love.graphics.setFont(fontMed)
    love.graphics.printf(string.format("%.1fx", simSpeed), pad, y, SIDEBAR_W - pad * 2, "center")
    y = y + 30

    -- Divider
    love.graphics.setColor(0.2, 0.22, 0.28)
    love.graphics.line(pad, y, SIDEBAR_W - pad, y)
    y = y + 12

    -- Controls help
    love.graphics.setFont(fontSmall)
    love.graphics.setColor(0.45, 0.5, 0.6)
    local controls = {
        "CLICK  Fire neutron",
        "C      Toggle ctrl rods",
        "UP/DN  Adjust rods",
        "+/-    Sim speed",
        "SPACE  Pause",
        "R      Reset reactor",
    }
    for _, line in ipairs(controls) do
        love.graphics.printf(line, pad, y, SIDEBAR_W - pad * 2, "left")
        y = y + 18
    end

    y = y + 8

    -- Divider
    love.graphics.setColor(0.2, 0.22, 0.28)
    love.graphics.line(pad, y, SIDEBAR_W - pad, y)
    y = y + 12

    -- Reactor status
    local activeNeutrons = 0
    for _, n in ipairs(neutrons) do if n.alive then activeNeutrons = activeNeutrons + 1 end end

    local status, statusColor
    if meltdown then
        status = "!! MELTDOWN !!"
        statusColor = {1, 0.15, 0.1}
    elseif activeNeutrons > 20 then
        status = "!! SUPERCRITICAL"
        statusColor = COLOR_DANGER
    elseif activeNeutrons > 5 then
        status = ">> CRITICAL"
        statusColor = {1, 0.7, 0.2}
    elseif activeNeutrons > 0 then
        status = "-- SUBCRITICAL"
        statusColor = COLOR_URANIUM
    else
        status = "-- IDLE"
        statusColor = {0.4, 0.5, 0.6}
    end

    drawStatLabel("REACTOR STATUS", y, pad)
    y = y + 18
    love.graphics.setFont(fontMed)
    love.graphics.setColor(statusColor)
    local blink = (activeNeutrons > 20) and (math.sin(love.timer.getTime() * 6) > 0) or true
    if blink then
        love.graphics.printf(status, pad, y, SIDEBAR_W - pad * 2, "center")
    end
    y = y + 28

    -- FPS
    love.graphics.setFont(fontSmall)
    love.graphics.setColor(0.3, 0.33, 0.4)
    love.graphics.setColor(0.45, 0.5, 0.6)
    love.graphics.printf("made with <3 by vinny", pad, H - 42, SIDEBAR_W - pad * 2, "center")
    love.graphics.setColor(0.3, 0.33, 0.4)
    love.graphics.printf("FPS: " .. tostring(love.timer.getFPS()), pad, H - 24, SIDEBAR_W - pad * 2, "center")
end

function drawStatLabel(text, y, pad)
    love.graphics.setFont(fontSmall)
    love.graphics.setColor(0.4, 0.45, 0.55)
    love.graphics.printf(text, pad, y, SIDEBAR_W - pad * 2, "center")
end

---------------------------------------------------------------------
-- Overlays
---------------------------------------------------------------------
function drawPauseOverlay()
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", REACTOR_X, REACTOR_Y, REACTOR_W, REACTOR_H)
    love.graphics.setColor(1, 1, 1, 0.9)
    love.graphics.setFont(fontHuge)
    love.graphics.printf("PAUSED", REACTOR_X, REACTOR_Y + REACTOR_H / 2 - 20, REACTOR_W, "center")
end

function drawMeltdownOverlay()
    local t = love.timer.getTime()
    local flash = math.abs(math.sin(t * 4))
    love.graphics.setColor(1, 0.1, 0.05, flash * 0.2)
    love.graphics.rectangle("fill", 0, 0, W, H)
    love.graphics.setColor(1, 0.2, 0.1, 0.9)
    love.graphics.setFont(fontHuge)
    love.graphics.printf("!! MELTDOWN !!", REACTOR_X, REACTOR_Y + REACTOR_H / 2 - 50, REACTOR_W, "center")
    love.graphics.setFont(fontMed)
    love.graphics.setColor(1, 0.6, 0.4)
    love.graphics.printf("Core temperature critical! Press R to reset.", REACTOR_X, REACTOR_Y + REACTOR_H / 2 + 10, REACTOR_W, "center")
end

---------------------------------------------------------------------
-- Input
---------------------------------------------------------------------
function love.mousepressed(x, y, button)
    if button == 1 and inReactor(x, y) then
        fireNeutron(x, y)
    end
end

function love.keypressed(key)
    if key == "space" then
        paused = not paused
    elseif key == "r" then
        resetReactor()
    elseif key == "c" then
        -- Toggle control rods
        if controlRodTarget < 0.5 then
            controlRodTarget = 1.0
        else
            controlRodTarget = 0.0
        end
        flux.to(controlRodObj, 0.8, { value = controlRodTarget }):ease("cubicout")
    elseif key == "up" then
        controlRodTarget = clamp(controlRodTarget + 0.1, 0, 1)
        flux.to(controlRodObj, 0.3, { value = controlRodTarget }):ease("quadout")
    elseif key == "down" then
        controlRodTarget = clamp(controlRodTarget - 0.1, 0, 1)
        flux.to(controlRodObj, 0.3, { value = controlRodTarget }):ease("quadout")
    elseif key == "=" or key == "kp+" then
        simSpeed = clamp(simSpeed + 0.25, 0.25, 5.0)
    elseif key == "-" or key == "kp-" then
        simSpeed = clamp(simSpeed - 0.25, 0.25, 5.0)
    end
end

function resetReactor()
    neutrons = {}
    fragments = {}
    flashes = {}
    trails = {}
    totalEnergy = 0
    fissionCount = 0
    neutronsFired = 0
    peakNeutrons = 0
    reactorTemp = 0
    meltdown = false
    energyDisplay.value = 0
    tempDisplay.value = 0
    shakeAmount = 0
    shakeObj.value = 0
    controlRodTarget = 0
    flux.to(controlRodObj, 0.5, { value = 0 }):ease("quadout")
    spawnAtoms(30)
end
