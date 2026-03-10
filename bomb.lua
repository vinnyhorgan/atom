-- bomb.lua
-- Implosion-type fission bomb simulation
-- Simulates the physics of a Fat Man-style nuclear weapon

local flux = require "flux"

local bomb = {}

---------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------
local PI = math.pi
local TWO_PI = PI * 2

-- Bomb geometry
local NUM_PIT_ATOMS    = 60       -- U-235 atoms in the pit (subcritical sphere)
local NUM_CHARGES      = 8        -- conventional explosive lenses
local PIT_RADIUS_FRAC  = 0.22    -- fraction of view area for pit circle
local CHARGE_RING_FRAC = 0.38    -- fraction of view area for explosive ring

-- Physics
local NEUTRON_SPEED     = 350     -- faster than reactor (no moderator)
local NEUTRON_RADIUS    = 3
local ATOM_RADIUS       = 12      -- smaller atoms, denser packing
local CAPTURE_RADIUS    = ATOM_RADIUS + NEUTRON_RADIUS
local FISSION_ENERGY    = 200     -- MeV per fission

-- Phases
local PHASE_IDLE       = "idle"
local PHASE_ARMED      = "armed"
local PHASE_IMPLOSION  = "implosion"
local PHASE_CHAIN      = "chain"
local PHASE_EXPLOSION  = "explosion"
local PHASE_AFTERMATH  = "aftermath"

-- Colors
local COLOR_PIT         = {0.15, 0.75, 0.25}
local COLOR_CHARGE      = {0.85, 0.55, 0.15}
local COLOR_CHARGE_LIT  = {1.0, 0.8, 0.2}
local COLOR_CASING      = {0.4, 0.42, 0.45}
local COLOR_NEUTRON     = {0.95, 0.85, 0.3}
local COLOR_NEUTRON_FAST = {1.0, 0.5, 0.15}
local COLOR_FLASH       = {1, 1, 0.9}
local COLOR_FIREBALL    = {1.0, 0.6, 0.1}
local COLOR_SHOCKWAVE   = {1.0, 0.95, 0.85}
local COLOR_TEXT        = {0.85, 0.88, 0.92}
local COLOR_ACCENT      = {0.3, 0.7, 1.0}
local COLOR_DANGER      = {1.0, 0.3, 0.25}

-- Adjustable weapon parameters (persist across resets)
local sliders = {
    { id = "fuel_mass",   label = "URANIUM FUEL",       unit = " atoms", min = 20,  max = 120, value = 60,  default = 60,  fmt = "%.0f" },
    { id = "enrichment",  label = "FUEL PURITY",        unit = "%",      min = 50,  max = 95,  value = 85,  default = 85,  fmt = "%.0f" },
    { id = "tamper",      label = "NEUTRON REFLECTOR",  unit = "x",      min = 1.0, max = 2.5, value = 1.5, default = 1.5, fmt = "%.1f" },
    { id = "initiators",  label = "DETONATORS",         unit = "",       min = 1,   max = 8,   value = 3,   default = 3,   fmt = "%.0f" },
}
local draggingSlider = nil
local sliderRects = {}

---------------------------------------------------------------------
-- State
---------------------------------------------------------------------
local state = {}
local fonts = {}
local particleSystems = {}

local function resetState()
    state = {
        phase = PHASE_IDLE,

        -- Geometry center (set in draw based on reactor rect)
        cx = 0, cy = 0, viewRadius = 0,

        -- Pit atoms
        atoms = {},
        atomsOriginal = {},   -- original positions for implosion lerp

        -- Explosive charges
        charges = {},

        -- Neutrons
        neutrons = {},
        trails = {},
        flashes = {},
        fragments = {},

        -- Implosion animation
        implosionT = 0,       -- 0..1 progress
        compressionRatio = 1, -- current compression

        -- Chain reaction stats
        fissionCount = 0,
        totalEnergy = 0,
        peakNeutrons = 0,
        chainStartTime = 0,
        chainElapsed = 0,     -- microseconds (simulated)

        -- Explosion
        fireballRadius = 0,
        fireballAlpha = 0,
        shockwaveRadius = 0,
        shockwaveAlpha = 0,
        explosionT = 0,

        -- Yield
        yieldKt = 0,          -- kilotons TNT equivalent
        normalizedYield = 0,  -- 0..1 fraction of theoretical max
        efficiency = 0,       -- percentage of fuel fissioned
        flashAlpha = 0,       -- initial detonation flash

        -- Camera shake
        shakeAmount = 0,
        shakeObj = { value = 0 },

        -- UI
        armBtnRect = nil,
        resetBtnRect = nil,

        -- Energy display
        energyDisplay = { value = 0 },
    }
