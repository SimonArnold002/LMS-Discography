# Step 0c of docs/classical-plan.md: the rule that matches a library WORK tag to an
# Open Opus work of the same composer. Pure functions, no I/O, so it can be measured
# here and ported to Perl unchanged. v2 (2026-10-03): signals scored per candidate,
# ties broken by the weaker signals, Open Opus duplicates collapsed.
import re, unicodedata

DASHES = dict.fromkeys(map(ord, '‐‑‒–—―−'), '-')
QUOTES = {ord(c): '"' for c in '“”„«»'}
QUOTES.update({ord(c): "'" for c in '‘’‚′'})

def fold(s):
    s = (s or '').translate(DASHES).translate(QUOTES)
    s = unicodedata.normalize('NFKD', s)
    s = ''.join(ch for ch in s if not unicodedata.combining(ch))
    return s.lower()

ROMAN = r'(?:x{0,3}(?:ix|iv|v?i{0,3}))'
CATS = ['bwv', 'hwv', 'twv', 'rv', 'kv', 'k', 'hob', 'woo', 'anh', 'd', 'sz', 'bb', 'trv', 'jw',
        'fp', 'wab', 'lw', 's', 'l', 'b', 'h', 'm', 'z', 'wq', 'op', 'bv', 'cd', 'g', 'opus',
        'wwv', 'buxwv', 'js', 'fs', 'jb', 'qr', 'p', 'opp', 'kiv', 'kk']
CAT_ALIAS = {'kv': 'k', 'opus': 'op', 'opp': 'op', 'kiv': 'bv', 'kk': 'k'}
CAT_RE = re.compile(r'(?<![a-z])(' + '|'.join(sorted(CATS, key=len, reverse=True)) + r')\.?\s*'
                    r'(?:(posth)\.?\s*(\d+[a-z]?)?|(' + ROMAN + r'[a-z]?)[:/]\s*(\d+[a-z]?)|(\d+[a-z]?))'
                    r'(?:\s*(?:,\s*)?(?:nos?\.?|nr\.?|number|/)\s*(\d+))?(?:\s*-\s*(\d+))?')

def catalogue(s):
    """{(cat, num), (cat, num, sub)} from a folded string; 'op. posth.' is not a number."""
    out = set()
    for m in CAT_RE.finditer(s):
        cat = CAT_ALIAS.get(m.group(1), m.group(1))
        if m.group(2):                       # 'op. posth.' alone is not a number; 'op. posth. 103' is 103
            if not m.group(3): continue
            num = m.group(3)
        else:
            num = m.group(4) + ':' + m.group(5) if m.group(5) else m.group(6)
        if not num: continue
        out.add((cat, num))
        if m.group(7):
            lo = int(m.group(7)); hi = int(m.group(8)) if m.group(8) else lo
            for n in range(lo, min(hi, lo + 24) + 1): out.add((cat, num, str(n)))
    return out

