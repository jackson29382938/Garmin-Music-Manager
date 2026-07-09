#!/usr/bin/env bash
#
# Rebuilds the app bundle from scratch into ./dist.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/Scripts/package-app.sh" --clean
