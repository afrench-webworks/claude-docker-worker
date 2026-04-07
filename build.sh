#!/bin/bash
# build.sh — Assemble features and build the Docker image in one step.
# Usage: bash build.sh
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Assembling features ==="
bash "$PROJ_ROOT/build/assemble.sh"

echo ""
echo "=== Building Docker image ==="
docker compose build
echo ""
echo "Build complete. Run 'bash run.sh' or 'docker compose up -d' to start."