TYPES = [
    ('piano concerto', r'piano concerto|concerto for piano|klavierkonzert|concerto pour piano'),
    ('violin concerto', r'violin concerto|concerto for violin|violinkonzert|concerto pour violon(?!celle)'),
    ('cello concerto', r'cello concerto|concerto for cello|cellokonzert|concerto pour violoncelle'),
    ('flute concerto', r'flute concerto|concerto for flute'),
    ('oboe concerto', r'oboe concerto|concerto for oboe'),
    ('clarinet concerto', r'clarinet concerto|concerto for clarinet'),
    ('horn concerto', r'horn concerto|concerto for horn'),
    ('trumpet concerto', r'trumpet concerto|concerto for trumpet'),
    ('organ concerto', r'organ concerto|concerto for organ'),
    ('guitar concerto', r'guitar concerto|concerto for guitar'),
    ('piano sonata', r'piano sonata|sonata for piano|klaviersonate'),
    ('violin sonata', r'violin sonata|sonata for violin'),
    ('cello sonata', r'cello sonata|sonata for cello'),
    ('string quartet', r'string quartet|streichquartett|quatuor a cordes'),
    ('piano trio', r'piano trio|klaviertrio'),
    ('piano quartet', r'piano quartet'),
    ('piano quintet', r'piano quintet'),
    ('symphony', r'symphon(?:y|ie|ia)\b|sinfonie\b|sinfonia\b'),
    ('sonata', r'sonata|sonate'),
    ('concerto', r'concerto|konzert'),
    ('nocturne', r'nocturne'), ('etude', r'etude'), ('waltz', r'waltz|valse|walzer'),
    ('mazurka', r'mazurka'), ('prelude', r'prelude'), ('ballade', r'ballade'),
    ('scherzo', r'scherzo'), ('polonaise', r'polonaise'), ('impromptu', r'impromptu'),
    ('rhapsody', r'rhapsod'), ('serenade', r'serenade'),
    ('overture', r'overture|ouverture'), ('requiem', r'requiem'),
    ('partita', r'partita'), ('divertimento', r'divertimento'), ('cantata', r'cantata|kantate'),
]
GENERIC = {'sonata', 'concerto'}

def typenums(s):
    """{(type, n)} for 'Symphony no. 4', 'Piano Concerto No.2', 'Concerto for Piano and Orchestra no. 1'."""
    out = set()
    for t, pat in TYPES:
        for m in re.finditer(r'(?:' + pat + r')(?:\s+(?:for|in|and|pour|fur)\s+[a-z ,&]+?)?' + r'\s*(?:no\.?|nr\.?|number)\s*(\d+)\b', s):
            out.add((t, m.group(1)))
        for m in re.finditer(r'(?:' + pat + r')' + r'\s+(\d+)\b', s):
            out.add((t, m.group(1)))
    spec = {(t, n) for t, n in out if ' ' in t}
    for t, n in list(out):
        if t in GENERIC and any(n == n2 and t in t2 for t2, n2 in spec):
            out.discard((t, n))
    return out

def types_in(s):
    """Specific work types named anywhere (no number needed), for the conflict check."""
    found = {t for t, pat in TYPES if re.search(pat, s)}
    return {t for t in found if t not in GENERIC}

def nicknames(s):
    return {q.strip() for q in re.findall(r'(?:^|(?<=[\s(\[]))["\']([^"\']{3,40})["\'](?=$|[\s),.;:\]])', s)
            if len(q.strip()) >= 3}

KEY_RE = re.compile(r'\bin ([a-g])(?:[ -]?(flat|sharp))?(?: (major|minor))?\b')
def key_of(s):
    m = KEY_RE.search(s)
    if not m: return None
    return (m.group(1), m.group(2) or '', m.group(3) or '')

def keys_conflict(a, b):
    if not a or not b: return False
    if a[0] != b[0] or a[1] != b[1]: return True
    return bool(a[2] and b[2] and a[2] != b[2])

NUMWORDS = {'one': '1', 'two': '2', 'three': '3', 'four': '4', 'five': '5', 'six': '6', 'seven': '7',
            'eight': '8', 'nine': '9', 'ten': '10', 'twelve': '12', 'deux': '2', 'trois': '3',
            'quatre': '4', 'cinq': '5', 'sept': '7', 'douze': '12', 'zwei': '2', 'drei': '3', 'vier': '4',
            'dos': '2', 'tres': '3', 'cuatro': '4', 'cinco': '5', 'siete': '7', 'due': '2', 'tre': '3'}
STOP = {'the', 'a', 'an', 'of', 'in', 'for', 'and', 'from', 'at', 'on', 'to', 'major', 'minor', 'flat',
        'sharp', 'no', 'nos', 'op', 'act', 'le', 'la', 'les', 'l', 'de', 'des', 'du', 'd', 'il', 'der',
        'die', 'das', 'et', 'y', 'e', 'un', 'une'}
