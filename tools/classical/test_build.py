# The build tool's own check (docs/classical-plan.md §9.6): corrections applied, Open Opus's
# repeats dropped (and a real pair kept), display order, an unchanged dump reports nothing,
# a changed one reports the change, a stale correction is named, a composer with no
# MusicBrainz id stops the build. A small made-up dump, written to a temp dir.
#   python3 tools/classical/test_build.py
import json, os, sys, tempfile, io, contextlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_data as B

passed = failed = 0
def ok(cond, name):
    global passed, failed
    if cond: passed += 1; print('ok   - ' + name)
    else: failed += 1; print('FAIL - ' + name)

def W(title, genre='Orchestral', sub='', pop='0', rec='0', st=''):
    return {'title': title, 'subtitle': sub, 'genre': genre, 'popular': pop, 'recommended': rec, 'searchterms': st}

def dump(extra=None):
    works = [W('Symphony no. 2, op. 9'), W('Symphony no. 1, op. 5', rec='1'), W('Candide', 'Stage', 'Opera'),
             W('Candide', 'Orchestral', 'Suite'), W('Overture  in C ', pop='1'), W('Overture in C,', rec='1'),
             W('Masquerada '), W('Song', 'Vocal')]
    return {'composers': [{'name': 'Test', 'complete_name': 'Test Composer', 'epoch': 'Romantic',
                           'birth': '1800-01-01', 'death': '1850-01-01', 'works': works + (extra or [])}]}

CORR = {'retitle': [{'composer': 'Test Composer', 'title': 'Masquerada', 'to': 'Masquerade'}],
        'searchterms': [{'composer': 'Test Composer', 'title': 'Song', 'add': ['Lied']}],
        'add': [{'composer': 'Test Composer', 'title': 'Arabesque', 'genre': 'Keyboard'}]}
MB = {'Test Composer': {'mbid': '00000000-0000-0000-0000-000000000001', 'mb_name': 'Test'}}
MBID = MB['Test Composer']['mbid']

with tempfile.TemporaryDirectory() as tmp:
    B.OUT = tmp
    new, notes = B.build(dump(), CORR, MB)
    ws = new[MBID]['works']
    titles = [w['t'] for w in ws]
    ok('Masquerade' in titles and 'Masquerada' not in titles, 'retitle applied')
    ok(any(w['t'] == 'Song' and w.get('q') == 'Lied' for w in ws), 'search name added')
    ok(any(w['t'] == 'Arabesque' and w['g'] == 'Keyboard' for w in ws), 'missing work added')
    ok(notes['repeats'] == 1, f"one repeat dropped (the Overture's two spellings): {notes['repeats']}")
    ov = [w for w in ws if w['t'].startswith('Overture')]
    ok(len(ov) == 1 and ov[0].get('p') == 1 and ov[0].get('r') == 1, 'the kept entry carries both entries\' flags')
    ok(ov and ov[0]['t'] == 'Overture in C', 'spaces trimmed and collapsed')
    ok(sum(1 for w in ws if w['t'] == 'Candide') == 2, 'a real pair (opera and suite) is kept')
    ok(titles[:3] == ['Symphony no. 1, op. 5', 'Overture in C', 'Symphony no. 2, op. 9'],
       f'display order: recommended first (catalogued, then not), then the rest by catalogue number: {titles[:3]}')
    ok(new[MBID]['meta']['w'] == len(ws) and new[MBID]['meta']['b'] == '1800', 'the table row: work count and years')
    ok(len({w['_id'] for w in ws}) == len(ws), 'work ids are unique')

    B.write(new, 'test')
    ok(os.path.exists(os.path.join(tmp, 'works', MBID + '.json')), 'files written')
    on_disk = json.load(open(os.path.join(tmp, 'works', MBID + '.json')))['works']
    ok(all('_id' not in w for w in on_disk), 'ids are not shipped (the plugin computes them)')
    ok(B.report(B.read_old(), new) == [], 'the same dump again: nothing reported')

    new2, _ = B.build(dump([W('Requiem', 'Vocal', rec='1')]), CORR, MB)
    rep = B.report(B.read_old(), new2)
    ok(any(l.startswith('+ Test Composer / Requiem') for l in rep), 'a work Open Opus added is reported')
    d3 = dump(); d3['composers'][0]['works'][7]['popular'] = '1'
    rep = B.report(B.read_old(), B.build(d3, CORR, MB)[0])
    ok(any('Song: popular - -> 1' in l for l in rep), 'a changed flag is reported: ' + '; '.join(rep))

    stale = dict(CORR, retitle=[{'composer': 'Test Composer', 'title': 'Gone', 'to': 'X'}])
    _, n = B.build(dump(), stale, MB)
    ok(any('retitle: Test Composer / Gone' in l for l in n['stale']), 'a correction that no longer applies is named')
    have = dict(CORR, add=[{'composer': 'Test Composer', 'title': 'Song', 'genre': 'Vocal'}])
    _, n = B.build(dump(), have, MB)
    ok(any('Open Opus has it now' in l for l in n['stale']), 'an added work Open Opus now has is named, not doubled')

    try:
        with contextlib.redirect_stdout(io.StringIO()):
            B.build(dump(), CORR, {})
        ok(False, 'a composer with no MusicBrainz id stops the build')
    except SystemExit as e:
        ok('Test Composer has no MusicBrainz id' in str(e), 'a composer with no MusicBrainz id stops the build, named')