end

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function dist(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return math.sqrt(dx*dx + dy*dy)
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function randomAngle() return love.math.random() * TWO_PI end
local function lerp(a, b, t) return a + (b - a) * t end

local function getSliderValue(id)
    for _, s in ipairs(sliders) do
        if s.id == id then return s.value end
    end
end

local function setSliderFromMouse(idx, mouseX)
    local rect = sliderRects[idx]
    if not rect then return end
    local s = sliders[idx]
    local t = clamp((mouseX - rect.barX) / rect.barW, 0, 1)
    local raw = s.min + t * (s.max - s.min)
    if s.fmt == "%.0f" then
        raw = math.floor(raw + 0.5)
    else
        raw = math.floor(raw * 10 + 0.5) / 10
    end
    s.value = clamp(raw, s.min, s.max)
end

local function respawnIfNeeded()
    if state.phase == PHASE_IDLE or state.phase == PHASE_ARMED then
        state.atoms = {}
        state.atomsOriginal = {}
    end
end

---------------------------------------------------------------------
-- Particle systems
---------------------------------------------------------------------
local function initParticles()
    -- Glow particles for fission
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

    particleSystems.glow = love.graphics.newParticleSystem(glowImg, 2000)
    particleSystems.glow:setParticleLifetime(0.2, 0.6)
    particleSystems.glow:setEmissionRate(0)
    particleSystems.glow:setSpeed(100, 300)
    particleSystems.glow:setSizes(0.8, 0.3)
    particleSystems.glow:setColors(
        1, 0.9, 0.4, 0.9,
        1, 0.5, 0.1, 0.5,
        1, 0.2, 0.05, 0
    )
    particleSystems.glow:setSpread(TWO_PI)

    -- Spark particles
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

    particleSystems.spark = love.graphics.newParticleSystem(sparkImg, 3000)
    particleSystems.spark:setParticleLifetime(0.1, 0.5)
    particleSystems.spark:setEmissionRate(0)
    particleSystems.spark:setSpeed(20, 80)
    particleSystems.spark:setSizes(0.8, 0.1)
    particleSystems.spark:setColors(
        1, 0.9, 0.5, 0.8,
        1, 0.6, 0.2, 0.0
    )
    particleSystems.spark:setSpread(TWO_PI)

    -- Explosion debris
    particleSystems.debris = love.graphics.newParticleSystem(sparkImg, 1000)
    particleSystems.debris:setParticleLifetime(1.0, 3.0)
    particleSystems.debris:setEmissionRate(0)
    particleSystems.debris:setSpeed(50, 250)
    particleSystems.debris:setSizes(1.2, 0.5, 0.1)
    particleSystems.debris:setColors(
        1, 0.7, 0.2, 1.0,
        1, 0.3, 0.1, 0.6,
        0.3, 0.1, 0.05, 0
    )
    particleSystems.debris:setSpread(TWO_PI)
    particleSystems.debris:setLinearAcceleration(-30, -30, 30, 30)
end

---------------------------------------------------------------------
-- Spawn pit atoms in a circular arrangement
---------------------------------------------------------------------
local function spawnPitAtoms(cx, cy, radius)
    state.atoms = {}
    state.atomsOriginal = {}

    -- Fill circle with atoms using rejection sampling for natural look
    local minDist = ATOM_RADIUS * 2.5
    local numAtoms = math.floor(getSliderValue("fuel_mass"))
    for i = 1, numAtoms do
        local placed = false
        local attempts = 0
        while not placed and attempts < 500 do
            local angle = randomAngle()
            local r = math.sqrt(love.math.random()) * radius
            local ax = cx + math.cos(angle) * r
            local ay = cy + math.sin(angle) * r
            local ok = true
            for _, a in ipairs(state.atoms) do
                if dist(ax, ay, a.x, a.y) < minDist then
                    ok = false
                    break
                end
            end
            if ok then
                table.insert(state.atoms, {
                    x = ax, y = ay,
                    alive = true,
                    pulsePhase = love.math.random() * TWO_PI,
                    glow = 0,
                })
                table.insert(state.atomsOriginal, { x = ax, y = ay })
                placed = true
            end
            attempts = attempts + 1
        end
    end
end

---------------------------------------------------------------------
-- Spawn explosive charges around the pit
---------------------------------------------------------------------
local function spawnCharges(cx, cy, radius)
    state.charges = {}
    for i = 1, NUM_CHARGES do
        local angle = (i - 1) / NUM_CHARGES * TWO_PI - PI / 2
        table.insert(state.charges, {
            angle = angle,
            cx = cx + math.cos(angle) * radius,
            cy = cy + math.sin(angle) * radius,
            radius = radius * 0.28,
            lit = false,
            litT = 0,
        })
    end
end

---------------------------------------------------------------------
-- Trigger fission in bomb mode (no moderator, fast neutrons)
---------------------------------------------------------------------
local function triggerBombFission(atom, neutron)
    atom.alive = false
    state.fissionCount = state.fissionCount + 1
    state.totalEnergy = state.totalEnergy + FISSION_ENERGY
    flux.to(state.energyDisplay, 0.3, { value = state.totalEnergy }):ease("expoout")

    -- Yield: 1 kiloton ≈ 1.45×10^23 fissions
    -- For visualization, scale dramatically so the counter is meaningful
    state.yieldKt = state.fissionCount * 0.5

    -- Camera shake
    state.shakeAmount = math.min(state.shakeAmount + 4, 25)
    state.shakeObj.value = state.shakeAmount
    flux.to(state.shakeObj, 0.5, { value = 0 }):ease("expoout")
        :onupdate(function() state.shakeAmount = state.shakeObj.value end)

    -- Flash
    table.insert(state.flashes, { x = atom.x, y = atom.y, radius = 5, alpha = 1.0 })
    local fl = state.flashes[#state.flashes]
    flux.to(fl, 0.4, { radius = 60, alpha = 0 }):ease("expoout")

    -- Particles
    particleSystems.glow:setPosition(atom.x, atom.y)
    particleSystems.glow:emit(20)

    -- Fission fragments
    local angle = randomAngle()
    local speed = 80 + love.math.random() * 60
    for j = 0, 1 do
        local a = angle + j * PI
        local hues = { {0.55, 0.3, 0.85}, {0.85, 0.35, 0.55} }
        table.insert(state.fragments, {
            x = atom.x, y = atom.y,
            vx = math.cos(a) * speed,
            vy = math.sin(a) * speed,
            radius = 8,
            alive = true,
            alpha = 1.0,
            r = hues[j+1][1], g = hues[j+1][2], b = hues[j+1][3],
            life = 2.0,
        })
    end

    -- Spawn 2-3 FAST neutrons (no moderation in a bomb)
    local numNew = love.math.random(2, 3)
    for i = 1, numNew do
        local a = randomAngle()
        local spd = NEUTRON_SPEED * (0.9 + love.math.random() * 0.4)
        table.insert(state.neutrons, {
            x = atom.x + math.cos(a) * ATOM_RADIUS,
            y = atom.y + math.sin(a) * ATOM_RADIUS,
            vx = math.cos(a) * spd,
            vy = math.sin(a) * spd,
            alive = true,
            age = 0,
            energy = 2.0,  -- fast fission neutrons, no moderation
        })
    end
end

---------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------
function bomb.load(fontS, fontM, fontL, fontH)
    fonts.small = fontS
    fonts.med = fontM
    fonts.large = fontL
    fonts.huge = fontH
    initParticles()
    resetState()
end

function bomb.reset()
    resetState()
end

function bomb.update(dt, reactorX, reactorY, reactorW, reactorH)
    -- Update center from reactor rect
    state.cx = reactorX + reactorW / 2
    state.cy = reactorY + reactorH / 2
    state.viewRadius = math.min(reactorW, reactorH) * 0.45

    -- Particles always update
    for _, ps in pairs(particleSystems) do
        ps:update(dt)
    end
    flux.update(0) -- flux is updated by main.lua, just reference it

    -- Spawn atoms if needed and in idle/armed
    if #state.atoms == 0 and (state.phase == PHASE_IDLE or state.phase == PHASE_ARMED) then
        local pitR = state.viewRadius * PIT_RADIUS_FRAC
        spawnPitAtoms(state.cx, state.cy, pitR)
        spawnCharges(state.cx, state.cy, state.viewRadius * CHARGE_RING_FRAC)
    end

    -- Phase-specific updates
    if state.phase == PHASE_IMPLOSION then
        updateImplosion(dt)
    elseif state.phase == PHASE_CHAIN then
        updateChainReaction(dt)
    elseif state.phase == PHASE_EXPLOSION then
        updateExplosion(dt)
    end

    -- Atom pulse animation
    for _, atom in ipairs(state.atoms) do
        if atom.alive then
            atom.pulsePhase = atom.pulsePhase + dt * 2
        end
    end

    -- Trail fade
    for i = #state.trails, 1, -1 do
        state.trails[i].alpha = state.trails[i].alpha - 5 * dt
        if state.trails[i].alpha <= 0 then
            table.remove(state.trails, i)
        end
    end

    -- Flash cleanup
    for i = #state.flashes, 1, -1 do
        if state.flashes[i].alpha <= 0 then
            table.remove(state.flashes, i)
        end
    end

    -- Fragment update
    for i = #state.fragments, 1, -1 do
        local f = state.fragments[i]
        if f.alive then
            f.x = f.x + f.vx * dt
            f.y = f.y + f.vy * dt
            f.life = f.life - dt
            f.alpha = clamp(f.life / 1.0, 0, 1)
            if f.life <= 0 then f.alive = false end
        end
        if not f.alive then
            table.remove(state.fragments, i)
        end
    end
end

---------------------------------------------------------------------
-- Implosion phase
---------------------------------------------------------------------
function updateImplosion(dt)
    state.implosionT = state.implosionT + dt * 0.7

    -- Light up charges sequentially
    local chargeProgress = state.implosionT * 2 -- faster than compression
    for i, ch in ipairs(state.charges) do
        if chargeProgress > (i - 1) / NUM_CHARGES then
            ch.lit = true
            ch.litT = math.min(1, ch.litT + dt * 3)
        end
    end

    -- Compress atoms inward
    if state.implosionT > 0.3 then
        local compressT = clamp((state.implosionT - 0.3) / 0.7, 0, 1)
        local eased = 1 - (1 - compressT) * (1 - compressT) -- ease out quad
        state.compressionRatio = lerp(1.0, 0.3, eased)

        for i, atom in ipairs(state.atoms) do
            local orig = state.atomsOriginal[i]
            if orig then
                local dx = orig.x - state.cx
                local dy = orig.y - state.cy
                atom.x = state.cx + dx * state.compressionRatio
                atom.y = state.cy + dy * state.compressionRatio
            end
        end
    end

    -- Spark effects during compression
    if state.implosionT > 0.3 and love.math.random() < 0.3 then
        local a = randomAngle()
        local r = state.viewRadius * CHARGE_RING_FRAC
        particleSystems.spark:setPosition(
            state.cx + math.cos(a) * r * state.compressionRatio,
            state.cy + math.sin(a) * r * state.compressionRatio
        )
        particleSystems.spark:emit(2)
    end

    -- Transition to chain reaction
    if state.implosionT >= 1.0 then
        state.phase = PHASE_CHAIN
        state.chainStartTime = love.timer.getTime()
        -- Fire initiator neutron from center
        local numInit = math.floor(getSliderValue("initiators"))
        for i = 1, numInit do
            local a = randomAngle()
            local spd = NEUTRON_SPEED
            table.insert(state.neutrons, {
                x = state.cx + math.cos(a) * 5,
                y = state.cy + math.sin(a) * 5,
                vx = math.cos(a) * spd,
                vy = math.sin(a) * spd,
                alive = true,
                age = 0,
                energy = 2.0,
            })
        end
    end
end

---------------------------------------------------------------------
-- Chain reaction phase (uncontrolled, fast)
---------------------------------------------------------------------
function updateChainReaction(dt)
    local sdt = dt * 3 -- bomb reactions are FAST

    state.chainElapsed = state.chainElapsed + sdt * 1000 -- microseconds

    local aliveCount = 0

    for i = #state.neutrons, 1, -1 do
        local n = state.neutrons[i]
        if n.alive then
            -- No moderation in a bomb (fast neutrons)
            n.x = n.x + n.vx * sdt
            n.y = n.y + n.vy * sdt
            n.age = n.age + sdt

            -- Trails
            if love.math.random() < 0.4 then
                table.insert(state.trails, { x = n.x, y = n.y, alpha = 0.5 })
            end

            -- Sparks
            if love.math.random() < 0.1 then
                particleSystems.spark:setPosition(n.x, n.y)
                particleSystems.spark:emit(1)
            end

            -- Bounce off compressed pit boundary (neutron reflector)
            local pitR = state.viewRadius * PIT_RADIUS_FRAC / state.compressionRatio
            local dFromCenter = dist(n.x, n.y, state.cx, state.cy)
            if dFromCenter > pitR * getSliderValue("tamper") then
                -- Reflect back toward center (tamper effect)
                local angle = math.atan2(state.cy - n.y, state.cx - n.x)
                angle = angle + (love.math.random() - 0.5) * 0.5
                local spd = math.sqrt(n.vx*n.vx + n.vy*n.vy)
                n.vx = math.cos(angle) * spd
                n.vy = math.sin(angle) * spd
            end

            -- Collide with atoms (very high fission probability in supercritical mass)
            if n.alive then
                for _, atom in ipairs(state.atoms) do
                    if atom.alive then
                        local d = dist(n.x, n.y, atom.x, atom.y)
                        if d < CAPTURE_RADIUS * (1 / state.compressionRatio) then
                            -- In a supercritical compressed mass, nearly every collision fissions
                            local fissionProb = getSliderValue("enrichment") / 100
                            if love.math.random() < fissionProb then
                                n.alive = false
                                triggerBombFission(atom, n)
                            else
                                -- Scatter
                                local sa = randomAngle()
                                local spd = math.sqrt(n.vx*n.vx + n.vy*n.vy)
                                n.vx = math.cos(sa) * spd
                                n.vy = math.sin(sa) * spd
                                particleSystems.spark:setPosition(atom.x, atom.y)
                                particleSystems.spark:emit(3)
                            end
                            break
                        end
                    end
                end
            end

            -- Max age
            if n.age > 5 then n.alive = false end

            if n.alive then aliveCount = aliveCount + 1 end
        end
    end

    -- Remove dead neutrons
    for i = #state.neutrons, 1, -1 do
        if not state.neutrons[i].alive then
            table.remove(state.neutrons, i)
        end
    end

    state.peakNeutrons = math.max(state.peakNeutrons, aliveCount)

    -- Check for explosion trigger: enough fissions or no more atoms
    local aliveAtoms = 0
    for _, a in ipairs(state.atoms) do
        if a.alive then aliveAtoms = aliveAtoms + 1 end
    end

    if aliveAtoms == 0 or state.fissionCount > getSliderValue("fuel_mass") * 0.8 then
        state.phase = PHASE_EXPLOSION
        state.explosionT = 0
        state.fireballRadius = 10
        state.fireballAlpha = 1.0
        state.shockwaveRadius = 5
        state.shockwaveAlpha = 1.0

        -- Calculate yield metrics for scaling
        local fuelMass = getSliderValue("fuel_mass")
        state.efficiency = (state.fissionCount / fuelMass) * 100
        state.normalizedYield = clamp(state.yieldKt / 30, 0, 1)
        state.flashAlpha = 0.6 + 0.4 * state.normalizedYield
        local yf = state.normalizedYield

        -- Scale particle burst by yield
        particleSystems.debris:setPosition(state.cx, state.cy)
        particleSystems.debris:emit(math.floor(80 + 320 * yf))
        particleSystems.glow:setPosition(state.cx, state.cy)
        particleSystems.glow:emit(math.floor(40 + 160 * yf))

        -- Scale screen shake by yield
        local shakeIntensity = 15 + 35 * yf
        local shakeDuration = 2.0 + 4.0 * yf
        state.shakeAmount = shakeIntensity
        state.shakeObj.value = shakeIntensity
        flux.to(state.shakeObj, shakeDuration, { value = 0 }):ease("expoout")
            :onupdate(function() state.shakeAmount = state.shakeObj.value end)
    end
end

---------------------------------------------------------------------
-- Explosion phase
---------------------------------------------------------------------
function updateExplosion(dt)
    state.explosionT = state.explosionT + dt * 0.4
    local yf = state.normalizedYield

    -- Expanding fireball (scaled by yield: fizzle is tiny, big yield is massive)
    local maxFireball = state.viewRadius * (0.5 + 1.8 * yf)
    state.fireballRadius = lerp(10, maxFireball, math.min(1, state.explosionT * 1.5))
    state.fireballAlpha = math.max(0, 1 - state.explosionT * (0.6 - 0.2 * yf))

    -- Shockwave ring (scaled by yield)
    local maxShock = state.viewRadius * (0.8 + 2.5 * yf)
    state.shockwaveRadius = lerp(5, maxShock, math.min(1, state.explosionT * 2))
    state.shockwaveAlpha = math.max(0, 1 - state.explosionT * (1.0 - 0.3 * yf))

    -- Flash fade
    state.flashAlpha = math.max(0, state.flashAlpha - dt * (1.0 - 0.4 * yf))

    -- Push remaining neutrons outward (force scaled by yield)
    local pushForce = 200 + 500 * yf
    for _, n in ipairs(state.neutrons) do
        if n.alive then
            local dx = n.x - state.cx
            local dy = n.y - state.cy
            local d = math.sqrt(dx*dx + dy*dy) + 0.01
            n.vx = n.vx + dx/d * pushForce * dt
            n.vy = n.vy + dy/d * pushForce * dt
            n.x = n.x + n.vx * dt
            n.y = n.y + n.vy * dt
        end
    end

    -- Debris emission during explosion (scaled by yield)
    local debrisRate = 0.3 + 0.7 * yf
    if love.math.random() < debrisRate then
        local a = randomAngle()
        local r = state.fireballRadius * love.math.random()
        particleSystems.debris:setPosition(state.cx + math.cos(a)*r, state.cy + math.sin(a)*r)
        particleSystems.debris:emit(math.floor(1 + 3 * yf))
    end

    -- Longer explosion for bigger yields
    if state.explosionT > (2.0 + 2.0 * yf) then
        state.phase = PHASE_AFTERMATH
    end
end

---------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------
function bomb.draw(rx, ry, rw, rh)
    local cx = rx + rw / 2
    local cy = ry + rh / 2
    local vr = math.min(rw, rh) * 0.45

    if state.phase == PHASE_EXPLOSION or state.phase == PHASE_AFTERMATH then
        -- No scissor — let the explosion break out of the reactor area
        drawExplosion(cx, cy, vr, rx, ry, rw, rh)
    else
        love.graphics.setScissor(rx, ry, rw, rh)
        drawBombDevice(cx, cy, vr, rx, ry, rw, rh)
        love.graphics.setScissor()
    end
end

function drawBombDevice(cx, cy, vr, rx, ry, rw, rh)
    local chargeR = vr * CHARGE_RING_FRAC

    -- Draw outer casing circle (tamper)
    love.graphics.setColor(0.2, 0.22, 0.25, 0.4)
    love.graphics.circle("line", cx, cy, chargeR * 1.35)

    -- Draw explosive charges
    for _, ch in ipairs(state.charges) do
        local r = ch.radius
        local x, y = ch.cx, ch.cy

        -- Compress charges with the implosion
        if state.phase == PHASE_IMPLOSION or state.phase == PHASE_CHAIN then
            local dx = ch.cx - cx
            local dy = ch.cy - cy
            x = cx + dx * math.max(0.5, state.compressionRatio)
            y = cy + dy * math.max(0.5, state.compressionRatio)
        end

        if ch.lit then
            -- Ignited charge: bright orange/yellow glow
            local glow = 0.3 + 0.7 * ch.litT
            love.graphics.setColor(COLOR_CHARGE_LIT[1], COLOR_CHARGE_LIT[2], COLOR_CHARGE_LIT[3], glow * 0.3)
            love.graphics.circle("fill", x, y, r * 1.4)
            love.graphics.setColor(
                lerp(COLOR_CHARGE[1], COLOR_CHARGE_LIT[1], ch.litT),
                lerp(COLOR_CHARGE[2], COLOR_CHARGE_LIT[2], ch.litT),
                lerp(COLOR_CHARGE[3], COLOR_CHARGE_LIT[3], ch.litT),
                0.9
            )
        else
            love.graphics.setColor(COLOR_CHARGE[1], COLOR_CHARGE[2], COLOR_CHARGE[3], 0.7)
        end

        -- Draw charge as a wedge/trapezoid shape
        local a = ch.angle
        local hw = PI / NUM_CHARGES * 0.7 -- half-width angle
        local innerR = chargeR * 0.55
        local outerR = chargeR * 1.1

        if state.phase == PHASE_IMPLOSION or state.phase == PHASE_CHAIN then
            innerR = innerR * math.max(0.5, state.compressionRatio)
            outerR = outerR * math.max(0.5, state.compressionRatio)
        end

        local x1 = cx + math.cos(a - hw) * innerR
        local y1 = cy + math.sin(a - hw) * innerR
        local x2 = cx + math.cos(a + hw) * innerR
        local y2 = cy + math.sin(a + hw) * innerR
        local x3 = cx + math.cos(a + hw) * outerR
        local y3 = cy + math.sin(a + hw) * outerR
        local x4 = cx + math.cos(a - hw) * outerR
        local y4 = cy + math.sin(a - hw) * outerR

        love.graphics.polygon("fill", x1, y1, x2, y2, x3, y3, x4, y4)

        -- Charge outline
        love.graphics.setColor(0.5, 0.4, 0.2, 0.5)
        love.graphics.polygon("line", x1, y1, x2, y2, x3, y3, x4, y4)
    end

    -- Draw tamper shell
    love.graphics.setColor(COLOR_CASING[1], COLOR_CASING[2], COLOR_CASING[3], 0.3)
    love.graphics.setLineWidth(2)
    local casingR = chargeR * 1.15
    if state.phase == PHASE_IMPLOSION or state.phase == PHASE_CHAIN then
        casingR = casingR * math.max(0.5, state.compressionRatio)
    end
    love.graphics.circle("line", cx, cy, casingR)
    love.graphics.setLineWidth(1)

    -- Draw neutron trails
    for _, t in ipairs(state.trails) do
        love.graphics.setColor(COLOR_NEUTRON[1], COLOR_NEUTRON[2], COLOR_NEUTRON[3], t.alpha * 0.4)
        love.graphics.circle("fill", t.x, t.y, 1.5)
    end

    -- Draw fission flashes
    for _, f in ipairs(state.flashes) do
        love.graphics.setColor(COLOR_FLASH[1], COLOR_FLASH[2], COLOR_FLASH[3], f.alpha * 0.4)
        love.graphics.circle("fill", f.x, f.y, f.radius)
    end

    -- Draw fission fragments
    for _, f in ipairs(state.fragments) do
        if f.alive then
            love.graphics.setColor(f.r, f.g, f.b, f.alpha * 0.7)
            love.graphics.circle("fill", f.x, f.y, f.radius)
        end
    end

    -- Draw pit atoms
    for _, atom in ipairs(state.atoms) do
        if atom.alive then
            local pulse = 1 + math.sin(atom.pulsePhase) * 0.08
            local r = ATOM_RADIUS * pulse

            -- Glow
            love.graphics.setColor(0.2, 1.0, 0.35, 0.12)
            love.graphics.circle("fill", atom.x, atom.y, r * 1.6)

            -- Core
            love.graphics.setColor(COLOR_PIT)
            love.graphics.circle("fill", atom.x, atom.y, r)

            -- Highlight
            love.graphics.setColor(0.4, 0.9, 0.5, 0.4)
            love.graphics.circle("fill", atom.x - r*0.25, atom.y - r*0.25, r * 0.4)
        end
    end

    -- Draw neutrons
    for _, n in ipairs(state.neutrons) do
        if n.alive then
            love.graphics.setColor(COLOR_NEUTRON_FAST)
            love.graphics.circle("fill", n.x, n.y, NEUTRON_RADIUS + 1)
            love.graphics.setColor(COLOR_NEUTRON)
            love.graphics.circle("fill", n.x, n.y, NEUTRON_RADIUS)
        end
    end

    -- Draw particles
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(particleSystems.glow)
    love.graphics.draw(particleSystems.spark)

    -- Labels
    if state.phase == PHASE_IDLE or state.phase == PHASE_ARMED then
        love.graphics.setFont(fonts.small)

        -- "EXPLOSIVE LENSES" label
        love.graphics.setColor(0.6, 0.5, 0.3, 0.7)
        local labelR = chargeR * 1.35
        love.graphics.print("EXPLOSIVE LENSES", cx + labelR * 0.5, cy - labelR - 18)

        -- "U-235 PIT" label
        love.graphics.setColor(0.3, 0.7, 0.4, 0.7)
        love.graphics.printf("U-235 PIT", cx - 50, cy + vr * PIT_RADIUS_FRAC + 8, 100, "center")

        -- "NEUTRON REFLECTOR" label
        love.graphics.setColor(0.4, 0.42, 0.5, 0.6)
        love.graphics.print("TAMPER/REFLECTOR", cx - chargeR * 1.35, cy + chargeR * 1.15)
    end
end

function drawExplosion(cx, cy, vr, rx, ry, rw, rh)
    local yf = state.normalizedYield

    -- Full-area detonation flash
    if state.flashAlpha > 0 then
        love.graphics.setColor(1, 1, 0.95, state.flashAlpha)
        love.graphics.rectangle("fill", rx, ry, rw, rh)
    end

    -- Fireball
    if state.fireballAlpha > 0 then
        -- Outer glow (bigger and brighter for higher yields)
        love.graphics.setColor(1, 0.3, 0.05, state.fireballAlpha * (0.1 + 0.15 * yf))
        love.graphics.circle("fill", cx, cy, state.fireballRadius * (1.2 + 0.3 * yf))

        -- Inner fireball gradient
        local layers = 5
        for i = layers, 1, -1 do
            local t = i / layers
            local r = state.fireballRadius * t
            local rr = lerp(1.0, 1.0, t)
            local gg = lerp(0.2, 0.95, t)
            local bb = lerp(0.05, 0.7, t)
            love.graphics.setColor(rr, gg, bb, state.fireballAlpha * (0.3 + 0.7 * t))
            love.graphics.circle("fill", cx, cy, r)
        end

        -- Bright white core (lingers longer for bigger yields)
        if state.explosionT < (1.0 + 1.0 * yf) then
            local coreA = math.max(0, 1 - state.explosionT / (0.8 + 0.4 * yf))
            love.graphics.setColor(1, 1, 1, coreA)
            love.graphics.circle("fill", cx, cy, state.fireballRadius * (0.25 + 0.2 * yf))
        end
    end

    -- Shockwave ring (thickness and count scaled by yield)
    if state.shockwaveAlpha > 0.02 then
        local lw = (3 + state.shockwaveRadius * 0.03) * (0.7 + 0.8 * yf)
        love.graphics.setColor(COLOR_SHOCKWAVE[1], COLOR_SHOCKWAVE[2], COLOR_SHOCKWAVE[3], state.shockwaveAlpha * 0.6)
        love.graphics.setLineWidth(lw)
        love.graphics.circle("line", cx, cy, state.shockwaveRadius)
        -- Second trailing shockwave for bigger yields
        if yf > 0.3 then
            love.graphics.setColor(COLOR_SHOCKWAVE[1], COLOR_SHOCKWAVE[2], COLOR_SHOCKWAVE[3], state.shockwaveAlpha * 0.25)
            love.graphics.setLineWidth(lw * 0.5)
            love.graphics.circle("line", cx, cy, state.shockwaveRadius * 0.8)
        end
        love.graphics.setLineWidth(1)
    end

    -- Heat distortion glow
    if state.fireballAlpha > 0.1 then
        love.graphics.setColor(1, 0.5, 0.1, state.fireballAlpha * 0.08 * yf)
        love.graphics.rectangle("fill", rx, ry, rw, rh)
    end

    -- Particles
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(particleSystems.glow)
    love.graphics.draw(particleSystems.spark)
    love.graphics.draw(particleSystems.debris)

    -- Remaining neutrons flying outward
    for _, n in ipairs(state.neutrons) do
        if n.alive then
            love.graphics.setColor(COLOR_NEUTRON[1], COLOR_NEUTRON[2], COLOR_NEUTRON[3], 0.5)
            love.graphics.circle("fill", n.x, n.y, NEUTRON_RADIUS)
        end
    end

    -- Aftermath overlay
    if state.phase == PHASE_AFTERMATH then
        -- Yield rating
        local rating, ratingColor
        if state.yieldKt < 1 then
            rating = "DUD"
            ratingColor = {0.5, 0.5, 0.5}
        elseif state.yieldKt < 5 then
            rating = "FIZZLE"
            ratingColor = {0.8, 0.7, 0.3}
        elseif state.yieldKt < 15 then
            rating = "TACTICAL"
            ratingColor = {1.0, 0.7, 0.2}
        elseif state.yieldKt < 25 then
            rating = "STRATEGIC"
            ratingColor = {1.0, 0.5, 0.15}
        elseif state.yieldKt < 40 then
            rating = "DEVASTATING"
            ratingColor = {1.0, 0.3, 0.1}
        else
            rating = "CITY KILLER"
            ratingColor = {1.0, 0.15, 0.1}
        end

        love.graphics.setColor(0, 0, 0, 0.7)
        love.graphics.rectangle("fill", rx + 20, cy - 80, rw - 40, 160, 8, 8)

        love.graphics.setFont(fonts.huge)
        love.graphics.setColor(ratingColor[1], ratingColor[2], ratingColor[3], 0.95)
        love.graphics.printf(rating, rx, cy - 70, rw, "center")

        love.graphics.setFont(fonts.large)
        love.graphics.setColor(1, 0.9, 0.5, 0.9)
        love.graphics.printf(string.format("%.1f kilotons", state.yieldKt), rx, cy - 30, rw, "center")

        love.graphics.setFont(fonts.med)
        love.graphics.setColor(0.7, 0.75, 0.85)
        love.graphics.printf(
            string.format("%d fissions  |  %.0f%% efficiency", state.fissionCount, state.efficiency),
            rx, cy + 10, rw, "center"
        )

        love.graphics.setFont(fonts.small)
        love.graphics.setColor(0.5, 0.55, 0.65)
        love.graphics.printf("Press R to reset  |  D to reset design", rx, cy + 45, rw, "center")
    end
end

---------------------------------------------------------------------
-- Sidebar content (drawn by main.lua)
---------------------------------------------------------------------
function bomb.drawSidebar(pad, startY, sidebarW, H, drawDivider, drawStatLabel)
    local y = startY

    -- Phase indicator
    local phaseNames = {
        [PHASE_IDLE]      = "STANDBY",
        [PHASE_ARMED]     = "!! ARMED !!",
        [PHASE_IMPLOSION] = ">> IMPLOSION",
        [PHASE_CHAIN]     = "!! CHAIN REACTION",
        [PHASE_EXPLOSION] = "!! DETONATION",
        [PHASE_AFTERMATH] = "-- AFTERMATH",
    }
    local phaseColors = {
        [PHASE_IDLE]      = {0.4, 0.5, 0.6},
        [PHASE_ARMED]     = {1.0, 0.7, 0.2},
        [PHASE_IMPLOSION] = COLOR_DANGER,
        [PHASE_CHAIN]     = {1, 0.3, 0.1},
        [PHASE_EXPLOSION] = {1, 0.2, 0.1},
        [PHASE_AFTERMATH] = {0.5, 0.6, 0.7},
    }

    drawStatLabel("WEAPON STATUS", y, pad, phaseColors[state.phase])
    y = y + 18
    love.graphics.setFont(fonts.med)
    love.graphics.setColor(phaseColors[state.phase])
    local blink = (state.phase == PHASE_CHAIN or state.phase == PHASE_EXPLOSION)
        and (math.sin(love.timer.getTime() * 8) > 0) or true
    if blink then
        love.graphics.printf(phaseNames[state.phase] or "UNKNOWN", pad, y, sidebarW - pad * 2, "center")
    end
    y = y + 28

    drawDivider(y, pad)
    y = y + 15

    -- Energy released
    drawStatLabel("ENERGY RELEASED", y, pad, {1, 0.85, 0.2})
    y = y + 18
    love.graphics.setColor(1, 0.85, 0.2)
    love.graphics.setFont(fonts.large)
    love.graphics.printf(string.format("%.0f MeV", state.energyDisplay.value), pad, y, sidebarW - pad * 2, "center")
    y = y + 32

    -- Yield
    drawStatLabel("ESTIMATED YIELD", y, pad, COLOR_DANGER)
    y = y + 18
    love.graphics.setColor(COLOR_DANGER)
    love.graphics.setFont(fonts.large)
    love.graphics.printf(string.format("%.1f kt", state.yieldKt), pad, y, sidebarW - pad * 2, "center")
    y = y + 22
    love.graphics.setFont(fonts.small)
    love.graphics.setColor(0.45, 0.5, 0.6)
    local maxYield = getSliderValue("fuel_mass") * 0.8 * 0.5
    love.graphics.printf(string.format("theoretical max: %.0f kt", maxYield), pad, y, sidebarW - pad * 2, "center")
    y = y + 20

    -- Fission count
    drawStatLabel("FISSION EVENTS", y, pad, COLOR_PIT)
    y = y + 18
    love.graphics.setColor(COLOR_PIT)
    love.graphics.setFont(fonts.large)
    love.graphics.printf(tostring(state.fissionCount), pad, y, sidebarW - pad * 2, "center")
    y = y + 22
    if state.fissionCount > 0 then
        love.graphics.setFont(fonts.small)
        local eff = (state.fissionCount / getSliderValue("fuel_mass")) * 100
        love.graphics.setColor(0.45, 0.5, 0.6)
        love.graphics.printf(string.format("%.0f%% of fuel fissioned", eff), pad, y, sidebarW - pad * 2, "center")
        y = y + 18
    else
        y = y + 10
    end

    -- Active neutrons
    local activeN = 0
    for _, n in ipairs(state.neutrons) do if n.alive then activeN = activeN + 1 end end
    drawStatLabel("ACTIVE NEUTRONS", y, pad, COLOR_NEUTRON)
    y = y + 18
    love.graphics.setColor(COLOR_NEUTRON)
    love.graphics.setFont(fonts.large)
    love.graphics.printf(tostring(activeN), pad, y, sidebarW - pad * 2, "center")
    y = y + 32

    -- Compression ratio (during implosion/chain)
    if state.phase ~= PHASE_IDLE and state.phase ~= PHASE_ARMED then
        drawStatLabel("COMPRESSION", y, pad, COLOR_ACCENT)
        y = y + 18
        love.graphics.setColor(COLOR_ACCENT)
        love.graphics.setFont(fonts.large)
        love.graphics.printf(string.format("%.1fx", 1 / state.compressionRatio), pad, y, sidebarW - pad * 2, "center")
        y = y + 35
    else
        y = y + 5
    end

    drawDivider(y, pad)
    y = y + 15

    -- Weapon design sliders
    drawStatLabel("WEAPON DESIGN", y, pad, COLOR_ACCENT)
    y = y + 18
    local editable = (state.phase == PHASE_IDLE or state.phase == PHASE_ARMED)
    local barMargin = 5
    local barW = sidebarW - pad * 2 - barMargin * 2
    local bx = pad + barMargin
    for idx, s in ipairs(sliders) do
        love.graphics.setFont(fonts.small)
        local valStr = string.format(s.fmt, s.value) .. s.unit
        love.graphics.setColor(COLOR_ACCENT[1], COLOR_ACCENT[2], COLOR_ACCENT[3], editable and 0.6 or 0.25)
        love.graphics.print(s.label, bx, y)
        love.graphics.setColor(1, 1, 1, editable and 0.75 or 0.25)
        love.graphics.printf(valStr, bx, y, barW, "right")
        y = y + 15
        local barH = 6
        local barR = 3
        love.graphics.setColor(0.1, 0.12, 0.16, editable and 0.9 or 0.35)
        love.graphics.rectangle("fill", bx, y, barW, barH, barR, barR)
        local t = (s.value - s.min) / (s.max - s.min)
        local fillW = math.max(barR, t * barW)
        love.graphics.setColor(COLOR_ACCENT[1], COLOR_ACCENT[2], COLOR_ACCENT[3], editable and 0.65 or 0.2)
        love.graphics.rectangle("fill", bx, y, fillW, barH, barR, barR)
        local handleR = 5
        local hx = bx + t * barW
        local hy = y + barH / 2
        love.graphics.setColor(1, 1, 1, editable and 0.85 or 0.2)
        love.graphics.circle("fill", hx, hy, handleR)
        if editable and draggingSlider == idx then
            love.graphics.setColor(COLOR_ACCENT[1], COLOR_ACCENT[2], COLOR_ACCENT[3], 0.6)
            love.graphics.setLineWidth(1.5)
            love.graphics.circle("line", hx, hy, handleR + 1)
        end
        sliderRects[idx] = {
            barX = bx, barY = y, barW = barW, barH = barH, handleR = handleR
        }
        y = y + barH + 10
    end
    y = y + 2

    drawDivider(y, pad)
    y = y + 15

    -- Controls
    love.graphics.setFont(fonts.small)
    local controls = {
        { key = "SPACE", desc = "Arm weapon" },
        { key = "ENTER", desc = "Detonate" },
        { key = "R",     desc = "Reset" },
        { key = "D",     desc = "Reset design" },
        { key = "V",     desc = "3D atom view" },
    }
    local cardH = #controls * 20 + 10
    love.graphics.setColor(0.055, 0.065, 0.085, 0.9)
    love.graphics.rectangle("fill", pad, y - 2, sidebarW - pad * 2, cardH, 6, 6)
    love.graphics.setColor(0.13, 0.15, 0.2, 0.5)
    love.graphics.rectangle("line", pad, y - 2, sidebarW - pad * 2, cardH, 6, 6)
    y = y + 4
    for _, ctrl in ipairs(controls) do
        local keyW = fonts.small:getWidth(ctrl.key) + 10
        local keyX = pad + 10
        love.graphics.setColor(0.1, 0.12, 0.16, 1)
        love.graphics.rectangle("fill", keyX, y, keyW, 16, 3, 3)
        love.graphics.setColor(0.2, 0.23, 0.3, 1)
        love.graphics.rectangle("line", keyX, y, keyW, 16, 3, 3)
        love.graphics.setColor(0.6, 0.65, 0.75)
        love.graphics.print(ctrl.key, keyX + 5, y + 1)
        love.graphics.setColor(0.45, 0.5, 0.6)
        love.graphics.print(ctrl.desc, keyX + keyW + 8, y + 1)
        y = y + 20
    end
    y = y + 8

    drawDivider(y, pad)
    y = y + 12

    -- Educational info
    drawStatLabel("HOW IT WORKS", y, pad, COLOR_ACCENT)
    y = y + 20
    love.graphics.setFont(fonts.small)
    love.graphics.setColor(0.45, 0.5, 0.6)

    local info
    if state.phase == PHASE_IDLE then
        info = "An implosion-type fission weapon uses shaped explosive charges to compress a subcritical sphere of U-235 to supercritical density."
    elseif state.phase == PHASE_ARMED then
        info = "The weapon is armed. Detonation will fire all explosive lenses simultaneously, compressing the pit to ~3x density."
    elseif state.phase == PHASE_IMPLOSION then
        info = "Explosive lenses fire inward, creating a spherical shockwave that compresses the uranium pit beyond critical mass."
    elseif state.phase == PHASE_CHAIN then
        info = "A neutron initiator floods the compressed core. With no moderator, fast neutrons cause an exponential chain reaction in microseconds."
    elseif state.phase == PHASE_EXPLOSION or state.phase == PHASE_AFTERMATH then
        info = "The energy release is so rapid the core disassembles before most fuel fissions. Typical efficiency is only 1-2% of the uranium."
    end

    love.graphics.printf(info, pad + 5, y, sidebarW - pad * 2 - 10, "left")

    return y
end

---------------------------------------------------------------------
-- Input
---------------------------------------------------------------------
function bomb.keypressed(key)
    if key == "space" then
        if state.phase == PHASE_IDLE then
            state.phase = PHASE_ARMED
        end
    elseif key == "return" or key == "kpenter" then
        if state.phase == PHASE_ARMED then
            state.phase = PHASE_IMPLOSION
            state.implosionT = 0
        end
    elseif key == "r" then
        local cx, cy, vr = state.cx, state.cy, state.viewRadius
        resetState()
        -- Re-spawn will happen in update when cx/cy are set
    elseif key == "d" then
        if state.phase == PHASE_IDLE or state.phase == PHASE_ARMED then
            for _, s in ipairs(sliders) do
                s.value = s.default
            end
            state.atoms = {}
            state.atomsOriginal = {}
        end
    end
    -- Return true if we handled the key (bomb mode active)
    return true
end

function bomb.getShakeAmount()
    return state.shakeAmount
end

function bomb.getFlashAlpha()
    return state.flashAlpha
end

function bomb.getPhase()
    return state.phase
end

function bomb.mousepressed(x, y, button)
    if button ~= 1 then return false end
    if state.phase ~= PHASE_IDLE and state.phase ~= PHASE_ARMED then return false end
    for idx = 1, #sliders do
        local rect = sliderRects[idx]
        if rect and x >= rect.barX - rect.handleR and x <= rect.barX + rect.barW + rect.handleR
            and y >= rect.barY - rect.handleR and y <= rect.barY + rect.barH + rect.handleR then
            draggingSlider = idx
            local oldVal = sliders[idx].value
            setSliderFromMouse(idx, x)
            if sliders[idx].value ~= oldVal and sliders[idx].id == "fuel_mass" then
                respawnIfNeeded()
            end
            return true
        end
    end
    return false
end

function bomb.mousemoved(x, y, dx, dy)
    if draggingSlider then
        local oldVal = sliders[draggingSlider].value
        setSliderFromMouse(draggingSlider, x)
        if sliders[draggingSlider].value ~= oldVal and sliders[draggingSlider].id == "fuel_mass" then
            respawnIfNeeded()
        end
        return true
    end
    return false
end

function bomb.mousereleased(x, y, button)
    if button == 1 and draggingSlider then
        draggingSlider = nil
        return true
    end
    return false
end

return bomb
