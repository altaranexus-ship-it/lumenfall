#!/usr/bin/env bash
# LUMENFALL build & release matrix — stopgap local runner (AGE-46).
# Implements Studio Pipeline Standard v1.0 §2.2/§2.3 for the Godot leg.
# Unity/Unreal/Roblox legs report SKIP until their toolchains land
# (AGE-10 CI runners + engine specialist scaffolds). Same script runs
# on CI runners unchanged: set GODOT_BIN / CI_COMMIT_REF_NAME / CI_PIPELINE_IID.
#
# Verdicts per leg: PASS | FAIL | SKIP.  Any FAIL => exit 1 (release blocked).
# Artifact naming (LOCKED — see BUILD_MATRIX.md):
#   builds/lumenfall_${CI_COMMIT_REF_NAME:-local}_${CI_PIPELINE_IID:-<utcstamp>}/
#
# Environment overrides:
#   GODOT_BIN              engine binary (must pair with installed export templates)
#   LUMENFALL_BUILD_ROOT   output root (default: <repo>/builds)
#   CI_COMMIT_REF_NAME     branch or tag (default: local)
#   CI_PIPELINE_IID        build number (default: UTC stamp)
#   WEB_BUDGET_MB          Q-16 payload budget (default: 60)
set -uo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
GODOT="${GODOT_BIN:-$HOME/tools/godot-4.5.1/Godot_v4.5.1-stable_macos.universal/Godot_v4.5.1-stable_macos.universal}"
REF_NAME="${CI_COMMIT_REF_NAME:-local}"
BUILDNUM="${CI_PIPELINE_IID:-$(date -u +%Y%m%d.%H%M%S)}"
BUILD_ROOT="${LUMENFALL_BUILD_ROOT:-$PROJ/builds}"
OUT="$BUILD_ROOT/lumenfall_${REF_NAME}_${BUILDNUM}"
LOGS="$OUT/logs"
WEB_BUDGET_MB="${WEB_BUDGET_MB:-60}"   # Q-16: web payload <= 60 MB

VERDICTS=()
overall=0

say() { printf '%s\n' "$*"; }

verdict() { # verdict <leg> <PASS|FAIL|SKIP>
  VERDICTS+=("$1=$2")
  if [ "$2" = "FAIL" ]; then overall=1; fi
  return 0
}

run_logged() { # run_logged <timeout_s> <logfile> <cmd...>  -> exit code of cmd
  local t="$1" log="$2"
  shift 2
  perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed\n"' "$t" "$@" >"$log" 2>&1
}

has_err() { grep -Eq '^(ERROR|SCRIPT ERROR)' "$1"; }

gate_fail() { # gate_fail <leg> <msg>
  say "  FAIL: $2"
  verdict "$1" FAIL
}

# ---------------------------------------------------------------- godot preflight
godot_preflight() {
  say "== [godot] preflight: import + smoke =="
  if [ ! -x "$GODOT" ]; then
    say "  godot binary missing or not executable: $GODOT"
    verdict godot_web SKIP; verdict godot_macos SKIP
    return 1
  fi
  say "  engine: $("$GODOT" --version 2>/dev/null | tail -1)"

  # 1) headless import (cold runs can take minutes; warm ~20 s)
  if ! run_logged 420 "$LOGS/import.log" "$GODOT" --headless --path "$PROJ" --import; then
    gate_fail godot_web "import timed out or crashed ($LOGS/import.log)"
    verdict godot_macos FAIL
    return 1
  fi
  if has_err "$LOGS/import.log"; then
    gate_fail godot_web "import log has errors:"
    grep -E '^(ERROR|SCRIPT ERROR)' "$LOGS/import.log" | head -5 | while IFS= read -r l; do say "    $l"; done
    verdict godot_macos FAIL
    return 1
  fi
  say "  import: clean"

  # Q-17: stamp commit + build id into build/build_info.json (surfaced in-game by debug overlay)
  bash "$PROJ/scripts_tool/stamp_build.sh" "$PROJ" >"$LOGS/stamp.log" 2>&1 || true

  # 2) smoke gate — content, not exit codes: require the PASS marker line
  if ! run_logged 240 "$LOGS/smoke.log" "$GODOT" --headless --path "$PROJ" "res://tests/smoke_test.tscn"; then
    gate_fail godot_web "smoke scene exited nonzero / timed out ($LOGS/smoke.log)"
    verdict godot_macos FAIL
    return 1
  fi
  if ! grep -q '^SMOKE_RESULT=PASS' "$LOGS/smoke.log"; then
    gate_fail godot_web "smoke gate: no SMOKE_RESULT=PASS marker"
    grep '^SMOKE_RESULT' "$LOGS/smoke.log" | head -3 | while IFS= read -r l; do say "    $l"; done
    verdict godot_macos FAIL
    return 1
  fi
  say "  smoke: $(grep '^SMOKE_RESULT' "$LOGS/smoke.log" | tail -1)"
  return 0
}

