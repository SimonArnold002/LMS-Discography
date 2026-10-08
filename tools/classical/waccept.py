# Step 0b acceptance, v15 (2026-10-03): does a service album (title + line 2) hold THIS work?
# Offline over the raw results wsearch.py collected, so the rule can be tuned without
# searching again. Tuned on the first 35 hand-checked searches and the works found nowhere,
# measured on 65 more (v14), then fixed for the faults those showed (v15; docs/classical-plan.md §8.2).
import json, re, sys, collections
from common import composers as oo_composers, data
from wrule import fold, catalogue, typenums, nicknames, title_key, work_head, GENERIC_HEAD, NUMWORDS, TYPES, KEY_RE, CAT_RE

def words(s): return re.sub(r'[^a-z0-9]+', ' ', fold(s)).strip()

# ---- one spelling per form word and instrument, whatever the language or number
CANON = {}
for canon, variants in {
    'fantasia': 'fantasia fantasie fantaisie fantasy fantasien fantasias fantasies fantazia',
    'concerto': 'concerto concertos concerti konzert konzerte concierto conciertos',
    'symphony': 'symphony symphonies sinfonie sinfonien symphonie sinfonia sinfonias symphonia',
    'sonata': 'sonata sonatas sonaten sonate sonates sonatina',
    'prelude': 'prelude preludes preludios preludio preludi praeludium praludium',
    'etude': 'etude etudes estudios estudos studies',
    'nocturne': 'nocturne nocturnes notturno',
    'waltz': 'waltz waltzes valse valses walzer valsa valsas vals',
    'mazurka': 'mazurka mazurkas mazurken', 'ballade': 'ballade ballades ballads', 'scherzo': 'scherzo scherzi scherzos',
    'polonaise': 'polonaise polonaises', 'impromptu': 'impromptu impromptus',
    'quartet': 'quartet quartets quartett quartette quatuor quatuors quartetto',
    'trio': 'trio trios', 'quintet': 'quintet quintets quintett quintette quintetto',
    'suite': 'suite suites', 'overture': 'overture overtures ouverture ouvertures',
    'variation': 'variation variations variationen',
    'dance': 'dance dances danse danses danza danzas tanz tanze',
    'song': 'song songs lieder lied chansons canciones', 'mass': 'mass masses messe missa',
    'cantata': 'cantata cantatas kantate kantaten', 'serenade': 'serenade serenades serenata',
    'rhapsody': 'rhapsody rhapsodies rhapsodie rapsodia', 'partita': 'partita partitas',
    'fugue': 'fugue fugues fuga fugen',
    'piano': 'piano klavier', 'violin': 'violin violine violon violino',
    'cello': 'cello violoncello violoncelle', 'flute': 'flute flote flauto', 'organ': 'organ orgel orgue',
    'harp': 'harp harpe arpa harfe', 'grosso': 'grosso grossi', 'orchestra': 'orchestra orchestral orchestre orchester',
    'string': 'string strings streich',
}.items():
    for v in variants.split(): CANON[v] = canon
FORM = {'fantasia', 'concerto', 'symphony', 'sonata', 'prelude', 'etude', 'nocturne', 'waltz', 'mazurka',
        'ballade', 'scherzo', 'polonaise', 'impromptu', 'quartet', 'trio', 'quintet', 'suite', 'overture',
        'variation', 'dance', 'song', 'mass', 'cantata', 'serenade', 'rhapsody', 'partita', 'requiem',
        'piano', 'violin', 'cello', 'flute', 'organ', 'string', 'oboe', 'clarinet', 'horn', 'harpsichord',
        'viola', 'guitar', 'harp', 'trumpet', 'bassoon', 'orchestra', 'chamber', 'concertante', 'divertimento',
        'march', 'piece', 'duo', 'octet', 'sextet', 'septet', 'fugue', 'toccata', 'chorale',
        'passacaglia', 'chaconne', 'ciaccona', 'canon', 'capriccio', 'barcarolle', 'berceuse', 'romance',
        'elegy', 'elegie', 'intermezzo', 'humoresque', 'rondo', 'minuet', 'menuet', 'sinfonietta', 'concertino',
        'invention', 'arabesque', 'bagatelle', 'caprice', 'study', 'adagio', 'allegro', 'andante', 'orchestral',
        'keyboard'}
# the forms whose plural names a set ('Violin Concertos', 'Ballades')
SETFORM = {'concerto', 'symphony', 'sonata', 'prelude', 'etude', 'nocturne', 'waltz', 'mazurka', 'ballade',
           'scherzo', 'polonaise', 'impromptu', 'quartet', 'trio', 'quintet', 'suite', 'overture', 'cantata',
           'partita', 'serenade', 'rhapsody', 'fantasia', 'variation', 'mass'}

INSTR_SET = {'piano', 'violin', 'cello', 'flute', 'oboe', 'clarinet', 'horn', 'organ', 'guitar', 'harp', 'viola',
             'trumpet', 'bassoon', 'harpsichord'}
def instr_set(text):
    return {CANON.get(x, x) for x in words(text).split() if CANON.get(x, x) in INSTR_SET}

INSTR = r'(piano|violin|violon|violino|cello|violoncelle|violoncello|flute|oboe|clarinet|horn|organ|guitar|harp|viola|trumpet|bassoon|harpsichord)'
FORMS_RE = r'(concertos?|concerti|conciertos?|sonatas?|sonates?|quartets?|trios?|quintets?)'

def normalise(s):
    """'Concerto pour violon' / 'Sonatas for Piano' -> 'violon concerto' / 'piano sonatas' (one instrument only;
    a sonata's piano partner goes first: 'Sonates pour violon et piano' -> 'violon sonates')."""
    s = re.sub(r'\b(sonatas?|sonates?|sonaten?)((?:\s+in\s+[a-g](?:[ -]?(?:flat|sharp))?(?:\s+(?:major|minor))?)?)\s+'
               r'(for|pour|per|fur|para|de)\s+' + INSTR + r'\s*(?:,|and|&|et|e|und)\s*(?:piano|klavier|pianoforte)\b',
               r'\1\2 \3 \4', s)
    return re.sub(r'\b' + FORMS_RE + r'((?:\s+in\s+[a-g](?:[ -]?(?:flat|sharp))?(?:\s+(?:major|minor))?)?)\s+(?:for|pour|per|fur|para|de)\s+' + INSTR +
                  r'(?!\s*(?:,|and|&|et|e|und)\s*(?:solo\s+)?' + INSTR + r')'           # one instrument, not a list
                  r'(?=\s*(?:$|[,;:)(/|-]|\s(?:in|and|&|et|no|nos|op|solo)\b|\s+\d))', r'\3 \1\2', s)

