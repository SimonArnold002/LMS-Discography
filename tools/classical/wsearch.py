# Step 0b of docs/classical-plan.md: collect the RAW Qobuz and TIDAL album-search results
# for Open Opus's recommended works, through the service plugins' own search menus on the
# rig (browse only, the MacBook Pro player). Acceptance is computed offline (waccept.py),
# so the rule can be tuned without searching again. Resumable JSONL.
#   python3 wsearch.py pilot 30     a seeded sample
#   python3 wsearch.py all          every recommended work
import json, os, sys, time, random, re, urllib.parse
from common import rpc, player, composers, data
from wrule import fold, nicknames, title_key, work_head, _generic, CAT_RE, KEY_RE
comps = composers()
works = [(c, w) for c in comps for w in c['works'] if w['recommended'] == '1']

GAP = 0.8   # seconds between searches, per service (two calls each)

def words(s): return re.sub(r'[^a-z0-9]+', ' ', fold(s)).strip()

CATWORD = re.compile(r'^(?:[a-z]{1,6}\d+[a-z]?|wwv|buxwv|bb|sz|hob|woo|p|g|h|fs|m|anh|wq|js|qr)$')

def surname(c):
    """Search words for the composer: 'c p e bach', 'johann strauss', else the short name."""
    n = c['name']
    if ',' in n:                                   # 'Bach, C.P.E.' -> 'c p e bach'
        a, b = n.split(',', 1); return words(b + ' ' + a)
    if re.search(r'\bjr\b', n, re.I):              # 'Strauss Jr' -> 'johann strauss'
        return words(re.sub(r'\bjr\b', '', c['complete_name'], flags=re.I))
    return words(n)

FORM_ONLY = {'symphony', 'concerto', 'sonata', 'suite', 'fantasia', 'fantasy', 'quartet', 'trio', 'quintet',
             'piano', 'violin', 'cello', 'string', 'flute', 'oboe', 'clarinet', 'horn', 'organ', 'harpsichord',
             'overture', 'prelude', 'preludes', 'serenade', 'divertimento', 'partita', 'mass', 'requiem'}

_HEADS = {}
def form_works(c, gen):
    """How many of the composer's Open Opus works have these form words in their head."""
    if c['complete_name'] not in _HEADS:
        _HEADS[c['complete_name']] = [set(title_key(work_head(x['title']))) for x in c['works']]
    return sum(1 for h in _HEADS[c['complete_name']] if all(g in h for g in gen))

