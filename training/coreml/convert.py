#!/usr/bin/env python3
"""Konvertiert die Web-Modelle des Safari Spotters nach Core ML.

Ergebnis (in ../../ios/Models/):
  SafariSpotterSpecies.mlpackage   Bild 224×224 → 65 Artwahrscheinlichkeiten (MobileNetV2-Embedding + Artenkopf, ein Modell, Vision-Classifier)
  SafariSpotterDetector.mlmodel    Bild 300×300 → Rahmen + Klassen (SSDLite MobileNetV2 COCO) mit Core-ML-NMS-Pipeline, Vision-kompatibel
  species-labels.json              Reihenfolge der Klassen (Schlüssel, Anzeigename, Gruppe, Artenschutz)

Aufruf (Python 3.12 mit tensorflow-cpu 2.17, coremltools 8.3, numpy; siehe requirements.txt):
  python convert.py [--check]
--check vergleicht die TF-Rekonstruktion numerisch mit den TF.js-Ausgaben (braucht die Referenzdateien aus check_reference.js).
"""
import argparse, json, os, re, struct, sys
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
OUT = os.path.join(ROOT, 'ios', 'Models')
HEAD = os.path.join(ROOT, 'models', 'head', '1.2.1')
NUM_BOXES, NUM_COCO = 1917, 90


def log(*a):
    print('[convert]', *a, flush=True)


def load_head_weights():
    m = json.load(open(os.path.join(HEAD, 'model.json')))
    manifest = m['weightsManifest'][0]
    raw = b''.join(open(os.path.join(HEAD, p), 'rb').read() for p in manifest['paths'])
    off, out = 0, {}
    for w in manifest['weights']:
        n = int(np.prod(w['shape']))
        out[w['name']] = np.frombuffer(raw[off:off + n * 4], dtype='<f4').reshape(w['shape']).copy()
        off += n * 4
    return out


def species_labels():
    meta = json.load(open(os.path.join(HEAD, 'classes.json')))
    info = json.load(open(os.path.join(ROOT, 'data', 'species-info.json')))
    labels = []
    for c in meta['classes']:
        labels.append({'key': c['key'], 'name': c['name'], 'group': c.get('group'), 'negative': bool(c.get('negative')), 'sensitive': bool(info.get(c['key'], {}).get('sensitive')), 'latin': info.get(c['key'], {}).get('latin')})
    return labels, meta