FORM_WORDS = {t for t, _ in TYPES} | {'symphony', 'concerto', 'sonata', 'quartet', 'trio', 'quintet',
              'suite', 'preludes', 'nocturnes', 'etudes', 'waltzes', 'mazurkas', 'pieces', 'songs',
              'variations', 'fugue', 'fantasia', 'fantasy', 'piano', 'violin', 'cello', 'string',
              'orchestra', 'march', 'dances', 'dance', 'mass', 'overture', 'concertos', 'sonatas'}

def title_key(s):
    s = CAT_RE.sub(' ', s)
    s = KEY_RE.sub(' ', s)
    s = re.sub(r'[^a-z0-9]+', ' ', s)
    out = []
    for t in s.split():
        t = NUMWORDS.get(t, t)
        if t in STOP or re.fullmatch(r'(?:1[5-9]|20)\d\d', t): continue   # years are not titles
        out.append(t)
    return out

def main_part(s):
    return re.split(r',|:|;|\s\(|\s-\s|\sfor\s', s, maxsplit=1)[0]

def oo_features(title, subtitle='', searchterms=''):
    t = fold(title); st = fold(subtitle)
    mains = [title_key(main_part(t))]
    for alt in (searchterms or '').split(','):
        k = title_key(main_part(fold(alt.strip())))
        if k: mains.append(k)
    return {'cat': catalogue(t + ' , ' + st), 'tn': typenums(t), 'types': types_in(t),
            'nick': {' '.join(title_key(n)) for n in nicknames(t)} - {''},
            'mains': mains, 'key': key_of(t), 'raw': t, 'all': title_key(t), 'sub': st}

def lib_features(title):
    t = fold(title)
    return {'cat': catalogue(t), 'tn': typenums(t), 'types': types_in(t),
            'nick': {' '.join(title_key(n)) for n in nicknames(t)} - {''},
            'main': title_key(main_part(t)), 'all': title_key(t), 'key': key_of(t), 'raw': t}

INSTR = {'violin', 'viola', 'cello', 'piano', 'flute', 'oboe', 'clarinet', 'bassoon', 'horn', 'trumpet',
         'guitar', 'harp', 'organ', 'harpsichord', 'recorder', 'saxophone', 'voice', 'chorus', 'choir'}

def _contains(hay, needle):
    return bool(needle) and (' ' + ' '.join(needle) + ' ') in (' ' + ' '.join(hay) + ' ')

def _nocount(k):
    return k[1:] if k and k[0].isdigit() and len(k) > 1 else k

def _strip_letter(c):
    return (c[0], re.sub(r'[a-z]$', '', c[1])) + c[2:]

def signals(L, O):
    """Which signals one Open Opus work O raises against a library work L."""
    s = {}
    lfull = {c for c in L['cat'] if len(c) == 3}; lbase = {c for c in L['cat'] if len(c) == 2}
    ofull = {c for c in O['cat'] if len(c) == 3}; obase = {c for c in O['cat'] if len(c) == 2}
    conflict = bool(L['types'] and O['types'] and not (L['types'] & O['types']))
    s['type_conflict'] = conflict
    s['cat_full'] = bool(lfull & ofull) and not conflict
    # a set entry (no sub-number) or the same sub-number; never a sibling piece of the set
    s['cat_base'] = bool(lbase & obase) and not conflict and not (lfull and ofull and not (lfull & ofull))
    if not s['cat_base'] and lbase and obase and not conflict:
        s['cat_base'] = any(_strip_letter(a) == _strip_letter(b) and (a[1][-1:].isdigit() or b[1][-1:].isdigit())
                            for a in lbase for b in obase if a[0] == b[0])
    s['tn'] = bool(L['tn'] & O['tn'])
    s['nick'] = any(_contains(L['all'], n.split()) for n in O['nick']) or \
                any(_contains(O['all'], n.split()) for n in L['nick'])
    real = [m for m in O['mains'] if m and not set(m) <= FORM_WORDS]
    lm = _nocount(L['main'])
    s['title_eq'] = bool(lm) and any(_nocount(m) == lm for m in O['mains'] if m)
    s['title_in'] = max((len(' '.join(m)) for m in real
                         if (len(m) >= 2 or len(m[0]) >= 6) and _contains(L['all'], m)), default=0)
    s['key_ok'] = not keys_conflict(L['key'], O['key'])
    s['nick_main'] = any(m[:len(n.split())] == n.split() for n in L['nick'] for m in O['mains'] if m)
    # shared words, minus an instrument the Open Opus title names and the tag does not
    extra_instr = (set(O['all']) & INSTR) - set(L['all'])
    s['overlap'] = len(set(L['all']) & set(O['all'])) - 2 * len(extra_instr)
    lsuite = 'suite' in L['raw']
    s['suite_agree'] = ('suite' in O['raw'] + ' ' + O['sub']) == lsuite
    return s

