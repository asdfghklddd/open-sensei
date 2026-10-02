#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/helper-tests
clang -O2 -DHELPER_SELF_TEST -framework IOKit -I Sources/SMCCore/include Sources/FanHelper/main.c Sources/SMCCore/SMCCore.c -o .build/helper-tests/unit
.build/helper-tests/unit
clang -O2 -DFAN_HELPER_SIMULATOR -I Sources/SMCCore/include Sources/FanHelper/main.c scripts/tests/FakeSMC.c -o .build/helper-tests/simulator
/usr/bin/python3 scripts/tests/helper-integration.py "$PWD/.build/helper-tests/simulator"

clang -O2 -framework IOKit -I Sources/SMCCore/include scripts/tests/smc-cache.c -o .build/helper-tests/cache
.build/helper-tests/cache

clang -O2 -framework IOKit -I Sources/SMCCore/include scripts/tests/smc-control.c -o .build/helper-tests/control
.build/helper-tests/control
