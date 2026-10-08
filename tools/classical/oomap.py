# Step 0a of docs/classical-plan.md: map Open Opus's 220 composers to MusicBrainz ids
# by name + birth year, on the PUBLIC API (1.15 s apart, contact-free User-Agent).
# Output: oomap.jsonl (one line per composer, resumable) and a summary on stdout.
import json, os, sys, urllib.parse
from common import mb_get, composers, data
OUT = data('oomap.jsonl')
comps = composers()
done = {}
if os.path.exists(OUT):
    for l in open(OUT):
        r = json.loads(l); done[r['complete_name']] = r

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')

def search(query, lim=10):
    d = mb_get('artist?query=' + urllib.parse.quote(query) + f'&limit={lim}')
    out = []
    for a in d.get('artists', []):
        ls = a.get('life-span', {}) or {}
        out.append({'id': a['id'], 'name': a['name'], 'score': a.get('score'), 'type': a.get('type'),
                    'begin': ls.get('begin'), 'end': ls.get('end'), 'dis': a.get('disambiguation', ''),
                    'sort': a.get('sort-name', ''), 'tags': sorted(t['name'] for t in a.get('tags', []) or [])})
    return d.get('count', 0), out

def yr(s):
    return (s or '')[:4]

f = open(OUT, 'a')
for c in comps:
    full, short = c['complete_name'], c['name']
    if full in done: continue
    by, dy = yr(c['birth']), yr(c['death'])
    rec = {'complete_name': full, 'name': short, 'birth': by, 'death': dy, 'epoch': c['epoch'],
           'works': len(c['works']), 'rec_works': sum(1 for w in c['works'] if w['recommended'] == '1')}
    passes = []
    # A: full name or alias, born that year
    n, hits = search(f'(artist:"{esc(full)}" OR alias:"{esc(full)}") AND type:person AND begin:{by}')
    passes.append(('A', n, hits))
    if n == 0:
        # B: short name / sort name, born that year
        n, hits = search(f'(artist:"{esc(short)}" OR alias:"{esc(short)}" OR sortname:"{esc(short)}") AND type:person AND begin:{by}')
        passes.append(('B', n, hits))
    if n == 0:
        # C: full name, any year (always doubtful)
        n, hits = search(f'(artist:"{esc(full)}" OR alias:"{esc(full)}") AND type:person')
        passes.append(('C', n, hits))
    p, n, hits = passes[-1]
    rec['pass'] = p
    rec['count'] = n
    rec['cands'] = hits[:5]
    born = [h for h in hits if yr(h['begin']) == by] if p != 'C' else []
    pick = born[0] if born else (hits[0] if hits else None)
    rec['pick'] = pick
    why = []
    if not pick: why.append('no candidate')
    else:
        if p == 'C': why.append('no birth-year match')
        if len(born) > 1: why.append(f'{len(born)} born {by}')
        if dy and yr(pick['end']) and yr(pick['end']) != dy: why.append(f'died {yr(pick["end"])} not {dy}')
        if dy and not yr(pick['end']): why.append('no death year on MB')
        if p == 'B': why.append('found by short name only')
    rec['doubt'] = why
    f.write(json.dumps(rec, ensure_ascii=False) + '\n'); f.flush()
    tag = 'OK ' if not why else 'DOUBT'
    print(f"{tag} {p} {full} ({by}) -> {pick['name'] if pick else '-'} {pick['id'][:8] if pick else ''} {'; '.join(why)}", flush=True)
f.close()