def coco_labels():
    src = open(os.path.join(ROOT, 'vendor', 'coco-ssd.min.js'), encoding='utf-8').read()
    found = dict((int(i), n) for i, n in re.findall(r'(\d+):\{name:"[^"]*",id:\d+,displayName:"([^"]+)"\}', src))
    if not found:
        found = dict((int(i), n) for i, n in re.findall(r'(\d+):\s*\{\s*name:\s*"[^"]*",\s*id:\s*\d+,\s*displayName:\s*"([^"]+)"', src))
    labels = [found.get(i, 'n/a %d' % i) for i in range(1, NUM_COCO + 1)]
    assert labels[0] == 'person' and 'zebra' in labels, labels[:5]
    return labels


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--skip-detector', action='store_true')
    args = ap.parse_args()
    import tensorflow as tf
    import coremltools as ct
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from tfjs_load import load_graph_def
    os.makedirs(OUT, exist_ok=True)
    labels, meta = species_labels()
    json.dump({'version': meta.get('version'), 'trained': meta.get('trained'), 'valTop1': meta.get('valTop1'), 'classes': labels}, open(os.path.join(OUT, 'species-labels.json'), 'w'), ensure_ascii=False, indent=1)

    # ---- Artenmodell: MobileNetV2 (TF Hub, [0,1]-Eingang) + Kopf ----
    log('lade MobileNetV2-Graph')
    mn_def, nfilled = load_graph_def(os.path.join(ROOT, 'models', 'mobilenet'))
    log('MobileNetV2:', len(mn_def.node), 'Knoten,', nfilled, 'Gewichte gesetzt')
    hw = load_head_weights()
    W1, b1, W2, b2 = (tf.constant(hw['dense_Dense1/kernel']), tf.constant(hw['dense_Dense1/bias']), tf.constant(hw['dense_Dense2/kernel']), tf.constant(hw['dense_Dense2/bias']))

    @tf.function
    def species_fn(image):
        emb = tf.import_graph_def(mn_def, input_map={'images:0': image}, return_elements=['module_apply_default/MobilenetV2/Logits/AvgPool:0'], name='mn')[0]
        x = tf.reshape(emb, [1, 1280])
        x = tf.nn.relu(tf.matmul(x, W1) + b1)
        return tf.nn.softmax(tf.matmul(x, W2) + b2, name='probabilities')

    species_cf = species_fn.get_concrete_function(tf.TensorSpec([1, 224, 224, 3], tf.float32, name='image'))
    log('konvertiere Artenmodell nach Core ML')
    species_ml = ct.convert(
        [species_cf], source='tensorflow',
        inputs=[ct.ImageType(name='image', shape=(1, 224, 224, 3), scale=1.0 / 255.0, color_layout=ct.colorlayout.RGB)],
        classifier_config=ct.ClassifierConfig([c['key'] for c in labels]),
        minimum_deployment_target=ct.target.iOS16, convert_to='mlprogram')
    species_ml.short_description = 'Safari Spotter: 61 südafrikanische Arten plus 4 Haustierklassen (MobileNetV2-Embedding + Kopf v%s)' % meta.get('version')
    species_ml.author = 'Sandro Alves, Safari Spotter'
    species_ml.license = 'Modellgewichte: Apache 2.0 (MobileNetV2), Kopf trainiert mit iNaturalist-Fotos (CC0/CC-BY/CC-BY-NC)'
    species_ml.version = str(meta.get('version'))
    species_ml.input_description['image'] = 'Quadratischer Bildausschnitt des Tiers, RGB'
    species_path = os.path.join(OUT, 'SafariSpotterSpecies.mlpackage')
    species_ml.save(species_path)
    log('gespeichert:', species_path)

    if args.check:
        ref = json.load(open(os.path.join(os.path.dirname(__file__), 'reference.json')))
        img = np.array(ref['species_input'], dtype=np.float32).reshape(1, 224, 224, 3)
        probs = species_cf(tf.constant(img))[0].numpy().reshape(-1)
        want = np.array(ref['species_probs'], dtype=np.float32)
        log('Artenmodell: max. Abweichung zu TF.js %.2e, Top-1 %s / %s' % (np.abs(probs - want).max(), labels[int(probs.argmax())]['name'], labels[int(want.argmax())]['name']))

    if args.skip_detector:
        return

    # ---- Detektor: SSDLite MobileNetV2 COCO, Eingang nach der Vorverarbeitung ([-1,1]), Ausgänge roh, NMS als Core-ML-Pipeline ----
    log('lade COCO-SSD-Graph')
    coco_def, nfilled = load_graph_def(os.path.join(ROOT, 'models', 'cocossd'))
    log('COCO-SSD:', len(coco_def.node), 'Knoten,', nfilled, 'Gewichte gesetzt')
    # 'Preprocessor/sub' durch einen Platzhalter ersetzen und den Vorverarbeitungs-Loop abschneiden
    new_def = tf.compat.v1.GraphDef()
    for n in coco_def.node:
        if n.name == 'Preprocessor/sub':
            ph = new_def.node.add(); ph.name = n.name; ph.op = 'Placeholder'
            ph.attr['dtype'].type = tf.float32.as_datatype_enum
            ph.attr['shape'].shape.CopyFrom(tf.TensorShape([1, 300, 300, 3]).as_proto())
        else:
            new_def.node.add().CopyFrom(n)
    new_def = tf.compat.v1.graph_util.extract_sub_graph(new_def, ['Postprocessor/Slice', 'Postprocessor/ExpandDims_1'])
    log('Detektor-Graph nach Beschnitt:', len(new_def.node), 'Knoten')

    @tf.function
    def det_fn(image):
        scores, boxes = tf.import_graph_def(new_def, input_map={'Preprocessor/sub:0': image}, return_elements=['Postprocessor/Slice:0', 'Postprocessor/ExpandDims_1:0'], name='det')
        scores = tf.reshape(scores, [NUM_BOXES, NUM_COCO])
        boxes = tf.reshape(boxes, [NUM_BOXES, 4])  # ymin, xmin, ymax, xmax (normiert)
        ymin, xmin, ymax, xmax = tf.unstack(boxes, axis=1)
        coords = tf.stack([(xmin + xmax) / 2, (ymin + ymax) / 2, xmax - xmin, ymax - ymin], axis=1)  # x, y, w, h für Core-ML-NMS
        return tf.identity(scores, name='raw_confidence'), tf.identity(coords, name='raw_coordinates')

    det_cf = det_fn.get_concrete_function(tf.TensorSpec([1, 300, 300, 3], tf.float32, name='image'))
    if args.check:
        ref = json.load(open(os.path.join(os.path.dirname(__file__), 'reference.json')))
        img = np.array(ref['det_input'], dtype=np.float32).reshape(1, 300, 300, 3) * (2.0 / 255.0) - 1.0
        sc, co = det_cf(tf.constant(img))
        sc = sc.numpy(); co = co.numpy()
        want_sc = np.array(ref['det_scores'], dtype=np.float32).reshape(NUM_BOXES, NUM_COCO)
        log('Detektor: max. Abweichung der Scores zu TF.js %.2e; beste Box: Klasse %d Score %.3f (TF.js: Klasse %d Score %.3f)' % (np.abs(sc - want_sc).max(), int(sc.max(axis=1).argmax()), sc.max(), int(want_sc.max(axis=1).argmax()), want_sc.max()))

    log('konvertiere Detektor nach Core ML (neuralnetwork)')
    det_ml = ct.convert(
        [det_cf], source='tensorflow',
        inputs=[ct.ImageType(name='image', shape=(1, 300, 300, 3), scale=2.0 / 255.0, bias=[-1.0, -1.0, -1.0], color_layout=ct.colorlayout.RGB)],
        minimum_deployment_target=ct.target.iOS14, convert_to='neuralnetwork')
    spec = det_ml.get_spec()
    # Ausgänge umbenennen und als 2D-Arrays deklarieren
    out_names = [o.name for o in spec.description.output]
    log('Detektor-Ausgänge:', out_names, [list(o.type.multiArrayType.shape) for o in spec.description.output])
    # Reihenfolge der Ausgänge entspricht der TF-Funktion: (Scores, Koordinaten)
    ct.utils.rename_feature(spec, out_names[0], 'raw_confidence')
    ct.utils.rename_feature(spec, out_names[1], 'raw_coordinates')
    for o in spec.description.output:
        shp = list(o.type.multiArrayType.shape)
        del o.type.multiArrayType.shape[:]
        o.type.multiArrayType.shape.extend([NUM_BOXES, NUM_COCO] if o.name == 'raw_confidence' else [NUM_BOXES, 4])
        o.type.multiArrayType.dataType = ct.proto.FeatureTypes_pb2.ArrayFeatureType.DOUBLE
    det_core = ct.models.MLModel(spec)

    # NMS-Modell
    nms_spec = ct.proto.Model_pb2.Model()
    nms_spec.specificationVersion = 5
    for i in range(2):
        d = spec.description.output[i].SerializeToString()
        nms_spec.description.input.add().ParseFromString(d)
        nms_spec.description.output.add().ParseFromString(d)
    nms_spec.description.output[0].name = 'confidence'
    nms_spec.description.output[1].name = 'coordinates'
    for o in nms_spec.description.output:
        ma = o.type.multiArrayType
        del ma.shape[:]
        ma.shapeRange.sizeRanges.add().lowerBound = 0
        ma.shapeRange.sizeRanges[0].upperBound = -1
        ma.shapeRange.sizeRanges.add().lowerBound = NUM_COCO if o.name == 'confidence' else 4
        ma.shapeRange.sizeRanges[1].upperBound = NUM_COCO if o.name == 'confidence' else 4
    nms = nms_spec.nonMaximumSuppression
    nms.confidenceInputFeatureName = 'raw_confidence'
    nms.coordinatesInputFeatureName = 'raw_coordinates'
    nms.confidenceOutputFeatureName = 'confidence'
    nms.coordinatesOutputFeatureName = 'coordinates'
    nms.iouThresholdInputFeatureName = 'iouThreshold'
    nms.confidenceThresholdInputFeatureName = 'confidenceThreshold'
    nms.iouThreshold = 0.5
    nms.confidenceThreshold = 0.25
    nms.pickTop.perClass = False  # wie im Web: klassenunabhängig auf den Höchstwert
    nms.stringClassLabels.vector.extend(coco_labels())
    for name in ('iouThreshold', 'confidenceThreshold'):
        inp = nms_spec.description.input.add(); inp.name = name; inp.type.doubleType.MergeFromString(b''); inp.type.isOptional = True
    nms_model = ct.models.MLModel(nms_spec)

    from coremltools.models import datatypes
    from coremltools.models.pipeline import Pipeline
    pipeline = Pipeline(input_features=[('image', datatypes.Array(3, 300, 300)), ('iouThreshold', datatypes.Double()), ('confidenceThreshold', datatypes.Double())], output_features=['confidence', 'coordinates'])
    pipeline.spec.description.input[0].ParseFromString(spec.description.input[0].SerializeToString())
    pipeline.add_model(det_core)
    pipeline.add_model(nms_model)
    pipeline.spec.description.output[0].ParseFromString(nms_spec.description.output[0].SerializeToString())
    pipeline.spec.description.output[1].ParseFromString(nms_spec.description.output[1].SerializeToString())
    pipeline.spec.description.input[1].shortDescription = '(optional) IoU-Schwelle, Standard 0.5'
    pipeline.spec.description.input[2].shortDescription = '(optional) Score-Schwelle, Standard 0.25'
    pipeline.spec.description.input[1].type.isOptional = True
    pipeline.spec.description.input[2].type.isOptional = True
    pipeline.spec.description.output[0].shortDescription = 'Scores je Rahmen (COCO-Klassen)'
    pipeline.spec.description.output[1].shortDescription = 'Rahmen (x, y, Breite, Höhe) normiert, Ursprung oben links'
    pipeline.spec.description.metadata.shortDescription = 'Safari Spotter Detektor: SSDLite MobileNetV2 (COCO) mit NMS, Vision-kompatibel (VNRecognizedObjectObservation)'
    pipeline.spec.description.metadata.author = 'Sandro Alves, Safari Spotter'
    pipeline.spec.specificationVersion = 5
    det_path = os.path.join(OUT, 'SafariSpotterDetector.mlmodel')
    ct.models.MLModel(pipeline.spec).save(det_path)
    log('gespeichert:', det_path)


if __name__ == '__main__':
    main()
