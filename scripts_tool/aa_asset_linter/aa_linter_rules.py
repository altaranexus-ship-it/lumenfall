"""
aa_linter_rules.py — pure-Python rule engine for the Agency Agents asset linter v1.

No bpy imports. Consumes "scene snapshots" (plain dicts) produced by
aa_linter_collector.py (Blender-attached) or by CI fixtures. Runs identically
in Blender-attached and headless-CI modes.

Snapshot schema (v1)
====================
{
  "source": "/path/to/file.blend",
  "collections": ["ASM_env_bridge_a"],
  "objects": [
    {
      "name": "env_arch_bridge_a_LOD0",
      "type": "MESH" | "EMPTY" | "ARMATURE",
      "collection": "ASM_env_bridge_a",
      "parent": "ROOT_env_bridge_a" | null,
      "depth": 1,
      "location": [x, y, z],
      "rotation": [rx, ry, rz],
      "scale": [sx, sy, sz],
      "users": 1,
      "tris": 1200,
      "verts": 340,
      "indexed": true,
      "has_uv": true,
      "mean_edge_m": 0.42,
      "materials": [
        {"name": "bridge_wood_m",
         "textures": [{"name": "bridge_wood_basecolor", "width": 2048, "height": 2048}]}
      ]
    }
  ]
}

Rule families (authoritative; mirrors spec §8.1)
================================================
L-01..L-04  naming        errors
L-05..L-08  hierarchy     errors (L-07 lights/cameras = warning)
L-10..L-14  transforms    errors (L-15 = UV requirement)
L-15        uv            error (greybox assets exempt: snapshot "greybox": true)
L-16        armature      error (identity armature in export set)
L-20..L-21  data sharing  errors
L-30..L-33  materials     errors/warnings
L-40..L-45  geometry      errors
L-50..L-51  export sanity warnings
L-6x        rig           reserved, not active in v1

Policy reference: docs/art_pipeline/AA-ARTPIPE-1_blender_gltf_export_and_linter_v1.md
"""

from __future__ import annotations

import math
import re

CATEGORIES = ("env", "prop", "char", "fx", "ui")

NAME_RE = re.compile(r"^[a-z0-9]+(_[a-z0-9]+)*$")
LOD_RE = re.compile(r"_LOD([0-9])$")
ROOT_RE = re.compile(r"^ROOT_[a-z0-9_]+$")
COL_RE = re.compile(r"^COL_[A-Za-z0-9_]+$")
COLLISION_HINT_RE = re.compile(r"collision", re.IGNORECASE)

TEX_ROLES = ("basecolor", "normal", "orm")
TILING_TAG_RE = re.compile(r"(tiling|_tex_|_tex$|^tex_)", re.IGNORECASE)
MATERIAL_SUFFIX = "_m"

LOC_TOL = 1e-3              # 1 mm
ROT_TOL = math.radians(0.01)
SCALE_TOL = 1e-3            # 0.1 %
SCALE_HUGE = 10.0

TRI_BUDGET_HERO = 30_000
TRI_BUDGET_ENV = 15_000
LOD_MIN_TRIS = 500
LOD_RATIO = 0.60
DEPTH_MAX = 4

TEX_CAP_HERO = 2048
TEX_CAP_ENV = 1024
TEX_HARD_FAIL = 4096
TEX_NONPOT_FAIL_ABOVE = 256

ROLE_KEYWORDS = {
    "basecolor": ("basecolor", "base_color", "albedo", "diffuse"),
    "normal": ("normal", "nrm"),
    "orm": ("orm",),
}

DEFAULT_NAMES = ("Mesh", "Mesh.001", "Material", "Material.001")

SEV_ERROR = "ERROR"
SEV_WARN = "WARNING"


