# AGENTS.md

## Project Overview

**Atom** is an educational simulation of uranium-235 fission built with
[LÖVE2D](https://love2d.org/) (Lua). It features two modes: a **reactor**
simulation where you inject neutrons, manage control rods, and try to avoid
meltdown, and a **fission bomb** simulation showing how an implosion-type
weapon compresses uranium to supercritical density.  An interactive **3D atom
viewer** lets you explore a physically-accurate model of the U-235 atom with
all 92 electrons across 7 shells.

> "How do I boil water?"
> — every nuclear engineer, when someone asks what they do for a living

## Tech Stack

- **Language:** Lua
- **Framework:** LÖVE2D 11.5
- **Tweening:** [flux](https://github.com/rxi/flux) (bundled as `flux.lua`)
- **3D rendering:** [g3d](https://github.com/groverburger/g3d) (bundled in `g3d/`)

## File Structure

```
atom/
├── main.lua    — Reactor simulation: physics, rendering, input, UI, mode switching
├── bomb.lua    — Fission bomb (implosion-type) simulation module
├── atom3d.lua  — Interactive 3D uranium-235 atom viewer (powered by g3d)
├── conf.lua    — LÖVE2D window/engine configuration (1280×800, resizable, min 1280×800)
├── flux.lua    — Tweening library (third-party, MIT license, by rxi)
├── flux.md     — Documentation for the flux tweening library
├── logo.png    — Project logo (1024×1024, anti-aliased)
├── g3d/        — 3D engine library (third-party, MIT license, by groverburger)
└── .github/workflows/build.yml — GitHub Action that builds atom.love on every push
```

## Architecture

The simulation has two main modes — **Reactor** and **Fission Bomb** — selectable
via tabs at the top of the sidebar. The reactor simulation lives in `main.lua`,
the bomb simulation in `bomb.lua`, and the 3D atom viewer in `atom3d.lua`.
`main.lua` acts as the entry point and delegates update/draw/input to the active
module based on `currentMode`.

### Key Concepts

| Concept            | Description                                                       |
|--------------------|-------------------------------------------------------------------|
| **Atoms**          | U-235 nuclei placed randomly in the reactor vessel                |
| **Neutrons**       | Projectiles that trigger fission on contact with atoms            |
| **Fission**        | Probabilistic: cross-section depends on neutron energy & temperature |
| **Control Rods**   | 5 vertical rods that absorb neutrons when inserted                |
| **Neutron Energy** | Fast (~2 MeV) from fission, thermalizes via moderator over time   |
| **Temperature**    | Rises with fission; Doppler broadening reduces reactivity         |
| **Meltdown**       | Reactor game-over state when core temperature exceeds 500°C       |
| **Bomb Sim**       | Implosion-type weapon: explosive compression → supercritical chain reaction |
| **3D Viewer**      | Orbit-camera view of U-235 atom: nucleus, 92 electrons, 7 shells  |

### Reactor Simulation Loop

1. Neutrons move at speed scaled by √(energy) — fast neutrons zoom, thermal crawl
2. Neutron energy decays exponentially (moderator simulation, rate = 10/s)
3. Collision checks: interaction probability depends on neutron energy (σ_total)
4. Interaction outcomes: fission (~84% thermal), elastic scatter, or radiative capture
5. Doppler broadening: higher temperature reduces effective fission cross-section
6. Delayed neutrons (β_eff ≈ 0.0065): ~0.65% of neutrons spawn after 0.2–12s delay
7. Temperature rises from fission; exponential cooling (Newton's law)
8. Meltdown triggers if temperature exceeds 500°C
9. User-fired (generation-0) neutrons always fission on first atom contact

### Bomb Simulation Phases

1. **Idle** — subcritical U-235 pit surrounded by explosive lenses, labeled diagram
2. **Armed** — weapon armed, awaiting detonation command
3. **Implosion** — explosive charges ignite sequentially, atoms compress to ~3× density
4. **Chain Reaction** — neutron initiator fires, fast neutrons (no moderator), 85% fission probability, neutron reflector (tamper)
5. **Explosion** — expanding fireball + shockwave ring + particle debris
6. **Aftermath** — yield display (kilotons), fission count, reset prompt

### Rendering Layers (reactor draw order)

1. Reactor background + wall border + temperature glow
2. Control rods
3. Neutron trails
4. Atoms (with glow/pulse/scatter ring)
5. Fission fragments
6. Neutrons (energy-based coloring, fade-out on death)
7. Fission flashes
8. Particle systems (glow + sparks)
9. Sidebar with mode tabs, stats, and controls
10. Pause/meltdown overlays

### Neutron Lifecycle

- **Spawn**: at click position (reactor) or from initiator (bomb)
- **Movement**: velocity × speedScale × dt; speedScale = 0.2 + 0.8 × √(E/2)
- **Interactions**: fission, elastic scatter (visible ring on atom), radiative capture
- **Death**: neutrons enter a `dying` state with smooth fade-out + spark puff
  (never vanish abruptly). Dying neutrons no longer interact with atoms.
- **Max age**: 15 seconds before fade-out begins

## Controls

### Reactor Mode

| Input              | Action                              |
|--------------------|-------------------------------------|
| **Left Click**     | Inject a neutron at click position  |
| **Space**          | Pause / unpause simulation          |
| **R**              | Reset the reactor                   |
| **C**              | Toggle control rods (in/out)        |
| **Up / Down**      | Adjust control rod insertion ±10%   |
| **+ / -**          | Adjust simulation speed (0.25–5×)   |
| **A**              | Add 5 more U-235 atoms              |
| **V**              | Toggle 3D atom viewer               |

### Bomb Mode

| Input              | Action                              |
|--------------------|-------------------------------------|
| **Space**          | Arm the weapon                      |
| **Enter**          | Detonate (must be armed first)      |
| **R**              | Reset the bomb                      |
| **V**              | Toggle 3D atom viewer               |

## Coding Conventions

- Game state is stored in module-level local tables (`atoms`, `neutrons`,
  `fragments`, `flashes`, `trails`); bomb state is encapsulated in `bomb.lua`
- Constants and tuning values are grouped at the top of each file
- Colors are stored as RGBA tables prefixed with `COLOR_`
- Animations and smooth transitions use the `flux` tweening library
- No external assets — all visuals are procedurally generated (circles,
  rectangles, and canvas-based particle images)
- Entity lifecycle: `alive` flag + optional `dying` state for animated death
- Modules expose a standard API: `load()`, `update(dt, ...)`, `draw(...)`,
  `keypressed(key)`, `reset()`

## How to Run

```bash
love .
```

Requires [LÖVE2D](https://love2d.org/) 11.x installed on your system.

## Editing Guidelines

- `flux.lua`, `flux.md`, and `g3d/` are **third-party vendored files** — do not modify
- Reactor tuning knobs are in the constants block at the top of `main.lua`.
  Bomb tuning knobs are at the top of `bomb.lua`.
- Each simulation mode (reactor, bomb) manages its own state, update, and draw.
  `main.lua` delegates to `bomb.lua` when in bomb mode via `bombSim.*` calls.
- When adding new entity types, follow the existing pattern: a table-of-tables
  with an `alive` flag, spawned in a function, updated in the module's update,
  drawn in the module's draw, and cleaned up with a reverse-iteration removal pass.
- The sidebar is drawn procedurally with hardcoded Y offsets — budget ~20px per
  new stat line. Mode tabs at the top switch between reactor and bomb sidebar content.
- LÖVE2D's default font has **no emoji/unicode** — use only ASCII in UI text.
- `love.graphics.setColor` bleeds into shaders — reset to white before 3D rendering.
