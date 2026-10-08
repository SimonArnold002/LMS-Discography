# Wikidata's facts about the composers' works (docs/classical-plan.md §10): for each composer in
# composers_mb.json, his item (P434 = his MusicBrainz id), every item naming him as composer
# (P86), and of each what the works page can show: composition date (P571), premiere (P1191),
# publication (P577), each with its precision; instrumentation (P870, with quantity P1114);
# librettist (P87); catalogue codes (P528). Wikidata is CC0, like Open Opus.
#
#   python3 wdfetch.py            every composer not yet fetched (resumable)
#   python3 wdfetch.py --again    every composer, fetched again
#   python3 wdfetch.py MBID ...   these composers, fetched again
#
# Raw answers go to sweep/classical/wikidata/<mbid>.json (git-ignored). Then the labels of the
# instruments and librettists, and the snapshot build_data.py reads: wikidata_works.json here,
# only the items carrying a date, an instrumentation or a librettist. Read-only, public API
# (not the query service, which throttles to one request a minute under load); one request
# every 1.5 s, a 429 waited out; the User-Agent carries no e-mail.
import json, os, sys, time, urllib.error, urllib.parse, urllib.request
from common import UA, data

HERE = os.path.dirname(os.path.abspath(__file__))
API = 'https://www.wikidata.org/w/api.php?'
RAW = data('wikidata')
SNAPSHOT = os.path.join(HERE, 'wikidata_works.json')
os.makedirs(RAW, exist_ok=True)
_last = [0.0]