class Finding:
    __slots__ = ("rule", "severity", "message", "obj", "file")

    def __init__(self, rule, severity, message, obj="", file=""):
        self.rule = rule
        self.severity = severity
        self.message = message
        self.obj = obj
        self.file = file

    def line(self):
        loc = self.obj or "-"
        return "[%s] %s: %s (%s)" % (self.rule, self.severity, self.message, loc)


def _cat_of(name):
    parts = name.split("_")
    if parts and parts[0] in CATEGORIES:
        return parts[0]
    return None


def _is_helper(name):
    return name.startswith("ROOT_") or name.startswith("COL_")


def _lod_of(name):
    m = LOD_RE.search(name)
    return int(m.group(1)) if m else None


def _base_name(name):
    return LOD_RE.sub("", name)


def _is_pot(n):
    return n > 0 and (n & (n - 1)) == 0


def _mat_is_tiling(mat):
    return bool(TILING_TAG_RE.search(mat.get("name", "")))


def _role_of(tex_name):
    n = tex_name.lower()
    for role, keywords in ROLE_KEYWORDS.items():
        for kw in keywords:
            if kw in n:
                return role
    return None


def _vec_close(vec, target, tol):
    return all(abs(a - b) <= tol for a, b in zip(vec, target))


# --------------------------------------------------------------------------
# rule families
# --------------------------------------------------------------------------

def _rules_naming(objs):
    out = []
    for o in objs:
        name = o.get("name", "")
        if name.startswith("ROOT_"):
            if not ROOT_RE.match(name):
                out.append(Finding("L-01", SEV_ERROR, "ROOT name must match ROOT_<cat>_<name>", name))
            continue
        if name.startswith("COL_"):
            if not COL_RE.match(name):
                out.append(Finding("L-01", SEV_ERROR, "COL helper name must match COL_<name>", name))
            continue
        # spec §2: <cat>_<name>[_<variant>][_LOD<N>] — the LOD suffix is
        # uppercase, so strip it before the lower_snake_case match.
        base = _base_name(name)
        if not NAME_RE.match(base):
            out.append(Finding("L-01", SEV_ERROR, "name must be lower_snake_case [a-z0-9_]", name))
            continue
        if _cat_of(base) is None:
            out.append(Finding("L-02", SEV_ERROR, "name must start with a category: %s" % "|".join(CATEGORIES), name))
        if _lod_of(name) is None and "lod" in base:
            out.append(Finding("L-04", SEV_ERROR, "LOD marker must be final segment _LOD<N>, N single digit", name))
        lod = _lod_of(name)
        if lod is not None:
            after = name[LOD_RE.search(name).end():]
            if after:
                out.append(Finding("L-03", SEV_ERROR, "LOD suffix must be the final segment", name))
    return out


def _rules_hierarchy(objs, collections):
    out = []
    asm = [c for c in collections if c.startswith("ASM_")]
    names = {o.get("name") for o in objs}

    for c in asm:
        if not re.match(r"^ASM_[a-z0-9_]+$", c):
            out.append(Finding("L-06", SEV_ERROR, "export collection must be ASM_<cat>_<name>", c))

    for o in objs:
        name = o.get("name", "")
        if name.startswith("ROOT_"):
            if o.get("type") != "EMPTY":
                out.append(Finding("L-06", SEV_ERROR, "ROOT_ must be an empty", name))
            continue
        if name.startswith("COL_"):
            if o.get("type") != "MESH":
                out.append(Finding("L-06", SEV_ERROR, "COL_ helper must be a mesh", name))
            continue
        if o.get("type") not in ("MESH", "EMPTY", "ARMATURE"):
            out.append(Finding("L-07", SEV_WARN, "%s inside ASM export set" % o.get("type", "OBJECT"), name))
            continue
        parent = o.get("parent")
        if parent is None:
            out.append(Finding("L-05", SEV_ERROR, "asset object has no parent; must descend from ROOT_*", name))
        elif parent.startswith("COL_"):
            out.append(Finding("L-05", SEV_ERROR, "asset parented to COL helper", name))
        elif not parent.startswith("ROOT_"):
            pname = parent
            ptype = next((p.get("type") for p in objs if p.get("name") == pname), "")
            if ptype and ptype not in ("MESH", "EMPTY", "ARMATURE"):
                out.append(Finding("L-07", SEV_WARN, "parent %s inside export set" % ptype, name))
        if o.get("depth", 0) > DEPTH_MAX:
            out.append(Finding("L-08", SEV_ERROR, "hierarchy depth %d > %d" % (o.get("depth"), DEPTH_MAX), name))

    roots = [n for n in names if n and n.startswith("ROOT_")]
    assets = [o for o in objs if not _is_helper(o.get("name", ""))]
    if assets and not roots:
        out.append(Finding("L-05", SEV_ERROR, "export set has asset objects but no ROOT_ empty"))
    return out


