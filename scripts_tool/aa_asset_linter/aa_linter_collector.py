"""
aa_linter_collector.py — Blender-attached collector for the Agency Agents asset linter.

Runs only inside Blender (imports bpy). Opens .blend files, builds snapshot
dicts (schema documented in aa_linter_rules docstring), runs the pure-Python
rule engine, and can write snapshots for CI replay.

Reached via scripts_tool/aa_asset_linter.py when bpy is importable.
"""

import json
import os
import sys

import bpy

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import aa_linter_rules as rules  # noqa: E402


def _rotation_of(obj):
    """Euler-equivalent XYZ radians regardless of the object's rotation mode.

    Rules engine checks identity against euler values; a QUATERNION or
    AXIS_ANGLE object would otherwise dodge L-11/L-16 entirely.
    """
    mode = obj.rotation_mode
    if mode == "QUATERNION":
        return obj.rotation_quaternion.to_euler()
    if mode == "AXIS_ANGLE":
        aa = obj.rotation_axis_angle
        from mathutils import Quaternion
        return Quaternion((aa[1], aa[2], aa[3]), aa[0]).to_euler()
    return obj.rotation_euler


def _tri_count(mesh):
    """Triangle count from polygon loop totals (no tessface allocation)."""
    total = 0
    for poly in mesh.polygons:
        total += poly.loop_total - 2
    return total


def _material_snapshot(mat):
    """One material -> dict with image texture sizes (loaded images only)."""
    out = {"name": mat.name, "textures": []}
    if mat.use_nodes and mat.node_tree:
        for node in mat.node_tree.nodes:
            if node.type != "TEX_IMAGE":
                continue
            img = node.image
            if img is None:
                continue
            w = int(img.size[0])
            h = int(img.size[1])
            if w <= 0 or h <= 0:
                # Size 0 = never rasterized. Classify why so the rule engine can
                # warn (packed/unloaded) or error (file missing on disk).
                tex = {"name": img.name, "width": 0, "height": 0}
                if img.packed_file is not None:
                    tex["packed"] = True
                else:
                    fp = bpy.path.abspath(img.filepath) if img.filepath else ""
                    if fp and os.path.isfile(fp):
                        tex["on_disk"] = True
                    else:
                        tex["unresolved"] = True
                out["textures"].append(tex)
                continue
            out["textures"].append({"name": img.name, "width": w, "height": h})
    return out


def _depth_of(obj):
    """Hierarchy depth via parent chain (0 = no parent)."""
    depth = 0
    seen = set()
    cur = obj
    while cur.parent is not None and cur.name not in seen:
        seen.add(cur.name)
        cur = cur.parent
        depth += 1
    return depth


def _collections_of(obj):
    """All collection names containing this object (user + linked)."""
    return [c.name for c in obj.users_collection]


def _mesh_shape_props(mesh):
    """(has_uv_layer, mean edge length in meters) — None-safe."""
    uv = bool(mesh.uv_layers)
    lens = []
    try:
        for e in mesh.edges:
            lens.append(e.calc_length())
            if len(lens) >= 4096:
                break
    except Exception:  # noqa: BLE001
        pass
    if not lens:
        return uv, None
    return uv, sum(lens) / len(lens)


def collect_snapshot():
    """Snapshot the current scene into the rules-engine schema."""
    objects = []
    for ob in bpy.data.objects:
        entry = {
            "name": ob.name,
            "type": ob.type,
            "collection": _collections_of(ob),  # list[str]
            "parent": ob.parent.name if ob.parent is not None else None,
            "depth": _depth_of(ob),
            "location": [round(v, 6) for v in ob.location],
            "rotation": [round(v, 6) for v in _rotation_of(ob)],
            "rotation_mode": ob.rotation_mode,
            "scale": [round(v, 6) for v in ob.scale],
        }
        if ob.type == "MESH" and ob.data is not None:
            me = ob.data
            entry["data_name"] = me.name
            entry["users"] = me.users
            entry["tris"] = _tri_count(me)
            entry["verts"] = len(me.vertices)
            # Blender mesh data is always index-referenced; flag kept so future
            # collectors (other DCCs) feed the same L-40 rule.
            entry["indexed"] = True
            has_uv, mean_edge = _mesh_shape_props(me)
            entry["has_uv"] = has_uv
            entry["mean_edge_m"] = round(mean_edge, 6) if mean_edge else None
            entry["materials"] = [_material_snapshot(m) for m in me.materials if m is not None]
        objects.append(entry)

    return {
        "source": bpy.data.filepath or "(unsaved)",
        "collections": [c.name for c in bpy.data.collections],
        "objects": objects,
    }


def _expand_paths(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for name in sorted(os.listdir(p)):
                if name.endswith(".blend") and not name.startswith("."):
                    files.append(os.path.join(p, name))
        elif os.path.isfile(p):
            files.append(p)
        else:
            print("no such path: %s" % p, file=sys.stderr)
            return None
    return files


def _flag_value(flags, flag):
    if flag in flags:
        idx = flags.index(flag)
        if idx + 1 < len(flags):
            return flags[idx + 1]
    return None


def main(argv, flags=None):
    flags = list(flags or [])
    if not paths_or_usage_error(argv):
        print("usage: blender --background --python scripts_tool/aa_asset_linter.py -- "
              "<file-or-dir> ... [--greybox] [--snapshot out.json] [--json]", file=sys.stderr)
        return 2

    files = _expand_paths(argv)
    if files is None:
        return 2
    if not files:
        print("[L-99] ERROR: no .blend files found in the given path(s); "
              "an empty run must not read as a clean pass", file=sys.stderr)
        return 2

    greybox = "--greybox" in flags
    all_findings = []
    snapshots = []
    for fp in files:
        try:
            bpy.ops.wm.open_mainfile(filepath=fp)
        except Exception as exc:  # noqa: BLE001
            print("[L-99] ERROR: cannot open %s: %s" % (fp, exc))
            all_findings.append(rules.Finding("L-99", rules.SEV_ERROR, "cannot open file", file=fp))
            continue
        snap = collect_snapshot()
        if greybox:
            # spec §9: blockout/greybox assets are exempt from UV (L-15)
            # and material (L-30..L-33) families
            snap["greybox"] = True
        snap["source"] = fp
        snapshots.append(snap)
        all_findings = all_findings + rules.run_rules(snap)

    as_json = "--json" in flags
    if as_json:
        errors, warns = rules.summarize(all_findings)
        print(json.dumps({
            "errors": errors,
            "warnings": warns,
            "findings": [
                {"rule": f.rule, "severity": f.severity, "message": f.message,
                 "object": f.obj, "file": f.file} for f in all_findings
            ],
        }, indent=2))
    else:
        last_file = None
        for f in all_findings:
            if f.file != last_file:
                print("-- %s" % (f.file or "(no source)"))
                last_file = f.file
            print(f.line())
        errors, warns = rules.summarize(all_findings)
        print("aa_asset_linter: %d error(s), %d warning(s)" % (errors, warns))

    snap_out = _flag_value(flags, "--snapshot")
    if snap_out and snapshots:
        payload = snapshots[0] if len(snapshots) == 1 else snapshots
        with open(snap_out, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2)
        print("snapshot written: %s" % snap_out)

    return 1 if errors else 0


def paths_or_usage_error(argv):
    return bool(argv)
