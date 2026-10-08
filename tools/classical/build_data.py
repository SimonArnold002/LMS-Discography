# Builds the plugin's classical data (docs/classical-plan.md §9.1, decision 1 in §6):
# Open Opus's dump + our corrections (corrections.json) + each composer's MusicBrainz id
# (composers_mb.json, the step-0 table) + Wikidata's facts about the works (wikidata_works.json,
# fetched by wdfetch.py, joined by wdjoin.py: the year written and the instrumentation, §10)
# -> Discography/classical/composers.json and one Discography/classical/works/<mbid>.json per
# composer, already in display order.
#
#   python3 build_data.py              the dump in sweep/classical/work_dump.json (fetched if absent)
#   python3 build_data.py FILE         a dump on disk
#   python3 build_data.py URL          a dump to fetch (https://api.openopus.org/work/dump.json)
#   python3 build_data.py --check ...  report only, write nothing
#
# Then it says what changed against the files already in the repo: composers and works
# added or removed, flags changed, and corrections that no longer apply. A composer with
# no MusicBrainz id stops the build: map it with oomap.py, check the pick by hand, add it
# to composers_mb.json, run again.
import hashlib, json, os, re, sys, urllib.request
from common import REPO, UA, data
from wrule import fold, CAT_RE, CAT_ALIAS
import wdjoin

HERE = os.path.dirname(os.path.abspath(__file__))
WIKIDATA = os.path.join(HERE, 'wikidata_works.json')
OUT = os.path.join(REPO, 'Discography', 'classical')
GENRES = ['Orchestral', 'Chamber', 'Keyboard', 'Stage', 'Vocal']


def load_dump(arg):
    if arg and re.match(r'https?://', arg):
        req = urllib.request.Request(arg, headers={'User-Agent': UA})
        return json.load(urllib.request.urlopen(req, timeout=120)), arg
    path = arg or data('work_dump.json')
    if not os.path.exists(path):
        from common import composers          # fetches the live dump into sweep/classical/
        composers()
    return json.load(open(path, encoding='utf-8')), path


def clean(s):
    return re.sub(r'\s+', ' ', s or '').strip()


def words(s):
    return tuple(re.sub(r'[^a-z0-9]+', ' ', fold(s)).split())


def terms(s):
    return [t for t in (clean(x) for x in (s or '').split(',')) if t]


def natural(s):
    return tuple((0, int(p), '') if p.isdigit() else (1, 0, p) for p in re.findall(r'\d+|[^\d]+', s))


def sort_key(w):
    """Recommended first, then by catalogue number (its first one in the title), then title."""
    t = fold(w['title'])
    cat = None
    for m in CAT_RE.finditer(t):
        num = m.group(3) if m.group(2) else (m.group(4) + ':' + m.group(5) if m.group(5) else m.group(6))
        if num:
            cat = (CAT_ALIAS.get(m.group(1), m.group(1)), natural(num), int(m.group(7) or 0))
            break
    return (0 if w['recommended'] else 1, 0 if cat else 1, cat or ('', (), 0), natural(t), fold(w['subtitle']))


def work_id(mbid, w):
    """A work's id: the first 8 hex of sha1(mbid|title|subtitle|genre), UTF-8. Classical.pm computes the same."""
    return hashlib.sha1('|'.join((mbid, w['title'], w['subtitle'], w['genre'])).encode()).hexdigest()[:8]


def _year(s):
    return int(s[:4]) if s and s[:4].isdigit() else None


