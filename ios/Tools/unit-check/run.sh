#!/usr/bin/env bash
# Gezielte Prüfungen der reinen Swift-Regeln ohne iOS-SDK: Bildkoordinaten (Core Image ↔ App), sichtbarer Ausschnitt,
# Korrektur ohne Doppelsichtung, Artenschutz der Positionen. Braucht nur swiftc (Xcode-Toolchain auf dem Mac oder Swift für Linux).
# Die Prüfungen mit echten Frameworks (Core Image, ImageIO, SwiftData) stehen in ios/SafariSpotterTests (xcodebuild test).
# Aufruf: ios/Tools/unit-check/run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd); SRC=$ROOT/ios/SafariSpotter
WORK=${TMPDIR:-/tmp}/spotter-unit-check; rm -rf "$WORK"; mkdir -p "$WORK/src"
cp "$HERE/Stubs.swift" "$HERE/main.swift" "$SRC/Core/Detection/ImageGeometry.swift" "$SRC/Core/Privacy/LocationProtection.swift" "$WORK/src/"
# Katalog wie im Logik-Abgleich: Bundle.main durch das Resources-Verzeichnis (Umgebungsvariable RES) ersetzen
sed -e 's#Bundle.main.url(forResource: name, withExtension: "json")#Optional(URL(fileURLWithPath: ProcessInfo.processInfo.environment["RES"]! + "/" + name + ".json"))#' \
    -e 's#Bundle.main.url(forResource: "species-info", withExtension: "json")#Optional(URL(fileURLWithPath: ProcessInfo.processInfo.environment["RES"]! + "/species-info.json"))#' \
    -e '/^import CoreLocation/d' "$SRC/Core/SpeciesCatalog.swift" > "$WORK/src/SpeciesCatalog.swift"
# Position (Vergröberung auf das 10-km-Raster) aus Models.swift
{ echo 'import Foundation'; sed -n '/^\/\/\/ Position einer Sichtung/,$p' "$SRC/Core/Data/Models.swift"; } > "$WORK/src/Position.swift"
swiftc -O -o "$WORK/check" "$WORK"/src/*.swift
RES="$SRC/Resources" "$WORK/check"
