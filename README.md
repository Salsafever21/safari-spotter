# Safari Spotter

Live-Tiererkennung mit Tracking für Safaris in Südafrika. Läuft komplett im Browser auf dem iPhone (Safari), ohne App Store: Kamera, Erkennung (COCO-SSD) und Artbestimmung (MobileNet v2, ImageNet) laufen auf dem Gerät, nichts verlässt das Telefon.

- Objektiv- und Zoomwahl (Hardware-Zoom, wenn Safari ihn freigibt, sonst digital)
- Tracking mit stabilen IDs und geglätteten Rahmen
- Aufnahme mit eingebranntem Overlay (MP4 in Safari), Teilen in Fotos oder in Dateien speichern
- Sichtungsliste des Tages, teilbar
- Offline nach dem ersten Laden (Service Worker, Modelle lokal gecacht)

Statische Seite, keine Build-Schritte: `index.html`, `sw.js`, `manifest.webmanifest`, `vendor/` (TensorFlow.js 4.22, coco-ssd 2.2.3, mobilenet 2.1.1), `models/`.

Version: 1.0.0