def build(dump, corr, mbmap, wd=None):
    """wd: wikidata_works.json's composers ({mbid: {'works': [...]}}), or None for no facts."""
    notes = {'applied': [], 'stale': [], 'repeats': 0, 'repeat_examples': [], 'facts': {'y': 0, 'i': 0, 'of': 0}}
    comps = {}
    for c in dump['composers']:
        ws = [{'title': clean(w['title']), 'subtitle': clean(w.get('subtitle')), 'genre': w['genre'],
               'popular': w.get('popular') == '1', 'recommended': w.get('recommended') == '1',
               'searchterms': terms(w.get('searchterms'))} for w in c['works']]
        comps[clean(c['complete_name'])] = {'c': c, 'works': ws}

    def find(rule, kind):
        comp = comps.get(rule['composer'])
        hits = [w for w in (comp['works'] if comp else []) if w['title'] == rule['title']]
        if not hits:
            notes['stale'].append(f"{kind}: {rule['composer']} / {rule['title']} (not in this dump)")
        return hits

    for r in corr.get('retitle', []):
        for w in find(r, 'retitle'):
            w['title'] = r['to']
            notes['applied'].append(f"retitle: {r['composer']} / {r['title']} -> {r['to']}")
    for r in corr.get('searchterms', []):
        for w in find(r, 'searchterms'):
            new = [t for t in r['add'] if t not in w['searchterms']]
            w['searchterms'] += new
            if new: notes['applied'].append(f"searchterms: {r['composer']} / {r['title']} + {', '.join(new)}")
            else: notes['stale'].append(f"searchterms: {r['composer']} / {r['title']} (already has {', '.join(r['add'])})")
    for r in corr.get('add', []):
        comp = comps.get(r['composer'])
        if not comp:
            notes['stale'].append(f"add: {r['composer']} (no such composer in this dump)"); continue
        w = {'title': r['title'], 'subtitle': r.get('subtitle', ''), 'genre': r['genre'],
             'popular': bool(r.get('popular')), 'recommended': bool(r.get('recommended')),
             'searchterms': list(r.get('searchterms', []))}
        if w['genre'] not in GENRES: sys.exit(f"corrections: unknown genre {w['genre']!r} for {r['title']}")
        if any(words(x['title']) == words(w['title']) for x in comp['works']):
            notes['stale'].append(f"add: {r['composer']} / {r['title']} (Open Opus has it now)"); continue
        comp['works'].append(w)
        notes['applied'].append(f"add: {r['composer']} / {r['title']}")

    # Our corrections to Wikidata's facts: a field of one item left out ("drop"), e.g. an
    # instrumentation Wikidata has wrong. Reported like the others: applied, or stale once the
    # item or the field is gone (then Wikidata itself was mended, and the entry can go).
    if wd is not None and corr.get('wikidata'):
        fix = {r['item']: r for r in corr['wikidata']}
        hit = set()
        def mend(it):
            r = fix.get(it.get('q'))
            if not r: return it
            hit.add(it['q'])
            drop = [f for f in r['drop'] if it.get(f)]
            if not drop:
                notes['stale'].append(f"wikidata: {it['q']} ({it.get('l')}) has no {', '.join(r['drop'])} now")
                return it
            notes['applied'].append(f"wikidata: {it['q']} ({it.get('l')}) {', '.join(drop)} left out")
            return {k: v for k, v in it.items() if k not in drop}
        wd = {m: dict(v, works=[mend(it) for it in (v.get('works') or [])]) for m, v in wd.items()}
        notes['stale'] += [f"wikidata: {q} (not in the snapshot)" for q in fix if q not in hit]

    out = {}
    for name, comp in comps.items():
        if name not in mbmap:
            sys.exit(f"STOP: {name} has no MusicBrainz id. Map it with oomap.py, check the pick by hand, "
                     f"add it to {os.path.join(HERE, 'composers_mb.json')} and run again.")
        mbid = mbmap[name]['mbid']
        kept, seen = [], {}
        for w in comp['works']:
            k = (w['genre'], words(w['title']), words(w['subtitle']))
            if k in seen:                    # Open Opus's repeat: keep the first, with both entries' flags
                first = seen[k]
                first['popular'] |= w['popular']; first['recommended'] |= w['recommended']
                first['searchterms'] += [t for t in w['searchterms'] if t not in first['searchterms']]
                notes['repeats'] += 1
                if len(notes['repeat_examples']) < 5: notes['repeat_examples'].append(f"{name} / {w['title']}")
                continue
            seen[k] = w
            kept.append(w)
        kept.sort(key=sort_key)
        rows, ids = [], set()
        for w in kept:
            wid = work_id(mbid, w)
            if wid in ids: sys.exit(f"STOP: work id {wid} twice for {name} ({w['title']})")
            ids.add(wid)
            row = {'t': w['title']}         # the id is not shipped: Classical.pm computes the same one
            if w['subtitle']: row['s'] = w['subtitle']
            row['g'] = w['genre']
            if w['popular']: row['p'] = 1
            if w['recommended']: row['r'] = 1
            if w['searchterms']: row['q'] = ', '.join(w['searchterms'])
            rows.append(row)
            row['_id'] = wid
        c = comp['c']
        if wd is not None:
            got = wdjoin.facts(rows, (wd.get(mbid) or {}).get('works'), _year(c.get('birth')), _year(c.get('death')))
            for i, f in got.items():
                rows[i].update(f)
                for k in f: notes['facts'][k] += 1
            notes['facts']['of'] += len(rows)
        out[mbid] = {'meta': {'n': clean(c['name']), 'c': name, 'b': (c.get('birth') or '')[:4],
                              'd': (c.get('death') or '')[:4], 'e': c.get('epoch') or '', 'w': len(rows)},
                     'works': rows}
        if mbmap[name].get('mb_name') and mbmap[name]['mb_name'] != name:
            out[mbid]['meta']['m'] = mbmap[name]['mb_name']
    if len(set(m['mbid'] for m in mbmap.values())) != len(mbmap):
        sys.exit('STOP: composers_mb.json gives one MusicBrainz id to two composers')
    return out, notes


def read_old():
    old = {}
    p = os.path.join(OUT, 'composers.json')
    if not os.path.exists(p): return old
    for mbid, meta in json.load(open(p, encoding='utf-8'))['composers'].items():
        wp = os.path.join(OUT, 'works', mbid + '.json')
        ws = json.load(open(wp, encoding='utf-8'))['works'] if os.path.exists(wp) else []
        for w in ws: w['_id'] = work_id(mbid, {'title': w['t'], 'subtitle': w.get('s', ''), 'genre': w['g']})
        old[mbid] = {'meta': meta, 'works': ws}
    return old