def _rules_transforms(objs):
    out = []
    for o in objs:
        name = o.get("name", "")
        otype = o.get("type", "")
        if otype == "EMPTY" and name.startswith("ROOT_"):
            continue  # roots may sit anywhere in the file
        if otype == "MESH" and name.startswith("COL_"):
            continue  # collision helpers exempt from origin/identity rules
        if otype not in ("MESH", "ARMATURE"):
            continue

        loc = o.get("location") or [0.0, 0.0, 0.0]
        rot = o.get("rotation") or [0.0, 0.0, 0.0]
        scl = o.get("scale") or [1.0, 1.0, 1.0]

        if not _vec_close(loc, (0.0, 0.0, 0.0), LOC_TOL):
            out.append(Finding("L-10", SEV_ERROR, "unapplied location (tol 1mm)", name))
        if otype == "ARMATURE":
            # identity armature: emit L-16 instead of the generic L-10/11/12
            if not _vec_close(loc, (0.0, 0.0, 0.0), LOC_TOL):
                out.append(Finding("L-16", SEV_ERROR, "armature location not identity (tol 1mm)", name))
            if not _vec_close(rot, (0.0, 0.0, 0.0), ROT_TOL):
                out.append(Finding("L-16", SEV_ERROR, "armature rotation not identity (tol 0.01 deg)", name))
            if not _vec_close(scl, (1.0, 1.0, 1.0), SCALE_TOL):
                out.append(Finding("L-16", SEV_ERROR, "armature scale not identity (tol 0.1%)", name))
            continue
        if not _vec_close(rot, (0.0, 0.0, 0.0), ROT_TOL):
            out.append(Finding("L-11", SEV_ERROR, "unapplied rotation (tol 0.01 deg)", name))
        if any(s < 0 for s in scl):
            out.append(Finding("L-13", SEV_ERROR, "negative (mirrored) scale", name))
        elif not _vec_close(scl, (1.0, 1.0, 1.0), SCALE_TOL):
            out.append(Finding("L-12", SEV_ERROR, "unapplied scale (tol 0.1%)", name))
        if any(abs(s) > SCALE_HUGE for s in scl):
            out.append(Finding("L-14", SEV_ERROR, "scale magnitude > %.0f on some axis" % SCALE_HUGE, name))
    return out


def _rules_uv(objs):
    """L-15: export-set meshes need UVs (greybox assets exempt)."""
    out = []
    for o in objs:
        if o.get("type") != "MESH" or (o.get("name", "") or "").startswith("COL_"):
            continue
        if o.get("has_uv") is False:
            out.append(Finding("L-15", SEV_ERROR, "mesh has no UV layer (greybox exempt via snapshot 'greybox': true)", o.get("name", "")))
    return out


