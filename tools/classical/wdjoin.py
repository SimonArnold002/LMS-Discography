# Joins Wikidata's facts about a composer's works (wikidata_works.json, fetched by wdfetch.py)
# to our Open Opus works, for the works page's second line (docs/classical-plan.md §10): the
# year a work was written and its instrumentation. Used by build_data.py; pure, no I/O.
#
# The join (measured 2026-10-08 on 8 composers; the traps are in the plan):
#   - each Wikidata work is matched to an Open Opus work with the library rule (wrule.match),
#     its label plus its catalogue codes standing in for a library WORK tag;
#   - a match whose catalogue numbers disagree with the Open Opus work's is refused (a dateless
#     K. 364 item let K. 297b's year through otherwise);
#   - several items on one work: the strongest rule wins, then the one whose numbers agree;
#   - the year: precise to the year (never a decade or century: K. 331 is stored "1770s"),
#     within the composer's working life, composition date first, then premiere, then publication;
#   - instrumentation: Wikidata's instrument names tidied, counts kept, ensembles last, and left
#     out when the title already says it (a piano sonata's "piano", a string quartet's strings).
import functools, re
import wrule

# wrule.match recomputes every Open Opus work's features on every call; they are pure and
# signals() only reads them, so a cache changes no answer and cuts Bach's join from 63 s.
wrule.oo_features = functools.lru_cache(maxsize=None)(wrule.oo_features)

RANK = ['cat_full', 'cat_base', 'tn', 'title_eq', 'nick', 'title_in']
MIN_AGE = 4                       # a "composition" dated before the composer was 4 is a wrong item

TIDY = {'continuo group': 'continuo', 'thoroughbass': 'continuo', 'basso continuo': 'continuo',
        'string orchestra': 'strings', 'string section': 'strings', 'string ensemble': 'strings',
        'symphony orchestra': 'orchestra', 'western concert flute': 'flute', 'transverse flute': 'flute',
        'keyboard instrument': 'keyboard', 'mixed choir': 'choir', 'chorus': 'choir', 'choir': 'choir',
        'pipe organ': 'organ', 'second violin': 'violin', 'first violin': 'violin',
        # Measured over all 220 composers (2026-10-08): Wikidata's labels that say a known thing
        # another way ("percussion guitare" is the label of Wikidata's percussion item), or nothing.
        'percussion guitare': 'percussion', 'percussion instrument': 'percussion',
        'string instrument': 'strings', 'natural horn': 'horn', 'baroque flute': 'flute',
        'tenor trombone': 'trombone', 'positive organ': 'organ', 'satb choir': 'choir',
        'sprechgesang': 'voice', 'a clarinet': 'clarinet', 'soprano clarinet': 'clarinet',
        'classical guitar': 'guitar', 'vocal range': 'voice', 'high voice': 'voice', 'choral music': 'choir',
        'stage orchestra': 'orchestra', 'brass instrument': 'brass', 'bowed string instrument': 'strings',
        'electronic musical instrument': 'electronics', 'percussion ensemble': 'percussion',
        'concertino': None, 'ripieno': None, 'musical duo': None, 'musical ensemble': None,
        'chamber music ensemble': None,
        'soloist': None, 'musical instrument': None, 'instrumental music': None,
        'instrumental ensemble': None, 'quintet': None, 'fanfare': None, "trio d'anches": None,
        'trio d’anches': None}
ENSEMBLES = ['choir', 'male choir', 'female choir', "children's choir", "boys' choir", 'orchestra', 'chamber orchestra',
             'wind orchestra', 'brass ensemble', 'jazz band', 'string quartet', 'strings', 'continuo']
NO_COUNT = {'strings', 'continuo'}   # "2 strings" would read as two instruments
MAX_ITEMS = 8                        # a longer line is a full orchestration: noise on a phone (Schnittke 30)

