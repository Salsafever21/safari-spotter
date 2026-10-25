# Safari Spotter

Live-Tiererkennung mit Tracking für Safaris in Südafrika. Läuft komplett im Browser auf dem iPhone (Safari), ohne App Store: Kamera, Erkennung (COCO-SSD) und Artbestimmung (MobileNet-v2-Embeddings plus eigener Artenkopf mit rund 60 südafrikanischen Arten) laufen auf dem Gerät, nichts verlässt das Telefon.

- Objektiv- und Zoomwahl (Hardware-Zoom, wenn Safari ihn freigibt, sonst digital)
- Tracking mit stabilen IDs und geglätteten Rahmen
- Aufnahme mit eingebranntem Overlay (MP4 in Safari), Teilen in Fotos oder in Dateien speichern
- Sichtungsliste des Tages, teilbar
- Offline nach dem ersten Laden (Service Worker, Modelle lokal gecacht)
- Fernerkennung: das Bild wird zusätzlich in Kacheln abgesucht (der Detektor rechnet intern mit 300×300 Pixeln), schwache Kandidaten bestätigt der Artenkopf
- Korrektur-Loop: Tipp auf einen Rahmen korrigiert die Art, unsichere Treffer landen in einer Prüfliste, Export als JSON für das Nachtraining
- Bilder aus der Mediathek analysieren (mit EXIF-Standort), Foto-Modus aus der Kamera
- Zählung pro Art, Big-Five-Checkliste, Anzahl je Sichtung manuell anpassbar
- GPS-Fahrtaufzeichnung mit Kilometern, Karte (Leaflet/OSM), Export als GPX und CSV
- Artenschutz: Nashorn-Standorte nur auf ein 10-km-Raster, Zeit in Exporten auf die Stunde gerundet, Fahrtspur rund um Nashorn-Sichtungen ausgeblendet
- Region als Vorwissen (GPS oder manuell), Artensteckbriefe offline
- Sammelnamen bei knapper Entscheidung (Nashorn, Löwe), Hinweis ohne Rahmen für Tiere, die der Detektor nicht einrahmt (Krokodil, Schildkröte, Waran)

Statische Seite, keine Build-Schritte: `index.html`, `sw.js`, `manifest.webmanifest`, `vendor/` (TensorFlow.js 4.22, coco-ssd 2.2.3, mobilenet 2.1.1), `models/` (COCO-SSD lite, MobileNet v2, Artenkopf unter `models/head/<version>/`).

## Artenmodell neu trainieren

```
cd training && npm install
python3 download.py            # Fotos von iNaturalist (research grade, CC0/CC-BY/CC-BY-NC), Liste in species.json
node embed.js                  # MobileNet-Embeddings mit demselben Graph wie im Browser
node train.js                  # Kopf trainieren, Bericht in report.json, Export nach ../models/head/<version>/
```

Neue Art: Eintrag in `training/species.json` (Anzeigename, optional Gruppe, iNaturalist-Taxon), dann die drei Schritte ausführen und `HEAD_DIR` in `index.html` auf die neue Version zeigen lassen. Die Fotos selbst bleiben lokal (`training/data/` ist nicht im Repo), die Lizenz- und Urheberangaben stehen in `training/data/manifest.json`.

Version: 1.3.0
