# Safari Spotter als native iOS-App

Dieser Ordner enthält die native iOS-App mit Core-ML-Modellen, SwiftUI-Oberfläche und SwiftData-Speicher. Die Regeln für
Erkennung, Game Drives und Artenschutz wurden aus der Web-App (`index.html`, `app.js`) übernommen.

Beim ersten Start fragt das Reise-Onboarding nach Ausgangsland und Reiseziel. Zehn recherchierte Länderprofile
(Südafrika, Namibia, Botswana, Simbabwe, Sambia, Mosambik, Tansania, Kenia, Uganda und Ruanda) nennen im bestehenden
Modell erkennbare Arten mit offiziellen Quellen. Alle anderen Länder sind ebenfalls wählbar und nutzen die allgemeine
Erkennung. Bei bereits sicher erkannten Tieren gibt das Reiseziel belegten Arten einen schwachen Faktor von 1,25, das
Ausgangsland einen Faktor von 1,15. Die Faktoren gelten nur für die bereits vom Modell gewählte Art. Unsichere Treffer,
Haustiere und Sammelnamen werden dadurch nicht zu einer neuen oder genaueren Safari-Sichtung. Bestehendes
GPS-Vorwissen für südafrikanische Teilregionen bleibt zusätzlich aktiv. Der Tierführer im Kamerabild ordnet Arten nach
Boden, Luft und Wasser ein und zeigt die Quellen. Er ist keine vollständige Verbreitungskarte. Südafrika enthält Elefanten,
wie SANParks für Kruger und Addo dokumentiert. Eine Auswahl nach Park oder Reservat ist für eine spätere Ausbaustufe
vorgesehen. Die Reiseauswahl kann in den Einstellungen geändert werden und ist in der nativen Sicherung enthalten.
Beim Onboarding wird die Kamera noch nicht geöffnet; der SwiftData-Speicher und die bisherigen Sichtungen bleiben erhalten.

Unter **Sichtungen → Liste/Zählung** lassen sich alle Tage, heute oder ein bestimmter Kalendertag auswählen und nach
Artnamen durchsuchen. Die Liste hat Datumüberschriften und zeigt die Zahl der sichtbaren und insgesamt gespeicherten
Einträge. Beim erneuten Öffnen werden alle Tage angezeigt; **Alle anzeigen** setzt die Auswahl zurück. Der Filter ist
eine reine Ansicht und entfernt keine Daten. Geteilte Zusammenfassungen nennen den tatsächlichen Zeitraum und den
Artfilter. CSV-Dateien entstehen erst beim Tippen auf **Auswahl als CSV teilen**, enthalten genau diese Auswahl und
bleiben während der Freigabe unverändert. Der Artenschutz berücksichtigt dabei weiterhin sämtliche Sichtungen und Fotos,
auch wenn sie ausgeblendet sind. CSV-Felder erhalten bei Trennzeichen, Anführungszeichen oder Zeilenumbrüchen die
nötige Maskierung; Namen, die als Tabellenformel interpretiert werden könnten, werden als Text ausgegeben.

