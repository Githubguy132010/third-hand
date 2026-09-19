#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
bash Scripts/build.sh --install
printf '\nReady. Open the updated app with: open "Third Hand.app"\n'
