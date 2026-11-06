#!/usr/bin/env python3
"""Import reviewed Safari Spotter crops into the local species-training dataset.

Usage: python3 training/import_corrections.py [--out training/data] korrekturen.json [...]
Requires Pillow. The destination is gitignored and images are rewritten without EXIF/GPS.
"""

import argparse
import base64
import binascii
from collections import Counter
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path
import tempfile
import warnings

try:
    from PIL import Image, ImageOps
except ImportError as error:
    raise SystemExit("Pillow fehlt: im Python-venv `pip install Pillow` ausführen.") from error


ROOT = Path(__file__).resolve().parent
MAX_EXPORT_BYTES = 250_000_000
MAX_IMAGE_BYTES = 10_000_000
MAX_ITEMS = 20_000
SOURCE = "safari-spotter-correction"
Image.MAX_IMAGE_PIXELS = 20_000_000


def _write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix=".correction-", suffix=".part", dir=path.parent, delete=False) as output:
        temporary = Path(output.name)
        try:
            output.write(data)
            output.flush()
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
    try:
        temporary.replace(path)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def _decode_image(value: object) -> tuple[str, bytes]:
    prefix = "data:image/jpeg;base64,"
    max_encoded = ((MAX_IMAGE_BYTES + 2) // 3) * 4
    if not isinstance(value, str) or not value.startswith(prefix) or len(value) > max_encoded + len(prefix):
        raise ValueError("JPEG-Daten fehlen oder sind zu gross")
    raw = base64.b64decode(value[len(prefix):], validate=True)
    if not raw or len(raw) > MAX_IMAGE_BYTES:
        raise ValueError("JPEG-Daten fehlen oder sind zu gross")
    with warnings.catch_warnings():
        warnings.simplefilter("error", Image.DecompressionBombWarning)
        with Image.open(BytesIO(raw)) as original:
            original.load()
            if not 32 <= original.width <= 2048 or not 32 <= original.height <= 2048:
                raise ValueError("Bildabmessungen ausserhalb des Korrekturformats")
            image = ImageOps.exif_transpose(original).convert("RGB")
    digest = sha256(image.width.to_bytes(4, "little") + image.height.to_bytes(4, "little") + image.tobytes()).hexdigest()
    output = BytesIO()
    image.save(output, format="JPEG", quality=95, subsampling=0)
    return digest, output.getvalue()


def import_export(source: Path, data_dir: Path, class_keys: set[str]) -> Counter:
    if source.stat().st_size > MAX_EXPORT_BYTES:
        raise ValueError("Korrektur-Export ist zu gross")
    payload = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(payload, dict) or not isinstance(payload.get("items"), list) or len(payload["items"]) > MAX_ITEMS:
        raise ValueError("Korrektur-Export hat kein gültiges items-Feld")
    manifest_path = data_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {}
    if not isinstance(manifest, dict):
        raise ValueError("Trainingsmanifest ist ungültig")
    existing = {entry["sourceHash"]: key.split("/", 1)[0]
                for key, entry in manifest.items()
                if isinstance(key, str) and isinstance(entry, dict) and entry.get("source") == SOURCE
                and isinstance(entry.get("sourceHash"), str)}
    counts = Counter()
    changed = False
    for item in payload["items"]:
        if not isinstance(item, dict) or item.get("status") not in {"confirmed", "corrected"}:
            counts["ungeprüft"] += 1
            continue
        key = item.get("labelKey")
        if not isinstance(key, str) or key not in class_keys:
            counts["ohne_klare_art"] += 1
            continue
        try:
            digest, image = _decode_image(item.get("img"))
        except (ValueError, OSError, binascii.Error, Image.DecompressionBombWarning, Image.DecompressionBombError):
            counts["bild_ungueltig"] += 1
            continue
        if digest in existing:
            counts["duplikat" if existing[digest] == key else "label_konflikt"] += 1
            continue
        relative = f"{key}/correction-{digest[:24]}.jpg"
        destination = data_dir / relative
        if destination.exists() and destination.read_bytes() != image:
            raise ValueError(f"Bestehende Trainingsdatei hat anderen Inhalt: {relative}")
        if not destination.exists():
            _write_atomic(destination, image)
        manifest[relative] = {"source": SOURCE, "sourceHash": digest,
                              "observation": "correction:" + digest[:24]}
        existing[digest] = key
        counts["uebernommen"] += 1
        changed = True
    if changed:
        _write_atomic(manifest_path, (json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("exports", nargs="+", type=Path, help="JSON-Export der geprüften Korrekturen")
    parser.add_argument("--out", type=Path, default=ROOT / "data", help="Lokaler, nicht versionierter Trainingsordner")
    args = parser.parse_args()
    spec = json.loads((ROOT / "species.json").read_text(encoding="utf-8"))
    keys = {item["key"] for item in spec["classes"]}
    total = Counter()
    for source in args.exports:
        counts = import_export(source, args.out, keys)
        total.update(counts)
        print(f"{source.name}: " + ", ".join(f"{key} {value}" for key, value in sorted(counts.items())))
    print("Gesamt: " + ", ".join(f"{key} {value}" for key, value in sorted(total.items())))


if __name__ == "__main__":
    main()