Die Zählung endet bei eins und löscht keine Sichtung. Eine einzelne Sichtung wird durch Wischen und anschliessende
Bestätigung entfernt; ihre Fotos bleiben in der Galerie. Schreibfehler bei der Zählung stellen den gespeicherten Wert wieder her.
Einzelbild und Galerie verwenden denselben Fotoexport-Auftrag. Er zeigt den Fortschritt, verhindert parallele Exporte
und sperrt das Löschen von Fotos, solange er läuft. Nach einem Fehler können nur die noch nicht erfolgreich gesicherten
Fotos erneut versucht werden. Der Auftrag bleibt beim Wechsel der Ansicht erhalten; er wird nach einem vollständigen
Beenden der App nicht automatisch fortgesetzt. Ein neuer Auftrag kann die offene Restliste nicht ersetzen: Zuerst
wiederholen oder den offenen Export ausdrücklich beenden. Bei einem inzwischen gelöschten oder nicht lesbaren bzw.
kodierbaren Foto kann dieses nach Bestätigung übersprungen werden; die übrigen Fotos werden weiter gesichert.
Übersprungene Fotos werden getrennt gezählt und nie als Sicherungserfolg angezeigt. Sie bleiben im Datenspeicher
und im Artenschutz-Kontext. Das Beenden eines Auftrags entfernt keine Originale oder Mediathek-Kopien.
Erfolgsmeldungen im Bildbetrachter gehören zur ID des gesicherten Fotos.
**Erneut sichern** erzeugt auf ausdrücklichen Wunsch eine weitere Kopie in der Mediathek. Die App-Originale bleiben erhalten.
Die Bildaufbereitung verarbeitet unveränderliche Kopien ausserhalb des Main Actors; SwiftData-Objekte verlassen ihren
Actor nicht. Ein unlesbares Bild wird vor der Fotos-Berechtigungsanfrage erkannt. Beschädigte Artenschutz-Metadaten
im gesamten Speicher stoppen den Export und können nicht über die Überspringen-Funktion umgangen werden.

Unter **Sichtungen → Karte** zeigt die Gesamtkarte alle Aufnahmen. Jede gespeicherte Fahrt lässt sich separat öffnen:
Route, Statistik, Stopps, Kilometer-Splits, Sichtungen und Fotos werden für ihren gespeicherten Zeitraum angezeigt.
GPX und CSV lassen sich für genau diese Fahrt teilen. Der Artenschutz berücksichtigt auch Nashorn-Sichtungen und
geschützte Fotos kurz ausserhalb des Fahrtzeitraums, damit angrenzende Spurpunkte geschützt bleiben. Andere Sichtungen
innerhalb von 15 Minuten werden beim Export ebenfalls vergröbert und zeitlich gerundet. Die Exportkoordinaten werden erneut
vergröbert, falls ein älterer Eintrag trotz sensibler Art noch eine genaue Position enthält. Unlesbare Routen werden
gemeldet und können nicht als scheinbar vollständige GPX-Datei exportiert werden. Die Originaldaten bleiben erhalten.
Exportdateien werden erst beim Tippen erstellt und nach Abschluss oder Abbruch der Freigabe entfernt.
Beim Sichern geschützter Fotos in die Fotos-Mediathek wird die Aufnahmezeit auf die Stunde gerundet. Die exportierte
Bilddatei wird ohne Quell-Metadaten neu geschrieben, damit keine zweite ursprüngliche Zeitangabe mitgeht.
Das gilt auch für andere Tierfotos innerhalb von 15 Minuten um geschützte Sichtungen oder Fotos. Vor Einzel- und
Sammelexporten wird der Schutzkontext aus dem gesamten Datenspeicher gelesen, auch im Foto-Viewer einer einzelnen Fahrt.
Bei einem Lesefehler wird der Export mit einer Meldung abgebrochen. Die gespeicherten Originalfotos werden nicht verändert.
Verifiziert am 6. November 2026 mit Xcode 27.2: 110 Tests im Simulator, 111 eigenständige Swift-Prüfungen und der Abgleich
mit der Web-Logik bestanden; der unsignierte iOS-Release-Build baut erfolgreich. Die neue Fahrtenhistorie wurde mit zwei
getrennten Fahrten in einem ausschliesslich im Arbeitsspeicher angelegten UI-Testdatensatz geprüft.