# ---- Wikidata's facts (wdjoin.py, plan §10): the year and the instrumentation
import wdjoin as J

# The year: year precision only, within the composer's working life, composition first.
ok(J.year({'inc': [[1770, 8]], 'pub': [[1783, 9]]}, 1756, 1791) == 1783,
   'a decade-precise date is skipped for the publication year (K. 331 is stored "1770s")')
ok(J.year({'inc': [[1975, 9]]}, 1756, 1791) is None, 'a year after the composer died is a film, not the work')
ok(J.year({'inc': [[1758, 9]]}, 1756, 1791) is None, 'a year before the composer was four is refused')
ok(J.year({'inc': [[1785, 9]], 'prem': [[1786, 9]]}, 1756, 1791) == 1785, 'the composition date wins over the premiere')
ok(J.year({'prem': [[1791, 9]], 'pub': [[1800, 9]]}, 1756, 1791) == 1791, 'then the premiere, a posthumous print refused')
ok(J.year({'inc': [[2001, 9]]}, 1950, None) == 2001, 'a living composer has no upper bound')

# The instrumentation line.
ok(J.instruments(['piano'], 'Piano Sonata no. 8') == '', 'the title already names the instrument: nothing')
ok(J.instruments(['piano'], 'Ballade no. 2 in F major, op. 38') == 'piano', 'a title that does not: shown')
ok(J.instruments([['violin', 2], 'viola', 'cello'], 'String Quartet no. 8') == '', 'a string quartet says its strings')
ok(J.instruments(['violin', 'violin', 'viola', 'cello', 'continuo group'], 'The Four Seasons') ==
   'violin, viola, cello, continuo', 'repeats folded, Wikidata\'s names tidied')
ok(J.instruments(['violin', ['oboe', 2], ['horn', 2], 'string orchestra'], 'Violin Concerto no. 3 in G major, K.216') ==
   'violin, 2 oboes, 2 horns, strings', 'counts kept, plurals made, ensembles last')
ok(J.instruments(['string orchestra', 'Western concert flute'], 'Something') == 'flute, strings',
   'an ensemble goes after the instruments whatever Wikidata\'s order')
ok(J.instruments(['harpsichord', 'keyboard instrument'], 'The Musical Offering') == 'harpsichord',
   'a bare "keyboard" beside a named one is dropped')
ok(J.instruments(['symphony orchestra'], 'Missa Solemnis, op. 123') == '', 'a mass implies its choir and orchestra')
ok(J.instruments(['soloist', 'musical instrument'], 'Something') == '', 'names that say nothing are dropped')
ok(J.instruments([['viola', {'amount': '+2'}]], 'Something') == 'viola', 'a count that is not a number is ignored')
# Rules from the measurement over all 220 composers (2026-10-08).
ok(J.instruments(['trumpet', 'cor anglais', 'string orchestra'], 'Quiet City, for English horn, trumpet, and strings') == '',
   'a title\'s "English horn" is Wikidata\'s cor anglais: all said, nothing shown')
