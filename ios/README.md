# Safari Spotter als native iOS-App

Dieser Ordner enthält die Vorbereitung, um die Web-App (`index.html`, `app.js`) als echte iOS-App mit denselben Funktionen
und derselben Erkennungslogik weiterzubauen: die beiden Modelle als Core ML, ein SwiftUI-Projekt mit allen Bausteinen und ein
Prüfwerkzeug, das die Swift-Logik gegen die Web-App rechnet.

Stand: Modelle konvertiert und numerisch geprüft, Swift-Code geschrieben und auf Syntax geprüft, die reine Logik (Katalog,
Artentscheidung, Tracker, Zusammenführung, Fahrtstatistik, Artenschutz-Vergröberung) rechnet nachweislich identisch zur
Web-App. **Noch nicht geschehen:** ein Build in Xcode und ein Test auf dem iPhone, weil es hier keinen Mac gibt. Beim ersten
Build sind einzelne Compiler-Korrekturen zu erwarten (siehe "Bekannte Lücken").

## Bauen

Voraussetzungen: Mac mit Xcode 16, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), ein
iPhone mit iOS 17 oder neuer (der Simulator hat keine Kamera).

```
cd ios
xcodegen generate            # erzeugt SafariSpotter.xcodeproj aus project.yml
open SafariSpotter.xcodeproj
```

In Xcode unter *Signing & Capabilities* das eigene Team wählen (oder `DEVELOPMENT_TEAM` in `project.yml` eintragen), das
iPhone anschliessen, Run. Beim ersten Start fragt die App nach Kamera, Standort ("Immer" für die Aufzeichnung bei gesperrtem
Gerät) und Fotos.

Bundle-ID: `ch.solution21.safarispotter` (in `project.yml` anpassbar).

## Was wo liegt

```
ios/
  project.yml                     XcodeGen-Spezifikation (Ziel, Info.plist-Rechte, Hintergrund-Standort)
  Models/
    SafariSpotterSpecies.mlpackage   Artenmodell: Bild 224×224 → 65 Wahrscheinlichkeiten (MobileNetV2 + Kopf 1.2.1, ein Modell)
    SafariSpotterDetector.mlmodel    Tierdetektor: Bild 300×300 → Rahmen + COCO-Klassen, mit NMS-Pipeline (Vision-kompatibel)
    species-labels.json              Klassenreihenfolge, Namen, Gruppen, Artenschutz-Flag
  SafariSpotter/
    App/SafariSpotterApp.swift       Einstieg, SwiftData-Container, AppSettings (entspricht ss.settings)
    Core/SpeciesCatalog.swift        Klassen, Steckbriefe, Regionen, Regionsvorwissen, decideSpecies
    Core/Detection/VisionPipeline    Detektor + Kacheln (Fernerkennung) + Zusammenführen + Artenkopf, optional YOLO-Pfad
    Core/Detection/Tracker.swift     IoU-Tracker mit Glättung, Bestätigung schwacher Kandidaten, Art-EMA 0.6/0.4
    Core/Detection/CameraController  AVFoundation bis 4K, Erkennungsschleife, Sichtungen, Schnappschüsse, Prüfliste
    Core/Data/Models.swift           SwiftData: Sighting, PhotoItem, Correction, Drive; Position mit coarsen()
    Core/Location/DriveRecorder      GPS, Region, Game Drive (Punkte, Statistik, Hintergrund), wie tripStats()
    Core/Export/Exporters.swift      CSV, GPX (Artenschutz-Regeln), JPEG mit EXIF/GPS in die Fotos-Mediathek
    UI/LiveView.swift                Kamerabild, Overlay, Tracken, Game Drive, Zoom
    UI/SightingsView.swift           Liste, Zählung, Karte (MapKit), Galerie, Prüfen
    UI/Sheets.swift                  Artwahl, Korrektur, Steckbrief, Game Drive live, Einstellungen, Bildanalyse
    Resources/                       species-info.json, regions.json, species-labels.json (Kopien aus data/ und Models/)
  Tools/logic-check/                 Abgleich Swift ↔ app.js (siehe unten)
training/coreml/                     Konvertierung TF.js → Core ML (convert.py, tfjs_load.py, check_reference.js)
training/yolo/                       Vorbereitung für den eigenen Ein-Modell-Detektor (Auto-Labels, Training, Export)
```

## Wie die Web-App auf iOS abgebildet ist

| Web-App (app.js) | iOS |
|---|---|
| `startCamera`, RES-Tabelle 720/1080/2160, Linsen, Zoom | `CameraController.configure` mit `AVCaptureSession.Preset`, `builtInTripleCamera` (Fallback Dual/Wide), `videoZoomFactor` |
| `detectLoop` → `detectRegion` (Vollbild 416 + Kacheln 2×2 / 3×3) → `mergeDetections` | `VisionPipeline.detectAll` mit `VNCoreMLRequest` je Ausschnitt (`.scaleFill`), `tileGrid`, `merge` |
| `updateTracks`, `isShown`, `classifyPending`, `runHead`, `decideSpecies` | `Tracker.update`, `Track.isShown`, `candidateForClassification`, `VisionPipeline.classify`, `SpeciesDecision.decide` |
| `applyPrior` (regions.json, Faktor 0,25) | `SpeciesCatalog.applyPrior` |
| `maybeLog`, `logSighting` (4 Treffer, 1,2 s, Zusammenführen 30 s) | `CameraController.maybeLog` / `log` → SwiftData `Sighting` |
| `coarsen` (10-km-Raster für Nashörner), Karte mit 10-km-Kreis, Exporte ohne genaue Zeiten/Positionen | `Position.coarsen`, `MapCircle` in `SightingsView`, `Exporters.csv/gpx` |
| `tripStats` (Stillstand 0,6 m/s, Stopp ab 45 s, Splits, Höhenmeter, Tempo-vs-Ort-Regel) | `DriveStats.compute` |
| `addTrackPoint` (Ausdünnen ≥10 m oder ≥15 s, max. 20 000 Punkte) | `DriveRecorder.addPoint` |
| localStorage / IndexedDB | SwiftData (`PhotoItem.image` mit `externalStorage`) |
| `withExif`, Export in Fotos | `PhotoExporter.jpegWithMetadata` (ImageIO), `PHAssetCreationRequest` mit Datum und Standort |
| Bildanalyse aus der Mediathek, `analyzeStill` | `PhotoAnalysisView` mit `PhotosPicker`, gleiche 3×3-Kacheln |
| Korrekturen, Prüfliste, JSON-Export | `CorrectionSheet`, `ReviewView` (gleiches JSON-Format wie die Web-App) |