ORDER = ['cat_full', 'cat_base', 'tn', 'title_eq', 'nick', 'title_in']
TIES = ['nick_main', 'suite_agree', 'overlap', 'rec', 'pop']

def match(lw, oos):
    """lw: library work title. oos: list of (index, title, subtitle, searchterms, recommended).
    Returns (index, rule) or (None, reason)."""
    L = lib_features(lw)
    C = []
    for i, t, st, se, rec, *pop in oos:
        sg = signals(L, oo_features(t, st, se))
        sg['rec'] = rec == '1'; sg['pop'] = bool(pop and pop[0] == '1')
        C.append((i, sg, rec, t))
    amb = None
    for k, sig in enumerate(ORDER):
        hits = [c for c in C if c[1][sig]]
        if sig == 'title_in' and hits:
            best = max(c[1][sig] for c in hits)
            hits = [c for c in hits if c[1][sig] == best]
        if sig in ('tn', 'nick', 'title_eq', 'title_in'):
            hits = [c for c in hits if c[1]['key_ok']]
        if not hits: continue
        if len(hits) == 1: return hits[0][0], sig
        # tie: the weaker signals decide, then the key, then Open Opus duplicates collapse
        for tb in ORDER[k + 1:] + ['key_ok'] + TIES:
            if tb == 'overlap':
                best = max(c[1][tb] for c in hits)
                sub = [c for c in hits if c[1][tb] == best]
                if len(sub) == 1: return sub[0][0], sig + '+' + tb
                hits = sub; continue
            sub = [c for c in hits if c[1][tb]]
            if len(sub) == 1: return sub[0][0], sig + '+' + tb
            if sub: hits = sub
        bags = {tuple(sorted(re.sub(r'[^a-z0-9]+', ' ', fold(c[3])).split())) for c in hits}
        if len(bags) == 1: return hits[0][0], sig + ' (duplicate entries)'
        if sig == 'cat_full':
            amb = amb or sig + ' ambiguous'; continue   # pieces of one set: the set entry may decide
        return None, sig + ' ambiguous'
    return None, amb or 'no rule'


# ---- the head of a work's title: what names the work, without catalogue numbers, key, scoring,
#      nickname or description. One definition for the search words (wsearch.py) and the
#      acceptance rule (waccept.py).
GENERIC_HEAD = {'music', 'musique', 'musik', 'pieces', 'piece', 'songs', 'dances', 'variations', 'studies',
                'works', 'concerto', 'sonata', 'quartet', 'quintet', 'trio', 'fantasia', 'fantasy', 'suite',
                'serenade', 'symphony', 'divertimento', 'octet', 'sextet', 'septet', 'duo', 'concertino',
                'sinfonia', 'overture', 'march', 'canzona', 'toccata', 'prelude', 'fugue', 'konzertstuck',
                'concertstuck', 'mass', 'requiem', 'quartett', 'quatuor', 'sonatina'}
DESCR = re.compile(r',\s*(?:tone poem|symphonic poem|symphonic impressions?|ballet|opera|oratorio|cantata|'
                   r'song cycle|incidental|suite (?:for|in|from)|fantasy for|concert overture|symphony in|'
                   r'collection|psalm|\d+ meditations|meditations|for |pour |fur |\d+ (?:pieces|movements|songs)|'
                   r'scene|drame|opera|motet|anthem|chamber concerto|concerto for|ou |or |oder )')
