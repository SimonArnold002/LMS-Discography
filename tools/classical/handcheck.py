# Step 0b hand-check: a seeded sample of (work, service) searches. For each, the albums the
# rule KEPT, and the albums it DROPPED that name the composer and share a word with the work
# (where a miss would hide). Top 20 only: what the work page would show first.
#   python3 handcheck.py N [seed] [first]   first = the first work (in wsearch order) to sample from;
#                                           part 1 drew 35 from works 0-398, part 2 65 from 399 on
import json, random, sys
from common import data
from waccept import load, Work, accept, ckey
from wrule import fold
from wsearch import works
C, IDX = load()
pos = {(c['complete_name'], w['title']): i for i, (c, w) in enumerate(works)}
first = int(sys.argv[3]) if len(sys.argv) > 3 else 0
rows = [json.loads(l) for p in ('ws_all_qobuz.jsonl', 'ws_all_tidal.jsonl') for l in open(data(p))]
rows = sorted((r for r in rows if pos[(r['composer'], r['title'])] >= first), key=lambda r: (pos[(r['composer'], r['title'])], r['svc']))
random.seed(int(sys.argv[2]) if len(sys.argv) > 2 else 3)
sample = random.sample(rows, int(sys.argv[1]))
for k, r in enumerate(sample, 1):
    w = Work(r['composer'], r['title'], r['subtitle'], IDX[r['composer']])
    v = [accept(a, C, w) for a in r['items'][:20]]
    print(f"\n#{k} {r['svc']} q={r['q']!r} <- {r['composer'].split()[-1]}: {r['title'][:80]}  ({r['count']} results)")
    for a, x in zip(r['items'][:20], v):
        t = a.replace('\n', ' | ')
        near = x.startswith('no') and x not in ('no:composer', 'no:junk') and (set(ckey(fold(a))) & (w.words - {'in', 'major', 'minor'}))
        if x.startswith('yes') or near:
            print(f"   {'+' if x.startswith('yes') else '-'} {x[:26]:26} {t[:150]}")
