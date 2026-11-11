#!/bin/bash
# Собрать и запустить GUI.
set -euo pipefail
cd "$(dirname "$0")"
./build-app.sh
open "build/DualShock 4 Audio.app"