Stand 6. November 2026: Xcode 27.2 baut die App für Simulator und iPhone. Build 7 wurde zu App Store Connect hochgeladen;
die Zuweisung zur internen TestFlight-Gruppe steht nach Apples Verarbeitung und erneuter Anmeldung noch aus. Build 8
enthält weitere Datenschutz-, Speicher- und Fotoexport-Verbesserungen; seine TestFlight-Bereitstellung steht noch aus.
Sandro hat auf dem iPhone bestätigt, dass der Fix für stehenbleibende Erkennungsrahmen funktioniert. Die Web-App kann eine
vollständige `.ssbackup`-Datei erzeugen. Die iOS-App kann diese importieren sowie ihre eigenen Sichtungen, Fotos,
Videoclips, Korrekturen, Fahrten und alle App-Einstellungen passwortgeschützt exportieren und wiederherstellen.
Für Build 7 bestanden 41 Simulator-Tests. Die Videoaufnahme selbst muss noch mit der iPhone-Kamera geprüft werden.
Build 3 ergänzt einen manuellen Foto-Auslöser und die Objektivwahl. Das Foto wird vor der Tieranalyse als `PhotoItem` im
App-Speicher gesichert, damit ein Abbruch der Analyse die Aufnahme nicht verliert. Die iOS-Sicherung enthält diese Fotos.
Build 4 verhindert, dass ein verspätetes Erkennungsergebnis nach dem Ausschalten des Trackings Status oder Rahmen erneut
einblendet. Beim Ausschalten werden die sichtbaren Treffer sofort entfernt; Ergebnisse des vorherigen Laufs werden verworfen.
In Build 8 prüft die Kamera-Speicherung Commit-Fehler: fehlgeschlagene Sichtungen gelten nicht als erfasst, der Track kann
nach einer kurzen Pause erneut gespeichert werden, und Speicherausfälle für Schnappschüsse und Prüfliste werden angezeigt.
Die Fotomarkierungen werden vor dem Wechsel auf den Hauptthread kopiert, statt den Tracker gleichzeitig auszulesen.
Manuelle Korrekturen brechen ab, wenn die verknüpften Fotos nicht gelesen oder die Änderungen nicht gespeichert werden
können; das verhindert insbesondere eine ungeschützte Nashorn-Position nach einer halben Korrektur. Listen, Galerie und
Prüfliste zeigen Speicherfehler an, statt sie zu verbergen. Ein Game Drive wird erst nach erfolgreichem Speichern beendet;
die laufende Route wird atomar zwischengespeichert. Beim Hintergrundwechsel werden die letzten GPS-Punkte gesichert.
Ein abgeschlossener Drive wird beim Neustart mit der SwiftData-Datenbank abgeglichen, falls die letzte JSON-Datei veraltet ist.
Fahrtspuren und Foto-Markierungen werden bei der Sicherung streng geprüft; beschädigte Daten lassen die Sicherung mit
einem Fehler abbrechen, statt unbemerkt zu fehlen. Die Mediathek-Analyse verarbeitet bis zu zehn ausgewählte Fotos
nacheinander; jedes Bild wird einzeln gespeichert oder übersprungen. Lade- und Modellfehler werden angezeigt, und ein
Speicherfehler lässt den aktuellen Schritt zur Wiederholung offen. Eine neue verschlüsselte Sicherung ersetzt die
vorherige Datei erst nach erfolgreicher Erstellung. Eine Videodatei mit unlesbaren Metadaten wird beim Start geprüft;
die ursprünglichen Metadaten bleiben für eine spätere Prüfung erhalten und werden mitgesichert. Kann die laufende
Videoaufnahme ihre ersten Metadaten nicht sichern, meldet die App den Schreibfehler und beendet die Aufnahme. Neue Fotos
werden nur gespeichert, wenn sämtliche Erkennungsmarkierungen kodiert werden können. Beim Import alter Web-Sicherungen
führen beschädigte Fotomarkierungen oder GPS-Punkte zu einem Fehler und einem vollständigen Rollback, statt unbemerkt
verloren zu gehen. Ein UI-Test prüft die Auswahl von zwei Fotos im Simulator.
Falls SwiftData beim App-Start den lokalen Speicher nicht öffnen kann, zeigt die App nun den Fehler und einen erneuten
Versuch an, statt abzustürzen. Dabei wird der bestehende Datenspeicher nicht ersetzt oder gelöscht.
Die Zoomsteuerung ändert das Kameraobjektiv nur nach erfolgreichem Sperren der Gerätekonfiguration; Fehler erscheinen
als Meldung, statt eine ungesperrte Einstellung zu versuchen.
Bei Game Drives werden auch gebündelte GPS-Updates vollständig in Zeitfolge übernommen. Jeder neue Stapel wird sofort
atomar zwischengespeichert; ein Schreibfehler erscheint in der Fahrtansicht.
Der GPS-Schalter aus der Web-App ist in den iOS-Einstellungen verfügbar. Ist er aus, stoppt die App die Standortupdates,
verwirft den letzten Fix und ergänzt neue Kamera-Sichtungen, Schnappschüsse und Videos nicht mit aktuellem GPS. Ein Game
Drive schaltet GPS beim Start ein; während einer aktiven Fahrt kann es erst nach dem Beenden ausgeschaltet werden.
Standortdaten, die bereits im importierten Foto stehen, bleiben unabhängig davon erhalten. Der Import einer Sicherung
wartet auf das Ende eines Game Drives oder einer Videoaufnahme. Für diesen Stand bestanden 58 Logiktests und ein UI-Test.
„Namen einblenden“ steuert nun auch die Live-Kamera: Rahmen bleiben sichtbar, Namen und Hinweise werden ausgeblendet.
Der Bildbetrachter verwendet bei älteren Fotos ohne gespeicherte Abmessungen die Bilddatei als Grössenquelle und zeigt
einen Hinweis, falls ein Foto nicht dekodiert werden kann.
Der Export der geprüften Korrekturen erzeugt die JSON-Datei erst beim Tippen auf **Korrekturen exportieren**. Jede
Freigabe erhält eine eigene Datei, damit Änderungen an der Prüfliste eine bereits geöffnete Freigabe nicht überschreiben;
Schreibfehler erscheinen in der App. Die exportierten Bildausschnitte werden ohne EXIF- und GPS-Metadaten neu kodiert.
Die temporäre Datei wird erst nach Abschluss oder Abbruch der Teilen-Aktion entfernt;
liegengebliebene Exportdateien, die älter als eine Stunde sind, werden beim nächsten Export bereinigt.
Neue Kamera-Sichtungen speichern für spätere Artkorrekturen einen 224-px-Ausschnitt statt eines 96-px-Vorschaubilds.
Der Export enthält einen Hash des ursprünglichen JPEGs, damit ein zuvor aus der Web-App übernommenes Bild beim lokalen
Training nicht ein zweites Mal gezählt wird. Ältere 96-px-Korrekturen bleiben in der App, der Trainingsimport verwirft sie.