ok(J.instruments(['viol'], 'Viola da gamba Sonata no. 1 in G major') == '', 'a viola da gamba sonata says its viol')
ok(J.instruments(['viol', 'harpsichord'], 'Viola da gamba Sonata no. 1 in G major') == 'viol, harpsichord',
   '... and with a harpsichord the title does not name, the whole line, as for any partly-said scoring')
ok(J.instruments(['organ'], 'Te Deum, WAB 45') == '', 'a Te Deum implies its organ (not shown as if it were for organ)')
ok(J.instruments([['soprano', 2], ['choir', 2], ['string orchestra', 2], ['continuo group', 2]], 'Something') ==
   '2 sopranos, 2 choirs, strings, continuo', 'strings and continuo take no count ("2 stringses")')
ok(J.instruments(['oboe', 'percussion guitare'], 'Dmaathen') == 'oboe, percussion',
   'Wikidata\'s "percussion guitare" label is percussion')
ok(J.instruments(['oboe', 'percussion guitare'], 'Dmaathen, for oboe and percussion') == '', '... and a title saying it is enough')
ok(J.instruments(['sprechgesang', 'instrumental ensemble'], 'Pierrot lunaire, for voice and chamber ensemble') == '',
   'sprechgesang is a voice; "instrumental ensemble" says nothing')
ok(J.instruments([f'x{n}' for n in range(9)], 'Something') == '', 'more than 8 items is a full orchestration: no line')
ok(J.instruments([f'x{n}' for n in range(8)], 'Something') == ', '.join(f'x{n}' for n in range(8)), '8 items still shown')

# The title's own scoring against Wikidata's: an item that contradicts it is another work.
ok(J.scoring_conflict(['oboe', 'string section'], 'Concerto in D minor, for harp and orchestra'),
   'the harp concerto is not the oboe concerto (Marcello)')
ok(J.scoring_conflict(['violin', 'clarinet', 'piano'], 'Adagio in F major, for string quartet'),
   'a string quartet is not violin, clarinet and piano (Berg)')
ok(J.scoring_conflict(['violin', 'viola', 'cello'], 'Cypresses, song cycle for voice and piano, B.11'),
   'the song cycle is not the string quartet set of the same name (Dvorak)')
ok(not J.scoring_conflict(['clarinet', 'cello', 'piano'], 'Piano Trio no. 4 in B flat major, op. 11'),
   'control: a piano trio with a clarinet for the violin stays (Beethoven op. 11, more inside than outside)')
ok(not J.scoring_conflict(['piano'], 'Cello Sonata no. 2 in G minor, op. 117'),
   'control: a cello sonata whose item lists only the piano stays (the sonata implies it)')
ok(not J.scoring_conflict(['viol'], 'Viola da gamba Sonata in G minor, Wq.88'), 'control: viola da gamba is the viol')
ok(not J.scoring_conflict(['violin', 'viola', 'cello'], 'String Quartet no. 10 in E flat major, op. 74, "Harp"'),
   'control: a nickname in quotes is not scoring ("Harp" quartet)')
ok(J.scoring_conflict(['piano', 'harp'], 'String Quartet no. 10 in E flat major, op. 74, "Harp"'),
   '... so the "Harp" quartet is not the Swiss-song variations for piano or harp (the nickname would have vouched for it)')
ok(not J.scoring_conflict(['harpsichord'], 'Flute Sonata in E minor, BWV.1034'),
   'control: a flute sonata has its keyboard (any sonata naming another instrument)')
ok(not J.scoring_conflict(['clarinet', 'harp', 'piano', 'string orchestra'], 'Clarinet Concerto'),
   'control: a concerto\'s extra instruments are not a conflict (Copland)')
ok(not J.scoring_conflict(['piano'], 'Ballade no. 1'), 'control: a title naming no instrument never conflicts')
ok(not J.scoring_conflict(None, 'Concerto for Oboe'), 'control: an item naming no instrument never conflicts')
ws2 = [{'t': 'Concerto in D minor, for harp and orchestra', 'g': 'Orchestral'}]
got2 = J.facts(ws2, [{'q': 'Q5', 'l': 'Concerto in D minor', 'inc': [[1717, 9]], 'instr': ['oboe', 'string section']},
                     {'q': 'Q6', 'l': 'Concerto in D minor', 'inc': [[1730, 9]], 'instr': ['harp', 'string section']}], 1673, 1747)
