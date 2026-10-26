#!/usr/bin/env bash
# Abgleich der Swift-Logik (Katalog, Entscheidung, Tracker, Zusammenführung, Fahrtstatistik, Vergröberung)
# mit den Originalfunktionen aus app.js. Braucht swiftc (Xcode-Toolchain auf dem Mac oder Swift für Linux) und node.
# Aufruf: ios/Tools/logic-check/run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../../.." && pwd); SRC=$ROOT/ios/SafariSpotter
WORK=${TMPDIR:-/tmp}/spotter-logic-check; rm -rf "$WORK"; mkdir -p "$WORK/src"
cp "$HERE/Stubs.swift" "$HERE/main.swift" "$WORK/src/"
# Katalog: Bundle.main durch das Resources-Verzeichnis (Umgebungsvariable RES) ersetzen
sed -e 's#Bundle.main.url(forResource: name, withExtension: "json")#Optional(URL(fileURLWithPath: ProcessInfo.processInfo.environment["RES"]! + "/" + name + ".json"))#' \
    -e 's#Bundle.main.url(forResource: "species-info", withExtension: "json")#Optional(URL(fileURLWithPath: ProcessInfo.processInfo.environment["RES"]! + "/species-info.json"))#' \
    -e '/^import CoreLocation/d' "$SRC/Core/SpeciesCatalog.swift" > "$WORK/src/SpeciesCatalog.swift"
sed -e '/^import CoreGraphics/d' "$SRC/Core/Detection/Tracker.swift" > "$WORK/src/Tracker.swift"
# VisionPipeline: nur Detection und die statischen Geometriefunktionen
{ sed -n '1p;/^struct Detection/,/^}/p' "$SRC/Core/Detection/VisionPipeline.swift"; echo 'final class VisionPipeline {'
  sed -n '/static func tileGrid/,/^    }$/p;/static func iou/,/^    }$/p;/static func containment/,/^    }$/p;/static func sameAnimal/,/^    }$/p;/static func merge/,/^    }$/p;/static func cropSquare/,/^    }$/p' "$SRC/Core/Detection/VisionPipeline.swift"; echo '}'; } > "$WORK/src/Geometry.swift"
# DriveStats (bis vor DriveRecorder) und Position
{ sed -n '1,/^\/\/\/ GPS, Region/p' "$SRC/Core/Location/DriveRecorder.swift" | sed -e '/^import CoreLocation/d;/^import Combine/d;/^\/\/\/ GPS, Region/d'
  sed -n '/^\/\/\/ Position einer Sichtung/,$p' "$SRC/Core/Data/Models.swift"; } > "$WORK/src/DriveStats.swift"
swiftc -O -o "$WORK/check" "$WORK"/src/*.swift
node "$HERE/mkinput.js" "$WORK/input.json"
node "$HERE/jsref.js" "$WORK/input.json" "$WORK/js-out.json"
RES="$SRC/Resources" "$WORK/check" "$WORK/input.json" "$WORK/swift-out.json"
node -e "
const fs=require('fs'); const a=JSON.parse(fs.readFileSync('$WORK/js-out.json')), b=JSON.parse(fs.readFileSync('$WORK/swift-out.json'));
let diffs=0;
function cmp(p,x,y){ if(typeof x==='number'&&typeof y==='number'){ if(Math.abs(x-y)>1e-6*Math.max(1,Math.abs(x))){diffs++; if(diffs<20) console.log('ABWEICHUNG',p,x,y);} return;} if(x===null||y===null||typeof x!=='object'||typeof y!=='object'){ if(x!==y){diffs++; if(diffs<20) console.log('ABWEICHUNG',p,JSON.stringify(x),JSON.stringify(y));} return;} for(const k of new Set([...Object.keys(x),...Object.keys(y)])) cmp(p+'.'+k,x[k],y[k]); }
for (const k of ['decisions','frames','tiles','square','stats','coarsen']) cmp(k,a[k],b[k]);
console.log('Katalog:', b.classes, 'Klassen,', b.regions, 'Regionen,', b.info, 'Steckbriefe; Kruger-Test:', b.kruger, '; sensibel:', JSON.stringify(b.sensitive));
console.log(diffs===0 ? 'Swift und Web-App rechnen identisch.' : diffs+' Abweichungen'); process.exit(diffs?1:0);"
