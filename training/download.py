#!/usr/bin/env python3
"""Lädt Trainingsfotos von iNaturalist (research grade, offene Lizenzen) für die Klassen in species.json.

Aufruf: python3 download.py [--per-class 220] [--out data]
Legt data/<key>/<photo_id>.jpg an und data/manifest.json mit Lizenz- und Urheberangaben.
"""
import argparse, gzip, json, os, sys, time, random, concurrent.futures as cf
import urllib.request, urllib.parse, urllib.error

API = 'https://api.inaturalist.org/v1'
UA = {'User-Agent': 'SafariSpotter/1.1 training-data (sandro.alves@bluewin.ch)', 'Accept-Encoding': 'gzip'}
ALLOWED_LICENSES = {'cc0', 'cc-by'}
LICENSES = ','.join(sorted(ALLOWED_LICENSES))


def get_json(url, retries=4):
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=30) as r:
                payload = r.read()
                if r.headers.get('Content-Encoding') == 'gzip':
                    payload = gzip.decompress(payload)
                return json.loads(payload)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                time.sleep(10 * (i + 1)); continue
            if e.code >= 500:
                time.sleep(3 * (i + 1)); continue
            raise
        except Exception:
            time.sleep(2 * (i + 1))
    raise RuntimeError('API-Fehler: ' + url)


def resolve_taxon(name):
    d = get_json(API + '/taxa?' + urllib.parse.urlencode({'q': name, 'per_page': 10}))
    res = d.get('results', [])
    exact = [r for r in res if r.get('name', '').lower() == name.lower()]
    r = (exact or res)[0]
    return r['id'], r['name'], r.get('observations_count', 0)


def list_photos(taxon_id, want, sex=None):
    """Sammelt (photo_id, medium_url, license, attribution, obs_id) bis 'want' erreicht ist, max. 1 Foto pro Beobachtung."""
    out, seen_obs, page = [], set(), 1
    params = {'taxon_id': taxon_id, 'quality_grade': 'research', 'photos': 'true', 'photo_license': LICENSES,
              'per_page': min(100, max(20, want)), 'order_by': 'votes', 'order': 'desc'}
    if sex:
        params['term_id'] = 9; params['term_value_id'] = sex
    while len(out) < want and page <= 6:
        params['page'] = page
        d = get_json(API + '/observations?' + urllib.parse.urlencode(params))
        results = d.get('results', [])
        if not results:
            break
        for o in results:
            if o['id'] in seen_obs:
                continue
            seen_obs.add(o['id'])
            for p in o.get('photos', [])[:1]:
                lic = p.get('license_code')
                if lic not in ALLOWED_LICENSES:
                    continue
                url = p['url'].replace('/square.', '/medium.')
                out.append({'photo_id': p['id'], 'url': url, 'license': lic, 'attribution': p.get('attribution', ''), 'obs': o['id']})
        page += 1
        time.sleep(1.1)  # iNat bittet um max. 1 Anfrage pro Sekunde
    return out[:want]


def fetch(item, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 2000:
        return True
    for i in range(3):
        try:
            req = urllib.request.Request(item['url'], headers=UA)
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            if len(data) < 2000 or data[:2] != b'\xff\xd8':
                return False
            temp = dest + '.part'
            with open(temp, 'wb') as f:
                f.write(data)
            os.replace(temp, dest)
            return True
        except Exception:
            time.sleep(1.5 * (i + 1))
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--per-class', type=int, default=220)
    ap.add_argument('--out', default=os.path.join(os.path.dirname(__file__), 'data'))
    ap.add_argument('--only', default='')
    args = ap.parse_args()
    spec = json.load(open(os.path.join(os.path.dirname(__file__), 'species.json')))
    classes = spec['classes']
    if args.only:
        keep = set(args.only.split(','))
        classes = [c for c in classes if c['key'] in keep]
    os.makedirs(args.out, exist_ok=True)
    manifest_path = os.path.join(args.out, 'manifest.json')
    manifest = json.load(open(manifest_path)) if os.path.exists(manifest_path) else {}

    pool = cf.ThreadPoolExecutor(max_workers=8)
    consecutive_api_failures = 0
    for c in classes:
        key = c['key']
        cdir = os.path.join(args.out, key)
        os.makedirs(cdir, exist_ok=True)
        # User corrections are additional examples, not a replacement for licensed iNaturalist photos.
        # Count only photos already committed to the manifest. A stopped download can leave
        # complete JPEGs on disk before the class manifest is written; the next run must revisit them.
        have = len([f for f in os.listdir(cdir) if f.endswith('.jpg') and f[:-4].isdigit()
                    and f"{key}/{f}" in manifest])
        if have >= args.per_class * 0.9:
            print(f'{key:22s} schon {have} Bilder, übersprungen'); continue
        try:
            tid, tname, n_obs = resolve_taxon(c['taxon'])
            items = list_photos(tid, int(args.per_class * 1.15), c.get('sex'))
            consecutive_api_failures = 0
        except Exception as e:
            consecutive_api_failures += 1
            print(f'{key:22s} API-FEHLER {e}', flush=True)
            if consecutive_api_failures >= 3:
                raise RuntimeError('iNaturalist ist wiederholt nicht erreichbar; Download später fortsetzen') from e
            continue
        futs = {pool.submit(fetch, it, os.path.join(cdir, f"{it['photo_id']}.jpg")): it for it in items}
        ok = 0
        for fu in cf.as_completed(futs):
            it = futs[fu]
            if fu.result():
                ok += 1
                manifest[f"{key}/{it['photo_id']}.jpg"] = {'license': it['license'], 'attribution': it['attribution'], 'observation': it['obs'], 'taxon': tname}
        manifest_temp = manifest_path + '.part'
        with open(manifest_temp, 'w') as output:
            json.dump(manifest, output, ensure_ascii=False)
        os.replace(manifest_temp, manifest_path)
        total = len([f for f in os.listdir(cdir) if f.endswith('.jpg') and f[:-4].isdigit()
                     and f"{key}/{f}" in manifest])
        print(f'{key:22s} taxon {tid} ({tname}, {n_obs} Beob.)  gelistet {len(items):3d}  geladen {ok:3d}  total {total:3d}', flush=True)
    pool.shutdown()


if __name__ == '__main__':
    main()
