# Eigener Detektor (YOLO) für Safari Spotter

Heute arbeitet die App zweistufig: ein allgemeiner COCO-Detektor (SSDLite, 300×300) findet "ein Tier", danach bestimmt der
Artenkopf (MobileNet-Embedding + Dense) die Art. Ein eigener YOLO-Detektor macht beides in einem Durchgang, kennt die 61 Arten
direkt, sieht mit 640 Pixeln Eingabe ferne Tiere besser und läuft als Core-ML-Modell auf der Neural Engine in Echtzeit.

Alles hier ist vorbereitet, aber noch nicht trainiert (das Training braucht einen Mac mit Apple Silicon oder eine GPU).

**Lizenz vor Verteilung klären:** Ultralytics stellt YOLO-Code und Modellgewichte unter AGPL-3.0 oder einer Enterprise-Lizenz
bereit ([offizielle Lizenzangaben](https://github.com/ultralytics/ultralytics/blob/main/README.md#-license)). Ein damit
trainiertes Modell wird nicht ohne geklärte Lizenz in Safari Spotter oder TestFlight übernommen. Der aktuelle Detektor
und Artenkopf bleiben bis dahin die veröffentlichte Erkennung.

**Apple-Alternative:** Create ML kann aus denselben geprüften Boxen einen Core-ML-Objektdetektor ohne YOLO11-Gewichte
trainieren ([Apple-Dokumentation](https://developer.apple.com/documentation/createml/mlobjectdetector)). Der Datensatz
wird dafür in Apples JSON-Format exportiert. Leistung und Erkennungsqualität dieses Wegs sind noch nicht gemessen.

## Ablauf

1. **Fotos holen** (falls `training/data/` fehlt), wie fürs Artenmodell. Der Downloader nimmt nur CC0-/CC-BY-Fotos,
   schreibt Lizenz und Urheber in `manifest.json` und kann nach Netzfehlern erneut gestartet werden:
   ```
   cd training && python3 download.py --per-class 80
   ```
2. **Auto-Labeln**: Der vorhandene COCO-Detektor zeichnet die Rahmen, die Art kommt aus dem Ordnernamen.
   ```
   cd training && ./setup_node_mac.sh && ./node22.sh yolo/autolabel.js
   ```
   Ergebnis: `training/yolo/dataset/{images,labels}/{train,val}` (Bilder als Symlinks, 15 % Validierung, gruppiert nach
   iNaturalist-Beobachtung bzw. Original-JPEG einer Korrektur), `dataset.yaml` (mit absolutem Pfad, also auf dem Rechner
   ausführen, der auch trainiert) und `classes.json`. Eingelesen werden nur Bilder mit aktivem Manifest-Eintrag und
   CC0-/CC-BY-Lizenz oder geprüfter Korrektur; ersetzte Beschriftungen und verwaiste Bilddateien bleiben draussen.
   Ein und dieselbe iNaturalist-Foto-ID oder Korrekturquelle in mehreren Artordnern wird wegen des widersprüchlichen
   Labels aus beiden Trainingspfaden ausgeschlossen; die Quelldateien bleiben erhalten.
   Nach Sichtprüfung ausgeschlossene Fotos stehen mit Grund in `training/excluded_photos.json`; auch sie bleiben als
   Originaldateien und Manifest-Einträge erhalten, werden aber weder für den Artenkopf noch YOLO verwendet.
   Ein erneuter Lauf erhält bestehende, auch manuell überarbeitete Labeldateien. `--overwrite` erzeugt sie bewusst neu;
   bei geänderter Klassenreihenfolge stoppt das Skript, damit alte Labelnummern nicht falsch verwendet werden.
   Wird eine Korrektur später ersetzt, entfernt der nächste Lauf nur ihre alte Bildverknüpfung aus dem Datensatz und
   verschiebt das bisherige Label nach `dataset/excluded/`. Das Originalbild und die alte Beschriftung bleiben erhalten.
   `dataset/label-review.json` listet Bilder mit Rückfall-Box und Bildern mit mehreren Tier-Boxen zur gezielten Sichtprüfung.
   Der COCO-Detektor darf deutliche Fremdarten (Elefant, Zebra, Giraffe) nicht als Box einer anderen Art übernehmen;
   für Vogelklassen gelten nur Vogel-Boxen. Diese Filter können zusätzliche Rückfall-Boxen erzeugen.
   Der vollständige Audit verweigert das Training, solange Bilder aus dieser Prüfliste nicht ausdrücklich am Foto
   geprüft wurden. Nach dem Prüfen und gegebenenfalls Korrigieren der YOLO-Labeldatei:
   ```
   ./node22.sh yolo/review_label.js <klasse/foto.jpg> --reviewed
   ```
   Die Freigabe speichert Prüfsummen von Originalfoto und Label in der lokalen `label-review.json`. Ändert sich danach
   das Foto oder der Rahmen, ist eine erneute Sichtprüfung nötig. `--partial` prüft nur die Struktur und zeigt die
   noch offenen Bilder an; es ist keine Trainingsfreigabe.
   Vor dem Trainieren prüft `node yolo/audit_dataset.js` alle Bildverknüpfungen, Labelwerte, Lizenz-/Quelleneinträge,
   Beobachtungsgruppen und die Mindestmenge je Klasse (20 Train, 3 Val). Für einen Probelauf mit `--limit` geht
   `node yolo/audit_dataset.js --partial`; `train_mac.sh` verlangt den vollständigen erfolgreichen Audit.
   Die vier Klassen Hausrind, Hausziege, Haushund und Esel werden mit leeren Labels als Gegenbeispiele aufgenommen.
   Probelauf: `node yolo/autolabel.js --limit 20`.

   Was die Auto-Labels können und was nicht:
   - Viele Bilder bekommen eine echte Detektor-Box. Der Rest (vor allem Reptilien, Vögel am Boden und Pinguine) bekommt
     zunächst eine zentrierte Rückfall-Box über 80 % des Bildes. Ein Stichprobencheck zeigte, dass solche Boxen kleine
     oder verdeckte Tiere oft verfehlen; sie sind deshalb nur ein Vorschlag zur manuellen Prüfung, kein fertiges Label.
   - Herden: Es werden alle Tier-Boxen behalten, die mindestens 25 % der grössten Box haben. Teilweise sichtbare zweite Tiere
     am Bildrand bleiben manchmal ohne Box; das kostet etwas Genauigkeit, aber kein Training.
   - Auch mehrere Detektor-Boxen können verschiedene Tierarten zeigen. Alle Rückfall- und Mehrfach-Labels müssen vor
     einem Trainingslauf am Bild geprüft werden; ein Werkzeug wie Label Studio kann YOLO-Labels direkt bearbeiten.
3. **Trainieren und exportieren** (Mac, Apple Silicon):
   ```
   uv venv training/.venv --python 3.11
   uv pip install --python training/.venv/bin/python ultralytics coremltools
   cd training/yolo && ./train_mac.sh yolo11n 60 640
   ```
   `yolo11n` ist das kleinste Modell (Echtzeit auf dem iPhone, Ziel 25 bis 30 fps bei 640 px), `yolo11s` ist genauer und
   etwa halb so schnell. Das Skript trainiert, validiert (mAP50 je Klasse in `runs/spotter-yolo11n/results.csv`) und
   exportiert nach Core ML **mit eingebauter NMS**. Das Pipeline-Modell hat dieselbe Schnittstelle wie
   `ios/Models/SafariSpotterDetector.mlmodel`: Ausgaben `confidence` [N, Klassen] und `coordinates` [N, 4].
   Vor dem Einlegen die Eingaben prüfen: Hat der Export neben `image` auch `iouThreshold`/`confidenceThreshold`, dürfen sie
   am NMS-Teilmodell nicht optional sein (sonst bricht `coremlc` ab wie beim Detektor), und Vision braucht dann Werte dafür
   (`VNCoreMLModel.featureProvider`) oder sie werden wie in `training/coreml/convert.py` fest verdrahtet.
4. **In die iOS-App einlegen**:
   ```
   cp -R training/yolo/runs/spotter-yolo11n/weights/best.mlpackage ios/Models/SafariSpotterYolo.mlpackage
   cd ios && xcodegen generate
   ```
   In `ios/project.yml` muss zusätzlich die dort kommentierte Dateireferenz für `SafariSpotterYolo.mlpackage` aktiviert
   werden. `VisionPipeline` lädt `SafariSpotterYolo.mlmodelc` zur Laufzeit,
   wenn es im Bundle liegt, und schaltet automatisch um: Rahmen und Art kommen dann aus dem Detektor
   (`Detection.species`, `Tracker.applyDetectorSpecies`), der Artenkopf bleibt als zweite Meinung für schwache Treffer,
   die Fernerkennung (Kacheln) funktioniert unverändert. Ohne die Datei baut und läuft die App wie bisher.

## Create ML als Alternative

Erst nach vollständigem Audit und der Sichtprüfung aller Rückfall- und Mehrfach-Boxen:

```
cd training
./node22.sh yolo/export_create_ml.js
swift yolo/train_create_ml.swift yolo/dataset/create_ml yolo/dataset/SafariSpotterCandidate.mlmodel
```

Der Export übernimmt die bereits nach Beobachtung getrennten Train-/Val-Bilder. Apples JSON bekommt normierte
Mittelpunkt-Koordinaten; negative Beispiele haben leere Annotationen. Der Export läuft nur nach bestandenem vollständigem
Audit und erzeugt keinen Datensatz, solange Prüffälle offen sind. `train_create_ml.swift` verwendet den festen
Validierungssplit und schreibt ein neues `.mlmodel`, ohne ein bestehendes Modell zu überschreiben. Nach unabhängigem
Qualitätstest kann es als `ios/Models/SafariSpotterYolo.mlmodel` in `ios/project.yml` referenziert werden;
`VisionPipeline` verwendet es dann als optionalen Ein-Modell-Detektor. Training und Gerätetest sind noch ausstehend.

## Was zu erwarten ist

- Die Validierung auf den Auto-Labels misst zunächst nur, wie gut das Modell diese Labels reproduziert. Vor dem Einbau
  braucht es zusätzlich unabhängige Tier- und Nichttierbilder sowie einen echten Gerätetest. Verwechslungen wie
  Löwe/Löwin, Breitmaul-/Spitzmaulnashorn und Kudu/Nyala müssen gesondert geprüft werden.
- Der grösste Gewinn ist bei fernen, kleinen Tieren und bei Tieren, die COCO nicht kennt (Warzenschwein, Erdmännchen,
  Krokodil, Strauss), weil der COCO-Detektor sie heute oft gar nicht erst findet.
- Für die Web-App lässt sich dasselbe Modell mit `yolo export format=tfjs` exportieren; der JS-Pfad müsste dann analog zum
  Swift-Pfad angepasst werden (Rahmen plus Art in einem Schritt, Kopf als zweite Meinung).

## Dateien

- `autolabel.js`: Auto-Labeling mit dem COCO-Detektor (tfjs-node), schreibt Datensatz, `dataset.yaml`, `classes.json`
- `train_mac.sh`: Training, Validierung, Core-ML-Export mit NMS
- `dataset/`, `runs/`: erzeugt, nicht im Git