def query_for(c, w):
    """v5 (2026-10-03): surname + the work's head (wrule.work_head: no catalogue number, key,
    description or nickname), a count in figures dropped. A generic head ('Concerto for ...') is
    searched by its nickname when it has one and no number ('boccherini fandango'), by its form
    words alone when the composer has three or fewer such works ('stravinsky octet'), else with two
    scoring words ('handel music royal fireworks'). A head of form words only: its nickname, else the
    scoring the full title gives. A nickname counts when it is a name, not a date or a sentence. 'Passion according to St. John' is searched the way
    albums title it, 'St. John Passion'."""
    sur = surname(c)
    t = fold(w['title'])
    wh = work_head(w['title'])
    wh = re.sub(r'^passion according to (st\.? \w+)', r'\1 passion', wh)
    key = lambda s: [x for x in title_key(s) if x not in sur.split() and not CATWORD.match(x)]
    # a count written in figures narrows nothing ('16 Rosenkranz-Sonaten'); one in words is the name ('Four Seasons')
    nocount = lambda k: k[1:] if len(k) > 1 and k[0].isdigit() and re.match(r'\d', wh) else k
    # a nickname is a good search when it is a name, not a date or a sentence ('Wanderer', 'Trout';
    # not 'From the Street, 1 October, 1905')
    nk = sorted(n for n in nicknames(t) if not re.search(r'\d', n) and len(title_key(fold(n))) <= 4)
    gm = re.search(r'\s(?:for|pour|fur|para)\s', wh)
    if gm and _generic(wh[:gm.start()]):
        gen, sc = nocount(key(wh[:gm.start()])), [x for x in key(wh[gm.end():]) if not x.isdigit()]
        if nk and not re.search(r'\bno\.?\s*\d', wh):
            return f"{sur} {words(nk[0])}", 'nickname'
        # the form alone when the composer has three or fewer works of it ('stravinsky octet'),
        # else with two scoring words ('handel music royal fireworks', 'mozart concerto flute harp')
        if form_works(c, gen) <= 3:
            return f"{sur} {' '.join(gen)}".strip(), 'form'
        return f"{sur} {' '.join(gen + sc[:2])}".strip(), 'form + scoring'
    tk = nocount(key(wh)) or key(t)
    form_only = all(x in FORM_ONLY for x in tk)
    has_num = any(x.isdigit() for x in tk)
    if form_only and not has_num and nk:
        return f"{sur} {words(nk[0])}", 'nickname'
    if form_only and not has_num:
        # only form words: the scoring is the title ('Piano Concerto for the Left Hand')
        bare = KEY_RE.sub(' ', CAT_RE.sub(' ', t))
        bare = re.split(r':|;|\s\(|\s-\s|,(?!\s*for\b)', bare, maxsplit=1)[0]
        ext = key(bare)
        if len(ext) > len(tk):
            return f"{sur} {' '.join(ext[:6])}".strip(), 'form + scoring'
    return f"{sur} {' '.join(tk[:6])}".strip(), 'main title'

def qobuz(q):
    enc = urllib.parse.quote(q)
    rpc(['qobuz', 'items', '0', '10', 'item_id:0.0', f'search:{q}', 'menu:1'], player())
    r = rpc(['qobuz', 'items', '0', '200', f'item_id:0.0_{enc}.0', 'menu:1'], player())
    return r.get('count'), [it.get('text', '') for it in r.get('item_loop', [])]

def tidal(q):
    enc = urllib.parse.quote(q)
    rpc(['tidal', 'items', '0', '10', 'item_id:7', f'search:{q}', 'menu:1'], player())
    r = rpc(['tidal', 'items', '0', '200', f'item_id:7_{enc}.3', 'menu:1'], player())
    return r.get('count'), [it.get('text', '') for it in r.get('item_loop', [])]

if __name__ == '__main__':
    mode = sys.argv[1]
    sel = works
    if mode == 'pilot':
        random.seed(1); sel = random.sample(works, int(sys.argv[2]))
    only = sys.argv[3] if len(sys.argv) > 3 else None          # one service per process
    out = data(f'ws_{mode}' + (f'_{only}' if only else '') + '.jsonl')
    done = set()
    if os.path.exists(out):
        for l in open(out):
            r = json.loads(l); done.add((r['svc'], r['composer'], r['title']))
    f = open(out, 'a')
    for i, (c, w) in enumerate(sel):
        q, how = query_for(c, w)
        for svc, fn in (('qobuz', qobuz), ('tidal', tidal)):
            if only and svc != only: continue
            if (svc, c['complete_name'], w['title']) in done: continue
            t0 = time.time()
            try: n, items = fn(q); err = None
            except Exception as e: n, items, err = None, [], str(e)[:200]
            rec = {'svc': svc, 'composer': c['complete_name'], 'name': c['name'], 'title': w['title'],
                   'subtitle': w['subtitle'], 'genre': w['genre'], 'q': q, 'qhow': how, 'count': n,
                   'items': items, 'err': err, 'secs': round(time.time() - t0, 2)}
            f.write(json.dumps(rec, ensure_ascii=False) + '\n'); f.flush()
            print(f"{i+1}/{len(sel)} {svc:5} {n!s:>4} {rec['secs']:5.1f}s  {q}  [{how}]{'  ERR '+err if err else ''}", flush=True)
            time.sleep(GAP)
    f.close()