## Bauen

Voraussetzungen: Mac mit aktuellem Xcode (für Uploads nach App Store Connect verlangt Apple jeweils ein aktuelles SDK, vor
dem ersten Upload nachsehen), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), ein iPhone mit
iOS 17 oder neuer (der Simulator hat keine Kamera).

```
cd ios
xcodegen generate            # erzeugt SafariSpotter.xcodeproj aus project.yml
open SafariSpotter.xcodeproj
```

In Xcode unter *Signing & Capabilities* bei Bedarf das Team wählen (`DEVELOPMENT_TEAM` in `project.yml` ist aktuell gesetzt), das
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

## Bestehende Daten übernehmen und neue Daten sichern

In der bisherigen Web-App unter **Einstellungen → Gesamte Daten sichern** eine `.ssbackup`-Datei erzeugen und über
**In Dateien sichern** ausserhalb der Web-App ablegen. Die Datei enthält alle Einträge dieser konkreten Browser-Installation,
einschliesslich Original-JPEGs, Korrekturen, Fahrten und Einstellungen. Vor einem Gerätewechsel die angezeigten Zählwerte
prüfen: Eine leere Sicherung ersetzt keine früheren Aufnahmen. Browser, Home-Screen-Apps und die native App können getrennte
Speicher haben.

