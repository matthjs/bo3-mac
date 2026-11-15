#!/bin/bash
set -e
cd "$(dirname "$0")"

command -v xcodegen >/dev/null 2>&1 || { echo "Install xcodegen: brew install xcodegen"; exit 1; }

# Debug builds sign with the maintainer's team. Anyone else lacks that
# certificate and the build fails outright, so sign ad-hoc instead, which is
# enough to run locally.
SIGN_ARGS=()
if ! security find-identity -v -p codesigning | grep -q "(J497DX6ZF8)"; then
  echo "==> Maintainer certificate not found, signing ad-hoc"
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

xcodegen generate --quiet
mkdir -p build
LOG="build/xcodebuild.log"
# Check xcodebuild's own status: a stale app from an earlier build would
# otherwise pass for a fresh one.
if xcodebuild -project BO3Launcher.xcodeproj \
  -scheme BO3Launcher \
  -configuration Debug \
  -derivedDataPath build \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  build > "$LOG" 2>&1; then
  echo "✅ Build succeeded"
  open "build/Build/Products/Debug/BO3 Launcher.app"
else
  grep -E "error:" "$LOG" | sort -u || tail -20 "$LOG"
  echo "❌ Build failed (full log: $LOG)"
  exit 1
fi
