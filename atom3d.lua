-- atom3d.lua — Accurate 3D uranium-235 atom viewer (powered by g3d)
--
-- U-235 electron configuration: [Rn] 5f3 6d1 7s2
--   Shell K(1): 2   Shell L(2): 8   Shell M(3): 18  Shell N(4): 32
--   Shell O(5): 21  Shell P(6): 9   Shell Q(7): 2   = 92 electrons
-- Nucleus: 92 protons + 143 neutrons = 235 nucleons

local atom3d = {}
local g3d
local litShader
local canvas, depthCanvas
local canvasW, canvasH = 0, 0

-- Models
local nucleusModel
local protonBumpsModel, neutronBumpsModel
local glowShell
local orbitModels = {}
local shellElectronModel = {}
local electronData = {}

-- Camera
local orbitH = 0.5
local orbitV = 0.4
local orbitDist = 18.0
local dragging = false
local dragStartX, dragStartY = 0, 0
local dragStartH, dragStartV = 0, 0

local timer = 0
atom3d.active = false
local font

-- Physical constants
local NUCLEUS_R  = 0.85
local NUCLEON_R  = 0.18
local ELECTRON_R = 0.12

-- Uranium electron shells
local shells = {
    { n=1, label="K", e=2,  R=1.8, rx=0.0,  ry=0.0,  speed=2.0 },
    { n=2, label="L", e=8,  R=2.5, rx=0.5,  ry=0.3,  speed=1.5 },
    { n=3, label="M", e=18, R=3.2, rx=-0.4, ry=0.8,  speed=1.2 },
    { n=4, label="N", e=32, R=4.0, rx=0.9,  ry=-0.4, speed=0.9 },
    { n=5, label="O", e=21, R=4.8, rx=-0.7, ry=0.5,  speed=0.7 },
    { n=6, label="P", e=9,  R=5.6, rx=0.3,  ry=-0.7, speed=0.5 },
    { n=7, label="Q", e=2,  R=6.4, rx=-0.5, ry=0.1,  speed=0.3 },
}

-- Shell colors (spectral gradient)
local shellColors = {
    {0.90, 0.35, 0.35},  -- K: red
    {0.95, 0.60, 0.20},  -- L: orange
    {0.95, 0.90, 0.25},  -- M: yellow
    {0.30, 0.85, 0.40},  -- N: green
    {0.25, 0.85, 0.85},  -- O: cyan
    {0.40, 0.50, 0.95},  -- P: blue
    {0.70, 0.40, 0.90},  -- Q: violet
}

---------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------
local function makeColorTex(r, g, b, a)
    local data = love.image.newImageData(1, 1)
    data:setPixel(0, 0, r, g, b, a or 1)
    return love.graphics.newImage(data)
end