# Other words a title uses for an instrument Wikidata names ("Quiet City, for English horn" ->
# "cor anglais"; a viola da gamba sonata -> "viol").
SYNONYMS = {'cor anglais': [{'english', 'horn'}, {'anglais'}], 'viol': [{'gamba'}], 'bass viol': [{'gamba'}],
            'double bass': [{'contrabass'}, {'double', 'bass'}], 'timpani': [{'kettledrums'}],
            'percussion': [{'percussionist'}, {'percussionists'}]}

# What a title's own words already say.
NAMED = {'keyboard': {'keyboard', 'clavier', 'harpsichord', 'harpsichords', 'piano', 'pianos', 'organ'},
         'voice': {'voice', 'voices', 'song', 'songs', 'lied', 'lieder'},
         'choir': {'choir', 'choirs', 'chorus', 'choral', 'chorale'},
         'strings': {'strings', 'string'},
         'orchestra': {'orchestra', 'orchestral'}}
IMPLIED = [  # (words in the title, instruments they imply)
    ({'symphony'}, {'orchestra'}), ({'sinfonia'}, {'orchestra'}), ({'symphonic'}, {'orchestra'}),
    ({'concerto'}, {'orchestra', 'strings', 'continuo'}), ({'concertos'}, {'orchestra', 'strings', 'continuo'}),
    ({'concerti'}, {'orchestra', 'strings', 'continuo'}), ({'concertante'}, {'orchestra'}),
    ({'string', 'quartet'}, {'violin', 'viola', 'cello'}), ({'string', 'quartets'}, {'violin', 'viola', 'cello'}),
    ({'string', 'trio'}, {'violin', 'viola', 'cello'}), ({'string', 'quintet'}, {'violin', 'viola', 'cello'}),
    ({'piano', 'trio'}, {'piano', 'violin', 'cello'}), ({'piano', 'trios'}, {'piano', 'violin', 'cello'}),
    ({'piano', 'quartet'}, {'piano', 'violin', 'viola', 'cello'}),
    ({'piano', 'quintet'}, {'piano', 'violin', 'viola', 'cello', 'double bass'}),
    ({'violin', 'sonata'}, {'violin', 'piano', 'keyboard'}), ({'cello', 'sonata'}, {'cello', 'piano', 'keyboard'}),
] + [({w}, {'choir', 'orchestra', 'strings', 'continuo', 'organ', 'voice', 'soprano', 'alto', 'tenor', 'bass'})
     for w in ('mass', 'missa', 'requiem', 'oratorio', 'passion', 'cantata', 'cantatas', 'magnificat', 'vespers',
               'vesperae', 'stabat', 'psalm', 'motet', 'motets', 'anthem', 'deum', 'gloria', 'credo', 'dixit',
               'beatus', 'laudate', 'miserere', 'lamentations', 'responsories', 'litaniae', 'confitebor')]
KEYBOARDS = {'harpsichord', 'piano', 'organ', 'clavichord', 'fortepiano', 'celesta'}


def _num(s):
    return re.sub(r'^0+(?=\d)', '', s)


def _numbers(cat_tuples):
    """The numbers of a set of wrule.catalogue() entries: 'k' 364 -> {'364'}."""
    out = set()
    for c in cat_tuples:
        n = c[1].split(':')[-1]
        if n: out.add(_num(n))
    return out


def _wd_numbers(codes):
    """The numbers in Wikidata's catalogue codes, which often come without their catalogue
    ('364', '320d') or with it ('K. 279b', 'BWV 1007')."""
    out = set()
    for c in codes:
        for n in re.findall(r'\d+[a-z]?', wrule.fold(c)): out.add(_num(n))
    return out


def _strength(why):
    for k, r in enumerate(RANK):
        if why.startswith(r): return k
    return len(RANK)


def year(item, birth, death):
    lo = birth + MIN_AGE if birth else None
    hi = death if death else None
    for key in ('inc', 'prem', 'pub'):
        ys = sorted(y for y, p in item.get(key, []) if p >= 9 and (lo is None or y >= lo) and (hi is None or y <= hi))
        if ys: return ys[0]
    return None