def ckey(s):
    """Canonical title words: catalogue, key and years removed, form words in one spelling."""
    out = []
    for t in title_key(normalise(s)):
        t = CANON.get(t, t)
        if t.endswith('s') and t[:-1] in FORM: t = t[:-1]
        if t not in ('no', 'nr', 'n', 'nos'): out.append(t)
    return out

def without(toks, phrases):
    """The words left once every listed phrase is taken out."""
    out = list(toks)
    for p in phrases:
        i = 0
        while i + len(p) <= len(out):
            if out[i:i + len(p)] == p: del out[i:i + len(p)]
            else: i += 1
    return out

def contains(hay, needle):
    return bool(needle) and (' ' + ' '.join(needle) + ' ') in (' ' + ' '.join(hay) + ' ')

# ---- keys in English and German ('in F minor', 'F-Dur', 'f-moll', 'Es-Dur')
DE_KEY = re.compile(r'\b([a-h])(is|es|s)?-(dur|moll)\b')
def album_keys(s):
    out = set()
    for m in KEY_RE.finditer(s):
        out.add((m.group(1), m.group(2) or '', m.group(3) or ''))
    for m in DE_KEY.finditer(s):
        n = {'h': 'b', 'b': 'b'}.get(m.group(1), m.group(1))
        acc = {'is': 'sharp', 'es': 'flat', 's': 'flat'}.get(m.group(2) or '', '')
        if m.group(1) == 'b' and not m.group(2): acc = 'flat'          # German B = B flat
        out.add((n, acc, 'major' if m.group(3) == 'dur' else 'minor'))
    return out

def key_eq(a, b):
    return a[0] == b[0] and a[1] == b[1] and (not a[2] or not b[2] or a[2] == b[2])

# ---- composers: a bare surname is the main composer of that name; the others need initials
# words of sleep/relaxation playlists; not 'sleeping' (The Sleeping Beauty)
JUNK = {'baby', 'babies', 'lullaby', 'lullabies', 'bedtime', 'sleep', 'spa', 'yoga', 'relax', 'relaxing',
        'relaxation', 'meditation', 'studying', 'focus', 'kids', 'karaoke', 'ringtone', 'ringtones', 'workout',
        'lofi', 'chill', 'chillout', 'massage', 'hypnosis', 'newborn', 'pregnancy'}
ENSEMBLE = r'(?:string\s+)?(?:quartet|quartett|quatuor|trio|quintet|ensemble|orchestra|orchester|orchestre|consort|choir|chor|chorus|society|players|collegium|sinfonietta|band|duo|soloists|festival)\b'

def vowelfold(w):
    return w.replace('ae', 'a').replace('oe', 'o').replace('ue', 'u')

class Composers:
    def __init__(self, comps):
        self.by = {}
        sur = collections.defaultdict(list)
        for c in comps:
            n = c['name']
            if ',' in n:
                a, b = n.split(',', 1)
                last, marks = words(a), [words(b) + ' ' + words(a), words(c['complete_name'])]
            elif re.search(r'\bjr\b', n, re.I):
                last = words(re.sub(r'\bjr\b', '', n, flags=re.I))
                first = words(re.sub(r'\bjr\b', '', c['complete_name'], flags=re.I))
                marks = [first, 'j ' + last, last + ' ii', last + ' jr', last + ' son', last + ' sohn']
            else:
                last, marks = words(n), []
            self.by[c['complete_name']] = {'last': last, 'marks': marks}
            sur[last].append(c['complete_name'])
        self.siblings = {k: v for k, v in sur.items() if len(v) > 1}
        self.surnames = {vowelfold(w) for c in comps for w in words(c['complete_name']).split()[-1:]}
        self.surnames |= {vowelfold(w) for c in comps for w in words(c['name'].split(',')[0]).split()[-1:]}

    def mentions(self, complete, text):
        """'yes' / 'other' (a sibling: C.P.E. for J.S. Bach) / 'no', for one piece of album text.
        A surname used as a first name ('Arnold Schonberg') or as an ensemble's ('Bartok Quartet',
        'Beethoven Trio Ravensburg') is not a mention."""
        me = self.by[complete]; raw = fold(text); t = ' ' + words(text) + ' '; sq = t.replace(' ', '')
        def hit(w):
            for m in re.finditer(r'(?<![a-z])' + re.escape(w).replace(r'\ ', r'[\W_]+') + r'(?![a-z])', raw):
                after = raw[m.end():]
                if re.match(r'\s+' + ENSEMBLE, after): continue
                nxt = re.match(r' ([a-z]+)', after)
                if not me['marks'] and ' ' not in w and nxt and vowelfold(nxt.group(1)) in self.surnames \
                        and nxt.group(1) != w: continue
                return True
            return len(w) > 6 and w.replace(' ', '') in sq
        if me['marks']:
            return 'yes' if any(hit(m) for m in me['marks']) else 'no'
        if not hit(me['last']): return 'no'
        for other in self.siblings.get(me['last'], []):
            if other != complete and any(hit(m) for m in self.by[other]['marks']): return 'other'
        return 'yes'

    def labels(self, at):
        """Composer labels in a title: the text before a colon at the start of each part, when it
        holds a known surname ('Mahler: Symphony No. 2 - Sibelius: ...')."""
        out = []
        for part in SEGS.split(at):
            m = re.match(r'\s*([^:]{2,60}):', part)
            if m and any(vowelfold(x) in self.surnames for x in words(m.group(1)).split()):
                out.append(m.group(1))
        return out

