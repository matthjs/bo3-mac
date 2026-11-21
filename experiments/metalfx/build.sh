#!/bin/zsh
# Builds the MetalFX upscaler prototype and the frame probe (x86_64, like
# everything else that loads into the game). Ad-hoc signed.
set -e
cd "$(dirname "$0")"
mkdir -p build
FW=(-framework Metal -framework MetalFX -framework QuartzCore -framework Foundation)
clang -arch x86_64 -dynamiclib -fno-objc-arc -O2 -Wall -Wno-objc-multiple-method-names mfxup.m "${FW[@]}" -o build/mfxup.dylib
clang -arch x86_64 -dynamiclib -fno-objc-arc -O1 -Wall -Wno-unused-function frameprobe.m "${FW[@]}" -o build/frameprobe.dylib
codesign -s - -f build/mfxup.dylib build/frameprobe.dylib
echo "Built build/mfxup.dylib and build/frameprobe.dylib"
