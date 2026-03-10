-- atom3d.lua — Interactive 3D uranium atom viewer (powered by g3d)

local atom3d = {}
local g3d
local litShader
local canvas, depthCanvas
local canvasW, canvasH = 0, 0

-- Models
local nucleus
local glowShell
local orbits = {}
local electrons = {}
local whiteTex

-- Camera state
local orbitH = 0.5
local orbitV = 0.4
local orbitDist = 8.0
local dragging = false
local dragStartX, dragStartY = 0, 0
local dragStartH, dragStartV = 0, 0

-- Animation
local timer = 0

-- UI state
atom3d.active = false
local font

-- Orbit definitions: major radius, tilt rx, tilt ry, animation speed, phase offset
local orbitDefs = {
    { R = 2.8, rx = 0.5,  ry = 0,   speed = 1.2, phase = 0 },
    { R = 3.2, rx = -0.6, ry = 0.3, speed = 0.9, phase = 2.1 },
    { R = 2.4, rx = 1.5,  ry = 0.2, speed = 1.5, phase = 4.2 },
}

---------------------------------------------------------------------
-- Geometry generators
---------------------------------------------------------------------
local function generateSphere(radius, rings, sectors, r, g, b, a)
    local verts = {}
    a = a or 255
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
                return {x, y, z, 0, 0, sp*ct, sp*st, cp, r, g, b, a}
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

local function generateTorus(majorR, minorR, majorSegs, minorSegs, r, g, b, a)
    local verts = {}
    a = a or 255
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
                return {x, y, z, 0, 0, cp*ct, cp*st, sp, r, g, b, a}
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
-- Rotation helper (matches g3d Euler order: Rx → Ry → Rz)
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
-- Lit shader with diffuse + specular lighting
---------------------------------------------------------------------
local function createLitShader()
    return love.graphics.newShader(
    [[  // Vertex shader
        uniform mat4 projectionMatrix;
        uniform mat4 viewMatrix;
        uniform mat4 modelMatrix;
        uniform bool isCanvasEnabled;
        attribute vec3 VertexNormal;

        varying vec4 worldPosition;
        varying vec4 viewPosition;
        varying vec3 vertexNormal;
        varying vec4 vertexColor;

        vec4 position(mat4 transformProjection, vec4 vertexPosition) {
            worldPosition = modelMatrix * vertexPosition;
            viewPosition = viewMatrix * worldPosition;
            vec4 screenPosition = projectionMatrix * viewPosition;
            vertexNormal = mat3(modelMatrix) * VertexNormal;
            vertexColor = VertexColor;
            if (isCanvasEnabled) { screenPosition.y *= -1.0; }
            return screenPosition;
        }
    ]],
    [[  // Fragment shader
        uniform vec3 cameraPos;
        varying vec4 worldPosition;
        varying vec3 vertexNormal;
        varying vec4 vertexColor;

        vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
            vec4 texColor = Texel(tex, tc) * vertexColor;
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
    -- g3d enables depth mode globally on require; disable for normal 2D rendering
    love.graphics.setDepthMode()

    litShader = createLitShader()

    -- 1×1 white texture so vertex colors drive appearance
    local imgData = love.image.newImageData(1, 1)
    imgData:setPixel(0, 0, 1, 1, 1, 1)
    whiteTex = love.graphics.newImage(imgData)

    -- Nucleus: bright green sphere
    nucleus = g3d.newModel(
        generateSphere(1.0, 28, 28, 50, 200, 80, 255),
        whiteTex, {0,0,0}, {0,0,0}, {1,1,1}
    )

    -- Glow shell: larger semi-transparent sphere (drawn with additive blend)
    glowShell = g3d.newModel(
        generateSphere(1.5, 16, 16, 50, 220, 80, 50),
        whiteTex, {0,0,0}, {0,0,0}, {1,1,1}
    )

    -- Electron orbit tori
    for i, def in ipairs(orbitDefs) do
        orbits[i] = g3d.newModel(
            generateTorus(def.R, 0.04, 64, 8, 100, 180, 255, 180),
            whiteTex, {0,0,0}, {def.rx, def.ry, 0}, {1,1,1}
        )
    end

    -- Electrons: small bright cyan spheres
    for i = 1, 3 do
        electrons[i] = g3d.newModel(
            generateSphere(0.18, 10, 10, 120, 210, 255, 255),
            whiteTex, {0,0,0}, {0,0,0}, {1,1,1}
        )
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

    -- Animate electrons along their orbits
    for i, def in ipairs(orbitDefs) do
        local theta = timer * def.speed + def.phase
        local ex = def.R * math.cos(theta)
        local ey = def.R * math.sin(theta)
        local ez = 0
        ex, ey, ez = rotatePoint(ex, ey, ez, def.rx, def.ry, 0)
        electrons[i]:setTranslation(ex, ey, ez)
    end

    -- Gentle auto-rotation when not dragging
    if not dragging then
        orbitH = orbitH + dt * 0.15
    end
end

function atom3d.draw(rx, ry, rw, rh)
    if not atom3d.active then return end

    ensureCanvas(rw, rh)

    -- Camera position from spherical coordinates
    local camX = orbitDist * math.cos(orbitV) * math.cos(orbitH)
    local camY = orbitDist * math.cos(orbitV) * math.sin(orbitH)
    local camZ = orbitDist * math.sin(orbitV)

    g3d.camera.aspectRatio = rw / rh
    g3d.camera.updateProjectionMatrix()
    g3d.camera.lookAt(camX, camY, camZ, 0, 0, 0)

    -- Send camera position to shader for specular
    litShader:send("cameraPos", {camX, camY, camZ})

    -- Render 3D scene to canvas
    love.graphics.push("all")
    love.graphics.setCanvas({canvas, depthstencil = depthCanvas})
    love.graphics.clear(0.04, 0.05, 0.07, 1)
    love.graphics.setDepthMode("lequal", true)

    -- Opaque objects
    nucleus:draw(litShader)
    for i = 1, 3 do
        orbits[i]:draw(litShader)
        electrons[i]:draw(litShader)
    end

    -- Glow shell: additive blend, depth test but no depth write
    love.graphics.setDepthMode("lequal", false)
    love.graphics.setBlendMode("add")
    glowShell:draw(litShader)
    love.graphics.setBlendMode("alpha")

    love.graphics.pop() -- restores canvas, shader, depth mode, blend mode

    -- Draw rendered canvas at reactor position
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(canvas, rx, ry)

    -- Overlay instructions
    love.graphics.setFont(font)
    love.graphics.setColor(0.5, 0.6, 0.7, 0.7)
    love.graphics.printf("Drag to rotate  •  Scroll to zoom  •  V to close",
                         rx, ry + rh - 25, rw, "center")
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
        orbitDist = math.max(3, math.min(20, orbitDist - y * 0.5))
        return true
    end
    return false
end

return atom3d
