#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
if [[ ! -d "build/Open Sensei.app" ]]; then
  /bin/zsh scripts/build.sh
fi
open "build/Open Sensei.app"