def get(params):
    url = API + urllib.parse.urlencode(dict(params, format='json'))
    for k in range(8):
        wait = 1.5 - (time.time() - _last[0])
        if wait > 0: time.sleep(wait)
        _last[0] = time.time()
        try:
            return json.load(urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': UA}), timeout=60))
        except urllib.error.HTTPError as e:
            if e.code in (429, 503): time.sleep(20 * (k + 1)); continue
            raise
        except urllib.error.URLError:
            time.sleep(10 * (k + 1))
    raise RuntimeError('gave up: ' + url)


def search(stmt):
    """Item ids carrying this statement (CirrusSearch haswbstatement)."""
    out, off = [], 0
    while True:
        r = get({'action': 'query', 'list': 'search', 'srsearch': 'haswbstatement:' + stmt,
                 'srlimit': 500, 'sroffset': off, 'srnamespace': 0})
        out += [h['title'] for h in r['query']['search']]
        if 'continue' not in r: return out
        off = r['continue']['sroffset']


def _vals(cl, p):
    out = []
    for c in cl.get(p, []):
        v = c['mainsnak'].get('datavalue', {}).get('value')
        if v is None: continue
        q = {k: [x.get('datavalue', {}).get('value') for x in xs] for k, xs in c.get('qualifiers', {}).items()}
        out.append((v, q))
    return out


def _date(v):
    return [int(v['time'][1:5]), v['precision']] if isinstance(v, dict) and 'time' in v and v['time'][0] == '+' else None


def _qty(q):
    a = (q.get('P1114') or [None])[0]
    return int(float(a['amount'])) if isinstance(a, dict) and a.get('unit') == '1' else None


def item(q, e):
    cl = e.get('claims', {})
    ids = lambda p: [v['id'] for v, _ in _vals(cl, p) if isinstance(v, dict) and 'id' in v]
    return {'q': q, 'l': e.get('labels', {}).get('en', {}).get('value'),
            'inc': [d for d in (_date(v) for v, _ in _vals(cl, 'P571')) if d],
            'prem': [d for d in (_date(v) for v, _ in _vals(cl, 'P1191')) if d],
            'pub': [d for d in (_date(v) for v, _ in _vals(cl, 'P577')) if d],
            'cat': [v for v, _ in _vals(cl, 'P528') if isinstance(v, str)],
            'instr': [[v['id'], _qty(qq)] for v, qq in _vals(cl, 'P870') if isinstance(v, dict) and 'id' in v],
            'lib': ids('P87')}


def pick_composer(ids):
    """Several items can carry one MusicBrainz id (Debussy: Q4700 and Q121316). The person is the
    one that is an instance of human (Q5); among those, the one with the most sitelinks."""
    if len(ids) < 2: return ids[0] if ids else None
    r = get({'action': 'wbgetentities', 'ids': '|'.join(ids), 'props': 'claims|sitelinks'})
    best = []
    for q, e in r.get('entities', {}).items():
        human = any(c['mainsnak'].get('datavalue', {}).get('value', {}).get('id') == 'Q5'
                    for c in e.get('claims', {}).get('P31', []))
        best.append((human, len(e.get('sitelinks', {})), q))
    best.sort(reverse=True)
    return best[0][2] if best and best[0][0] else None


def fetch(mbid):
    comp = search('P434=' + mbid)
    rec = {'mbid': mbid, 'composer': comp, 'picked': pick_composer(comp), 'works': []}
    if rec['picked']:
        ids = search('P86=' + rec['picked'])
        for i in range(0, len(ids), 50):
            r = get({'action': 'wbgetentities', 'ids': '|'.join(ids[i:i + 50]), 'props': 'labels|claims', 'languages': 'en'})
            rec['works'] += [item(q, e) for q, e in r.get('entities', {}).items() if 'missing' not in e]
    json.dump(rec, open(os.path.join(RAW, mbid + '.json'), 'w', encoding='utf-8'), ensure_ascii=False)
    return rec


def labels(ids):
    path = os.path.join(RAW, 'labels.json')
    lab = json.load(open(path, encoding='utf-8')) if os.path.exists(path) else {}
    need = sorted(set(ids) - set(lab))
    for i in range(0, len(need), 50):
        r = get({'action': 'wbgetentities', 'ids': '|'.join(need[i:i + 50]), 'props': 'labels', 'languages': 'en'})
        for q, e in r.get('entities', {}).items():
            lab[q] = e.get('labels', {}).get('en', {}).get('value')
    json.dump(lab, open(path, 'w', encoding='utf-8'), ensure_ascii=False)
    return lab


def main():
    mbmap = json.load(open(os.path.join(HERE, 'composers_mb.json'), encoding='utf-8'))
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    want = args or [v['mbid'] for v in mbmap.values()]
    for n, mbid in enumerate(want, 1):
        path = os.path.join(RAW, mbid + '.json')
        if os.path.exists(path) and not args and '--again' not in sys.argv: continue
        rec = fetch(mbid)
        name = next((k for k, v in mbmap.items() if v['mbid'] == mbid), mbid)
        flag = '' if len(rec['composer']) == 1 else f"  COMPOSER ITEMS: {rec['composer'] or 'none'} -> {rec['picked']}"
        print(f"{n}/{len(want)} {name}: {len(rec['works'])} works{flag}", flush=True)

    recs = [json.load(open(os.path.join(RAW, v['mbid'] + '.json'), encoding='utf-8'))
            for v in mbmap.values() if os.path.exists(os.path.join(RAW, v['mbid'] + '.json'))]
    lab = labels([i for r in recs for w in r['works'] for i in [x[0] for x in w['instr']] + w['lib']])
    snap = {}
    for r in sorted(recs, key=lambda r: r['mbid']):
        keep = []
        for w in r['works']:
            if not w['l'] or not (w['inc'] or w['prem'] or w['pub'] or w['instr'] or w['lib']): continue
            row = {'q': w['q'], 'l': w['l']}
            for k in ('cat', 'inc', 'prem', 'pub'):
                if w[k]: row[k] = w[k]
            ins = [[lab[i], n] if n else lab[i] for i, n in w['instr'] if lab.get(i)]
            if ins: row['instr'] = ins
            lib = [lab[i] for i in w['lib'] if lab.get(i)]
            if lib: row['lib'] = lib
            keep.append(row)
        snap[r['mbid']] = {'composer': r.get('picked'),
                           'works': sorted(keep, key=lambda x: int(x['q'][1:]))}
    with open(SNAPSHOT, 'w', encoding='utf-8') as f:
        f.write('{"about": ' + json.dumps('Wikidata (CC0) facts about the composers\' works, fetched by '
                                          'tools/classical/wdfetch.py; build_data.py joins them to Open Opus.') + ',\n')
        f.write('"composers": {\n' + ',\n'.join(
            json.dumps(m) + ': {"composer": ' + json.dumps(s['composer']) + ', "works": [\n'
            + ',\n'.join(json.dumps(w, ensure_ascii=False, separators=(',', ':')) for w in s['works']) + ']}'
            for m, s in snap.items()) + '\n}}\n')
    print(f"snapshot: {SNAPSHOT} ({len(snap)} composers, {sum(len(s['works']) for s in snap.values())} items, "
          f"{os.path.getsize(SNAPSHOT):,} bytes)")


if __name__ == '__main__':
    main()
