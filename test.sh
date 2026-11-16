#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"

mkdir -p .build/ModuleCache
executable=.build/RingCoreChecks
xcrun swiftc -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path .build/ModuleCache \
  Sources/Models.swift Sources/GroupIcons.swift \
  Sources/Ring/RingGeometry.swift Sources/Ring/RingLayout.swift \
  Sources/Ring/RingAnimation.swift Sources/Ring/RingHitTester.swift \
  Tests/RingCoreChecks.swift -o "$executable"
"$executable"
