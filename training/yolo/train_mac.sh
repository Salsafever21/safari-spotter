#!/usr/bin/env bash
# Eigener Ein-Modell-Detektor (YOLO) für Safari Spotter: Training auf dem Mac (Apple Silicon, MPS) und Export nach Core ML.
# Voraussetzungen: Python 3.10+, `pip install ultralytics coremltools`, Datensatz aus `node yolo/autolabel.js` (training/yolo/dataset).
# Aufruf aus training/yolo/:  ./train_mac.sh [modell] [epochen] [bildgroesse]
#   modell:     yolo11n (schnell, ~2.6M Parameter, Echtzeit auf dem iPhone) | yolo11s (genauer, ~9M) | yolo11m
#   epochen:    Standard 60
#   bildgroesse: Standard 640 (für Fernerkennung 960 probieren, dann wird das Modell langsamer)
set -euo pipefail
MODEL=${1:-yolo11n}; EPOCHS=${2:-60}; IMGSZ=${3:-640}
HERE=$(cd "$(dirname "$0")" && pwd)
test -f "$HERE/dataset.yaml" || { echo "dataset.yaml fehlt: zuerst  cd .. && node yolo/autolabel.js"; exit 1; }

# 1) Training. MPS = Apple-GPU; auf Intel-Macs device=cpu. Ein yolo11n mit 16k Bildern braucht auf einem M-Chip grob 1 bis 3 Stunden.
yolo detect train data="$HERE/dataset.yaml" model="$MODEL.pt" epochs="$EPOCHS" imgsz="$IMGSZ" batch=32 device=mps \
  project="$HERE/runs" name="spotter-$MODEL" exist_ok=True \
  mosaic=1.0 fliplr=0.5 scale=0.6 degrees=5 hsv_h=0.015 hsv_s=0.6 hsv_v=0.4 \
  patience=15 cos_lr=True

BEST="$HERE/runs/spotter-$MODEL/weights/best.pt"
# 2) Kennzahlen auf dem Validierungssplit (mAP50 je Klasse steht in runs/.../results.csv und der Konsole)
yolo detect val model="$BEST" data="$HERE/dataset.yaml" imgsz="$IMGSZ" device=mps

# 3) Export nach Core ML mit eingebauter NMS: ergibt ein Pipeline-Modell mit den Ausgaben "confidence" [N, Klassen] und
#    "coordinates" [N, 4] (x, y, w, h, normiert), also dieselbe Schnittstelle wie ios/Models/SafariSpotterDetector.mlmodel.
#    Vision liefert daraus VNRecognizedObjectObservation mit den Artnamen als Labels.
yolo export model="$BEST" format=coreml nms=True imgsz="$IMGSZ" half=True
OUT=$(dirname "$BEST")/best.mlpackage
echo
echo "Fertig: $OUT"
echo "Ins Xcode-Projekt übernehmen:  cp -R \"$OUT\" ../../ios/Models/SafariSpotterYolo.mlpackage"
echo "Danach in ios/SafariSpotter/Core/Detection/VisionPipeline.swift den YOLO-Pfad aktivieren (siehe training/yolo/README.md)."
