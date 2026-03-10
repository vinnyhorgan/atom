# AGENTS.md

## Project Overview

**Atom** is a visual simulation of uranium-235 fission chain reactions built
with [LÖVE2D](https://love2d.org/) (Lua). Click inside the reactor to fire
neutrons at U-235 atoms and watch the chain reaction unfold — complete with
control rods, a temperature system, and a meltdown state.

> "How do I boil water?"
> — every nuclear engineer, when someone asks what they do for a living

## Tech Stack

- **Language:** Lua
- **Framework:** LÖVE2D 11.5
- **Tweening:** [flux](https://github.com/rxi/flux) (bundled as `flux.lua`)

## File Structure

```
atom/
├── main.lua    — Reactor simulation: physics, rendering, input, UI
├── bomb.lua    — Fission bomb (implosion-type) simulation module
├── atom3d.lua  — Interactive 3D uranium atom viewer (powered by g3d)
├── conf.lua    — LÖVE2D window/engine configuration
├── flux.lua    — Tweening library (third-party, MIT license, by rxi)
├── flux.md     — Documentation for the flux tweening library
└── g3d/        — 3D engine library (third-party, MIT license, by groverburger)
```

## Architecture

The simulation has two main modes — **Reactor** and **Fission Bomb** — selectable
via tabs in the sidebar. The reactor simulation lives in `main.lua`, the bomb
simulation in `bomb.lua`, and the 3D atom viewer in `atom3d.lua`.

### Key Concepts

| Concept           | Description                                                       |
|-------------------|-------------------------------------------------------------------|
| **Atoms**         | U-235 nuclei placed randomly in the reactor vessel                |
| **Neutrons**      | Projectiles that trigger fission on contact with atoms            |
| **Fission**       | Probabilistic: cross-section depends on neutron energy & temperature |
| **Control Rods**  | 5 vertical rods that absorb neutrons when inserted                |
| **Neutron Energy**| Fast (~2 MeV) from fission, thermalizes via moderator over time   |
| **Temperature**   | Rises with fission; Doppler broadening reduces reactivity (neg. coeff) |
| **Meltdown**      | Game-over state when reactor temperature goes critical             |
| **Bomb Sim**      | Implosion-type weapon: compression → supercritical chain reaction  |

### Simulation Loop

1. Neutrons move at speed scaled by √(energy) — fast neutrons zoom, thermal crawl
2. Neutron energy decays exponentially (moderator simulation, rate = 10/s)
3. Collision checks: interaction probability depends on neutron energy (σ_total)
4. Interaction outcomes: fission (~84% thermal), elastic scatter, or radiative capture
5. Doppler broadening: higher temperature reduces effective fission cross-section
6. Delayed neutrons (β_eff ≈ 0.0065): ~0.65% of neutrons spawn after 0.2–12s delay
7. Temperature rises from fission; exponential cooling (Newton's law)
8. Meltdown triggers if temperature exceeds the critical threshold

### Rendering Layers (draw order)

1. Reactor background + wall border
2. Control rods
3. Neutron trails
4. Fission flashes
5. Fission fragments
6. Atoms (with glow/pulse)
7. Neutrons (with speed-based coloring)
8. Particle systems (glow + sparks)
9. Sidebar with stats and controls
10. Pause/meltdown overlays

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

- All game state is stored in module-level local tables (`atoms`, `neutrons`,
  `fragments`, `flashes`, `trails`)
- Constants and tuning values are grouped at the top of `main.lua`
- Colors are stored as RGBA tables prefixed with `COLOR_`
- Animations and smooth transitions use the `flux` tweening library
- No external assets — all visuals are procedurally generated (circles,
  rectangles, and canvas-based particle images)

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
  with an `alive` flag, spawned in a function, updated in `love.update`,
  drawn in `love.draw`, and cleaned up with a reverse-iteration removal pass.
- The sidebar is drawn procedurally with hardcoded Y offsets — budget ~20px per
  new stat line. Mode tabs at the top switch between reactor and bomb sidebar content.
