import base64
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

    def item(self, key="elefant", status="corrected"):
        return {"status": status, "labelKey": key,
                "img": "data:image/jpeg;base64," + base64.b64encode(self.source_image).decode("ascii")}

    def write_export(self, items):
        self.export.write_text(json.dumps({"app": "Safari Spotter iOS", "items": items}), encoding="utf-8")

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

    def test_conflicting_label_for_same_image_is_skipped(self):
        self.write_export([self.item()])
        import_export(self.export, self.data, {"elefant", "leopard"})
        self.write_export([self.item(key="leopard")])
        counts = import_export(self.export, self.data, {"elefant", "leopard"})
        self.assertEqual(counts["label_konflikt"], 1)
        self.assertFalse((self.data / "leopard").exists())

    def test_invalid_image_is_not_written(self):
        item = self.item()
        item["img"] = "data:image/jpeg;base64,not-base64"
        self.write_export([item])
        counts = import_export(self.export, self.data, {"elefant"})
        self.assertEqual(counts["bild_ungueltig"], 1)
        self.assertFalse((self.data / "elefant").exists())


if __name__ == "__main__":
    unittest.main()
