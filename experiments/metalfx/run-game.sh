#!/bin/zsh
# Launch BO3 the way the launcher does, plus extra injected dylibs:
#   EXTRA="$PWD/build/mfxup.dylib" ./run-game.sh   (absolute paths)
# Steam must be running. Output (including the dylibs' logs) goes to stdout.
R="$HOME/Library/Application Support/Steam/steamapps/common/Call of Duty Black Ops III"
OV="$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/gameoverlayrenderer.dylib"
D="$R/BO3MacFix/BO3MacFix.dylib:$R/BO3MacFix/DualSenseRumble.dylib:$OV"
[ -n "$EXTRA" ] && D="$D:$EXTRA"
cd "$R/CoDBlkOps3.app/Contents/MacOS"
exec env DYLD_INSERT_LIBRARIES="$D" WINEPREFIX="$R/BO3MacFix/pfx" SteamAppId=311210 SteamGameId=311210 SteamOverlayGameId=311210 \
  DS_XBOX_GLYPHS=1 WINEDLLOVERRIDES="mscoree,mshtml=" WINEDEBUG=-all MTL_HUD_ENABLED=1 \
  "$R/CoDBlkOps3.app/Contents/MacOS/CoDBlkOps3_Exe"