In der iOS-App unter **Einstellungen → Bisherige Web-App-Daten → Sicherungsdatei importieren** die Datei auswählen. Der
Import prüft Format, Zählwerte und SHA-256 der Fotos, speichert die Originaldatei im App-Speicher und legt bei erneutem
Import keine Duplikate an. Für spätere Sicherungen unter **Einstellungen → Daten sichern** ein Passwort mit mindestens
12 Zeichen vergeben, danach über **Teilen** eine Kopie ausserhalb der App sichern. Fertige verschlüsselte Sicherungen
bleiben im geschützten App-Speicher auch nach einem Neustart verfügbar und können einzeln direkt wiederhergestellt,
geteilt oder entfernt werden. Die direkte Wiederherstellung behält die verschlüsselte Datei und erzeugt keine zweite
Archivkopie im App-Speicher. Ein Simulator-UI-Test prüft den gesamten Weg vom Erstellen über die Passwortabfrage bis
zur Wiederherstellung und bestätigt, dass die Datei danach weiter verfügbar ist.
Beim Öffnen der Einstellungen übernimmt die App auch vollständig geschriebene temporäre Sicherungen aus früheren Builds;
unvollständige Dateien werden erkannt und nicht als fertige Sicherung angeboten.
Beim Löschen der App verschwinden diese lokalen Kopien; die externe Kopie bleibt deshalb wichtig. Die iOS-App verschlüsselt die
gesamte Datei, einschliesslich aller Clip-Dateien, mit einem zufälligen Salt, PBKDF2-HMAC-SHA256 und AES-256-GCM in Blöcken.
Die Sicherung lässt sich erst starten, wenn eine laufende Videoaufnahme vollständig gespeichert ist. Zum Wiederherstellen
bei einer lokalen Sicherung **Wiederherstellen** wählen oder eine externe Datei importieren und das Passwort eingeben.
Ohne Passwort ist eine Wiederherstellung nicht möglich; die App speichert es nicht.
Die unverschlüsselten Originaldaten werden nach dem Erstellen der geschützten Datei aus dem temporären Speicher entfernt.
Beim Import einer geschützten Datei bleibt im App-Archiv nur die verschlüsselte Originaldatei erhalten.

Ältere unverschlüsselte `.ssbackup`-Dateien der Web-App und früherer iOS-Builds lassen sich weiterhin importieren. Sie
enthalten genaue Aufnahmezeiten und Fahrtspuren; daraus können auch geschützte Tierstandorte abgeleitet werden. Solche
Dateien nur an einem vertrauenswürdigen Ort aufbewahren. Importierte Originalarchive liegen mit iOS-Dateischutz im
App-Speicher und können in den Einstellungen einzeln entfernt werden, ohne die importierten Einträge zu löschen.

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
    Core/Data/ProtectedBackupStore   Lokale, dauerhaft verfügbare verschlüsselte Sicherungsdateien
    Core/Data/SightingStore.swift    Umbenennen, Entfernen, Live-Korrektur (nie doppelt, Abspalten bei n > 1), Fotoschutz
    Core/Privacy/LocationProtection  Artenschutz-Regeln als reine Funktionen (Position, sensible Arten, Korrekturplan)
    Core/Detection/DetectionGate     Trennt Bildlieferung (Aufnahme) und Erkennung, staut nie Bilder an
    Core/Video/                      VideoRecorder (AVAssetWriter), VideoOverlayRenderer (eingebrannte Rahmen),
                                     ClipFiles (Dateiformat, Wiederherstellung, Restore), ClipLibrary (Galerie, Fotos-Export)
    UI/ClipViews.swift               Videos in der Galerie, Player mit Teilen, In Fotos sichern, Löschen
    Core/Location/DriveRecorder      GPS, Region, Game Drive (Punkte, Statistik, Hintergrund), wie tripStats()
    Core/Location/DriveHistory       Zeitraumfilter und geschützte Exporte einzelner Fahrten
    Core/Export/Exporters.swift      CSV, GPX (Artenschutz-Regeln), JPEG mit EXIF/GPS in die Fotos-Mediathek
    UI/LiveView.swift                Kamerabild, Overlay, Tracken, Game Drive, Zoom
    UI/DriveHistoryView.swift        Gesamtkarte, Fahrtenhistorie und Detailansicht mit GPX/CSV
    UI/TravelViews.swift             Reise-Onboarding, Länderauswahl und Tierführer
    UI/SightingsView.swift           Liste, Zählung, Karte (MapKit), Galerie, Prüfen
    UI/Sheets.swift                  Artwahl, Korrektur, Steckbrief, Game Drive live, Einstellungen, Bildanalyse
    Resources/                       species-info.json, regions.json, species-labels.json, country-profiles.json
  SafariSpotterTests/                XCTests: Bildausschnitte, Artenschutz, Korrektur, Backup und Restore, Videoaufnahme
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