def report(old, new):
    lines = []
    for mbid in sorted(set(old) | set(new), key=lambda m: (new.get(m) or old[m])['meta']['c']):
        name = (new.get(mbid) or old[mbid])['meta']['c']
        if mbid not in old: lines.append(f"+ composer {name} ({new[mbid]['meta']['w']} works)"); continue
        if mbid not in new: lines.append(f"- composer {name}"); continue
        o = {w['_id']: w for w in old[mbid]['works']}; n = {w['_id']: w for w in new[mbid]['works']}
        for i in n.keys() - o.keys(): lines.append(f"+ {name} / {n[i]['t']} ({n[i]['g']})")
        for i in o.keys() - n.keys(): lines.append(f"- {name} / {o[i]['t']} ({o[i]['g']})")
        for i in n.keys() & o.keys():
            for f, label in (('p', 'popular'), ('r', 'recommended'), ('q', 'search names'),
                             ('y', 'year'), ('i', 'instrumentation')):
                if o[i].get(f) != n[i].get(f):
                    lines.append(f"~ {name} / {n[i]['t']}: {label} {o[i].get(f, '-')} -> {n[i].get(f, '-')}")
        if [w['_id'] for w in old[mbid]['works'] if w['_id'] in n] != [w['_id'] for w in new[mbid]['works'] if w['_id'] in o]:
            lines.append(f"~ {name}: display order changed")
    return lines


def write(new, source):
    os.makedirs(os.path.join(OUT, 'works'), exist_ok=True)
    comps = {m: new[m]['meta'] for m in sorted(new, key=lambda m: new[m]['meta']['c'])}
    with open(os.path.join(OUT, 'composers.json'), 'w', encoding='utf-8') as f:
        f.write('{"about": ' + json.dumps('Open Opus (openopus.org, CC0) with our corrections; built by '
                                          'tools/classical/build_data.py. n name, c full name, m MusicBrainz '
                                          'name, b/d birth/death year, e epoch, w works. A work: t title, s subtitle, '
                                          'g genre, p popular, r recommended, q search names; y the year written and '
                                          'i its instrumentation, from Wikidata (CC0).') + ',\n')
        f.write('"composers": {\n' + ',\n'.join(json.dumps(m) + ': ' + json.dumps(v, ensure_ascii=False)
                                                for m, v in comps.items()) + '\n}}\n')
    keep = set()
    for mbid, c in new.items():
        keep.add(mbid + '.json')
        with open(os.path.join(OUT, 'works', mbid + '.json'), 'w', encoding='utf-8') as f:
            f.write('{"mbid": ' + json.dumps(mbid) + ', "works": [\n'
                    + ',\n'.join(json.dumps({k: v for k, v in w.items() if k != '_id'}, ensure_ascii=False,
                                             separators=(',', ':'))
                                  for w in c['works']) + '\n]}\n')
    for fn in os.listdir(os.path.join(OUT, 'works')):
        if fn.endswith('.json') and fn not in keep: os.remove(os.path.join(OUT, 'works', fn))


def main():
    args = [a for a in sys.argv[1:] if a != '--check']
    dump, source = load_dump(args[0] if args else None)
    corr = json.load(open(os.path.join(HERE, 'corrections.json'), encoding='utf-8'))
    mbmap = json.load(open(os.path.join(HERE, 'composers_mb.json'), encoding='utf-8'))
    wd = json.load(open(WIKIDATA, encoding='utf-8'))['composers'] if os.path.exists(WIKIDATA) else None
    new, notes = build(dump, corr, mbmap, wd)
    old = read_old()
    print(f"source: {source}")
    print(f"composers {len(new)}, works {sum(len(c['works']) for c in new.values())} "
          f"(Open Opus {sum(len(c['works']) for c in dump['composers'])}), "
          f"repeated entries dropped {notes['repeats']}")
    if wd is None:
        print(f"  NO {WIKIDATA}: no years or instrumentation (run wdfetch.py)")
    else:
        f = notes['facts']
        print(f"  Wikidata: a year for {f['y']} works, instrumentation for {f['i']}, of {f['of']} "
              f"({len(wd)} composers in the snapshot)")
    for l in notes['applied']: print('  applied  ' + l)
    for l in notes['stale']: print('  NO LONGER APPLIES  ' + l)
    changes = report(old, new) if old else ['(no earlier build to compare with)']
    print(f"changes against the files in the repo: {len(changes) if old else 'first build'}")
    for l in changes[:200]: print('  ' + l)
    if len(changes) > 200: print(f'  ... and {len(changes) - 200} more')
    if '--check' in sys.argv: print('--check: nothing written'); return
    write(new, source)
    size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(OUT) for f in fs)
    print(f"written: {OUT} ({size:,} bytes)")


if __name__ == '__main__':
    main()