# ---- the work, once
class Work:
    def __init__(self, comp, title, subtitle, siblings):
        t = fold(title)
        self.comp = comp
        self.raw = t
        self.cat = catalogue(t + ' , ' + fold(subtitle))
        m = re.match(r'cantata no\.?\s*(\d+)', t)
        if comp == 'Johann Sebastian Bach' and m: self.cat.add(('bwv', m.group(1)))   # Bach's cantatas: no. = BWV
        self.tn = typenums(normalise(t))
        self.key = next(iter(album_keys(t)), None) if KEY_RE.search(t) else None
        self.nick = [ckey(n) for n in nicknames(t)]
        self.nick = [n for n in self.nick if n and len(' '.join(n)) >= 4]
        hk = ckey(work_head(title))
        self.count = hk[0] if hk and hk[0].isdigit() and len(hk) > 1 else None
        self.head = hk[1:] if self.count else hk
        self.phrase = [x for x in self.head if not x.isdigit()]
        self.num = next((x for x in self.head if x.isdigit()), None)
        self.form_only = bool(self.head) and all(x in FORM or x.isdigit() for x in self.head)
        self.real = [x for x in self.head if x not in FORM and not x.isdigit()]
        self.distinct = len(self.real) >= 2 or (len(self.real) == 1 and len(self.real[0]) >= 7)
        self.words = set(ckey(t))
        self.shared = siblings.get(tuple(self.head), 0)
        self.unique = self.shared <= 1
        # how many of the composer's works share this title once numbers go: 3 or fewer is a small set
        self.set_size = siblings.get(('#',) + tuple(self.phrase), 0)
        # works with this head that are OTHER works: they differ in key, number, count, opus or a
        # number within a set ('Concerto Grosso op. 6 no. 3' / 'no. 8'), not just in description or
        # scoring ('Der Rosenkavalier' / its waltz sequences, 'Fratres' / its versions)
        me = signature(t, hk)
        self.rivals = sum(1 for sg in siblings.get(('@sig',) + tuple(self.head), []) if differs(me, sg))
        # Open Opus lists some works twice ('Sinfonietta, FP141' and 'Sinfonietta, for chamber orchestra,
        # FP141'; C.P.E. Bach's cello concertos as Wq.170-172 and as nos. 1-3): count works, not entries
        same_head = siblings.get(('@sig',) + tuple(self.head), [])
        self.unique = self.unique or clusters(same_head) <= 1
        # the one Open Opus recommends among works of one title: what a plain title most likely means
        # ('Liszt: Les Preludes' = S.97, not the piano S.637; 'Mendelssohn: Violin Concerto' = op. 64)
        self.canonical = any(sg['t'] == t and sg['rec'] for sg in same_head) and \
                         sum(1 for sg in same_head if sg['rec']) == 1 and \
                         not (set(self.head) & COLLECTION) and \
                         clusters(same_head) <= 3                    # not one of Vivaldi's 39 bassoon concertos
        self.set_size = min(self.set_size, clusters(siblings.get(('@psig',) + tuple(self.phrase), [])) or self.set_size)
        self.instr = instr_set(t)
        self.longer = sorted((list(p) for p in siblings.get(('@phr',), ())
                              if self.phrase and len(p) > len(self.phrase) and contains(list(p), self.phrase)),
                             key=len, reverse=True)
        # a generic head with its scoring kept ('Concerto for Flute and Harp', 'Music for Strings,
        # Percussion and Celesta', 'Serenade for Tenor, Horn, and Strings')
        self.gen = self.scoring = None
        wh = work_head(title)
        gm = re.search(r'\s(?:for|pour|fur|para)\s', wh)
        if gm:
            g = ckey(wh[:gm.start()])
            g = g[1:] if g and g[0].isdigit() and len(g) > 1 else g
            part = wh[gm.end():]
            nm = re.search(r'\bno\.?\s*(\d+)', part)
            sc = ckey(re.sub(r'\bno\.?\s*\d+.*$', '', part))
            if g and sc:
                self.gen, self.num = g, (nm.group(1) if nm else None)
                self.scoring = [x for x in sc if not x.isdigit()]
                self.scount = [(sc[i], sc[i + 1]) for i in range(len(sc) - 1) if sc[i].isdigit() and not sc[i + 1].isdigit()]
                self.req = [x for x in self.scoring if x not in OPTIONAL] or self.scoring[:1]
                heads = siblings.get(('@heads',), [])
                self.gen_n = sum(1 for h in heads if all(g in h for g in self.gen))
                self.gen_unique = self.gen_n <= 1
                self.gen_s1_n = sum(1 for h in heads if all(g in h for g in self.gen) and self.scoring[0] in h)
                self.abbrev_ok = self.gen_s1_n <= 1

# words that name a collection, never one work a plain title could mean
COLLECTION = {'song', 'songs', 'lied', 'lieder', 'piece', 'pieces', 'dance', 'dances', 'waltz', 'march', 'chorale',
              'motet', 'madrigal', 'aria', 'duet', 'canon', 'study', 'etude', 'bagatelle', 'minuet', 'work', 'works'}
OPTIONAL = {'orchestra', 'string', 'strings', 'continuo', 'basso', 'ensemble', 'piano', 'instrument', 'instruments'}

def signature(t, hk):
    """What tells one work from another of the same head: key, number, count, opus, set number."""
    cat = catalogue(t)
    return {'key': next(iter(album_keys(t)), None) if KEY_RE.search(t) else None,
            'num': next((x for x in (hk[1:] if hk and hk[0].isdigit() and len(hk) > 1 else hk) if x.isdigit()), None),
            'count': hk[0] if hk and hk[0].isdigit() and len(hk) > 1 else None,
            'op': {re.sub(r'[a-z]$', '', c[1]) for c in cat if c[0] == 'op' and len(c) == 2},
            'sub': {c[2] for c in cat if len(c) == 3},
            'cat': {(c[0], re.sub(r'(?<=\d)[a-z]+$', '', c[1])) for c in cat if len(c) == 2}}

def same_work(a, b):
    """Two Open Opus entries for one work, for counting works: they share a catalogue number
    ('Sinfonietta, FP141' twice; 'Les Preludes, S.97' and 'S97/R414'), or nothing tells them apart
    and nothing at all is known of either. Missing data is not sameness: Chopin's 'Nocturnes, op. 9'
    and 'Nocturne in C minor, B.108' are two works."""
    if differs(a, b): return False
    if a['cat'] & b['cat']: return True
    blank = lambda s: not (s['key'] or s['num'] or s['count'] or s['cat'])
    return blank(a) and blank(b)

