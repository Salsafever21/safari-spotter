"""Lädt ein TF.js-Graph-Modell (model.json + Gewichtsdateien) als TensorFlow-GraphDef, ohne die veraltete tensorflowjs-Bibliothek."""
import json, os
import numpy as np
from google.protobuf import json_format
from tensorflow.core.framework import graph_pb2, types_pb2

DTYPES = {'float32': (np.float32, types_pb2.DT_FLOAT), 'int32': (np.int32, types_pb2.DT_INT32), 'bool': (np.bool_, types_pb2.DT_BOOL), 'uint8': (np.uint8, types_pb2.DT_UINT8)}


def load_graph_def(model_dir):
    m = json.load(open(os.path.join(model_dir, 'model.json')))
    topo = m['modelTopology']
    # Ältere TF.js-Konverter schreiben Byte-Attribute (z. B. padding "SAME") als Zahlenlisten statt Base64
    import base64
    def fix_bytes(v):
        if isinstance(v, list) and all(isinstance(x, int) for x in v):
            return base64.b64encode(bytes(v)).decode('ascii')
        return v
    for n in topo.get('node', []):
        for k, v in (n.get('attr') or {}).items():
            if isinstance(v, dict):
                if 's' in v: v['s'] = fix_bytes(v['s'])
                if 'list' in v and isinstance(v['list'], dict) and 's' in v['list']:
                    v['list']['s'] = [fix_bytes(x) for x in v['list']['s']]
    gd = graph_pb2.GraphDef()
    json_format.ParseDict(topo, gd, ignore_unknown_fields=True)
    nodes = {n.name: n for n in gd.node}
    filled = 0
    for group in m['weightsManifest']:
        data = b''.join(open(os.path.join(model_dir, p), 'rb').read() for p in group['paths'])
        off = 0
        for w in group['weights']:
            np_dtype, tf_dtype = DTYPES[w['dtype']]
            count = int(np.prod(w['shape'])) if w['shape'] else 1
            if 'quantization' in w:
                q = w['quantization']; qdt = {'uint8': np.uint8, 'uint16': np.uint16}[q['dtype']]
                raw = np.frombuffer(data[off:off + count * np.dtype(qdt).itemsize], dtype=qdt); off += raw.nbytes
                arr = (raw.astype(np.float32) * q['scale'] + q['min']).astype(np_dtype)
            else:
                arr = np.frombuffer(data[off:off + count * np.dtype(np_dtype).itemsize], dtype=np_dtype); off += arr.nbytes
            node = nodes.get(w['name'])
            if node is None:
                continue
            t = node.attr['value'].tensor
            t.Clear(); t.dtype = tf_dtype
            t.tensor_shape.Clear()
            for d in w['shape']:
                t.tensor_shape.dim.add().size = int(d)
            t.tensor_content = np.ascontiguousarray(arr.reshape(w['shape']) if w['shape'] else arr).tobytes()
            node.attr['dtype'].type = tf_dtype
            filled += 1
    gd = defuse(gd)
    return gd, filled


def defuse(gd):
    """Löst _FusedConv2D / _FusedDepthwiseConv2dNative (BiasAdd, optional Relu/Relu6) in Einzel-Ops auf; coremltools kennt die fusionierten Ops nicht."""
    out = graph_pb2.GraphDef()
    out.library.CopyFrom(gd.library); out.versions.CopyFrom(gd.versions)
    for n in gd.node:
        if n.op not in ('_FusedConv2D', '_FusedDepthwiseConv2dNative'):
            out.node.add().CopyFrom(n); continue
        fused = [x.decode() if isinstance(x, bytes) else x for x in n.attr['fused_ops'].list.s]
        if not fused or fused[0] != 'BiasAdd' or len(fused) > 2 or (len(fused) == 2 and fused[1] not in ('Relu', 'Relu6')):
            raise ValueError('Unbekanntes Fusionsmuster %s bei %s' % (fused, n.name))
        base_op = 'Conv2D' if n.op == '_FusedConv2D' else 'DepthwiseConv2dNative'
        conv = out.node.add(); conv.name = n.name + '/defused_conv'; conv.op = base_op
        conv.input.extend(n.input[:2])
        for k in ('T', 'strides', 'padding', 'dilations', 'data_format', 'explicit_paddings'):
            if k in n.attr: conv.attr[k].CopyFrom(n.attr[k])
        if base_op == 'Conv2D' and 'use_cudnn_on_gpu' in n.attr: conv.attr['use_cudnn_on_gpu'].CopyFrom(n.attr['use_cudnn_on_gpu'])
        bias = out.node.add(); bias.name = n.name if len(fused) == 1 else n.name + '/defused_bias'; bias.op = 'BiasAdd'
        bias.input.extend([conv.name, n.input[2]])
        bias.attr['T'].CopyFrom(n.attr['T'])
        if 'data_format' in n.attr: bias.attr['data_format'].CopyFrom(n.attr['data_format'])
        if len(fused) == 2:
            act = out.node.add(); act.name = n.name; act.op = fused[1]
            act.input.append(bias.name); act.attr['T'].CopyFrom(n.attr['T'])
    return out