# ---------------------------------------------------------------- godot web leg
leg_godot_web() {
  say "== [godot] leg: Web export (release) =="
  mkdir -p "$OUT/web"
  if ! run_logged 300 "$LOGS/export_web.log" "$GODOT" --headless --path "$PROJ" --export-release "Web" "$OUT/web/index.html"; then
    gate_fail godot_web "export-release Web failed ($LOGS/export_web.log)"; return
  fi
  if [ ! -f "$OUT/web/index.html" ] || [ ! -f "$OUT/web/index.pck" ]; then
    gate_fail godot_web "web artifacts missing (index.html / index.pck)"; return
  fi
  if has_err "$LOGS/export_web.log"; then
    gate_fail godot_web "export log has errors:"
    grep -E '^(ERROR|SCRIPT ERROR)' "$LOGS/export_web.log" | head -5 | while IFS= read -r l; do say "    $l"; done
    return
  fi
  kb="$(du -sk "$OUT/web" | cut -f1)"
  mb=$(( kb / 1024 ))
  if [ "$kb" -gt $(( WEB_BUDGET_MB * 1024 )) ]; then
    gate_fail godot_web "web payload ${mb} MB exceeds ${WEB_BUDGET_MB} MB (Q-16)"; return
  fi
  say "  web: payload ${mb} MB <= ${WEB_BUDGET_MB} MB (Q-16); files: $(ls "$OUT/web" | tr '\n' ' ')"
  verdict godot_web PASS
}

# ---------------------------------------------------------------- godot macos leg
leg_godot_macos() {
  say "== [godot] leg: macOS export (release) =="
  mkdir -p "$OUT/macos"
  if ! run_logged 300 "$LOGS/export_macos.log" "$GODOT" --headless --path "$PROJ" --export-release "macOS" "$OUT/macos/LUMENFALL.zip"; then
    gate_fail godot_macos "export-release macOS failed ($LOGS/export_macos.log)"; return
  fi
  if [ ! -f "$OUT/macos/LUMENFALL.zip" ]; then
    gate_fail godot_macos "macOS artifact missing (LUMENFALL.zip)"; return
  fi
  # NOTE: no `grep -q` here — under `set -o pipefail` grep -q early-exits after the
  # first match, unzip dies with SIGPIPE (141), and the pipeline reports failure on a
  # perfectly valid zip. `grep -c >/dev/null` consumes all input, no SIGPIPE.
  if [ "$(unzip -l "$OUT/macos/LUMENFALL.zip" 2>/dev/null | grep -c '\.app/Contents/MacOS/')" -eq 0 ]; then
    gate_fail godot_macos "zip does not contain LUMENFALL.app bundle"; return
  fi
  if has_err "$LOGS/export_macos.log"; then
    gate_fail godot_macos "export log has errors:"
    grep -E '^(ERROR|SCRIPT ERROR)' "$LOGS/export_macos.log" | head -5 | while IFS= read -r l; do say "    $l"; done
    return
  fi
  say "  macos: $(du -h "$OUT/macos/LUMENFALL.zip" | cut -f1) zip contains LUMENFALL.app"
  verdict godot_macos PASS
}

# ------------------------------------------------------- other-engine legs (§2.3)
leg_unity() {
  say "== [unity] leg =="
  if [ -d "/Applications/Unity/Hub/Editor" ] || command -v Unity >/dev/null 2>&1; then
    say "  SKIP: Unity present but batch build method not yet provided (owner: Unity Architect)"
  else
    say "  SKIP: toolchain absent (unblock: AGE-10 CI runners / Unity Architect)"
  fi
  verdict unity SKIP
}

leg_unreal() {
  say "== [unreal] leg =="
  uat="/Users/Shared/Epic Games/UE_5.4/Engine/Build/BatchFiles/RunUAT.sh"
  if [ -f "$uat" ]; then
    say "  SKIP: RunUAT BuildCookRun scaffold not yet provided (owner: Unreal Systems Engineer)"
  else
    say "  SKIP: toolchain absent (unblock: AGE-10 CI runners / Unreal Systems Engineer)"
  fi
  verdict unreal SKIP
}

leg_roblox() {
  say "== [roblox] leg =="
  if command -v rojo >/dev/null 2>&1 && command -v lune >/dev/null 2>&1; then
    say "  SKIP: rojo+lune present but place scaffold not yet provided (owner: Roblox Systems Scripter)"
  else
    say "  SKIP: toolchain absent (unblock: AGE-10 CI runners / Roblox Systems Scripter)"
  fi
  verdict roblox SKIP
}

# ---------------------------------------------------------------- summary
summary() {
  say ""
  say "== BUILD MATRIX VERDICTS (stamp: lumenfall_${REF_NAME}_${BUILDNUM}) =="
  local v
  for v in "${VERDICTS[@]}"; do say "  $v"; done
  if [ "$overall" -eq 0 ]; then
    say "BUILD_MATRIX_RESULT=OK"
    say "artifacts: $OUT"
  else
    say "BUILD_MATRIX_RESULT=FAIL (logs: $LOGS)"
  fi
  return "$overall"
}

# ---------------------------------------------------------------- main
mkdir -p "$OUT" "$LOGS"
mkdir -p "$BUILD_ROOT"
touch "$BUILD_ROOT/.gdignore"   # keep build output out of Godot's next export scan (pck self-inflation)

say "LUMENFALL build & release matrix — Studio Pipeline Standard v1.0 §2.2/§2.3"
say "project: $PROJ"

if godot_preflight; then
  leg_godot_web
  leg_godot_macos
fi
leg_unity
leg_unreal
leg_roblox
summary