def _rules_sharing(objs):
    out = []
    by_data = {}
    for o in objs:
        if o.get("type") != "MESH":
            continue
        data = o.get("data_name")
        if not data:
            continue
        by_data.setdefault(data, []).append(o.get("name"))
    for data, users in by_data.items():
        if len(users) > 1:
            out.append(Finding("L-21", SEV_ERROR,
                               "mesh data '%s' shared by %d export objects; exporter duplicates geometry per node"
                               % (data, len(users)),
                               ", ".join(users)))
    for o in objs:
        if o.get("type") == "MESH" and o.get("users", 1) > 1:
            out.append(Finding("L-20", SEV_ERROR,
                               "mesh data has %d users (multi-user data in export set)" % o.get("users"),
                               o.get("name")))
    return out


def _rules_materials(objs):
    out = []
    for o in objs:
        name = o.get("name", "")
        if o.get("type") != "MESH" or name.startswith("COL_"):
            continue
        mats = o.get("materials") or []
        if not mats:
            out.append(Finding("L-30", SEV_ERROR, "mesh has no materials", name))
            continue
        for mat in mats:
            mname = mat.get("name", "")
            texs = mat.get("textures") or []
            if not mname.endswith(MATERIAL_SUFFIX):
                out.append(Finding("L-33", SEV_ERROR, "material name must end '%s'" % MATERIAL_SUFFIX, "%s/%s" % (name, mname)))
            tiling = _mat_is_tiling(mat)
            cat = _cat_of(name) or "env"
            cap = TEX_CAP_ENV if cat == "env" else TEX_CAP_HERO
            multi = len(texs) >= 2
            roles = []
            for t in texs:
                tname = t.get("name", "")
                w = t.get("width", 0)
                h = t.get("height", 0)
                mx = max(w, h)
                if mx == 0:
                    # Collector could not rasterize this image: packed/unloaded
                    # sources give no pixel buffer. Unresolved path = the export
                    # would ship a broken texture reference — that is an error.
                    if t.get("unresolved"):
                        out.append(Finding("L-30", SEV_ERROR, "texture file missing on disk: %s" % tname, "%s/%s" % (name, mname)))
                    else:
                        out.append(Finding("L-30", SEV_WARN, "texture not loaded (packed or unloaded): %s" % tname, "%s/%s" % (name, mname)))
                    continue
                if mx >= TEX_HARD_FAIL:
                    out.append(Finding("L-31", SEV_ERROR, "texture %dx%d >= %d hard fail" % (w, h, TEX_HARD_FAIL), "%s/%s" % (name, tname)))
                elif not _is_pot(w) or not _is_pot(h):
                    if not tiling and mx > TEX_NONPOT_FAIL_ABOVE:
                        out.append(Finding("L-31", SEV_ERROR, "non-power-of-two %dx%d on non-tiling material" % (w, h), "%s/%s" % (name, tname)))
                if mx > cap:
                    out.append(Finding("L-32", SEV_ERROR, "texture %dx%d over %s budget %d" % (w, h, cat, cap), "%s/%s" % (name, tname)))
                if multi:
                    role = _role_of(tname)
                    roles.append(role)
            if multi and any(r is None for r in roles):
                out.append(Finding("L-33", SEV_WARN, "multi-texture material has untagged texture roles", "%s/%s" % (name, mname)))
    return out