def differs(a, b):
    if a['key'] and b['key'] and not key_eq(a['key'], b['key']): return True
    for f in ('num', 'count'):
        if a[f] and b[f] and a[f] != b[f]: return True
    for f in ('op', 'sub'):
        if a[f] and b[f] and not (a[f] & b[f]): return True
    return False

def clusters(sigs):
    """How many different works a list of signatures holds."""
    reps = []
    for sg in sigs:
        if not any(same_work(sg, r) for r in reps): reps.append(sg)
    return len(reps)

def head_index(comp):
    """Per composer: how many works share each head (Open Opus repeats counted once), their
    signatures, and every head's words."""
    idx = collections.Counter(); sigs = collections.defaultdict(list); heads = []
    titles = {}; rec = collections.defaultdict(bool); phr = set()
    for w in comp['works']:
        titles.setdefault(fold(w['title']).strip(), w['title'])
        rec[fold(w['title']).strip()] |= w['recommended'] == '1'
    for t in sorted(titles):
        hk = ckey(work_head(titles[t]))
        hk2 = hk[1:] if hk and hk[0].isdigit() and len(hk) > 1 else hk
        idx[tuple(hk2)] += 1
        idx[('#',) + tuple(x for x in hk2 if not x.isdigit())] += 1
        sigs[('@sig',) + tuple(hk2)].append(dict(signature(t, hk), rec=rec[t], t=t))
        sigs[('@psig',) + tuple(x for x in hk2 if not x.isdigit())].append(signature(t, hk))
        heads.append(set(hk2))
        phr.add(tuple(x for x in hk2 if not x.isdigit()))
    out = dict(idx); out.update(sigs); out[('@heads',)] = heads; out[('@phr',)] = phr
    return out

# ---- numbers given for a form in a title
PLURAL = {'symphony': r'symphon(?:y|ies|ie|ien|ia)|sinfonien|sinfonie|sinfonia',
          'piano concerto': r'piano concert(?:os?|i)|klavierkonzerte?',
          'violin concerto': r'violin concert(?:os?|i)|violinkonzerte?',
          'cello concerto': r'cello concert(?:os?|i)|cellokonzerte?',
          'string quartet': r'string quartets?|streichquartette?|quatuors? a cordes',
          'piano sonata': r'piano sonat(?:as?|es?|en)|klaviersonaten?',
          'piano trio': r'piano trios?|klaviertrios?',
          'cantata': r'cantatas?|kantaten?'}
ORDINAL = {'first': '1', 'second': '2', 'third': '3', 'fourth': '4', 'fifth': '5', 'sixth': '6',
           'seventh': '7', 'eighth': '8', 'ninth': '9', 'tenth': '10'}
HARD = re.compile(r'\s[-–/|]\s|;|\s/|/\s|\s\|\s|(?<=[a-z)])/(?=[a-z(])')
SEGS = re.compile(r'\s[-–/|&+]\s|;|\s/|/\s|\s\|\s|(?<=[a-z)])/(?=[a-z(])|,\s+(?=(?!(?:[a-z]\.\s*)+:)[a-z][a-z .\'\-]{1,40}:)')
NOISE = re.compile(r'\b(?:vol(?:ume)?|cd|disc|part|book|act|livre|teil|heft)\.?\s*\d+(?:\s*:)?|\(\d{4}\)|\b(?:1[5-9]|20)\d\d\b|\b\d+\.?\s*(?:movement|mvt|satz|mov)\b')
# the words that start another work in a list; an instrument or 'orchestra' is scoring, not a new work
NONFORM = {'piano', 'violin', 'cello', 'flute', 'organ', 'string', 'harp', 'orchestra', 'oboe', 'clarinet', 'horn',
           'guitar', 'viola', 'trumpet', 'bassoon', 'harpsichord', 'chamber', 'orchestral', 'grosso'}
FORMWORD = re.compile(r'\b(?:' + '|'.join(sorted({w for w in set(CANON) | FORM if CANON.get(w, w) not in NONFORM}, key=len, reverse=True)) + r')\b')

def form_pattern(phrase_or_type):
    if phrase_or_type in PLURAL: return PLURAL[phrase_or_type]
    if phrase_or_type in dict(TYPES): return dict(TYPES)[phrase_or_type]
    toks = [x for x in phrase_or_type.split() if x]
    alt = lambda w: '(?:' + '|'.join(re.escape(v) for v in [k for k, c in CANON.items() if c == w] + [w]) + r')s?'
    return r'\s+(?:and|&)?\s*'.join(alt(w) for w in toks)

def plain_form(tw, w):
    """The form word stands alone: not 'String Trio' or 'Scherzo & Trio' for a Piano Trio."""
    f = w.phrase[-1]
    for i, x in enumerate(tw):
        if x == f and i and (tw[i - 1] in FORM or tw[i - 1] in INSTR_SET) and tw[i - 1] not in w.phrase: return False
    return True

def other_number(reg, w):
    """The album gives a catalogue number of the work's own system, and not the work's."""
    base = lambda c: (c[0], re.sub(r'(?<=\d)[a-z]+$', '', c[1]))
    ours = {base(c) for c in w.cat if len(c) == 2}
    theirs = {base(c) for c in catalogue(reg) if len(c) == 2 and c[0] in {o[0] for o in ours}}
    return bool(theirs) and not (theirs & ours)

def numbered_ok_gen(reg, w):
    """A numbered work with a generic head ('Sonata for Violin and Piano no. 1')."""
    nums = numbers_for(reg, '(?:' + form_pattern(w.gen[-1]) + ')')
    if nums and w.num in nums: return 'yes'
    if nums: return 'no:other number'
    return 'no:number not given'

