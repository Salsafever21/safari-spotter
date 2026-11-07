import base64
from hashlib import sha256
from io import BytesIO
import json
from pathlib import Path
import sys
import tempfile
import unittest

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from import_corrections import import_export


class ImportCorrectionsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.data = self.root / "data"
        self.export = self.root / "korrekturen.json"
        image = Image.new("RGB", (224, 224), (80, 120, 40))
        exif = Image.Exif()
        exif[270] = "sensitive source description"
        output = BytesIO()
        image.save(output, format="JPEG", exif=exif)
        self.source_image = output.getvalue()
        self.assertTrue(Image.open(BytesIO(self.source_image)).getexif())

    def item(self, key="elefant", status="corrected", image=None, source_hash=None, t=1_000):
        item = {"status": status, "labelKey": key, "t": t,
                "img": "data:image/jpeg;base64," + base64.b64encode(image or self.source_image).decode("ascii")}
        if source_hash:
            item["sourceJPEGHash"] = source_hash
        return item

    def write_export(self, items, exported="2026-11-06T10:00:00Z"):
        self.export.write_text(json.dumps({"app": "Safari Spotter iOS", "exported": exported,
                                           "items": items}), encoding="utf-8")

    def test_import_is_idempotent_and_strips_metadata(self):
        self.write_export([self.item(), self.item(status="review"), self.item(key="unknown")])
        counts = import_export(self.export, self.data, {"elefant", "leopard"})
        self.assertEqual(counts["uebernommen"], 1)
        self.assertEqual(counts["ungeprüft"], 1)
        self.assertEqual(counts["ohne_klare_art"], 1)
        images = list((self.data / "elefant").glob("correction-*.jpg"))
        self.assertEqual(len(images), 1)
        with Image.open(images[0]) as saved:
            self.assertEqual(saved.size, (224, 224))
            self.assertFalse(saved.getexif())
        manifest = json.loads((self.data / "manifest.json").read_text(encoding="utf-8"))
        self.assertIn("elefant/" + images[0].name, manifest)

        again = import_export(self.export, self.data, {"elefant", "leopard"})
        self.assertEqual(again["duplikat"], 1)
        self.assertEqual(len(list((self.data / "elefant").glob("correction-*.jpg"))), 1)

    def test_newer_label_replaces_old_without_training_both(self):
        self.write_export([self.item()])
        import_export(self.export, self.data, {"elefant", "leopard"})
        self.write_export([self.item(key="leopard")], exported="2026-11-06T11:00:00Z")
        counts = import_export(self.export, self.data, {"elefant", "leopard"})
        self.assertEqual(counts["label_ersetzt"], 1)
        self.assertEqual(counts["uebernommen"], 1)
        manifest = json.loads((self.data / "manifest.json").read_text(encoding="utf-8"))
        self.assertTrue(next(v for k, v in manifest.items() if k.startswith("elefant/")).get("superseded"))
        self.assertFalse(next(v for k, v in manifest.items() if k.startswith("leopard/")).get("superseded", False))
        self.write_export([self.item(key="leopard")], exported="2026-11-06T12:00:00Z")
        self.assertEqual(import_export(self.export, self.data, {"elefant", "leopard"})["duplikat"], 1)
        # Importing an older archive later must not silently undo the newer review.
        self.write_export([self.item()], exported="2026-11-06T11:30:00Z")
        old = import_export(self.export, self.data, {"elefant", "leopard"})
        self.assertEqual(old["label_konflikt"], 1)

    def test_web_and_ios_reencoding_share_original_identity(self):
        self.write_export([self.item()])
        import_export(self.export, self.data, {"elefant"})
        with Image.open(BytesIO(self.source_image)) as original:
            recoded = BytesIO()
            original.save(recoded, format="JPEG", quality=90)
        self.assertNotEqual(self.source_image, recoded.getvalue())
        self.write_export([self.item(image=recoded.getvalue(), source_hash=sha256(self.source_image).hexdigest())])
        counts = import_export(self.export, self.data, {"elefant"})
        self.assertEqual(counts["duplikat"], 1)
        self.assertEqual(len(list((self.data / "elefant").glob("correction-*.jpg"))), 1)

    def test_comment_and_small_image_are_not_imported(self):
        comment = b"GEHEIM 24.5S 31.5E"
        marked = b"\xff\xd8\xff\xfe" + (len(comment) + 2).to_bytes(2, "big") + comment + self.source_image[2:]
        self.write_export([self.item(image=marked)])
        counts = import_export(self.export, self.data, {"elefant"})
        self.assertEqual(counts["uebernommen"], 1)
        saved = next((self.data / "elefant").glob("correction-*.jpg")).read_bytes()
        self.assertNotIn(comment, saved)
        small = BytesIO()
        Image.new("RGB", (96, 96), "green").save(small, format="JPEG")
        self.write_export([self.item(image=small.getvalue())])
        counts = import_export(self.export, self.data, {"elefant"})
        self.assertEqual(counts["bild_ungueltig"], 1)

    def test_invalid_image_is_not_written(self):
        item = self.item()
        item["img"] = "data:image/jpeg;base64,not-base64"
        self.write_export([item])
        counts = import_export(self.export, self.data, {"elefant"})
        self.assertEqual(counts["bild_ungueltig"], 1)
        self.assertFalse((self.data / "elefant").exists())


if __name__ == "__main__":
    unittest.main()