---------------------------------------------------------------------
-- Geometry generators (white vertex colors; texture provides color)
---------------------------------------------------------------------
local function generateSphere(radius, rings, sectors)
    local verts = {}
    for i = 0, rings - 1 do
        for j = 0, sectors - 1 do
            local function vert(ii, jj)
                local phi = math.pi * ii / rings
                local theta = 2 * math.pi * jj / sectors
                local sp, cp = math.sin(phi), math.cos(phi)
                local st, ct = math.sin(theta), math.cos(theta)
                local x = radius * sp * ct
                local y = radius * sp * st
                local z = radius * cp
                return {x, y, z, 0, 0, sp*ct, sp*st, cp, 255, 255, 255, 255}
            end
            local v1 = vert(i, j)
            local v2 = vert(i+1, j)
            local v3 = vert(i+1, j+1)
            local v4 = vert(i, j+1)
            verts[#verts+1] = v1; verts[#verts+1] = v2; verts[#verts+1] = v3
            verts[#verts+1] = v1; verts[#verts+1] = v3; verts[#verts+1] = v4
        end
    end
    return verts
end

local function appendOffsetSphere(verts, cx, cy, cz, radius, rings, sectors)
    for i = 0, rings - 1 do
        for j = 0, sectors - 1 do
            local function vert(ii, jj)
                local phi = math.pi * ii / rings
                local theta = 2 * math.pi * jj / sectors
                local sp, cp = math.sin(phi), math.cos(phi)
                local st, ct = math.sin(theta), math.cos(theta)
                local nx, ny, nz = sp*ct, sp*st, cp
                return {cx + radius*nx, cy + radius*ny, cz + radius*nz,
                        0, 0, nx, ny, nz, 255, 255, 255, 255}
            end
            local v1 = vert(i, j)
            local v2 = vert(i+1, j)
            local v3 = vert(i+1, j+1)
            local v4 = vert(i, j+1)
            verts[#verts+1] = v1; verts[#verts+1] = v2; verts[#verts+1] = v3
            verts[#verts+1] = v1; verts[#verts+1] = v3; verts[#verts+1] = v4
        end
    end
end

local function generateTorus(majorR, minorR, majorSegs, minorSegs)
    local verts = {}
    for i = 0, majorSegs - 1 do
        for j = 0, minorSegs - 1 do
            local function vert(ii, jj)
                local theta = 2 * math.pi * ii / majorSegs
                local phi = 2 * math.pi * jj / minorSegs
                local sp, cp = math.sin(phi), math.cos(phi)
                local st, ct = math.sin(theta), math.cos(theta)
                local x = (majorR + minorR * cp) * ct
                local y = (majorR + minorR * cp) * st
                local z = minorR * sp
                return {x, y, z, 0, 0, cp*ct, cp*st, sp, 255, 255, 255, 255}
            end
            local v1 = vert(i, j)
            local v2 = vert(i+1, j)
            local v3 = vert(i+1, j+1)
            local v4 = vert(i, j+1)
            verts[#verts+1] = v1; verts[#verts+1] = v2; verts[#verts+1] = v3
            verts[#verts+1] = v1; verts[#verts+1] = v3; verts[#verts+1] = v4
        end
    end
    return verts
end

---------------------------------------------------------------------
-- Rotation helper (matches g3d Euler order: Rx -> Ry -> Rz)
---------------------------------------------------------------------
local function rotatePoint(x, y, z, rx, ry, rz)
    local cx, sx = math.cos(rx), math.sin(rx)
    local y1 = y * cx - z * sx
    local z1 = y * sx + z * cx
    y, z = y1, z1
    local cy, sy = math.cos(ry), math.sin(ry)
    local x1 = x * cy + z * sy
    z1 = -x * sy + z * cy
    x, z = x1, z1
    local cz, sz = math.cos(rz), math.sin(rz)
    x1 = x * cz - y * sz
    y1 = x * sz + y * cz
    return x1, y1, z
end

---------------------------------------------------------------------
-- Shader (texture-driven color, diffuse + specular)
---------------------------------------------------------------------
local function createLitShader()
    return love.graphics.newShader(
    [[  uniform mat4 projectionMatrix;
        uniform mat4 viewMatrix;
        uniform mat4 modelMatrix;
        uniform bool isCanvasEnabled;
        attribute vec3 VertexNormal;
        varying vec4 worldPosition;
        varying vec3 vertexNormal;
        vec4 position(mat4 transformProjection, vec4 vertexPosition) {
            worldPosition = modelMatrix * vertexPosition;
            vec4 screenPosition = projectionMatrix * viewMatrix * worldPosition;
            vertexNormal = mat3(modelMatrix) * VertexNormal;
            if (isCanvasEnabled) { screenPosition.y *= -1.0; }
            return screenPosition;
        }
    ]],
    [[  uniform vec3 cameraPos;
        varying vec4 worldPosition;
        varying vec3 vertexNormal;
        vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
            vec4 texColor = Texel(tex, tc);
            vec3 n = normalize(vertexNormal);
            vec3 lightDir = normalize(vec3(0.4, 0.6, 0.8));
            float diff = max(dot(n, lightDir), 0.0);
            vec3 viewDir = normalize(cameraPos - worldPosition.xyz);
            vec3 halfDir = normalize(lightDir + viewDir);
            float spec = pow(max(dot(n, halfDir), 0.0), 48.0);
            vec3 ambient = texColor.rgb * 0.3;
            vec3 diffuse = texColor.rgb * diff * 0.65;
            vec3 specular = vec3(1.0) * spec * 0.25;
            return vec4(ambient + diffuse + specular, texColor.a) * color;
        }
    ]])
end

---------------------------------------------------------------------
-- Module API
---------------------------------------------------------------------
function atom3d.load(f)
    font = f
    g3d = require("g3d.g3d")
    love.graphics.setDepthMode()
    litShader = createLitShader()

    -- Textures
    local nucleusTex = makeColorTex(0.18, 0.60, 0.25, 1.0)
    local protonTex  = makeColorTex(0.85, 0.25, 0.20, 1.0)
    local neutronTex = makeColorTex(0.30, 0.45, 0.85, 1.0)
    local glowTex    = makeColorTex(0.20, 0.86, 0.31, 1.0)

    -- Nucleus core sphere
    nucleusModel = g3d.newModel(
        generateSphere(NUCLEUS_R, 24, 24),
        nucleusTex, {0,0,0}, {0,0,0}, {1,1,1}
    )

    -- Nucleon bumps via Fibonacci sphere distribution
    local NUM_NUCLEONS = 80
    local NUM_PROTONS = math.floor(NUM_NUCLEONS * 92 / 235)
    local golden = (1 + math.sqrt(5)) / 2
    local protonVerts, neutronVerts = {}, {}

    for k = 1, NUM_NUCLEONS do
        local theta = 2 * math.pi * k / golden
        local phi = math.acos(1 - 2 * (k - 0.5) / NUM_NUCLEONS)
        local sr = NUCLEUS_R + NUCLEON_R * 0.3
        local cx = sr * math.sin(phi) * math.cos(theta)
        local cy = sr * math.sin(phi) * math.sin(theta)
        local cz = sr * math.cos(phi)
        local target = (k <= NUM_PROTONS) and protonVerts or neutronVerts
        appendOffsetSphere(target, cx, cy, cz, NUCLEON_R, 6, 6)
    end

    protonBumpsModel  = g3d.newModel(protonVerts, protonTex, {0,0,0}, {0,0,0}, {1,1,1})
    neutronBumpsModel = g3d.newModel(neutronVerts, neutronTex, {0,0,0}, {0,0,0}, {1,1,1})

    -- Glow shell around nucleus
    glowShell = g3d.newModel(
        generateSphere(NUCLEUS_R + 0.6, 16, 16),
        glowTex, {0,0,0}, {0,0,0}, {1,1,1}
    )

    -- 7 electron shell orbit tori + one shared electron model per shell
    for s, shell in ipairs(shells) do
        local c = shellColors[s]
        orbitModels[s] = g3d.newModel(
            generateTorus(shell.R, 0.03, 64, 8),
            makeColorTex(c[1], c[2], c[3], 0.6),
            {0,0,0}, {shell.rx, shell.ry, 0}, {1,1,1}
        )
        shellElectronModel[s] = g3d.newModel(
            generateSphere(ELECTRON_R, 8, 8),
            makeColorTex(c[1], c[2], c[3], 1.0),
            {0,0,0}, {0,0,0}, {1,1,1}
        )
    end

    -- Build per-electron data: shell index + angular offset
    electronData = {}
    for s, shell in ipairs(shells) do
        for e = 1, shell.e do
            electronData[#electronData + 1] = {
                shell = s,
                angle = (e - 1) / shell.e * 2 * math.pi,
                x = 0, y = 0, z = 0,
            }
        end
    end

    love.graphics.setDepthMode()
end

local function ensureCanvas(w, h)
    if canvasW ~= w or canvasH ~= h then
        canvasW, canvasH = w, h
        canvas = love.graphics.newCanvas(w, h)
        depthCanvas = love.graphics.newCanvas(w, h, {format = "depth24"})
    end
end

function atom3d.update(dt)
    if not atom3d.active then return end
    timer = timer + dt

    -- Compute electron positions
    for _, ed in ipairs(electronData) do
        local shell = shells[ed.shell]
        local theta = timer * shell.speed + ed.angle
        local ex = shell.R * math.cos(theta)
        local ey = shell.R * math.sin(theta)
        ed.x, ed.y, ed.z = rotatePoint(ex, ey, 0, shell.rx, shell.ry, 0)
    end

    if not dragging then
        orbitH = orbitH + dt * 0.12
    end
end

function atom3d.draw(rx, ry, rw, rh)
    if not atom3d.active then return end
    ensureCanvas(rw, rh)

    local camX = orbitDist * math.cos(orbitV) * math.cos(orbitH)
    local camY = orbitDist * math.cos(orbitV) * math.sin(orbitH)
    local camZ = orbitDist * math.sin(orbitV)

    g3d.camera.aspectRatio = rw / rh
    g3d.camera.updateProjectionMatrix()
    g3d.camera.lookAt(camX, camY, camZ, 0, 0, 0)
    litShader:send("cameraPos", {camX, camY, camZ})

    love.graphics.push("all")
    love.graphics.setCanvas({canvas, depthstencil = depthCanvas})
    love.graphics.clear(0.04, 0.05, 0.07, 1)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setDepthMode("lequal", true)

    -- 1) Opaque: nucleus + nucleon bumps
    nucleusModel:draw(litShader)
    protonBumpsModel:draw(litShader)
    neutronBumpsModel:draw(litShader)

    -- 2) Opaque: electrons (92 total, 7 shared models repositioned)
    for _, ed in ipairs(electronData) do
        local model = shellElectronModel[ed.shell]
        model:setTranslation(ed.x, ed.y, ed.z)
        model:draw(litShader)
    end

    -- 3) Semi-transparent: orbit tori (depth test, no depth write)
    love.graphics.setDepthMode("lequal", false)
    for s = 1, #shells do
        orbitModels[s]:draw(litShader)
    end

    -- 4) Additive: nucleus glow
    love.graphics.setBlendMode("add")
    love.graphics.setColor(1, 1, 1, 0.15)
    glowShell:draw(litShader)

    love.graphics.pop()

    -- Clip composite to rounded reactor rect via stencil
    love.graphics.stencil(function()
        love.graphics.rectangle("fill", rx, ry, rw, rh, 8, 8)
    end, "replace", 1)
    love.graphics.setStencilTest("greater", 0)

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, rx, ry)

    -- Info overlay
    love.graphics.setFont(font)
    love.graphics.setColor(0.6, 0.7, 0.8, 0.8)
    love.graphics.printf("U-235:  92 protons  |  143 neutrons  |  92 electrons (7 shells)",
                         rx, ry + 8, rw, "center")
    love.graphics.setColor(0.5, 0.6, 0.7, 0.6)
    love.graphics.printf("Drag to rotate  -  Scroll to zoom  -  V to close",
                         rx, ry + rh - 25, rw, "center")

    love.graphics.setStencilTest()
end

function atom3d.toggle()
    atom3d.active = not atom3d.active
end

function atom3d.mousepressed(x, y, button, rx, ry, rw, rh)
    if not atom3d.active then return false end
    if button == 1 and x >= rx and x <= rx + rw and y >= ry and y <= ry + rh then
        dragging = true
        dragStartX, dragStartY = x, y
        dragStartH, dragStartV = orbitH, orbitV
        return true
    end
    return false
end

function atom3d.mousereleased(x, y, button)
    if button == 1 then dragging = false end
end

function atom3d.mousemoved(x, y, dx, dy)
    if not atom3d.active or not dragging then return false end
    orbitH = dragStartH - (x - dragStartX) * 0.008
    orbitV = math.max(-math.pi/2 + 0.05, math.min(math.pi/2 - 0.05,
             dragStartV + (y - dragStartY) * 0.008))
    return true
end

function atom3d.wheelmoved(x, y, rx, ry, rw, rh)
    if not atom3d.active then return false end
    local mx, my = love.mouse.getPosition()
    if mx >= rx and mx <= rx + rw and my >= ry and my <= ry + rh then
        orbitDist = math.max(5, math.min(35, orbitDist - y * 1.0))
        return true
    end
    return false
end

return atom3d
