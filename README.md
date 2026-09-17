# LUMENFALL

Atmospheric 3D platform-adventure built in **Godot 4.5**. The world has gone dark. You are the last light-bearer: rekindle cold beacons, carry flame between them across greybox ruins, and push back the dark — one checkpoint at a time.

**Version:** 0.1.0-foundation

**Play in browser:** https://altaranexus-ship-it.github.io/lumenfall/ *(Web export)*

## What's in the foundation slice

- **3C controller** — walk / run / climb / glide (camera-collision aware)
- **Rekindle interaction** — revive cold beacons into living light sources
- **Light-carry** — pick up flame and transport it; kindled objects stay lit
- **Checkpoint save/load** — persistent world state via `SaveManager`
- **Debug overlay** (Q-17) — live telemetry for tuning
- **Headless smoke-test suite** — CI-runnable (`tests/smoke_test.gd`)

## Run it

### In Godot (editor)
1. Install [Godot 4.5](https://godotengine.org/download) (or 4.x compatible)
2. Open `project.godot`
3. Press **F5** (main scene: `scenes/greybox_map.tscn`)

### From source
```bash
git clone https://github.com/altaranexus-ship-it/lumenfall.git
cd lumenfall
godot --path . # or open in editor
```

### Headless smoke test
```bash
godot --headless --path . res://tests/smoke_test.tscn
```

## Controls

| Input | Action |
|-------|--------|
| WASD / arrows | Move |
| Space | Jump / glide (hold) |
| Shift | Run |
| E | Interact (rekindle / pick up light) |
| F3 | Debug overlay |

## Project layout

```
scenes/          core (debug overlay), greybox map, interactions, player, world
scripts/         matching GDScript: core, player, interactions, world
tests/           headless smoke test suite + probe scene
scripts_tool/    build stamping helper
```

## Tech notes

- Godot **4.5** feature target (`config/features=PackedStringArray("4.5")`)
- No external assets required — all visuals are procedural greybox + generated meshes
- Autoloads: `GameConfig`, `SaveManager`, `BuildInfo`, `DebugOverlay`

## License

MIT — see [LICENSE](LICENSE).

---

*Built by [altaranexus-ship-it](https://github.com/altaranexus-ship-it) — an autonomous-agent shipping org.*
