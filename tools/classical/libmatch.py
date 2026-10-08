# Step 0c, part 2: match each library WORK tag to an Open Opus work of its composer (wrule.match).
import json, collections, sys
from common import data, composers
from wrule import match
lib = json.load(open(data('libmap.json')))
oomap = {}
for l in open(data('oomap.jsonl')):
    r = json.loads(l); oomap[r['pick']['id']] = r['complete_name']
oo = {c['complete_name']: c for c in composers()}
works = json.load(open(data('lms_works.json')))
rows = []
for w in works:
    if w['composer'] == '[traditional]': continue            # MB special entity, never a composer page
    m = lib.get(w['composer'], {}).get('mbid')
    if m not in oomap: continue
    c = oo[oomap[m]]
    oos = [(i, x['title'], x['subtitle'], x['searchterms'], x['recommended'], x['popular']) for i, x in enumerate(c['works'])]
    i, why = match(w['work'], oos)
    rows.append({'composer': w['composer'], 'work': w['work'], 'work_id': w['work_id'], 'oo': c['complete_name'],
                 'hit': c['works'][i]['title'] if i is not None else None, 'why': why,
                 'rec': c['works'][i]['recommended'] if i is not None else None})
json.dump(rows, open(data('libmatch.json'), 'w'), ensure_ascii=False, indent=1)
n = len(rows); hit = [r for r in rows if r['hit']]
print(f'works {n}, matched {len(hit)}, unmatched {n - len(hit)}')
print('by rule', collections.Counter(r['why'] for r in rows).most_common())