**Native Möglichkeiten:** Vision und Core ML verwenden die iOS-Inferenzpfade; GPS-Aufzeichnung kann mit
`UIBackgroundModes: location` auch bei gesperrtem Gerät weiterlaufen. Leistung und Zuverlässigkeit der Live-Erkennung
müssen noch auf dem iPhone geprüft werden.

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
# unit-check: 110 Prüfungen bestanden.
```

## Eigener Detektor (YOLO)

Der Pfad ist vorbereitet: Sobald `ios/Models/SafariSpotterYolo.mlpackage` existiert (Training und Export in
`training/yolo/README.md`) und in `project.yml` als eigene Zeile eingetragen ist (Vorlage als Kommentar dort), schaltet
`VisionPipeline` zur Laufzeit um, Rahmen und Art kommen aus einem Modell, der Artenkopf bleibt zweite Meinung. Ohne die
Datei baut und läuft die App unverändert.

## Videoaufnahme

Roter Knopf in der unteren Leiste startet und stoppt die Aufnahme, mit oder ohne laufende Tiererkennung. Oben läuft ein Timer.
Ab Build 7 fragt die App beim ersten Videostart nach Mikrofonzugriff und schreibt bei Erlaubnis eine AAC-Tonspur. Ohne
Erlaubnis kann sie weiterhin ein stummes Video aufnehmen; ältere Clips erhalten nachträglich keinen Ton.
Videos erscheinen in *Sichtungen → Galerie → Videos* (Abspielen, Teilen, In Fotos sichern, Löschen mit Rückfrage).

- **Unabhängig von der Erkennung**: Die Kamera liefert Bilder auf eine eigene Queue (`CameraController.frameQueue`). Jedes Bild
  geht sofort an `VideoRecorder.append`, die Erkennung bekommt eines nur, wenn sie frei ist (`DetectionGate.route`); sie wird
  nie angestaut. `alwaysDiscardsLateVideoFrames` ist darum aus. Bilder, die doch verloren gehen (Kamera-Puffer voll, Schreiber
  nicht bereit, mehr als 6 Bilder im Rückstau), zählt `droppedFrames` im Clip.
- **Datei**: QuickTime `.mov`, HEVC (sonst H.264), höchstens Full HD wie im Web (4K wird verkleinert), 30 fps,
  optionaler AAC-Mikrofonton.
  Fragmente je Sekunde: Nach einem Absturz bleibt der Clip bis zur letzten Sekunde lesbar und wird beim nächsten Start als
  "wiederhergestellt" in die Galerie geholt (`ClipFiles.recoverInterrupted`).
- **Rahmen einbrennen** (Einstellungen → Video, Standard an wie `settings.burnIn` im Web): Rahmen, Eckwinkel, Namen (falls
  "Namen einblenden" an) und Zeitstempel "Safari Spotter · Datum Zeit" in derselben Optik wie das Live-Overlay.
- **Beenden**: Stopp-Knopf; automatisch beim Wechsel in den Hintergrund (mit Hintergrundzeit zum Fertigschreiben), bei
  Kamera-Unterbrechung oder Laufzeitfehler, bei kritischer Temperatur und unter 300 MB freiem Speicher (Start erst ab 1 GB).
- **Objektiv**: Während der Aufnahme ist die Objektivwahl gesperrt; beim virtuellen Mehrfachobjektiv ("Automatisch") wird
  auch die automatische Umschaltung gesperrt, der Zoom bleibt dann digital.
- **Artenschutz**: Die Videodatei trägt nur Erstellungsdatum und Software, nie einen Standort. Die Clip-Metadaten speichern
  höchstens die 10-km-Zelle; "In Fotos sichern" gibt dem Eintrag ebenfalls nur diese Zelle.

### Clip-Dateien (Schnittstelle für Sicherung und Wiederherstellung)

Clips liegen nicht in SwiftData, sondern als Dateien:

```
Application Support/Clips/
  <UUID>.mov    Video
  <UUID>.json   ClipRecord, Version 1 (ISO-8601-Daten, sortierte Schlüssel)
  <UUID>.jpg    Vorschaubild, längste Seite höchstens 480 px (optional)
