# The Perl port's reference answers (docs/classical-plan.md §9.5): wrule.match over the
# library's WORK tags (lms_works.json, libmap.json from step 0), against the SHIPPED works
# files in display order, written to tools/fixtures/classical_parity.json. tools/t_classical.pl
# checks Classical.pm gives the same answer for every one. Run after build_data.py.
import json, os, sys
from common import REPO, data
from wrule import match
from build_data import work_id

OUT = os.path.join(REPO, 'Discography', 'classical')
FIX = os.path.join(REPO, 'tools', 'fixtures', 'classical_parity.json')

comps = json.load(open(os.path.join(OUT, 'composers.json'), encoding='utf-8'))['composers']
lib = json.load(open(data('libmap.json'), encoding='utf-8'))
works = json.load(open(data('lms_works.json'), encoding='utf-8'))
old = {(r['composer'], r['work']): r for r in json.load(open(data('libmatch.json'), encoding='utf-8'))}

rows, same, moved = [], 0, []
for w in works:
    mbid = (lib.get(w['composer']) or {}).get('mbid')
    if w['composer'] == '[traditional]' or mbid not in comps: continue
    ws = json.load(open(os.path.join(OUT, 'works', mbid + '.json'), encoding='utf-8'))['works']
    oos = [(i, x['t'], x.get('s', ''), x.get('q', ''), '1' if x.get('r') else '0', '1' if x.get('p') else '0')
           for i, x in enumerate(ws)]
    i, why = match(w['work'], oos)
    hit = ws[i] if i is not None else None
    rows.append({'mbid': mbid, 'work': w['work'], 'rule': why,
                 'expect': work_id(mbid, {'title': hit['t'], 'subtitle': hit.get('s', ''), 'genre': hit['g']}) if hit else None,
                 'title': hit['t'] if hit else None})
    o = old.get((w['composer'], w['work']))
    if o and (o['hit'] or None) == (hit['t'] if hit else None): same += 1
    elif o: moved.append((w['composer'], w['work'], o['hit'], hit['t'] if hit else None))

os.makedirs(os.path.dirname(FIX), exist_ok=True)
with open(FIX, 'w', encoding='utf-8') as f:
    f.write('[\n' + ',\n'.join(json.dumps(r, ensure_ascii=False) for r in rows) + '\n]\n')
print(f"{len(rows)} library works, matched {sum(1 for r in rows if r['expect'])}; "
      f"same answer as step 0 (raw Open Opus) {same}, different {len(moved)}")
for m in moved: print('  ', ' | '.join(str(x) for x in m))
print('written', FIX)
