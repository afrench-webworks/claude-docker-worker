#!/bin/bash
# run.sh — Assemble features, build the Docker image, and start the container.
# Usage: bash run.sh
set -euo pipefail

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Assembling features ==="
bash "$PROJ_ROOT/build/assemble.sh"

echo ""
echo "=== Building Docker image ==="
docker compose build

echo ""
echo "=== Starting container ==="
docker compose up -d

echo ""
echo "Container is running. SSH in with: ssh claude-docker-worker"
