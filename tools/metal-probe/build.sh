#!/bin/zsh
# Builds the frame probe (x86_64, like everything else that loads into the
# game). Ad-hoc signed.
set -e
cd "$(dirname "$0")"
mkdir -p build
FW=(-framework Metal -framework QuartzCore -framework Foundation)
clang -arch x86_64 -dynamiclib -fno-objc-arc -O1 -Wall -Wno-unused-function frameprobe.m "${FW[@]}" -o build/frameprobe.dylib
codesign -s - -f build/frameprobe.dylib
echo "Built build/frameprobe.dylib"