def _plural(name):
    head, _, last = name.rpartition(' ')
    last = last + ('es' if re.search(r'(s|x|ch|sh)$', last) else 's')
    return (head + ' ' + last).strip()


def _words(text):
    return set(re.sub(r'[^a-z0-9]+', ' ', wrule.fold(text)).split())


def instruments(raw, title, subtitle=''):
    """Wikidata's instrumentation as a short line, or '' when the title says it all."""
    seen, order = {}, []
    for entry in raw or []:
        name, n = (entry if isinstance(entry, list) else [entry, None])
        n = n if isinstance(n, int) and n > 1 else None
        key = name.strip().lower()
        key = TIDY.get(key, key)
        if not key: continue
        if key not in seen: order.append(key); seen[key] = n or 1
        else: seen[key] = max(seen[key], n or 1)
    if 'keyboard' in seen and KEYBOARDS & set(seen):   # "harpsichord, keyboard" says it twice
        order.remove('keyboard'); del seen['keyboard']
    if not order: return ''
    words = _words(title + ' ' + subtitle)
    implied = set()
    for need, gives in IMPLIED:
        if need <= words: implied |= gives
    def told(k):
        if k in implied: return True
        last = k.split()[-1]
        if {last, last + 's'} & words: return True
        if (NAMED.get(k, set()) | NAMED.get(last, set())) & words: return True
        return any(s <= words for s in SYNONYMS.get(k, []))
    if all(told(k) for k in order): return ''
    plain = [k for k in order if k not in ENSEMBLES]
    ens = [k for k in ENSEMBLES if k in seen]
    if len(plain) + len(ens) > MAX_ITEMS: return ''
    return ', '.join((f'{seen[k]} {_plural(k)}' if seen[k] > 1 and k not in NO_COUNT else k)
                     for k in plain + ens)


# THE TITLE'S OWN SCORING AGAINST WIKIDATA'S (measured over all 220 composers, 2026-10-08):
# an item whose instruments contradict the scoring the title states is another work, or another
# version of it, and is not used (its year either). Two tests, both on solo instruments only:
#   1. the title names instruments, none of them is in Wikidata's list, and Wikidata lists one the
#      title neither names nor implies: Marcello's "Concerto in D minor, for harp and orchestra"
#      against the oboe concerto; Arnold's 2-piano concerto against his viola concerto. A cello
#      sonata whose item lists only the piano is not one (a cello sonata implies its piano).
#   2. the title is a complete chamber group (string quartet, piano trio...) and more of Wikidata's
#      instruments fall outside it than inside: Berg's "Adagio ... for string quartet" against the
#      Adagio for violin, clarinet and piano. Beethoven's op. 11 trio (clarinet, cello, piano) stays.
# A nickname in quotes is not scoring ("Harp" quartet).
SOLO = {'violin', 'viola', 'cello', 'piano', 'flute', 'oboe', 'clarinet', 'bassoon', 'horn', 'trumpet',
        'trombone', 'tuba', 'harp', 'guitar', 'organ', 'harpsichord', 'recorder', 'saxophone', 'lute',
        'mandolin', 'theorbo', 'timpani', 'celesta', 'harmonium', 'accordion', 'bandoneon', 'cimbalom',
        'marimba', 'vibraphone', 'xylophone', 'viol', 'chalumeau', 'piccolo', 'cornet', 'clavichord',
        'euphonium', 'glockenspiel', 'percussion', 'coranglais', 'doublebass'}
_SOLO_ALIAS = {'violoncello': 'cello', 'pianoforte': 'piano', 'fortepiano': 'piano', 'celli': 'cello'}
FULL_GROUPS = [(re.compile(r'\bstring (?:quartet|trio|quintet)s?\b'), {'violin', 'viola', 'cello'}),
               (re.compile(r'\bpiano trios?\b'), {'piano', 'violin', 'cello'}),
               (re.compile(r'\bpiano quartets?\b'), {'piano', 'violin', 'viola', 'cello'}),
               (re.compile(r'\bpiano quintets?\b'), {'piano', 'violin', 'viola', 'cello', 'doublebass'})]