Alle Schwellen (Score-Minimum `max(0.12, thr*0.4)`, IoU 0,25 für Zuordnung, Glättung 0,55, Verifikation ab 0,6, Gruppenregel
0,3, "sicher" ab 0,5) sind 1:1 übernommen.

**Was auf iOS besser geht als im Browser:** Kamera und Modelle laufen ohne WebGL-Umweg (Neural Engine), die Fernerkennung mit
3×3 Kacheln ist damit flüssig; GPS-Aufzeichnung läuft bei gesperrtem Gerät weiter (`UIBackgroundModes: location`); Fotos
landen mit korrekten Metadaten direkt in der Mediathek; kein Service-Worker, kein Cache-Limit.

## Modelle neu erzeugen

Nach einem neuen Artenkopf (`training/train.js` → `models/head/<version>/`) die Core-ML-Modelle neu bauen:

```
cd training/coreml
python3.12 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
# optional: Referenzausgaben der TF.js-Modelle für den numerischen Abgleich
(cd .. && node coreml/check_reference.js)
python convert.py --check            # --skip-detector, wenn nur der Kopf neu ist
```

`convert.py` liest die TF.js-Graphen direkt (eigener Loader in `tfjs_load.py`, weil der offizielle Konverter mit den Modellen
nicht umgehen kann), setzt MobileNetV2 und Kopf zu **einem** Vision-Classifier zusammen und baut den Detektor als Pipeline
(SSDLite → Core-ML-NMS, IoU 0,5, Confidence 0,25, klassenübergreifend wie im Web). Die `HEAD`-Konstante in `convert.py` zeigt
auf die Kopfversion. Beide Modelle wurden gegen TF.js geprüft (maximale Abweichung 1,2e-07). Danach `species-labels.json`
nach `SafariSpotter/Resources/` kopieren.

## Logik-Abgleich mit der Web-App

`ios/Tools/logic-check/run.sh` kompiliert Katalog, Tracker, Geometrie, Fahrtstatistik und Vergröberung mit kleinen
Ersatztypen für CoreLocation (ohne iOS-SDK, läuft auf jedem Mac mit Xcode-Toolchain oder mit Swift für Linux), führt
dieselben Eingaben durch die Originalfunktionen aus `app.js` und vergleicht die Ergebnisse. Nach jeder Änderung an einer der
beiden Seiten einmal ausführen:

```
ios/Tools/logic-check/run.sh
# ... Swift und Web-App rechnen identisch.
```

## Eigener Detektor (YOLO)

Der Pfad ist vorbereitet: Sobald `ios/Models/SafariSpotterYolo.mlpackage` existiert (Training und Export in
`training/yolo/README.md`), schaltet `VisionPipeline` zur Laufzeit um, Rahmen und Art kommen aus einem Modell, der Artenkopf
bleibt zweite Meinung. Ohne die Datei baut und läuft die App unverändert.

## Bekannte Lücken

- **Nicht kompiliert**: Der Code wurde ohne Xcode geschrieben. Syntax und die Foundation-Logik sind geprüft, Aufrufe in
  AVFoundation, Vision, SwiftData, MapKit und PhotosUI nicht. Rechne beim ersten Build mit einigen kleinen Korrekturen
  (fehlende Labels, `@MainActor`-Hinweise, geänderte API-Namen).
- **Modelle auf dem Gerät ungetestet**: Die Core-ML-Dateien sind numerisch korrekt, aber noch nie auf einem iPhone gelaufen.
  Falls Vision beim Detektor die optionalen Eingaben `iouThreshold`/`confidenceThreshold` nicht mag, lassen sie sich in
  `convert.py` entfernen (fest verdrahtete Werte in der NMS-Schicht).
- **Videoaufnahme mit eingebranntem Overlay** fehlt noch. Im Web zeichnet ein Canvas Rahmen ins Video; nativ braucht das einen
  `AVAssetWriter` mit einem Overlay-Layer (`AVVideoCompositionCoreAnimationTool`) oder das Mitschneiden der gerenderten
  Vorschau. Der Audio-Teil (Mikrofon-Recht) ist in `project.yml` schon angelegt.
- **Linsen**: Das iPhone 18 Pro wechselt mit `builtInTripleCamera` automatisch zwischen den Objektiven; eine manuelle
  Linsenwahl wie das `<select>` der Web-App ist noch nicht gebaut (`AVCaptureDevice.DiscoverySession`).
- **Hintergrund-Erkennung**: Die Kamera läuft nur im Vordergrund (iOS-Regel); die Game-Drive-Aufzeichnung läuft weiter.
- Die Web-App bleibt die Referenz; neue Regeln zuerst dort einbauen und testen, dann portieren und mit dem Logik-Abgleich prüfen.
