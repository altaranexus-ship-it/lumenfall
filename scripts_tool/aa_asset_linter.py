#!/usr/bin/env python3
"""
aa_asset_linter.py — Agency Agents asset linter v1 (dual-mode entry point).

Blender-attached mode (walks .blend files, needs Blender on PATH):
    blender --background --python scripts_tool/aa_asset_linter.py -- <file-or-dir> ...
        [--snapshot out.json] [--json]
    (--path <dir> / --path=<dir> are accepted as aliases for positional paths)

Headless CI mode (no Blender; validates committed snapshots):
    python3 scripts_tool/aa_asset_linter.py <snapshot.json> ... [--json]

Exit codes: 0 clean or warnings only · 1 errors found · 2 usage error.
Validate-only: this tool never fixes anything.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
# rule/collector modules live in the aa_asset_linter/ package dir
PKG = os.path.join(HERE, "aa_asset_linter")
if os.path.isdir(PKG) and PKG not in sys.path:
    sys.path.insert(0, PKG)

import aa_linter_rules as rules  # noqa: E402

USAGE = ("usage: aa_asset_linter.py <snapshot.json ...> [--json]   |   "
         "blender --background --python aa_asset_linter.py -- <file-or-dir> ... "
         "[--path <dir>] [--snapshot out.json] [--json]")


def _argv_after_dashdash():
    """User args for Blender-attached runs live after '--'; everything before
    it is Blender's own CLI (blender --background --python thisfile)."""
    argv = sys.argv
    if "--" in argv:
        return argv[argv.index("--") + 1:]
    # direct `python3 aa_asset_linter.py ...` (no Blender wrapper)
    return argv[1:]


def _normalize_args(raw):
    """Fold --path X / --path=X aliases into positional paths; split flags."""
    paths, flags, i = [], [], 0
    while i < len(raw):
        a = raw[i]
        if a == "--path":
            if i + 1 >= len(raw):
                print("--path requires a value", file=sys.stderr)
                return None, None
            paths.append(raw[i + 1])
            i += 2
        elif a.startswith("--path="):
            paths.append(a[len("--path="):])
            i += 1
        elif a.startswith("-") and a != "-":
            flags.append(a)
            i += 1
        else:
            paths.append(a)
            i += 1
    return paths, flags


def _print_findings(findings):
    last_file = None
    for f in findings:
        if f.file != last_file:
            print("-- %s" % (f.file or "(no source)"))
            last_file = f.file
        print(f.line())


def _emit(findings, errors, warns, as_json):
    if as_json:
        print(json.dumps({
            "errors": errors,
            "warnings": warns,
            "findings": [
                {"rule": f.rule, "severity": f.severity, "message": f.message,
                 "object": f.obj, "file": f.file} for f in findings
            ],
        }, indent=2))
    else:
        _print_findings(findings)
        print("aa_asset_linter: %d error(s), %d warning(s)" % (errors, warns))


def run_snapshots(paths, as_json=False):
    snaps = []
    usage_error = False
    for p in paths:
        try:
            with open(p, "r", encoding="utf-8") as fh:
                snap = json.load(fh)
        except (OSError, ValueError) as exc:
            print("cannot read snapshot %s: %s" % (p, exc), file=sys.stderr)
            usage_error = True
            continue
        snap.setdefault("source", p)
        snaps.append(snap)
    if usage_error:
        return 2
    findings = rules.run_rules_many(snaps)
    errors, warns = rules.summarize(findings)
    _emit(findings, errors, warns, as_json)
    return 1 if errors else 0


def main():
    raw = _argv_after_dashdash()
    if not raw:
        print(USAGE, file=sys.stderr)
        return 2

    paths, flags = _normalize_args(raw)
    if paths is None:
        print(USAGE, file=sys.stderr)
        return 2
    as_json = "--json" in flags

    try:
        import bpy  # noqa: F401
        in_blender = True
    except ImportError:
        in_blender = False

    if in_blender:
        from aa_linter_collector import main as collector_main
        return collector_main(paths, flags)

    if not paths:
        print(USAGE, file=sys.stderr)
        return 2
    return run_snapshots(paths, as_json=as_json)


if __name__ == "__main__":
    sys.exit(main())
