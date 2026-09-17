# AA-ARTPIPE-1 — Blender glTF Export + Asset Linter v1

**Status:** v1.0 · **Date:** 2026-09-17
**Author:** Blender Add-on Engineer (aeb8663b) · **Review owner:** Technical Artist (2dfdad85)
**Parent issue:** AGE-20 (dispatch AGE-47) · **Engine priority:** Godot 4.5 first (LUMENFALL)
**Upstream:** implements §1 (Art-to-Engine Pipeline) of Studio Pipeline Standard v1.0; on any conflict that document wins.

## 1. Purpose and scope

Authored once in Blender 4.5 LTS, exported as glTF 2.0 binary (.glb), imported per-engine with zero hand-fixes. This spec adds the project-level detail and the automated enforcement layer (linter v1 + export preset) on top of the Studio Standard.

In scope: naming, units/transforms, hierarchy, materials/textures, geometry budgets, export settings, validation, Godot import notes.
Out of scope (design-lock fence): shader/lookdev authoring, lighting, engine rendering features — Technical Artist territory. Rig-depth validation is deferred (§9).

## 2. Naming (checks L-0x)

Pattern: `<cat>_<name>[_<variant>][_LOD<N>]`, lower_snake_case throughout.

| Slot | Rule |
|---|---|
| `cat` | exactly one of `env`, `prop`, `char`, `fx`, `ui` |
| `name` | `[a-z0-9]+(_[a-z0-9]+)*`, no leading/trailing whitespace or separators |
| `variant` | optional `[a-z0-9]+(_[a-z0-9]+)*` |
| `LOD` | optional final segment `_LOD0`..`_LOD9`; LOD numbering ascending with reduction |

Examples: `env_arch_bridge_a_LOD0`, `prop_lamp_street_02`, `char_lamplighter_hero`.

- Exportable assemblies live in collections named `ASM_<cat>_<name>[_<variant>]`; each also has a `ROOT_<cat>_<name>[_<variant>]` empty as asset root (§3).
- Material names end `_m` (e.g. `bridge_wood_m`); textures `<asset>_<role>` with role in `basecolor`, `normal`, `orm` (§5).
- Collision shapes are objects named `COL_*` (§6).
- Godot imports .glb node names verbatim; lower_snake_case is mandated studio-wide so tooling greps and the linter stay deterministic.

## 3. Units, transforms, hierarchy (L-1x, L-2x)

- 1 Blender unit = 1 meter (Metric, `scale_length = 1.0`).
- Every export-set mesh object, at export time:
  - location within 1 mm of origin,
  - rotation within 0.01° of identity,
  - scale within 0.1% of (1, 1, 1).
  Checked separately — no combined "apply all" assumption. Transforms are applied in Blender before export; engines never correct scale at import.
- Negative (mirrored) scale is a hard fail: it produces negative-determinant matrices and flipped normals in glTF.
- Asset root: `ROOT_*` empty with glTF axes (+Y up, −Z forward). Valid parents under a root: meshes/empties, or an armature (at identity) above skinned meshes. Max hierarchy depth below root: 4.
- Skinned: armature object identity; rest pose A or T, feet at z=0.

## 4. Data sharing (L-2x)

Export-set objects must use single-user mesh data. Blender's glTF exporter does not share mesh blocks across nodes: linked duplicates (two objects → one mesh datablock) are exported as duplicated geometry per node, silently multiplying VRAM versus engine-side instancing. Dense dressing ships as separate `prop_*` assets instanced engine-side (Godot MultiMesh), never as Blender linked duplicates inside one export.

## 5. Materials and textures (L-3x)

- Principled BSDF, metallic/roughness workflow, **ORM packed** (Occlusion=R, Roughness=G, Metalness=B).
- Texture sizes: powers of two. Caps: hero 2048, environment 1024, tiling environment materials exempt (material name contains `tiling` or `tex`). 4096+ is a hard fail anywhere; non-POT above 256 on non-tiling materials is an error.
- Texel density targets (Studio Standard §1.1): 10.24 px/cm hero, 5.12 px/cm environment. Density is not machine-checked in v1 (needs UV+camera metadata); budget caps and POT are enforced instead. L-3x reserves the ID for a future density check.
- Texel density: 10.24 px/cm hero, 5.12 px/cm environment; tiling environment materials exempt (same tag rule). Not machine-checked in v1 (needs UV/island metadata); POT + budget caps are enforced, the density rule stays manual in Technical Artist review.

## 6. Geometry (L-4x)

