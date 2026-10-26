# Eigener Detektor (YOLO) für Safari Spotter

Heute arbeitet die App zweistufig: ein allgemeiner COCO-Detektor (SSDLite, 300×300) findet "ein Tier", danach bestimmt der
Artenkopf (MobileNet-Embedding + Dense) die Art. Ein eigener YOLO-Detektor macht beides in einem Durchgang, kennt die 61 Arten
direkt, sieht mit 640 Pixeln Eingabe ferne Tiere besser und läuft als Core-ML-Modell auf der Neural Engine in Echtzeit.

Alles hier ist vorbereitet, aber noch nicht trainiert (das Training braucht einen Mac mit Apple Silicon oder eine GPU).

## Ablauf

1. **Fotos holen** (falls `training/data/` fehlt), wie fürs Artenmodell:
   ```
   cd training && pip install -r requirements.txt && python download.py
   ```
2. **Auto-Labeln**: Der vorhandene COCO-Detektor zeichnet die Rahmen, die Art kommt aus dem Ordnernamen.
   ```
   cd training && npm install && node yolo/autolabel.js
   ```
   Ergebnis: `training/yolo/dataset/{images,labels}/{train,val}` (Bilder als Symlinks, 15 % Validierung, deterministisch
   nach Dateiname), `dataset.yaml` (mit absolutem Pfad, also auf dem Rechner ausführen, der auch trainiert) und `classes.json`.
   Auf 16 000 Bildern dauert das auf einer CPU rund eine Stunde. Probelauf: `node yolo/autolabel.js --limit 20`.

   Was die Auto-Labels können und was nicht:
   - Rund 85 % der Bilder bekommen eine echte Detektor-Box, der Rest (vor allem Reptilien, Vögel am Boden, Pinguine) eine
     zentrierte Rückfall-Box über 80 % des Bildes. iNaturalist-Fotos zeigen das Tier meist bildfüllend, darum ist das brauchbar.
   - Herden: Es werden alle Tier-Boxen behalten, die mindestens 25 % der grössten Box haben. Teilweise sichtbare zweite Tiere
     am Bildrand bleiben manchmal ohne Box; das kostet etwas Genauigkeit, aber kein Training.
   - Wer mehr will, prüft die Labels in einem Werkzeug wie Label Studio oder Roboflow (YOLO-Format wird direkt importiert) und
     korrigiert vor allem die Rückfall-Boxen.
3. **Trainieren und exportieren** (Mac, Apple Silicon):
   ```
   pip install ultralytics coremltools
   cd training/yolo && ./train_mac.sh yolo11n 60 640
   ```
   `yolo11n` ist das kleinste Modell (Echtzeit auf dem iPhone, Ziel 25 bis 30 fps bei 640 px), `yolo11s` ist genauer und
   etwa halb so schnell. Das Skript trainiert, validiert (mAP50 je Klasse in `runs/spotter-yolo11n/results.csv`) und
   exportiert nach Core ML **mit eingebauter NMS**. Das Pipeline-Modell hat dieselbe Schnittstelle wie
   `ios/Models/SafariSpotterDetector.mlmodel`: Ausgaben `confidence` [N, Klassen] und `coordinates` [N, 4].
4. **In die iOS-App einlegen**:
   ```
   cp -R training/yolo/runs/spotter-yolo11n/weights/best.mlpackage ios/Models/SafariSpotterYolo.mlpackage
   cd ios && xcodegen generate
   ```
   `project.yml` nimmt alle `.mlpackage` in `ios/Models` auf. `VisionPipeline` lädt `SafariSpotterYolo.mlmodelc` zur Laufzeit,
   wenn es im Bundle liegt, und schaltet automatisch um: Rahmen und Art kommen dann aus dem Detektor
   (`Detection.species`, `Tracker.applyDetectorSpecies`), der Artenkopf bleibt als zweite Meinung für schwache Treffer,
   die Fernerkennung (Kacheln) funktioniert unverändert. Ohne die Datei baut und läuft die App wie bisher.

## Was zu erwarten ist

- Nach 60 Epochen auf den Auto-Labels liegt ein yolo11n erfahrungsgemäss bei mAP50 um 0,7 bis 0,8 über alle 61 Arten; die
  verwechslungsanfälligen Paare (Löwe männlich / Löwin, Breitmaul / Spitzmaul, Kudu / Nyala) bleiben die Schwachstellen, dort
  hilft die Gruppenregel der App (`decideSpecies`) weiter.
- Der grösste Gewinn ist bei fernen, kleinen Tieren und bei Tieren, die COCO nicht kennt (Warzenschwein, Erdmännchen,
  Krokodil, Strauss), weil der COCO-Detektor sie heute oft gar nicht erst findet.
- Für die Web-App lässt sich dasselbe Modell mit `yolo export format=tfjs` exportieren; der JS-Pfad müsste dann analog zum
  Swift-Pfad angepasst werden (Rahmen plus Art in einem Schritt, Kopf als zweite Meinung).

## Dateien

- `autolabel.js`: Auto-Labeling mit dem COCO-Detektor (tfjs-node), schreibt Datensatz, `dataset.yaml`, `classes.json`
- `train_mac.sh`: Training, Validierung, Core-ML-Export mit NMS
- `dataset/`, `runs/`: erzeugt, nicht im Git