ok(got2.get(0) == {'y': 1730}, f'the join skips the conflicting item and takes the one that agrees: {got2.get(0)}')

# The join: the strongest match wins, catalogue numbers must agree.
ws = [{'t': 'Sinfonia concertante in E flat major, K.364', 'g': 'Orchestral'},
      {'t': 'Symphony no. 40 in G minor, K.550', 'g': 'Orchestral', 'r': 1}]
items = [{'q': 'Q1', 'l': 'Sinfonia Concertante for Four Winds', 'cat': ['K. 279b'], 'inc': [[1778, 9]]},
         {'q': 'Q2', 'l': 'Symphony No. 40', 'cat': ['550'], 'inc': [[1788, 9]], 'instr': ['orchestra']},
         {'q': 'Q3', 'l': 'Symphony No. 40 (arrangement)', 'inc': [[1790, 9]]}]
got = J.facts(ws, items, 1756, 1791)
ok(0 not in got, "another work's catalogue number is refused (K. 297b's year never reaches K. 364)")
ok(got.get(1) == {'y': 1788}, f'the catalogue match beats a title-only one; a symphony\'s "orchestra" is implied: {got.get(1)}')
ok(J.facts(ws, None) == {} and J.facts(ws, []) == {}, 'no Wikidata items: no facts')

with tempfile.TemporaryDirectory() as tmp:
    B.OUT = tmp
    wd = {MBID: {'works': [{'q': 'Q9', 'l': 'Symphony No. 1', 'cat': ['Op. 5'], 'inc': [[1830, 9]],
                            'instr': ['symphony orchestra', 'mixed choir']}]}}
    new, notes = B.build(dump(), CORR, MB, wd)
    sym = [w for w in new[MBID]['works'] if w['t'] == 'Symphony no. 1, op. 5'][0]
    ok(sym.get('y') == 1830 and sym.get('i') == 'choir, orchestra', f'the facts land on the work: {sym}')
    ok(notes['facts'] == {'y': 1, 'i': 1, 'of': len(new[MBID]['works'])}, f"counted: {notes['facts']}")
    c2 = dict(CORR, wikidata=[{'item': 'Q9', 'drop': ['instr'], 'why': 'test'},
                              {'item': 'Q404', 'drop': ['inc'], 'why': 'test'}])
    fixed, n2 = B.build(dump(), c2, MB, wd)
    sym2 = [w for w in fixed[MBID]['works'] if w['t'] == 'Symphony no. 1, op. 5'][0]
    ok(sym2.get('y') == 1830 and 'i' not in sym2, f'a "wikidata" correction leaves its field out, the rest stays: {sym2}')
    ok(any(a.startswith('wikidata: Q9 ') for a in n2['applied']) and any('Q404 (not in the snapshot)' in s for s in n2['stale']),
       'reported: applied, and stale when the item is gone')
    ok(wd[MBID]['works'][0].get('instr'), 'the snapshot itself is not changed')
    plain, _ = B.build(dump(), CORR, MB)
    ok(all('y' not in w and 'i' not in w for w in plain[MBID]['works']), 'no snapshot: no facts, nothing else changes')
    B.write(plain, 'test')
    rep = B.report(B.read_old(), new)
    ok(any('Symphony no. 1, op. 5: year - -> 1830' in l for l in rep) and
       any('instrumentation - -> choir, orchestra' in l for l in rep), 'a new year and instrumentation are reported')
    B.write(new, 'test')
    on_disk = [w for w in json.load(open(os.path.join(tmp, 'works', MBID + '.json')))['works'] if w['t'].startswith('Symphony no. 1')]
    ok(on_disk[0].get('y') == 1830 and on_disk[0].get('i') == 'choir, orchestra', 'shipped as y and i')

print(f'\n{passed} passed, {failed} failed')
sys.exit(1 if failed else 0)