def _rules_geometry(objs):
    out = []
    lods = {}
    for o in objs:
        name = o.get("name", "")
        if o.get("type") != "MESH":
            continue
        if name.startswith("COL_"):
            if not COL_RE.match(name):
                out.append(Finding("L-44", SEV_ERROR, "collision helper must be named COL_*", name))
            continue
        if COLLISION_HINT_RE.search(name):
            out.append(Finding("L-44", SEV_ERROR, "collision-like object must be named COL_*", name))
        if o.get("indexed") is False:
            out.append(Finding("L-40", SEV_ERROR, "mesh is non-indexed", name))
        if o.get("verts", 0) == 0:
            out.append(Finding("L-45", SEV_ERROR, "mesh has no geometry", name))
        tris = o.get("tris", 0)
        cat = _cat_of(name) or "env"
        lod = _lod_of(name)
        if lod is None:
            budget = TRI_BUDGET_ENV if cat == "env" else TRI_BUDGET_HERO
            if tris > budget:
                out.append(Finding("L-41", SEV_ERROR, "LOD0 %d tris over %s budget %d" % (tris, cat, budget), name))
        base = _base_name(name)
        lods.setdefault(base, {})[lod if lod is not None else 0] = tris
        lods[base]["_cat"] = cat
    for base, per in lods.items():
        cat = per.get("_cat", "env")
        if cat != "env":
            continue
        t0 = per.get(0)
        if t0 is not None and t0 >= LOD_MIN_TRIS:
            if 1 not in per or 2 not in per:
                out.append(Finding("L-42", SEV_ERROR, "env LOD0 >= %d tris requires LOD1 and LOD2" % LOD_MIN_TRIS, base))
            else:
                if per[1] > per[0] * LOD_RATIO:
                    out.append(Finding("L-43", SEV_ERROR, "LOD1 %.0f tris > 60%% of LOD0 %d" % (per[1], per[0]), base))
                if per[2] > per[1] * LOD_RATIO:
                    out.append(Finding("L-43", SEV_ERROR, "LOD2 %.0f tris > 60%% of LOD1 %d" % (per[2], per[1]), base))
    return out


def _rules_export_sanity(objs):
    out = []
    armatures = [o for o in objs if o.get("type") == "ARMATURE"]
    skinned = [o for o in objs if o.get("type") == "MESH" and o.get("parent") in {a.get("name") for a in armatures}]
    for a in armatures:
        if not skinned:
            out.append(Finding("L-50", SEV_WARN, "armature with no skinned mesh in export set", a.get("name")))
    for o in objs:
        if o.get("name") in DEFAULT_NAMES:
            out.append(Finding("L-51", SEV_WARN, "default datablock name", o.get("name")))
    return out


FAMILIES = (
    _rules_naming,
    _rules_hierarchy,
    _rules_transforms,
    _rules_uv,
    _rules_sharing,
    _rules_materials,
    _rules_geometry,
    _rules_export_sanity,
)


def _obj_in_export_set(obj, asm):
    """True if the object lives in any ASM_* collection.

    Collector emits obj["collection"] as a list of collection names
    (users_collection); CI fixtures may use a single string. Both accepted.
    """
    cols = obj.get("collection")
    if isinstance(cols, str):
        cols = [cols]
    if not isinstance(cols, (list, tuple)):
        return False
    return any(c in asm for c in cols)


def run_rules(snapshot):
    """Run all v1 rules against one snapshot dict. Returns list[Finding]."""
    findings = []
    objs = snapshot.get("objects", [])
    collections = [c for c in snapshot.get("collections", []) if isinstance(c, str)]
    asm = set(c for c in collections if c.startswith("ASM_"))
    greybox = bool(snapshot.get("greybox"))
    export_objs = [o for o in objs if _obj_in_export_set(o, asm)]
    if greybox:
        # greybox dispatch: UV (L-15) and material (L-30..L-33) families skipped
        for family in FAMILIES:
            if family is _rules_uv or family is _rules_materials:
                continue
            if family is _rules_hierarchy:
                findings += family(export_objs, collections)
            else:
                findings += family(export_objs)
        for f in findings:
            f.file = snapshot.get("source", f.file)
        return findings

    for family in FAMILIES:
        if family is _rules_hierarchy:
            findings += family(export_objs, collections)
        else:
            findings += family(export_objs)

    for f in findings:
        f.file = snapshot.get("source", f.file)
    return findings


def run_rules_many(snapshots):
    """Run rules over several snapshots. Returns list[Finding]."""
    out = []
    for snap in snapshots:
        out += run_rules(snap)
    return out


def summarize(findings):
    """(errors, warnings) counts."""
    errors = sum(1 for f in findings if f.severity == SEV_ERROR)
    warns = sum(1 for f in findings if f.severity == SEV_WARN)
    return errors, warns