# a count of players, not a work's number ('Concerto for 2 Keyboards', 'for 4 hands')
# (plural nouns only: '3 Piano Sonatas' counts sonatas)
COUNTED = re.compile(r'\b\d+\s+(?:pianos|violins|violas|cellos|keyboards|harpsichords|flutes|oboes|horns|'
                     r'trumpets|clarinets|bassoons|guitars|mandolins|organs|hands|players|percussionists|'
                     r'voices|choirs|orchestras|strings|winds|soloists)\b')

# a number counting a form after it ('& 5 Piano Concertos', '7 Arabesques'): blank the number, keep the form
PLURAL_FORMS = {v for v, c in CANON.items() if v != c and re.search(r'(?:s|i|en)$', v)} | {f + 's' for f in FORM} | \
               {'symphonies', 'rhapsodies', 'fantasies', 'studies', 'elegies', 'menuets', 'minuets'}
INSTR_WORDS = {v for v, c in CANON.items() if c in INSTR_SET | {'string'}} | INSTR_SET | {'string', 'wind', 'keyboard'}
COUNT_OF = re.compile(r'\b\d+(?=\s+(?:(?:' + '|'.join(sorted(INSTR_WORDS, key=len, reverse=True)) + r')\s+)?(?:' +
                      '|'.join(sorted(PLURAL_FORMS, key=len, reverse=True)) + r')\b)')
YEARS = re.compile(r'\b(?:1[5-9]|20)\d\d\s*[-–]\s*\d{2,4}\b')

def numbers_for(text, pat):
    """The numbers written for this form in `text` ('Symphonies Nos. 1, 3 & 10', 'Quartets 1 - 6',
    '4th Symphony'), stopping at a separator, a colon or another form. None when the form is absent."""
    t = CAT_RE.sub(lambda m: ' ' * len(m.group(0)), text)
    t = YEARS.sub(lambda m: ' ' * len(m.group(0)), t)
    t = NOISE.sub(lambda m: ' ' * len(m.group(0)), t)
    t = COUNTED.sub(lambda m: ' ' * len(m.group(0)), t)
    t = COUNT_OF.sub(lambda m: ' ' * len(m.group(0)), t)
    found = None
    for m in re.finditer(r'(?:(\d+)(?:st|nd|rd|th)\s+|\b(' + '|'.join(ORDINAL) + r')\s+)?(?:' + pat + r')', t):
        found = found if found is not None else set()
        if m.group(1): found.add(m.group(1))
        if m.group(2): found.add(ORDINAL[m.group(2)])
        rest = t[m.end():]
        stop = HARD.search(rest)
        seg = rest[:stop.start()] if stop else rest
        colon = seg.find(':')
        if colon >= 0: seg = seg[:colon]
        fw = FORMWORD.search(seg)
        while fw and re.fullmatch(pat, fw.group(0)): fw = FORMWORD.search(seg, fw.end())
        if fw: seg = seg[:fw.start()]
        for a, b in re.findall(r'(\d+)\s*[-–]\s*(\d+)', seg):
            if 0 < int(b) - int(a) <= 30: found.update(str(n) for n in range(int(a), int(b) + 1))
        found.update(re.findall(r'(?<!\d)(?<!\d\.)(\d{1,3})(?!\d)', seg))
    return found

VOLUME = re.compile(r'\b(?:vol(?:ume)?|part|book|cd|disc|teil|livre)\.?\s*\d')

def vol_of(text, form):
    """A volume, book or disc of this form's set ('Piano Trios, Vol. 5', 'Preludes, Book 1', 'The Complete
    Organ Concertos, 4'), not of an anthology ('Orchestral Works, Vol. 1: La Mer, Nocturnes'); numbers
    straight after the form are works ('Violin Concertos 1 & 2')."""
    t = fold(text)
    for m in re.finditer(r'[a-z]+', t):
        w = m.group(0)
        if CANON.get(w, w[:-1] if w.endswith('s') and w[:-1] in FORM else w) != form: continue
        tail = t[m.end():m.end() + 30]
        if VOLUME.match(re.sub(r'^[\s,.:;(\-]+', '', tail)) or re.match(r'\s*,\s*\d+\b(?!\s*[a-z])', tail): return True
    return False

def is_complete(text, form):
    """'Complete Nocturnes', 'Samtliche Sinfonien', 'The Complete String Quartets': every work of the
    form, so every number. Not a volume, disc or part of one."""
    if vol_of(text, form): return False
    toks = words(text).split()
    for i, t in enumerate(toks):
        c = CANON.get(t, t[:-1] if t.endswith('s') and t[:-1] in FORM else t)
        if c == form and t != form and any(x in ('complete', 'integral', 'integrale', 'samtliche', 'all') for x in toks[max(0, i - 4):i]):
            return True
        if c == form and t != form and 'the' in toks[max(0, i - 2):i]:     # 'Chopin: The Nocturnes'
            return True
    return False

def full_count(text, form, size):
    """'4 Symphonies' for a composer with four: the count before the plural covers the whole set."""
    toks = words(text).split()
    for i, t in enumerate(toks):
        c = CANON.get(t, t[:-1] if t.endswith('s') and t[:-1] in FORM else t)
        if c != form or t == form: continue
        for x in toks[max(0, i - 3):i]:
            n = NUMWORDS.get(x, x)
            if n.isdigit() and size >= 2 and int(n) >= size: return True
    return False

def is_plural(text, form):
    """The text names several works of this form: a plural spelling ('Ballades', 'Concerti',
    'Sinfonien'), 'complete ...', or a 'Nos.' list after it."""
    toks = words(text).split()
    for i, t in enumerate(toks):
        c = CANON.get(t, t[:-1] if t.endswith('s') and t[:-1] in FORM else t)
        if c != form: continue
        if t != form and (t.endswith(('s', 'i', 'en')) or t in ('lieder',)): return True
        if any(x in ('complete', 'integral', 'integrale', 'samtliche', 'all') for x in toks[max(0, i - 4):i]): return True
        if i + 1 < len(toks) and toks[i + 1] == 'nos': return True
    return False

EXCERPT = re.compile(r'\b(?:excerpts?|highlights?|selections?|extraits?|auszuge|scenes? from|arias? from|suite from|music from)\b')

