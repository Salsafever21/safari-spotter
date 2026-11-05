# Safari Spotter als native iOS-App

Dieser Ordner enthält die Vorbereitung, um die Web-App (`index.html`, `app.js`) als echte iOS-App mit denselben Funktionen
und derselben Erkennungslogik weiterzubauen: die beiden Modelle als Core ML, ein SwiftUI-Projekt mit allen Bausteinen und ein
Prüfwerkzeug, das die Swift-Logik gegen die Web-App rechnet.

Stand: Modelle konvertiert, Swift-Code geschrieben und auf Syntax geprüft, die reine Logik (Katalog, Artentscheidung,
Tracker, Zusammenführung, Fahrtstatistik, Artenschutz-Vergröberung) rechnet nachweislich identisch zur Web-App
(`Tools/logic-check`), die neuen Regeln für Bildausschnitte, Korrektur und Artenschutz sind mit `Tools/unit-check` geprüft.
**Noch nicht geschehen:** ein Build in Xcode, die XCTests in `SafariSpotterTests/` und ein Test auf dem iPhone, weil es hier
keinen Mac gibt. Beim ersten Build sind einzelne Compiler-Korrekturen möglich (siehe "Bekannte Lücken").

## Bauen

Voraussetzungen: Mac mit aktuellem Xcode (für Uploads nach App Store Connect verlangt Apple jeweils ein aktuelles SDK, vor
dem ersten Upload nachsehen), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), ein iPhone mit
iOS 17 oder neuer (der Simulator hat keine Kamera).

```
cd ios
xcodegen generate            # erzeugt SafariSpotter.xcodeproj aus project.yml
open SafariSpotter.xcodeproj
```

In Xcode unter *Signing & Capabilities* das eigene Team wählen (oder `DEVELOPMENT_TEAM` in `project.yml` eintragen), das
iPhone anschliessen, Run. Beim ersten Start fragt die App nach der Kamera und nach dem Standort ("Beim Verwenden" genügt:
ein gestarteter Game Drive zeichnet dank Hintergrund-Standort auch bei gesperrtem Gerät weiter, auf dem Gerät noch zu
bestätigen), beim ersten Sichern nach "Fotos hinzufügen". Ist die Kamera verweigert, zeigt die App einen Hinweis mit Sprung in
die Einstellungen.

Tests (Bildausschnitte mit echtem Core Image, Artenschutz mit ImageIO und SwiftData im Speicher, Korrektur ohne
Doppelsichtung) im Simulator:

```
cd ios
xcodebuild -scheme SafariSpotter -destination 'platform=iOS Simulator,name=iPhone 16' test
```

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
    Core/Detection/ImageGeometry     Koordinaten App (oben links) ↔ Core Image/Vision (unten links), sichtbarer Ausschnitt
    Core/Detection/Tracker.swift     IoU-Tracker mit Glättung, Bestätigung schwacher Kandidaten, Art-EMA 0.6/0.4
    Core/Detection/CameraController  AVFoundation bis 4K, Rechte und Lebenszyklus, Erkennungsschleife, Sichtungen, Schnappschüsse
    Core/Data/Models.swift           SwiftData: Sighting, PhotoItem, Correction, Drive; Position mit coarsen()
    Core/Data/SightingStore.swift    Umbenennen, Entfernen, Live-Korrektur (nie doppelt, Abspalten bei n > 1), Fotoschutz
    Core/Privacy/LocationProtection  Artenschutz-Regeln als reine Funktionen (Position, sensible Arten, Korrekturplan)
    Core/Location/DriveRecorder      GPS, Region, Game Drive (Punkte, Statistik, Hintergrund), wie tripStats()
    Core/Export/Exporters.swift      CSV, GPX (Artenschutz-Regeln), JPEG mit EXIF/GPS in die Fotos-Mediathek
    UI/LiveView.swift                Kamerabild, Overlay, Tracken, Game Drive, Zoom
    UI/SightingsView.swift           Liste, Zählung, Karte (MapKit), Galerie, Prüfen
    UI/Sheets.swift                  Artwahl, Korrektur, Steckbrief, Game Drive live, Einstellungen, Bildanalyse
    Resources/                       species-info.json, regions.json, species-labels.json (Kopien aus data/ und Models/)
  SafariSpotterTests/                XCTests: Bildausschnitte, Artenschutz der Fotos, Korrektur ohne Doppelsichtung
  Tools/logic-check/                 Abgleich Swift ↔ app.js (siehe unten)
  Tools/unit-check/                  Prüfungen der reinen Swift-Regeln ohne iOS-SDK (siehe unten)