- Meshes must be indexed. Non-indexed mesh data bloats .glb vertex counts and breaks engine-side smooth/flat interpretation. (Blender mesh data is virtually always indexed; the check is a cheap guard against scripted "loose" mesh generation.)
- LODs: env assets with LOD0 ≥ 500 tris must ship LOD0/LOD1/LOD2 with each successive LOD ≤ 60% of the previous tri count. Char LODs deferred to AA-ARTPIPE-2 (needs Technical Artist base rig reference).
- Poly budgets (LOD0): hero prop ≤ 30 000 tris, env asset ≤ 15 000 tris. District aggregates are an engine-side concern, not per-asset.
- Collision: simple shape objects `COL_*`, parents allowed to deviate from transform rules (they are helpers, still must be single-user and named). Never per-poly collision on props (Studio Q-05).
- Empty meshes (no vertices) are a fail.

## 7. Export — `AA_GLB_EXPORT` preset (L-5x)

One sanctioned preset; committed at `scripts_tool/aa_glb_export_presets/io_scene_gltf2/AA_GLB_EXPORT.py` (Blender stores glTF operator presets under `presets/operator/io_scene_gltf2/`). The .py file is authoritative; this table is the human summary.

| Setting | Value | Why |
|---|---|---|
| Format | GLB binary (.glb), +Y up | Studio Standard §1.2 |
| Tangents | on | engine normal mapping without recompute |
| Draco compression | off | engines compress; skinned meshes break under KHR_draco here |
| KHR_texture_transform | allowed | material tiling via UV transform |
| KHR_materials_pbrSpecularGlossiness | disallowed | metal/rough only, ORM mapping |
| Apply modifiers | on | export shape is the scene shape |
| Animation | export if armature present; shape keys if present | chars only |
| Selection | export set = `ASM_*` collection contents, not transient selection | deterministic exports |

L-5x export-sanity checks (warnings): armature with no skinned mesh, default `Mesh`/`Mesh.001` names, root count sanity in export set. Deterministic failures upstream (transforms, naming) stay errors in their own families.

## 8. Linter v1 — `scripts_tool/aa_asset_linter.py`

Validate-only, never auto-fixes (division tool policy: report before anyone fixes; batch tools log what they change). Dual-mode:

- **Blender-attached:** `blender --background --python scripts_tool/aa_asset_linter.py -- <file-or-dir> [--snapshot out.json]` — walks .blend files, collects scene facts, runs rules, optionally writes a snapshot.
- **Headless CI (no DCC):** `python3 scripts_tool/aa_asset_linter.py snapshot1.json [snapshot2.json ...]` — runs the same rule engine over committed snapshots. CI lints without Blender installed; a snapshot failing in CI replays deterministically.

Exit codes: 0 clean/warnings-only, 1 errors, 2 usage. Output: per-file `[L-xx] SEVERITY: message` lines. Warnings never fail CI; errors do.

### 8.1 Check families (v1)

| IDs | Family | Severity | Summary |
|---|---|---|---|
| L-01..L-04 | naming | error | pattern, category, LOD suffix form/order, whitespace |
| L-05..L-08 | hierarchy | error | ASM collection, ROOT present, parent legality, depth ≤ 4 |
| L-10..L-15 | transforms | error | location/rotation/scale tolerance, negative scale, armature identity |
| L-20..L-21 | data sharing | error | single-user mesh in export set |
| L-30..L-33 | materials/textures | error/warn | material present, ORM role tags, POT, category caps, 4096 hard fail, tiling exemption |
| L-40..L-45 | geometry | error | indexed, tri budgets, LOD presence/ratio, collision naming, empty mesh |
| L-50..L-51 | export sanity | warn | dead armature, default names |
| L-6x | rig | — | reserved, not active in v1 (§9) |

Authoritative rule text (IDs, severities, messages): module docstring of `scripts_tool/aa_asset_linter.py`. Rule-engine code carries no `bpy` imports, so it runs identically in both modes.

## 9. Deferrals

- **AA-ARTPIPE-2** (Technical Artist co-owner): rig conformity L-6x (Rigify base rig, mixamo-compatible bone names, feet z=0, A/T-pose) — blocked on base rig reference; texel-density machine check L-34; Godot reimport preset `AA_Import_Godot` (ORM channel material generation); Unity `aa_gltf_to_urp.json` remap; Roblox 1024-cap export variant.
- AGE-22 blockout may rely now on: naming (§2), transforms/hierarchy (§3), geometry budgets (§6), export via `AA_GLB_EXPORT` (§7).

## 10. File map

```
docs/art_pipeline/AA-ARTPIPE-1_blender_gltf_export_and_linter_v1.md   (this spec)
scripts_tool/aa_asset_linter.py            entry point (dual-mode CLI)
scripts_tool/aa_asset_linter/
  aa_linter_rules.py                       pure-Python rule engine (no bpy)
  aa_linter_collector.py                   bpy collector (Blender-attached mode only)
  README.md                                usage + CI wiring
  tests/test_aa_linter_rules.py            pytest for the rule engine (no bpy)
scripts_tool/aa_glb_export_presets/io_scene_gltf2/AA_GLB_EXPORT.py    Blender export preset
```
