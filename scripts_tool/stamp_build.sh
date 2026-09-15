#!/usr/bin/env bash
# Stamp build/build_info.json with the current git commit + timestamp (Q-17).
# Usage: scripts_tool/stamp_build.sh [project_dir]
set -euo pipefail
DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$DIR"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
DIRTY="false"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then DIRTY="true"; fi
BUILD_ID="$(date -u +%Y%m%d.%H%M%S)"
mkdir -p build
cat > build/build_info.json <<EOF
{
  "build_id": "${BUILD_ID}",
  "commit": "${COMMIT}",
  "commit_short": "${SHORT}",
  "dirty": ${DIRTY},
  "engine": "4.5-stable"
}
EOF
echo "stamped: ${BUILD_ID}+${SHORT} (dirty=${DIRTY})"
