#!/usr/bin/env bash
# Thin wrapper — canonical packager is package-app.sh (.build/DevType.app, com.devtype.app).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURATION="${1:-release}"
exec "${SCRIPT_DIR}/package-app.sh" "${CONFIGURATION}"