def is_excerpt(at, w, comps):
    if EXCERPT.search(w.raw): return False
    if re.match(r'^\W*(?:opera\s+|famous\s+|great\s+)?(?:arias?|highlights?|excerpts?|scenes?|selections?|duets?)\b', at):
        return True
    probe = (w.real or w.phrase or w.head)[:2]
    if not probe: return False
    me = comps.by[w.comp]['last']
    for part in HARD.split(at):
        pw = ckey(part)
        if not all(x in pw for x in probe): continue
        if EXCERPT.search(part) or re.search(r'\bact\s+(?:[ivx]+|\d)\b', part): return True
        if re.search(r'\bfrom\s+(?:the\s+|l[ae]s?\s+|"|\')?' + re.escape(probe[0][:5]), part): return True
        # 'Work, Op. 7: II. Adagio' -- a colon close after the work's own words
        last = None
        for x in probe:
            m = re.search(r'(?<![a-z])' + re.escape(x[:5]), part)
            if m: last = max(last or 0, m.end())
        if last is not None:
            c = part.find(':', last)
            if c >= 0:
                between, after = part[last:c], part[c + 1:]
                if len(between) <= 40 and not re.search(r'&|\band\b|\bet\b|\+', between) and re.search(r'[a-z]', after) \
                        and not re.match(r'\s*nos\.?\s*\d', after) \
                        and me not in words(after) and not all(x in ckey(after) for x in probe) \
                        and not any(vowelfold(x) in comps.surnames and x != me for x in words(between).split()):
                    return True
    chunks = re.split(r',|;|\s[-–/|]\s', at)
    for i, ch in enumerate(chunks):
        if all(x in ckey(ch) for x in probe):
            for nxt in chunks[i + 1:i + 3]:                  # 'Wozzeck, Op. 7 - Three Excerpts'
                if len(words(nxt).split()) > 4: break
                if re.search(r'\b(?:highlights?|excerpts?|extraits?|selections?|auszuge|act\s+(?:[ivx]+|\d))\b', nxt):
                    return True
            break
    return False

ROMANS = re.compile(r'^(?:x{0,3}(?:ix|iv|v?i{0,3}))$')

def catalogue_list(s):
    """catalogue() plus the numbers listed with one: 'BWV 140 & 147', 'BWV 6-99-147', 'Bwv 21, 147',
    'Op. 59 Nos. 1, 3' (sub-numbers); a dash between numbers 30 or less apart is a range
    ('BWV 1046-1051', 'Nos. 1-3')."""
    out = set(catalogue(s))
    for m in CAT_RE.finditer(s):
        base = catalogue(m.group(0))
        if not base: continue
        cat = next(iter(base))[0]
        num = m.group(3) or (m.group(4) + ':' + m.group(5) if m.group(5) else m.group(6))
        if not num: continue
        sub, hi = m.group(7), m.group(8)
        seq = [('', sub or num)] + ([('-', hi)] if hi else [])
        tail = re.match(r'((?:\s*(?:,|&|\band\b|\+|/|-|–)\s*\d+[a-z]?\b)+)', s[m.end():])
        if tail: seq += re.findall(r'\s*(,|&|\band\b|\+|/|-|–)\s*(\d+[a-z]?)', tail.group(1))
        prev = None
        for sep, n in seq:
            k = int(re.match(r'\d+', n).group(0)) if re.match(r'\d+', n) else None
            vals = [n]
            if sep in ('-', '–') and prev is not None and k is not None and 0 < k - prev <= 30:
                vals = [str(x) for x in range(prev, k + 1)]
            for v in vals:
                out.add((cat, num, v) if sub else (cat, v))
            prev = k
        if sub: out.add((cat, num))
    return out

def cat_about_other(at, w, comps):
    """A catalogue number of our prefix, other than ours, written right after words of THIS work."""
    base = lambda c: (c[0], re.sub(r'(?<=\d)[a-z]+$', '', c[1]))       # 'op. 71a' = 'op. 71 a'
    ours = {base(c) for c in w.cat}; prefixes = {c[0] for c in ours}
    mine = set(w.real) | set(w.phrase)
    key_words = set(w.real) or set(w.phrase)          # 'Brandenburg', not 'concerto', for a Brandenburg Concerto
    prev = 0
    for m in CAT_RE.finditer(at):
        cs = {base(c) for c in catalogue(m.group(0))}
        win = SEGS.split(at[prev:m.start()])[-1]
        prev = m.end()
        if not cs or cs & ours or not ({c[0] for c in cs} & prefixes): continue
        wt = {x for x in ckey(win) if len(x) > 3 and not x.isdigit() and not ROMANS.match(x)
              and vowelfold(x) not in comps.surnames}
        if not (wt & key_words): continue
        if wt - mine - FORM: continue                       # another work's own words
        if (wt & FORM) - mine and (mine & FORM) - wt: continue  # another form (quintet vs quartet)
        return True
    return False

def names_composer(label, comps):
    """A known composer's surname, as spelt in Open Opus or with -ov for -off ('Rachmaninov')."""
    return any(vowelfold(x) in comps.surnames or vowelfold(x).replace('ov', 'off') in comps.surnames
               for x in words(label).split())

def is_label(label, comps, w, raw_title):
    """Text before a colon that names a composer: a known surname, or 1-3 capitalised words that
    are neither form words nor this work's own words ('Weiner:', not 'Rodeo:' for Rodeo)."""
    toks = words(label).split()
    if any(vowelfold(x) in comps.surnames for x in toks): return True
    if not 1 <= len(toks) <= 3 or any(x.isdigit() or CANON.get(x, x) in FORM or x in ('vol', 'cd', 'live', 'disc', 'act', 'part', 'no', 'op') for x in toks):
        return False
    if all(x in w.words or x in words(w.raw).split() for x in toks): return False
    m = re.search(re.escape(label.strip()[:12]), fold(raw_title))
    orig = raw_title[m.start():m.start() + 1] if m else ''
    return orig.isupper()