UPPERCAT = re.compile(r'(?:,\s*|\s)(?!(?:No|Nos|Op|Opus|In|For|And|The|Of|Book|Set|Act|Part|Vol|Suite|Sonata|Symphony|Concerto)\b|An?\s)'
                      r'([A-Z][A-Za-z]{0,4})(?:\.?\s*(?:[IVXivx]+\s*[/:.]?\s*)?\d|\.\s*[IVXLivxl]+\b)')

ARTICLES = ('the', 'a', 'an', 'le', 'la', 'les', 'l', 'die', 'der', 'das', 'il')

HEAD_INSTR = {'piano', 'violin', 'cello', 'flute', 'oboe', 'clarinet', 'horn', 'organ', 'harpsichord', 'guitar',
              'viola', 'trumpet', 'string', 'keyboard', 'harp', 'bassoon', 'wind', 'brass'}

def _generic(text):
    """Only form words, instruments and counts: 'concerto', 'piano concerto', '3 pieces'."""
    ws = [x for x in re.sub(r'[^a-z0-9]+', ' ', text).split() if x not in ARTICLES]
    return bool(ws) and all(x in GENERIC_HEAD or x in HEAD_INSTR or x.isdigit() for x in ws)

def work_head(title):
    """Folded head of a work title: 'Danse macabre, tone poem, op. 40' -> 'danse macabre';
    'Choros no. 10, A.209, "Rasga o Coracao"' -> 'choros no. 10'. A head of generic words keeps its
    scoring: 'Music for 18 Musicians, for 4 ...' -> 'music for 18 musicians', 'Concerto in D minor
    for 3 Harpsichords, BWV.1063' -> 'concerto for 3 harpsichords'. A head ending in a preposition
    goes on into its quoted name: "Musique de theatre pour 'Andromede'" -> 'musique de theatre pour andromede'."""
    t = fold(title)
    cuts = []
    m = UPPERCAT.search(title or '')
    if m: cuts.append((m.start(), 'cat'))
    for kind, r in (('cat', CAT_RE.search(t)), ('key', KEY_RE.search(t)), ('descr', DESCR.search(t)),
                    ('punct', re.search(r':|;|\s\(|\s-\s', t)), ('quote', re.search(r'(?:,\s*|\s)["\'](?=\w)', t)),
                    ('cat', re.search(r'(?:,\s*|\s)[ivx]+/\d+\b', t))):
        if r and r.start() > 0: cuts.append((r.start(), kind))
    cut, kind = min(cuts) if cuts else (len(t), None)
    h = t[:cut]
    quoted = False
    if kind == 'quote' and re.search(r'\b(?:pour|for|de|du|des|to|of|la|le|les|il|der|die|das)\s*$', h):
        later = [c for c, k in cuts if k != 'quote' and c > cut]
        cut = min(later) if later else len(t)
        h = re.sub(r'["\']', '', t[:cut]); quoted = True
    m = re.search(r'\s(?:for|pour|fur|para)\s', h)
    if quoted:
        pass
    elif m and m.start() > 0:
        if not _generic(h[:m.start()]): h = h[:m.start()]
    elif _generic(h):
        # the scoring after a key or a comma: 'Concerto in D minor for 3 Harpsichords', 'Concerto, for violin ...'
        sm = re.search(r'(?:^|[\s,])(?:for|pour|fur|para)\s+(.+)', t[cut:])
        if sm:
            sc = sm.group(1)
            ends = [r.start() for r in (KEY_RE.search(sc), CAT_RE.search(sc), re.search(r'[;:(]|["\']|\s-\s', sc)) if r]
            sc = sc[:min(ends)] if ends else sc
            sc = sc.strip(' ,.')
            if sc: h = h.strip(' ,.') + ' for ' + sc
    return h.strip(' ,.')