def _solo_words(text):
    t = re.sub(r'[^a-z0-9]+', ' ', text)
    t = re.sub(r'\bviola d[ae] gamba\b|\bgamba\b', ' viol ', t)
    t = re.sub(r'\benglish horn\b|\bcor anglais\b', ' coranglais ', t)
    t = re.sub(r'\bdouble bass(?:es)?\b|\bcontrabass(?:es)?\b', ' doublebass ', t)
    out = set()
    for w in t.split():
        w = _SOLO_ALIAS.get(w, w)
        for s in (w, w[:-2] if w.endswith('es') else None, w[:-1] if w.endswith('s') else None):
            if s in SOLO: out.add(s); break
    return out


def _wd_solo(raw):
    """The solo instruments in Wikidata's list ("bass clarinet" -> clarinet, "oboe d'amore" -> oboe)."""
    out = set()
    for entry in raw or []:
        name = entry[0] if isinstance(entry, list) else entry
        if not isinstance(name, str): continue
        key = name.strip().lower()
        key = TIDY.get(key, key)
        if key and key != 'bass guitar': out |= _solo_words(key)
    return out


def scoring_conflict(raw, title, subtitle=''):
    """True when Wikidata's instruments contradict the scoring the title states."""
    text = re.sub(r'"[^"]*"', ' ', wrule.fold(title + ' , ' + subtitle))
    wd = _wd_solo(raw)
    if not wd: return False
    named = _solo_words(text)
    words = _words(text)
    implied = set()
    for need, gives in IMPLIED:
        if need <= words: implied |= gives
    if words & {'sonata', 'sonatas'} and named - {'piano', 'harpsichord', 'organ', 'clavichord'}:
        implied |= {'piano', 'harpsichord'}           # a violin, flute or cello sonata has its keyboard
    full = set()
    for rx, gives in FULL_GROUPS:
        if rx.search(text): full |= gives
    implied = {('doublebass' if i == 'double bass' else i) for i in implied} | full
    if named and not (named & wd) and (wd - implied - named): return True
    if full:
        inside = wd & (full | named)
        if len(wd - full - named) > len(inside): return True
    return False


def facts(works, wd_items, birth=None, death=None):
    """works: our rows for one composer ({'t','s','q','r','p',...}) in display order.
    wd_items: that composer's Wikidata items (wikidata_works.json). Returns {index: {'y', 'i'}}."""
    oos = [(i, w['t'], w.get('s', ''), w.get('q', ''), '1' if w.get('r') else '0', '1' if w.get('p') else '0')
           for i, w in enumerate(works)]
    best = {}
    for it in wd_items or []:
        if not it.get('l'): continue
        title = it['l'] + (', ' + ', '.join(it['cat']) if it.get('cat') else '')
        i, why = wrule.match(title, oos)
        if i is None: continue
        w = works[i]
        on = _numbers(wrule.catalogue(wrule.fold(w['t'] + ' , ' + w.get('s', ''))))
        wn = _wd_numbers(it.get('cat', [])) | _numbers(wrule.catalogue(wrule.fold(it['l'])))
        if on and wn and not (on & wn): continue      # the numbers say another work
        if scoring_conflict(it.get('instr'), w['t'], w.get('s', '')): continue   # the scoring does
        rank = (_strength(why), 0 if (on and wn) else 1)
        if i not in best or rank < best[i][0]: best[i] = (rank, it)
    out = {}
    for i, (_, it) in best.items():
        w = works[i]
        f = {}
        y = year(it, birth, death)
        if y: f['y'] = y
        line = instruments(it.get('instr'), w['t'], w.get('s', ''))
        if line: f['i'] = line
        if f: out[i] = f
    return out
