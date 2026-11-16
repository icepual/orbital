#!/bin/zsh
set -euo pipefail
cd -- "${0:A:h}"

build_dir="$PWD/.build"
app="$PWD/环启.app"
stage="$(mktemp -d "${TMPDIR:-/tmp}/orbital.XXXXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
staged_app="$stage/环启.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" \
  "$stage/Orbital.iconset" "$build_dir"

arch="$(uname -m)"
xcrun swiftc -O -whole-module-optimization -target "$arch-apple-macosx14.0" \
  -module-cache-path "$build_dir/ModuleCache" \
  Sources/*.swift -o "$staged_app/Contents/MacOS/Orbital"
cp Info.plist "$staged_app/Contents/Info.plist"
"$staged_app/Contents/MacOS/Orbital" --make-icon "$stage/Orbital.iconset"
iconutil -c icns "$stage/Orbital.iconset" -o "$staged_app/Contents/Resources/Orbital.icns"
codesign --force --sign - "$staged_app"
if [[ -d "$app" ]]; then
  rm -rf -- "$app"
fi
mv -- "$staged_app" "$app"
print -r -- "$app"
