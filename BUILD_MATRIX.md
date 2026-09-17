# LUMENFALL Build & Release Matrix (AGE-46)

Implements **Studio Pipeline Standard v1.0 §2.2/§2.3** (AGE-16) for the LUMENFALL vertical slice. This is the sanctioned **stopgap local runner** per the risk plan (AGE-16 Escalation 1): if AGE-10 CI runners are not available by the D3 gate, `build_matrix.sh` runs the same gates locally, and the identical script runs unchanged on CI when runners land.

Run it:

```bash
./build_matrix.sh                 # defaults: GODOT_BIN=~/tools/godot-4.5.1/..., ref=local, stamp=UTC
CI_COMMIT_REF_NAME=main CI_PIPELINE_IID=42 ./build_matrix.sh   # CI-style invocation
```

Verdicts: `godot_web` / `godot_macos` = **PASS|FAIL|SKIP**, `unity` / `unreal` / `roblox` = **SKIP** until toolchains land (see "Engine legs" below). Any FAIL ⇒ exit 1 ⇒ release blocked.

## Artifact naming convention (LOCKED)

```
builds/lumenfall_<ref>_<buildnum>/
├── web/index.html + index.pck + index.wasm + sidecars   (§2.2 Web showcase build)
├── macos/LUMENFALL.zip                                  (§2.2 signed-showcase desktop build, unsigned ad-hoc for now)
└── logs/{import,smoke,export_web,export_macos}.log      (gate evidence, per §2.3 smoke-gate column)
```

- `<ref>` = `CI_COMMIT_REF_NAME` (branch or `vX.Y.Z` tag; `local` when unset).
- `<buildnum>` = `CI_PIPELINE_IID` (monotonic CI number; UTC stamp `YYYYMMDD.HHMMSS` when local).
- Godot-side mapping: build number + commit hash are stamped into `build/build_info.json` by `scripts_tool/stamp_build.sh` and surfaced in-game via the debug overlay (Q-17).
- Nightly/versioned retention per §2.2 (`proj_<branch>_<buildnum>`) maps 1:1 onto this scheme once the AGE-10 artifact store exists.
- `builds/` is `.gdignore`d so output never self-inflates the next export's pck.

## Engine legs (Pipeline Standard §2.3)

| Leg | Command (as wired) | Smoke gate (enforced in script) |
|---|---|---|
| Godot | `godot --headless --path . --import`, then `--export-release "Web" <abs out>/index.html` and `--export-release "macOS" <abs out>/LUMENFALL.zip` | import log `^ERROR`-free; smoke scene prints `SMOKE_RESULT=PASS`; export exit 0 + artifacts exist + export logs `^ERROR`-free; web payload ≤ 60 MB (Q-16); macOS zip contains `.app/Contents/MacOS/` |
| Unity | `Unity -batchmode -executeMethod AABuild.Build -quit` (§2.3) — **SKIP**: no batch build method scaffold in repo yet | exit 0 + 0 compiler errors (to wire) |
| Unreal | `RunUAT BuildCookRun -project=... -build -cook -stage -package` (§2.3) — **SKIP**: no UE project scaffold | exit 0 + cook warnings < threshold (to wire) |
| Roblox | `rojo build` + `lune run upload` via Open Cloud (§2.3) — **SKIP**: no place scaffold | place rebuild + luau-lsp clean (to wire) |

SKIP is distinct from FAIL by design: missing toolchain must not block the Godot release; a red Godot leg must.

## Engine/template pairing (locked for this host)

| Binary | Templates dir | Status |
|---|---|---|
| `~/tools/godot-4.5.1/Godot_v4.5.1-stable_macos.universal` (4.5.1.stable) | `~/Library/Application Support/Godot/export_templates/4.5.1.stable/` | active pairing |
| `/usr/local/bin/godot` (4.7.2.stable) | `4.7.2.stable/` | project features pin `4.5` — do not use |

Rule: the engine binary's exact version must have a matching `export_templates/<version>/` dir; the script refuses to run exports with a missing/mismatched binary (SKIP, exit stays 0).

## CI migration path (AGE-10 unblock)

When VP Eng delivers runners: set `GODOT_BIN`, `CI_COMMIT_REF_NAME`, `CI_PIPELINE_IID`, `LUMENFALL_BUILD_ROOT` (or an artifact-store upload step after the script), and call `./build_matrix.sh` from the pipeline. No script changes required — the env contract is the interface. Godot smoke gate content requirement (`SMOKE_RESULT=PASS` marker) and Q-16 budget travel with it.