def region(at, comps, w, raw_title=''):
    """The part of the title about our composer, as written: from our label ('Barber:') up to the
    next composer's label; all of it when the title carries no labels or ours cannot be placed.
    Also says whether our label names other composers too ('Beethoven - Bartok - Dvorak:')."""
    m0 = re.match(r'\s*([^:]{2,80}):', at)
    if m0:                                   # one label naming several composers: 'A - B - C: Quartets'
        names = {vowelfold(x) for x in words(m0.group(1)).split() if vowelfold(x) in comps.surnames}
        if len(names) > 1 and comps.mentions(w.comp, m0.group(1)) == 'yes' and ':' not in at[m0.end():]:
            return at[m0.end():], True
    pieces = re.split('(' + SEGS.pattern + ')', at)
    out, mine, labelled, shared = [], False, False, False
    for k in range(0, len(pieces), 2):
        p = pieces[k]; sep = pieces[k - 1] if k else ''
        m = re.match(r'\s*([^:]{2,60}):', p)
        if m and sep.startswith(',') and not names_composer(m.group(1), comps): m = None
        if m and is_label(m.group(1), comps, w, raw_title):
            labelled = True
            mine = comps.mentions(w.comp, m.group(1)) == 'yes'
            if mine:
                lead = re.split('(?:' + SEGS.pattern + ')', at[:at.find(p)])
                shared = sum(1 for x in words(m.group(1)).split() if vowelfold(x) in comps.surnames) > 1
        if mine: out.append((sep if out else '') + p)
    if labelled and out: return ''.join(out), shared
    return at, False

def accept(album, comps, w):
    title, _, line2 = album.partition('\n')
    at = normalise(fold(title))
    at = re.sub(r'(\d)\s+[-–]\s+(\d)', r'\1-\2', at)          # 'Nos. 1 - 6' is a range, not a separator
    if (set(words(at).split()) & JUNK) - set(words(w.raw).split()): return 'no:junk'
    # the composer: the title decides; line 2 only when the title names no other composer
    in_title = comps.mentions(w.comp, title)
    if in_title == 'other': return 'no:other composer'
    labels = comps.labels(at)
    named = in_title == 'yes'
    if not named and not labels:
        in_l2 = comps.mentions(w.comp, line2)
        if in_l2 == 'other': return 'no:other composer'
        named = in_l2 == 'yes'
    reg, shared_label = region(at, comps, w, title) if named else (at, False)
    # a plural only says 'the set' when the title names no other composer
    others = {vowelfold(x) for x in words(title).split() if vowelfold(x) in comps.surnames} - {vowelfold(x) for x in comps.by[w.comp]['last'].split()}
    tw = without(ckey(reg), w.longer)
    own = PHRASE_OWNERS.get(tuple(w.real), {w.comp})
    title_hit = w.distinct and contains(without(ckey(at), w.longer), w.real or w.phrase)
    if not named and not (title_hit and own <= {w.comp}): return 'no:composer'
    ex = is_excerpt(at, w, comps)
    yes = lambda why: 'yes:' + why + (' (excerpt)' if ex else '')
    # 1. catalogue numbers: an opus number counts in our composer's part of the title, a
    #    composer's own catalogue (BWV, K., D., RV ...) anywhere
    acat = catalogue_list(at); rcat = catalogue_list(reg)
    wbase = {c[:2] for c in w.cat}
    hit = {c for c in acat if c[:2] in wbase and (c[0] != 'op' or c[:2] in {x[:2] for x in rcat})}
    if hit:
        wsub = {c for c in w.cat if len(c) == 3}; asub = {c for c in acat if len(c) == 3 and c[:2] in wbase}
        if wsub and asub and not (wsub & asub): return 'no:other number in set'
        return yes('catalogue')
    if wbase and cat_about_other(reg, w, comps): return 'no:other catalogue'
    # 2. type and number
    for t, n in w.tn:
        nums = numbers_for(reg, '(?:' + form_pattern(t) + ')')
        if nums is None: continue
        if n in nums:
            if w.real and named and not any(x in tw for x in w.real): return 'no:other work, same number'
            return yes('type+number')
        if nums: return 'no:other number'
    # 3. nickname
    if any(contains(tw, n) for n in w.nick): return yes('nickname')
    keys = album_keys(reg)
    plural = bool(w.phrase) and w.phrase[-1] in SETFORM and is_plural(reg, w.phrase[-1]) and not shared_label and not others
    def numbered_ok():
        """A work numbered in its own title ('Orchestral Suite no. 3'): the album must agree."""
        nums = numbers_for(reg, '(?:' + form_pattern(' '.join(w.phrase)) + ')')
        if nums and w.num in nums: return 'yes'
        if nums: return 'no:other number'
        if plural and w.set_size <= 6 and not vol_of(reg, w.phrase[-1]): return 'set'
        if plural and full_count(reg, w.phrase[-1], w.set_size): return 'set'
        if plural and is_complete(reg, w.phrase[-1]) and (not w.instr or instr_set(reg) & w.instr): return 'set'
        return 'no:number not given'
    # 3b. a generic head and its scoring: the form word and the scoring in any order ('Flute and
    #     Harp Concerto'), or the form word with its first scoring word when no other work of the
    #     composer has both ('Serenade for Tenor'), or the form alone when it is the only one ('Octet')
    if w.gen and named and contains(tw, w.gen):
        # counts: 'Concerto for 2 Violins' is not '3 Violins'; one counted instrument must keep its count
        # ('2 Pianos and Percussion' for '2 Pianos and 2 Percussion'; not 'Piano Concerto' for '2 Pianos')
        seen = counted = False
        for d, x in w.scount:
            got = {tw[i - 1] for i in range(1, len(tw)) if tw[i] == x and tw[i - 1].isdigit()}
            if got and d not in got: return 'no:other scoring'
            seen = seen or x in tw
            counted = counted or d in got
        count_missing = seen and not counted
        full = all(x in tw for x in w.req)
        short = w.abbrev_ok and contains(tw, w.gen + w.scoring[:1])           # 'Serenade for Tenor'
        keyhit = bool(w.key) and any(key_eq(w.key, k) for k in keys)
        # 'Flute Concertos & Concerto for Flute and Harp': a singular mention is about one work
        sing = any(CANON.get(x, x) == w.gen[-1] and not re.search(r'(?:s|i|en)$', x) for x in words(reg).split())
        if is_plural(reg, w.gen[-1]) and not sing and not keyhit and not others:
            # several works of this form: all of them, or few enough that ours is surely there
            if is_complete(reg, w.gen[-1]) and (full or not instr_set(reg)): return yes('form, the set')
            n = w.gen_s1_n if w.scoring[0] in tw else w.gen_n
            if (full or not instr_set(reg)) and n <= 3: return yes('form, a small set')
            return 'no:one of several'
        if count_missing: return 'no:other scoring'
        if (full or short) and w.rivals >= 2 and not keyhit: return 'no:title shared by several works'
        if full or short or w.gen_unique or keyhit:
            if w.count:
                cn = {tw[i - 1] for i in range(1, len(tw)) if tw[i] == w.gen[0] and tw[i - 1].isdigit()}
                if cn and w.count not in cn: return 'no:other count'
            if w.num:
                v = numbered_ok_gen(reg, w)
                if v != 'yes': return v
            if w.key and keys and len(HARD.split(reg)) == 1 and not any(key_eq(w.key, k) for k in keys):
                return 'no:other key'
            return yes('form+scoring' if (full or short) else 'form+key' if keyhit else 'only one of its kind')
        return 'no:other scoring'
    # 4. title words
    whole = bool(w.num) and contains(tw, w.head)          # the number is part of the title as written
    if named and w.phrase and not w.form_only and not w.gen and (contains(tw, w.phrase) or whole):
        if w.num and not whole:
            v = numbered_ok()
            if v == 'yes': return yes('title+number')
            if v == 'set': return yes('title, the set')
            return v
        if w.rivals >= 2 and not (w.key and any(key_eq(w.key, k) for k in keys)):
            if is_complete(reg, w.phrase[-1]): return yes('title, the set')
            return 'no:title shared by several works'
        return yes('title')
    if title_hit and not named: return yes('title (composer not named)')
    if named and len(w.real) >= 2:
        got = sum(1 for x in w.real if x in tw)
        if got >= 2 and got * 3 >= len(w.real) * 2: return yes('title words, any order')
    if named and not w.gen and len(w.phrase) >= 2 and w.distinct and all(x in tw for x in w.phrase):
        if w.num:
            v = numbered_ok()
            if v == 'yes': return yes('title words, any order')
            if v == 'set': return yes('title, the set')
            return v
        return yes('title words, any order')
    # 5. only form words ('Fantasia', 'Violin Concerto'): a key, a count, or the only one of its kind
    if named and w.form_only and not w.gen and w.key and len(w.phrase) > 1 and contains(tw, w.phrase[-1:]) \
            and not contains(tw, w.phrase) and any(key_eq(w.key, k) for k in keys) \
            and (not instr_set(reg) or instr_set(reg) & w.instr) and plain_form(tw, w) and not other_number(reg, w):
        return yes('form+key')                          # 'Liszt: Sonata in B Minor - Piano Works'
    if named and w.form_only and not w.gen and w.phrase and contains(tw, w.phrase):
        if w.count and contains(tw, [w.count] + w.phrase[:1]): return yes('count+form')
        if w.key and any(key_eq(w.key, k) for k in keys): return yes('form+key')
        if w.key and keys and len(HARD.split(reg)) == 1: return 'no:other key'
        if w.num:
            v = numbered_ok()
            if v == 'yes': return yes('form+number')
            if v == 'set': return yes('form, the set')
            return v
        if w.unique: return yes('only one of its kind')
        plain = not keys and not numbers_for(reg, '(?:' + form_pattern(' '.join(w.phrase)) + ')')
        if w.canonical and plain and not plural: return yes('the one usually meant')
        # a set Open Opus recommends ('Nocturnes, op. 9') in an album of that form ('Chopin: The Nocturnes')
        if w.canonical and plural and is_plural(w.raw, w.phrase[-1]) and not vol_of(reg, w.phrase[-1]): return yes('the set usually meant')
        if plural and w.set_size <= 3 and not vol_of(reg, w.phrase[-1]): return yes('form, a small set')
        if plural and is_complete(reg, w.phrase[-1]) and (not w.instr or instr_set(reg) & w.instr): return yes('form, the set')
        return 'no:form only'
    return 'no:not named'

