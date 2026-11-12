#!/bin/bash
# Reproducible texture review without starting NSApplication or any overlay.
set -euo pipefail
PORTAL_REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PORTAL_TOOLS="$HOME/Library/Caches/Portal/texture-tools"
PORTAL_SHOTS="$HOME/Library/Caches/Portal/src/shots/texture-review"
mkdir -p "$PORTAL_TOOLS/ModuleCache"
export CLANG_MODULE_CACHE_PATH="$PORTAL_TOOLS/ModuleCache"
swiftc -emit-library -emit-module -module-name DropPortalCore \
    "$PORTAL_REPO/Sources/DropPortalCore/PortalEffect.swift" \
    -o "$PORTAL_TOOLS/libDropPortalCore.dylib" \
    -emit-module-path "$PORTAL_TOOLS/DropPortalCore.swiftmodule"
swiftc "$PORTAL_REPO/Sources/DropPortal/PortalLightTexture.swift" \
    "$PORTAL_REPO/.droppykit/tools/render-light.swift" \
    -I "$PORTAL_TOOLS" -L "$PORTAL_TOOLS" -lDropPortalCore \
    -Xlinker -rpath -Xlinker "$PORTAL_TOOLS" -o "$PORTAL_TOOLS/render-light"
"$PORTAL_TOOLS/render-light" "$PORTAL_SHOTS"