```

`ClipRecord` (Datei `Core/Video/ClipFiles.swift`): `version`, `id`, `createdAt`, `duration` (s), `width`, `height`, `codec`
("hvc1"/"avc1"), `fileSize` (Bytes), `frames`, `droppedFrames`, `burnedIn`, `trackingActive`, `species`, `sightingIds`,
`sensitive`, `lat`/`lon` (nur vergröbert oder fehlend), `coarse`, `lens`, `state` ("recording", "complete", "recovered",
"damaged"), `file` ("<UUID>.mov"), `thumbnail` ("<UUID>.jpg" oder fehlend).

- Lesen: `ClipFiles.defaultDirectory()`, `ClipFiles.list(in:)`, `ClipFiles.movieURL/metadataURL/thumbnailURL(_:in:)`.
  Die verschlüsselte Gesamtsicherung nimmt die vorhandenen Clip-Dateien mit, auch beschädigte Dateien für einen späteren
  Wiederherstellungsversuch. Eine gerade laufende Aufnahme muss vorher beendet sein.
- Wiederherstellen: `ClipFiles.install(movie:record:thumbnail:in:)` (idempotent, prüft Dateiname und Grösse, lehnt genaue
  Positionen ab), danach `ClipLibrary.shared.reload()`.
- Die Einstellung `burnIn` liegt in `AppSettings` (UserDefaults-Schlüssel "burnIn").

## Artenschutz im Code

- Sichtungen: Position bei sensiblen Arten (Nashörner, auch Sammelname "Nashorn") schon beim Speichern auf dem 10-km-Raster.
- Umbenennen auf eine sensible Art (Liste oder Live-Rahmen) setzt die Sichtung **und alle verknüpften Fotos** auf das Raster.
- Schnappschüsse sind ungenau, sobald irgendein Rahmen im Bild eine sensible Art zeigt.
- "In Fotos sichern" ermittelt die Position noch einmal (`PhotoExporter.exportCoordinate`) und übernimmt nie GPS aus der
  Quelldatei; das schützt auch Fotos aus älteren Ständen oder aus einem Import.
- Bereits vergröberte Positionen werden nie ein zweites Mal vergröbert.

## Bekannte Lücken

Core-ML-Artenkopf auf lokalen Bildern prüfen (Mac):

```
xcrun swift ios/Tools/model-check/main.swift ios/Models/SafariSpotterSpecies.mlpackage training/data [Art-Schlüssel]
```

- **Gerätetest**: Der Tracking-Fix aus Build 4 und der Sicherungsweg aus Build 6 wurden auf dem iPhone bestätigt. Die
  Videoaufnahme muss mit dem nächsten TestFlight-Build auf dem Gerät geprüft werden.
- **Fotoexport auf dem Gerät**: Mediathek-Fehler mitten in einer Serie, Hintergrundwechsel beim Schreiben und die
  Reaktionszeit grosser Fotoserien sind noch mit dem iPhone zu prüfen. Die automatisierten Teilfehler-Tests verwenden
  einen kontrollierten Schreiber ohne Mediathekzugriff. Ein UI-Test prüft den tatsächlichen Bildfehler vor der
  Berechtigungsanfrage, die Überspringen-Bestätigung und den Erhalt des Originals mit einem flüchtigen Testdatensatz.
- **Erkennungsqualität**: Die Core-ML-Erkennung läuft auf dem Gerät, ihre Treffergenauigkeit wurde noch nicht systematisch
  mit echten Tieraufnahmen vermessen. Die Trainingsbilder für das vorbereitete YOLO-Modell liegen derzeit nicht im Repository.
  Geprüfte Korrekturbilder aus der App lassen sich lokal mit `training/import_corrections.py` in den Artenkopf-Datensatz
  übernehmen; das Modell muss danach erneut trainiert und nach Core ML konvertiert werden. Die App lernt nicht selbsttätig.
  `ios/Tools/model-check/main.swift` prüft den vorhandenen Core-ML-Artenkopf auf einem lokalen Bildordner und meldet
  Top 1, Top 3, die Einzelbildentscheidung mit Sammelnamen, stark selbstsichere Fehler sowie die Mac-Laufzeit.
  Auf 228 lokal geladenen Fotos aus vier Klassen (Elefant, Breitmaulnashorn, Impala, Leopard) waren 186 Top-1-Treffer,
  210 Top-3-Treffer und 189 korrekte Einzelbildentscheidungen ohne Tracking und Region; zwölf Ausgaben waren Sammelnamen.
  Zehn Fehler hatten mindestens 70 % Modellkonfidenz. Die Sichtprüfung zeigte auch fehlerhafte oder gemischte Bildinhalte:
  Ein angebliches Elefantenfoto
  zeigte ein Nashorn, ein Impalafoto zusätzlich einen grossen Elefanten. Die Bilder können zudem mit dem bisherigen
  Trainingssatz überlappen. Diese Zahlen belegen keine Feldgenauigkeit und sind keine Grundlage für neue Schwellen.
  Der gemessene Mac-Median von rund 2 ms betrifft nur den Artenkopf, nicht Detektor, Kacheln und iPhone-Kamera.
  Ein Nachtbild wurde deutlich falsch als Nashorn eingestuft.
  Abweichung zur Web-App
  bei der NMS: coco-ssd nutzt `minScore` auch als IoU-Schwelle und höchstens 10 Rahmen je Durchlauf, die Core-ML-NMS fest
  IoU 0,5 ohne Obergrenze; die Zusammenführung danach (`VisionPipeline.merge`) gleicht das grösstenteils aus.
- **Mikrofonton auf dem Gerät**: Die AAC-Tonspur ist mit synthetischen Samples im Simulator geprüft, die echte
  Mikrofonaufnahme muss auf dem iPhone noch abgehört werden.
- **Video auf dem Gerät**: Schreiber, Rahmen und Wiederherstellung sind mit XCTests im Simulator abgedeckt, die echte Kamera
  (4K, Wärme bei langer Aufnahme mit Erkennung, Hintergrundwechsel) ist noch nicht geprüft. Nicht eingebrannt wird der
  Hinweis "… vermutet" ohne Rahmen; das Video zeigt das ganze Kamerabild, nicht nur den Bildschirmausschnitt wie im Web.
- **Objektivwahl und Foto auf dem Gerät**: Beide Wege kompilieren, sind aber noch nicht mit der echten Kamera getestet.
- **Hintergrund-Erkennung**: Die Kamera läuft nur im Vordergrund (iOS-Regel) und wird im Hintergrund angehalten; die
  Game-Drive-Aufzeichnung läuft weiter.
- **Ausrichtung**: Die erste iOS-Version ist auf Hochformat beschränkt, damit Kamerabild, Rahmen und Tippkoordinaten übereinstimmen.
- Die Web-App bleibt die Referenz; neue Regeln zuerst dort einbauen und testen, dann portieren und mit dem Logik-Abgleich prüfen.
