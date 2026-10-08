# Step 0b numbers: what the work search finds, per service and together.
#   python3 report.py                       ws_all_qobuz.jsonl + ws_all_tidal.jsonl
#   python3 report.py ws_pilot.jsonl        any other collection
import json, sys, collections, statistics
from common import data
from waccept import load, Work, accept

C, IDX = load()
files = sys.argv[1:] or ['ws_all_qobuz.jsonl', 'ws_all_tidal.jsonl']
rows = [json.loads(l) for f in files for l in open(f if '/' in f else data(f))]

per = collections.defaultdict(dict)          # (composer, title) -> svc -> stats
why_all = collections.defaultdict(collections.Counter)
for r in rows:
    w = Work(r['composer'], r['title'], r['subtitle'], IDX[r['composer']])
    v = [accept(a, C, w) for a in r['items']]
    yes = [x for x in v if x.startswith('yes')]
    per[(r['composer'], r['title'])][r['svc']] = {
        'n': r['count'] or 0, 'err': r['err'], 'kept': len(yes),
        'top20': sum(1 for x in v[:20] if x.startswith('yes')),
        'excerpt': sum(1 for x in yes if 'excerpt' in x), 'qhow': r['qhow'], 'q': r['q']}
    for x in yes: why_all[r['svc']][x.split(':', 1)[1].replace(' (excerpt)', '')] += 1

def pct(a, b): return f'{a} ({100 * a / b:.0f}%)' if b else '0'

svcs = sorted({s for d in per.values() for s in d})
print(f'works {len(per)}')
for s in svcs:
    L = [d[s] for d in per.values() if s in d]
    k = [x['kept'] for x in L]; t = [x['top20'] for x in L]
    print(f"\n{s}: searched {len(L)}, errors {sum(1 for x in L if x['err'])}, no results {sum(1 for x in L if not x['n'])}")
    print(f"  works with a recording kept: {pct(sum(1 for x in k if x), len(L))}")
    print(f"  kept per work: median {statistics.median(k)}, mean {statistics.mean(k):.1f}; "
          f"of the first 20 results: median {statistics.median(t)}")
    print(f"  kept 1-4: {sum(1 for x in k if 1 <= x <= 4)}, 5-19: {sum(1 for x in k if 5 <= x <= 19)}, 20+: {sum(1 for x in k if x >= 20)}")
    tot = sum(k); ex = sum(x['excerpt'] for x in L)
    print(f"  albums kept {tot}, of them excerpts/highlights {pct(ex, tot)}")
    print('  why kept:', ', '.join(f'{n} {c}' for n, c in why_all[s].most_common()))
    by = collections.defaultdict(list)
    for x in L: by[x['qhow']].append(x['kept'])
    print('  by wording:', '; '.join(f"{h}: {len(v)} works, {sum(1 for y in v if y)} found, median {statistics.median(v)}"
                                     for h, v in sorted(by.items())))
both = [d for d in per.values() if len(d) == len(svcs)]
either = sum(1 for d in both if any(d[s]['kept'] for s in svcs))
all_ = sum(1 for d in both if all(d[s]['kept'] for s in svcs))
print(f'\nboth services searched: {len(both)}; found on at least one: {pct(either, len(both))}; on all: {pct(all_, len(both))}')
none = [k for k, d in per.items() if len(d) == len(svcs) and not any(d[s]['kept'] for s in svcs)]
print(f'found nowhere: {len(none)}')
if '-n' in sys.argv or True:
    for c, t in none[:60]: print(f'   {c.split()[-1]}: {t[:70]}   q={per[(c, t)][svcs[0]]["q"]!r}')
