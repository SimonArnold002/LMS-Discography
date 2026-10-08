# Step 0c, part 1: resolve the library's 72 composer names to MusicBrainz ids the way a page
# does (name or alias, exact name preferred, else a top hit scoring >= 90), then join them
# to the composer table by mbid. Public API, 1.15 s apart.
import json, os, urllib.parse, re
from common import mb_get, rpc, data
from wrule import fold
WORKS = data('lms_works.json')
if not os.path.exists(WORKS):                      # the library's WORK tags, as LMS lists them
    json.dump(rpc(['works', 0, 5000]).get('works_loop', []), open(WORKS, 'w'), ensure_ascii=False, indent=1)
works = json.load(open(WORKS))
names = sorted({w['composer'] for w in works})
OUT = data('libmap.json')
res = json.load(open(OUT)) if os.path.exists(OUT) else {}

def key(s): return re.sub(r'[^a-z0-9]+', ' ', fold(s)).strip()

for n in names:
    if n in res: continue
    q = n.replace('"', '\\"')
    d = mb_get('artist?query=' + urllib.parse.quote(f'(artist:"{q}" OR alias:"{q}") AND type:person') + '&limit=10')
    hits = d.get('artists', [])
    pick, how = None, 'none'
    for a in hits:
        al = [a['name']] + [x.get('name', '') for x in a.get('aliases', []) or []]
        if any(key(x) == key(n) for x in al): pick, how = a, 'exact name/alias'; break
    if not pick and hits and hits[0].get('score', 0) >= 90: pick, how = hits[0], 'top hit'
    res[n] = {'mbid': pick['id'] if pick else None, 'mbname': pick['name'] if pick else None, 'how': how,
              'dis': pick.get('disambiguation', '') if pick else ''}
    json.dump(res, open(OUT, 'w'), ensure_ascii=False, indent=1)
    print(f"{n} -> {res[n]['mbname']} {(res[n]['mbid'] or '')[:8]} [{how}]", flush=True)