PHRASE_OWNERS = {}

def phrase_owners(comps):
    """For every work's real title phrase, the set of composers with a title that holds it."""
    heads = collections.defaultdict(set)
    for c in comps:
        for w in c['works']:
            hk = [x for x in ckey(work_head(w['title'])) if x not in FORM and not x.isdigit()]
            if hk: heads[tuple(hk)].add(c['complete_name'])
    alltitles = [(c['complete_name'], ' ' + ' '.join(ckey(fold(w['title']))) + ' ') for c in comps for w in c['works']]
    out = {}
    for ph in heads:
        s = ' ' + ' '.join(ph) + ' '
        out[ph] = {c for c, t in alltitles if s in t}
    return out

def load():
    comps = oo_composers()
    PHRASE_OWNERS.update(phrase_owners(comps))
    return Composers(comps), {c['complete_name']: head_index(c) for c in comps}

if __name__ == '__main__':
    C, IDX = load()
    rows = [json.loads(l) for path in sys.argv[1].split(',') for l in open(path if '/' in path else data(path))]
    stats = collections.defaultdict(list)
    for r in rows:
        w = Work(r['composer'], r['title'], r['subtitle'], IDX[r['composer']])
        v = [accept(a, C, w) for a in r['items']]
        stats[r['svc']].append((sum(x.startswith('yes') for x in v), sum(x.startswith('yes') for x in v[:20]), r))
        if '-v' in sys.argv:
            print(f"\n## {r['svc']} {r['q']!r}  <- {r['composer']}: {r['title']}  results={r['count']} kept={stats[r['svc']][-1][0]}")
            for a, x in list(zip(r['items'], v))[:int(sys.argv[sys.argv.index('-v') + 1])]:
                print(f"   {x:22} {a.replace(chr(10), ' | ')[:140]}")
    for svc, L in stats.items():
        ys = sorted(y for y, *_ in L); y20 = sorted(y for _, y, _ in L)
        print(f"{svc}: works {len(L)}, none kept {sum(1 for y in ys if y == 0)}, median kept {ys[len(ys)//2]}, "
              f"median of top 20 {y20[len(y20)//2]}")