training/coreml/                     Konvertierung TF.js → Core ML (convert.py, tfjs_load.py, check_reference.js)
training/yolo/                       Vorbereitung für den eigenen Ein-Modell-Detektor (Auto-Labels, Training, Export)
```

## Wie die Web-App auf iOS abgebildet ist

| Web-App (app.js) | iOS |
|---|---|
| `startCamera`, RES-Tabelle 720/1080/2160, Linsen, Zoom | `CameraController.start` (Recht, einmalige Konfiguration mit `AVCaptureSession.Preset`), `builtInTripleCamera` (Fallback Dual/Wide), `videoZoomFactor` |
| `visibleRegion` | `ImageGeometry.visibleRegion` (Erkennung nur im sichtbaren Ausschnitt), `ImageGeometry.ciRect` für jeden Bildausschnitt |
| `renameSighting` bei Korrektur eines Live-Rahmens | `CameraController.correct` → `SightingStore.applyTrackCorrection` (umbenennen statt neu anlegen; bei n > 1 ein Tier abspalten) |
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
(SSDLite → Core-ML-NMS, klassenübergreifend wie im Web). Die NMS-Schwellen sind fest verdrahtet (IoU 0,5, Score 0,12 =
Untergrenze von `minScore`; den eigentlichen Score-Filter macht `VisionPipeline.detect`), der Detektor hat als einzige
Eingabe das Bild: optionale Schwellen-Eingaben am NMS-Modell lehnt `coremlc` ab ("Features cannot be optional to this type
of model"). Die `HEAD`-Konstante in `convert.py` zeigt
auf die Kopfversion. `--check` vergleicht die TensorFlow-Funktion vor der Konvertierung mit TF.js (maximale Abweichung
1,2e-07); die gespeicherten Core-ML-Dateien selbst sind damit noch nicht gegen TF.js geprüft (das geht nur auf einem Mac
bzw. iPhone). Danach `species-labels.json` nach `SafariSpotter/Resources/` kopieren.

## Logik-Abgleich mit der Web-App

`ios/Tools/logic-check/run.sh` kompiliert Katalog, Tracker, Geometrie, Fahrtstatistik und Vergröberung mit kleinen
Ersatztypen für CoreLocation (ohne iOS-SDK, läuft auf jedem Mac mit Xcode-Toolchain oder mit Swift für Linux), führt
dieselben Eingaben durch die Originalfunktionen aus `app.js` und vergleicht die Ergebnisse. Nach jeder Änderung an einer der
beiden Seiten einmal ausführen:

```
ios/Tools/logic-check/run.sh
# ... Swift und Web-App rechnen identisch.
```

`ios/Tools/unit-check/run.sh` prüft die Regeln, die es in der Web-App so nicht gibt, ebenfalls ohne iOS-SDK: Umrechnung der
Bildausschnitte nach Core Image (der Grund für vertikal gespiegelte Kacheln vor dem Fix), sichtbarer Ausschnitt wie
`visibleRegion()`, Korrekturplan ohne Doppelsichtung und die Artenschutz-Regeln für Positionen (inklusive: nie zweimal
vergröbern, weil `coarsen` beim Längengrad nicht idempotent ist).

```
ios/Tools/unit-check/run.sh
# unit-check: 42 Prüfungen bestanden.
```

## Eigener Detektor (YOLO)

Der Pfad ist vorbereitet: Sobald `ios/Models/SafariSpotterYolo.mlpackage` existiert (Training und Export in
`training/yolo/README.md`) und in `project.yml` als eigene Zeile eingetragen ist (Vorlage als Kommentar dort), schaltet
`VisionPipeline` zur Laufzeit um, Rahmen und Art kommen aus einem Modell, der Artenkopf bleibt zweite Meinung. Ohne die
Datei baut und läuft die App unverändert.

## Artenschutz im Code

- Sichtungen: Position bei sensiblen Arten (Nashörner, auch Sammelname "Nashorn") schon beim Speichern auf dem 10-km-Raster.
- Umbenennen auf eine sensible Art (Liste oder Live-Rahmen) setzt die Sichtung **und alle verknüpften Fotos** auf das Raster.
- Schnappschüsse sind ungenau, sobald irgendein Rahmen im Bild eine sensible Art zeigt.
- "In Fotos sichern" ermittelt die Position noch einmal (`PhotoExporter.exportCoordinate`) und übernimmt nie GPS aus der
  Quelldatei; das schützt auch Fotos aus älteren Ständen oder aus einem Import.
- Bereits vergröberte Positionen werden nie ein zweites Mal vergröbert.

## Bekannte Lücken

- **Build und Tests**: Mit Xcode 27.2 auf dem Mac kompiliert, 25/25 Simulator-Tests bestanden und auf dem iPhone 18 Pro
  installiert. Die Live-Kamera konnte über iPhone-Synchronisierung nicht geprüft werden, weil Apple dort das Kamerabild sperrt.
- **Modelle auf dem Gerät ungetestet**: Die Core-ML-Dateien wurden mit dem iPhone-Build kompiliert, aber die Erkennung wurde
  noch nicht mit einer echten Kameraaufnahme auf dem iPhone geprüft. Abweichung zur Web-App
  bei der NMS: coco-ssd nutzt `minScore` auch als IoU-Schwelle und höchstens 10 Rahmen je Durchlauf, die Core-ML-NMS fest
  IoU 0,5 ohne Obergrenze; die Zusammenführung danach (`VisionPipeline.merge`) gleicht das grösstenteils aus.
- **Videoaufnahme mit eingebranntem Overlay** fehlt noch. Im Web zeichnet ein Canvas Rahmen ins Video; nativ braucht das einen
  `AVAssetWriter` mit einem Overlay-Layer (`AVVideoCompositionCoreAnimationTool`) oder das Mitschneiden der gerenderten
  Vorschau. Der Audio-Teil (Mikrofon-Recht) ist in `project.yml` schon angelegt.
- **Linsen**: Das iPhone 18 Pro wechselt mit `builtInTripleCamera` automatisch zwischen den Objektiven; eine manuelle
  Linsenwahl wie das `<select>` der Web-App ist noch nicht gebaut (`AVCaptureDevice.DiscoverySession`).
- **Hintergrund-Erkennung**: Die Kamera läuft nur im Vordergrund (iOS-Regel) und wird im Hintergrund angehalten; die
  Game-Drive-Aufzeichnung läuft weiter.
- **Ausrichtung**: Die erste iOS-Version ist auf Hochformat beschränkt, damit Kamerabild, Rahmen und Tippkoordinaten übereinstimmen.
- Die Web-App bleibt die Referenz; neue Regeln zuerst dort einbauen und testen, dann portieren und mit dem Logik-Abgleich prüfen.
