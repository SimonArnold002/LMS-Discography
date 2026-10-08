package Plugins::Discography::Classical;

# The composer works page's data and matching (docs/classical-plan.md §9, step 1).
#
#   * THE DATA is our corrected copy of Open Opus (CC0), shipped in classical/
#     beside this file and built by tools/classical/build_data.py: composers.json
#     (220 composers by MusicBrainz id) and works/<mbid>.json (one composer's
#     works, already in display order). Read from disk, never asked of a service:
#     the list is read once, a composer's works when his page opens, and kept in
#     a small memo. It changes only with a build, like the plugin's images, so it
#     needs no cache rules and no migration.
#   * THE RULE that marks a work "In your library" is tools/classical/wrule.py,
#     ported line for line (plan §8.3: 345 of 397 library works matched, 1
#     wrong). The port is pinned against the Python by tools/t_classical.pl over
#     Simon's 425 library works (tools/fixtures/classical_parity.json).
#   * THE LIBRARY SIDE is LMS's Works data, which exists only where the files
#     carry WORK tags (§7). A library without them gets the works list with no
#     marks and no "Other works" section.

use strict;
use warnings;

use Digest::SHA ();
use Encode ();
use File::Basename ();
use File::Spec;
use JSON::XS ();
use Unicode::Normalize ();

use Slim::Utils::Log;

my $log = logger('plugin.discography');
sub _dbg { Plugins::Discography::Plugin::dbg(@_) if Plugins::Discography::Plugin->can('dbg') }

use constant WORKS_MEMO_MAX => 8;    # composers' works kept in memory (Bach's file is 65 KB)
use constant OWNED_MEMO_MAX => 16;   # composers' "In your library" answers kept
use constant LIB_WORKS_MAX  => 2000; # one composer's library works read
use constant WORK_ALBUMS_MAX => 200; # albums listed for one work
use constant WORK_TRACKS_MAX => 2000; # one LMS work's tracks read, across its albums

# The genres Open Opus files works under, in the page's order (plan §9.3).
use constant GENRES => qw(Orchestral Chamber Keyboard Stage Vocal);

# ---------------------------------------------------------------------------
# The shipped data
# ---------------------------------------------------------------------------

# The data directory; a suite points it at a fixture.
our $DATA_DIR;
sub _dataDir {
    $DATA_DIR //= File::Spec->catdir(
        File::Spec->rel2abs(File::Basename::dirname(__FILE__)), 'classical');
    return $DATA_DIR;
}

sub _readJson {
    my ($path) = @_;
    my $fh;
    unless (open($fh, '<:raw', $path)) {
        $log->warn("classical data missing: $path");
        return undef;
    }
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $d = eval { JSON::XS->new->utf8->decode($raw) };
    $log->warn("classical data unreadable: $path: $@") unless $d;
    return $d;
}

my $COMPOSERS;               # mbid => { n, c, m, b, d, e, w }
my (%WORKS, @WORKS_ORDER);   # mbid => [ works ], newest last
my (%OWNED, @OWNED_ORDER);   # mbid => { sig, works, answer }, newest last
my %IDX;                     # mbid => { works, ix }: _index's answer for his works

# Forget everything read (the suite, between fixtures).
sub forget {
    undef $COMPOSERS;
    %WORKS = (); @WORKS_ORDER = ();
    %OWNED = (); @OWNED_ORDER = ();
    %IDX = ();
}

# The composer the table holds under this MusicBrainz id, or undef.
sub composer {
    my ($class, $mbid) = @_;
    return undef unless defined $mbid && $mbid =~ /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
    unless ($COMPOSERS) {
        my $d = _readJson(File::Spec->catfile(_dataDir(), 'composers.json'));
        $COMPOSERS = (ref $d eq 'HASH' && ref $d->{composers} eq 'HASH') ? $d->{composers} : {};
    }
    return $COMPOSERS->{ lc $mbid };
}

# A work's id: the first 8 hex of sha1(mbid|title|subtitle|genre) over UTF-8,
# exactly as build_data.py computes it (it checks they are unique per composer).
sub workId {
    my ($mbid, $w) = @_;
    my $s = join '|', lc($mbid // ''), map { $_ // '' } @$w{qw(title subtitle genre)};
    return substr(Digest::SHA::sha1_hex(Encode::encode_utf8($s)), 0, 8);
}

# One composer's works, in display order (recommended first, then catalogue
# number, then title): [ { id, title, subtitle, genre, popular, recommended,
# searchterms } ]. Empty for anyone not in the table.
sub works {
    my ($class, $mbid) = @_;
    return [] unless $class->composer($mbid);
    $mbid = lc $mbid;
    return $WORKS{$mbid} if $WORKS{$mbid};
    my $d = _readJson(File::Spec->catfile(_dataDir(), 'works', "$mbid.json"));
    my @out;
    for my $r (@{ (ref $d eq 'HASH' && ref $d->{works} eq 'ARRAY') ? $d->{works} : [] }) {
        next unless ref $r eq 'HASH' && defined $r->{t} && length $r->{t};
        my %w = (title => $r->{t}, subtitle => $r->{s} // '', genre => $r->{g} // '',
                 popular => $r->{p} ? 1 : 0, recommended => $r->{r} ? 1 : 0,
                 searchterms => $r->{q} // '',
                 # From Wikidata at build time (tools/classical/wdjoin.py), when it knows:
                 # the year written and a short instrumentation line. Not in the id.
                 year => ($r->{y} && $r->{y} =~ /^\d{3,4}$/) ? $r->{y} : '',
                 instr => (defined $r->{i} && !ref $r->{i}) ? $r->{i} : '');
        $w{id} = workId($mbid, \%w);
        push @out, \%w;
    }
    $WORKS{$mbid} = \@out;
    @WORKS_ORDER = ((grep { $_ ne $mbid } @WORKS_ORDER), $mbid);
    delete $WORKS{ shift @WORKS_ORDER } while @WORKS_ORDER > WORKS_MEMO_MAX;
    return \@out;
}

# ---------------------------------------------------------------------------
# The rule: a library WORK tag -> an Open Opus work of the same composer.
# A line-for-line port of tools/classical/wrule.py (match and what it calls);
# keep the two in step. Sets are hashes; a catalogue entry is its parts joined
# by \x1f (two parts: catalogue + number; three: + sub-number).
# ---------------------------------------------------------------------------

# Characters, not octets (a DB string normally is; a param may not be).
sub _chars {
    my ($s) = @_;
    $s = '' unless defined $s;
    return $s if utf8::is_utf8($s);
    my $d = $s;
    return utf8::decode($d) ? $d : $s;
}

sub fold {
    my $s = _chars(shift);
    # (a replacement list shorter than the search list repeats its last character)
    $s =~ tr/\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}/-/;
    $s =~ tr/\x{201C}\x{201D}\x{201E}\x{AB}\x{BB}/"/;
    $s =~ tr/\x{2018}\x{2019}\x{201A}\x{2032}/'/;
    $s = Unicode::Normalize::NFKD($s);
    $s =~ s/\P{ccc=0}//g;    # Python's unicodedata.combining(): any mark that combines
    return lc $s;
}

my $ROMAN = qr/(?:x{0,3}(?:ix|iv|v?i{0,3}))/;
my @CATS = qw(bwv hwv twv rv kv k hob woo anh d sz bb trv jw fp wab lw s l b h m z wq op bv cd g
              opus wwv buxwv js fs jb qr p opp kiv kk);
my %CAT_ALIAS = (kv => 'k', opus => 'op', opp => 'op', kiv => 'bv', kk => 'k');
my $CAT_ALT = join '|', sort { length($b) <=> length($a) } @CATS;   # longest first, as Python's
my $CAT_RE = qr/(?<![a-z])($CAT_ALT)\.?\s*(?:(posth)\.?\s*(\d+[a-z]?)?|(${ROMAN}[a-z]?)[:\/]\s*(\d+[a-z]?)|(\d+[a-z]?))(?:\s*(?:,\s*)?(?:nos?\.?|nr\.?|number|\/)\s*(\d+))?(?:\s*-\s*(\d+))?/;

sub catalogue {
    my ($s) = @_;
    my %out;
    while ($s =~ /$CAT_RE/g) {
        my ($c, $posth, $pn, $rom, $rn, $n, $lo, $hi) = ($1, $2, $3, $4, $5, $6, $7, $8);
        my $cat = $CAT_ALIAS{$c} // $c;
        my $num;
        if (defined $posth) {
            next unless defined $pn && length $pn;
            $num = $pn;
        }
        else {
            $num = (defined $rn && length $rn) ? ($rom // '') . ':' . $rn : $n;
        }
        next unless defined $num && length $num;
        $out{"$cat\x1f$num"} = 1;
        if (defined $lo && length $lo) {
            my $top = (defined $hi && length $hi) ? $hi : $lo;
            $top = $lo + 24 if $top > $lo + 24;
            $out{"$cat\x1f$num\x1f" . ($_ + 0)} = 1 for $lo .. $top;
        }
    }
    return \%out;
}

my @TYPES = (
    ['piano concerto', 'piano concerto|concerto for piano|klavierkonzert|concerto pour piano'],
    ['violin concerto', 'violin concerto|concerto for violin|violinkonzert|concerto pour violon(?!celle)'],
    ['cello concerto', 'cello concerto|concerto for cello|cellokonzert|concerto pour violoncelle'],
    ['flute concerto', 'flute concerto|concerto for flute'],
    ['oboe concerto', 'oboe concerto|concerto for oboe'],
    ['clarinet concerto', 'clarinet concerto|concerto for clarinet'],
    ['horn concerto', 'horn concerto|concerto for horn'],
    ['trumpet concerto', 'trumpet concerto|concerto for trumpet'],
    ['organ concerto', 'organ concerto|concerto for organ'],
    ['guitar concerto', 'guitar concerto|concerto for guitar'],
    ['piano sonata', 'piano sonata|sonata for piano|klaviersonate'],
    ['violin sonata', 'violin sonata|sonata for violin'],
    ['cello sonata', 'cello sonata|sonata for cello'],
    ['string quartet', 'string quartet|streichquartett|quatuor a cordes'],
    ['piano trio', 'piano trio|klaviertrio'],
    ['piano quartet', 'piano quartet'],
    ['piano quintet', 'piano quintet'],
    ['symphony', 'symphon(?:y|ie|ia)\b|sinfonie\b|sinfonia\b'],
    ['sonata', 'sonata|sonate'],
    ['concerto', 'concerto|konzert'],
    ['nocturne', 'nocturne'], ['etude', 'etude'], ['waltz', 'waltz|valse|walzer'],
    ['mazurka', 'mazurka'], ['prelude', 'prelude'], ['ballade', 'ballade'],
    ['scherzo', 'scherzo'], ['polonaise', 'polonaise'], ['impromptu', 'impromptu'],
    ['rhapsody', 'rhapsod'], ['serenade', 'serenade'],
    ['overture', 'overture|ouverture'], ['requiem', 'requiem'],
    ['partita', 'partita'], ['divertimento', 'divertimento'], ['cantata', 'cantata|kantate'],
);
my %GENERIC = map { $_ => 1 } qw(sonata concerto);
# Compiled once: the bare pattern, "type ... no. N", and "type N".
for my $t (@TYPES) {
    my $p = $t->[1];
    push @$t, qr/(?:$p)/,
              qr/(?:$p)(?:\s+(?:for|in|and|pour|fur)\s+[a-z ,&]+?)?\s*(?:no\.?|nr\.?|number)\s*(\d+)\b/,
              qr/(?:$p)\s+(\d+)\b/;
}

sub typenums {
    my ($s) = @_;
    my %out;
    for my $t (@TYPES) {
        my ($name, undef, $anyRe, $numRe, $bareRe) = @$t;
        next unless $s =~ $anyRe;    # neither form matches without the type's own words
        while ($s =~ /$numRe/g)  { $out{"$name\x1f$1"} = 1 }
        while ($s =~ /$bareRe/g) { $out{"$name\x1f$1"} = 1 }
    }
    my @spec = grep { (split /\x1f/)[0] =~ / / } keys %out;
    for my $k (keys %out) {
        my ($t, $n) = split /\x1f/, $k;
        next unless $GENERIC{$t};
        delete $out{$k} if grep { my ($t2, $n2) = split /\x1f/; $n eq $n2 && index($t2, $t) >= 0 } @spec;
    }
    return \%out;
}

# Specific work types named anywhere (no number needed), for the conflict check.
sub types_in {
    my ($s) = @_;
    return { map { $_->[0] => 1 } grep { !$GENERIC{ $_->[0] } && $s =~ $_->[2] } @TYPES };
}

sub nicknames {
    my ($s) = @_;
    my %out;
    while ($s =~ /(?:^|(?<=[\s(\[]))["']([^"']{3,40})["'](?=$|[\s),.;:\]])/g) {
        (my $q = $1) =~ s/^\s+|\s+$//g;
        $out{$q} = 1 if length($q) >= 3;
    }
    return [ sort keys %out ];
}

my $KEY_RE = qr/\bin ([a-g])(?:[ -]?(flat|sharp))?(?: (major|minor))?\b/;
sub key_of {
    my ($s) = @_;
    return undef unless $s =~ $KEY_RE;
    return [ $1, $2 // '', $3 // '' ];
}

sub keys_conflict {
    my ($x, $y) = @_;
    return 0 unless $x && $y;
    return 1 if $x->[0] ne $y->[0] || $x->[1] ne $y->[1];
    return ($x->[2] && $y->[2] && $x->[2] ne $y->[2]) ? 1 : 0;
}

my %NUMWORDS = (one => 1, two => 2, three => 3, four => 4, five => 5, six => 6, seven => 7,
                eight => 8, nine => 9, ten => 10, twelve => 12, deux => 2, trois => 3,
                quatre => 4, cinq => 5, sept => 7, douze => 12, zwei => 2, drei => 3, vier => 4,
                dos => 2, tres => 3, cuatro => 4, cinco => 5, siete => 7, due => 2, tre => 3);
my %STOP = map { $_ => 1 } qw(the a an of in for and from at on to major minor flat sharp no nos op
                              act le la les l de des du d il der die das et y e un une);
my %FORM_WORDS = map { $_ => 1 } (map { $_->[0] } @TYPES),
    qw(symphony concerto sonata quartet trio quintet suite preludes nocturnes etudes waltzes
       mazurkas pieces songs variations fugue fantasia fantasy piano violin cello string
       orchestra march dances dance mass overture concertos sonatas);

sub title_key {
    my ($s) = @_;
    $s =~ s/$CAT_RE/ /g;
    $s =~ s/$KEY_RE/ /g;
    $s =~ s/[^a-z0-9]+/ /g;
    my @out;
    for my $t (split ' ', $s) {
        $t = $NUMWORDS{$t} // $t;
        next if $STOP{$t} || $t =~ /^(?:1[5-9]|20)[0-9][0-9]\z/;   # years are not titles
        push @out, $t;
    }
    return \@out;
}

sub main_part {
    my ($s) = @_;
    my ($h) = split /,|:|;|\s\(|\s-\s|\sfor\s/, $s, 2;
    return $h // '';
}

my %INSTR = map { $_ => 1 } qw(violin viola cello piano flute oboe clarinet bassoon horn trumpet
                               guitar harp organ harpsichord recorder saxophone voice chorus choir);

sub _set { return { map { $_ => 1 } @{ $_[0] } } }

# What both sides carry, precomputed: the joined word string for _contains and
# the word set for the overlap.
sub _words {
    my ($k) = @_;
    return { list => $k, str => ' ' . join(' ', @$k) . ' ', set => _set($k) };
}

sub _splitCat {
    my ($cat) = @_;
    my (%full, %base);
    for my $c (keys %$cat) {
        my $n = () = $c =~ /\x1f/g;
        if ($n == 2) { $full{$c} = 1 } else { $base{$c} = 1 }
    }
    return (\%full, \%base);
}

sub oo_features {
    my ($title, $subtitle, $searchterms) = @_;
    my $t  = fold($title);
    my $st = fold($subtitle);
    my @mains = (title_key(main_part($t)));
    for my $alt (split /,/, ($searchterms // ''), -1) {
        (my $a = $alt) =~ s/^\s+|\s+$//g;
        my $k = title_key(main_part(fold($a)));
        push @mains, $k if @$k;
    }
    my %nick = map { $_ => 1 } grep { length } map { join ' ', @{ title_key($_) } } @{ nicknames($t) };
    my $all = title_key($t);
    my ($full, $base) = _splitCat(catalogue($t . ' , ' . $st));
    return {
        full => $full, base => $base, tn => typenums($t), types => types_in($t),
        nick => [ sort keys %nick ], mains => \@mains, key => key_of($t), raw => $t,
        all => _words($all), sub => $st,
        # the mains that are not form words only, with their joined length
        real => [ map { [ $_, length(join ' ', @$_), ' ' . join(' ', @$_) . ' ' ] }
                  grep { @$_ && grep { !$FORM_WORDS{$_} } @$_ } @mains ],
    };
}

sub lib_features {
    my ($title) = @_;
    my $t = fold($title);
    my %nick = map { $_ => 1 } grep { length } map { join ' ', @{ title_key($_) } } @{ nicknames($t) };
    my ($full, $base) = _splitCat(catalogue($t));
    return {
        full => $full, base => $base, tn => typenums($t), types => types_in($t),
        nick => [ sort keys %nick ], main => title_key(main_part($t)), all => _words(title_key($t)),
        key => key_of($t), raw => $t,
    };
}

sub _contains {
    my ($hayStr, $needle) = @_;
    return 0 unless @$needle;
    return index($hayStr, ' ' . join(' ', @$needle) . ' ') >= 0 ? 1 : 0;
}

sub _nocount {
    my ($k) = @_;
    return [ @$k[1 .. $#$k] ] if @$k > 1 && $k->[0] =~ /^[0-9]+\z/;
    return $k;
}

sub _strip_letter {
    my @p = split /\x1f/, $_[0], -1;
    $p[1] =~ s/[a-z]\z//;
    return join "\x1f", @p;
}

sub _common { my ($x, $y) = @_; return scalar grep { $y->{$_} } keys %$x }

sub signals {
    my ($L, $O) = @_;
    my %s;
    my ($lfull, $lbase, $ofull, $obase) = (@$L{qw(full base)}, @$O{qw(full base)});
    my $conflict = (%{ $L->{types} } && %{ $O->{types} } && !_common($L->{types}, $O->{types})) ? 1 : 0;
    $s{type_conflict} = $conflict;
    $s{cat_full} = (_common($lfull, $ofull) && !$conflict) ? 1 : 0;
    $s{cat_base} = (_common($lbase, $obase) && !$conflict
                    && !(%$lfull && %$ofull && !_common($lfull, $ofull))) ? 1 : 0;
    if (!$s{cat_base} && %$lbase && %$obase && !$conflict) {
        OUTER: for my $x (keys %$lbase) {
            for my $y (keys %$obase) {
                my ($xc, $xn) = split /\x1f/, $x;
                my ($yc, $yn) = split /\x1f/, $y;
                next unless $xc eq $yc;
                if (_strip_letter($x) eq _strip_letter($y) && ($xn =~ /\d\z/ || $yn =~ /\d\z/)) {
                    $s{cat_base} = 1; last OUTER;
                }
            }
        }
    }
    $s{tn} = _common($L->{tn}, $O->{tn}) ? 1 : 0;
    $s{nick} = ((grep { _contains($L->{all}{str}, [ split ' ', $_ ]) } @{ $O->{nick} })
             || (grep { _contains($O->{all}{str}, [ split ' ', $_ ]) } @{ $L->{nick} })) ? 1 : 0;
    my $lm = _nocount($L->{main});
    my $lms = join ' ', @$lm;
    $s{title_eq} = (@$lm && grep { @$_ && join(' ', @{ _nocount($_) }) eq $lms } @{ $O->{mains} }) ? 1 : 0;
    my $best = 0;
    for my $r (@{ $O->{real} }) {
        my ($m, $len, $str) = @$r;
        next unless @$m >= 2 || length($m->[0]) >= 6;
        next unless index($L->{all}{str}, $str) >= 0;
        $best = $len if $len > $best;
    }
    $s{title_in} = $best;
    $s{key_ok} = keys_conflict($L->{key}, $O->{key}) ? 0 : 1;
    my $nm = 0;
    NM: for my $n (@{ $L->{nick} }) {
        my @nw = split ' ', $n;
        for my $m (@{ $O->{mains} }) {
            next unless @$m;
            my @head = @$m[0 .. ($#nw < $#$m ? $#nw : $#$m)];
            if (@head == @nw && join("\x1f", @head) eq join("\x1f", @nw)) { $nm = 1; last NM }
        }
    }
    $s{nick_main} = $nm;
    my @extra = grep { $INSTR{$_} && !$L->{all}{set}{$_} } keys %{ $O->{all}{set} };
    $s{overlap} = _common($L->{all}{set}, $O->{all}{set}) - 2 * scalar(@extra);
    my $lsuite = index($L->{raw}, 'suite') >= 0 ? 1 : 0;
    $s{suite_agree} = ((index($O->{raw} . ' ' . $O->{sub}, 'suite') >= 0 ? 1 : 0) == $lsuite) ? 1 : 0;
    return \%s;
}

my @ORDER = qw(cat_full cat_base tn title_eq nick title_in);
my @TIES  = qw(nick_main suite_agree overlap rec pop);
my %KEYED = map { $_ => 1 } qw(tn nick title_eq title_in);

# An Open Opus work's features, worked out once and kept on the work.
sub _ooFeatures {
    my ($w) = @_;
    return $w->{_f} //= oo_features($w->{title}, $w->{subtitle}, $w->{searchterms});
}

sub _bag {
    my ($t) = @_;
    (my $s = fold($t)) =~ s/[^a-z0-9]+/ /g;
    return join ' ', sort split ' ', $s;
}

# Which Open Opus works COULD raise one of the rule's ORDER signals for a
# library work, keyed by what each signal compares: a catalogue number (with
# its sub-number; without it, its letter aside), a type and number, a main
# title, a title's or nickname's first word, any word of the title. A SUPERSET:
# match only ever chooses among works raising an ORDER signal, so leaving the
# rest out cannot change an answer (t_classical.pl's parity run proves it), and
# Bach's 975 works stop costing a full pass per library work.
sub _index {
    my ($works) = @_;
    my %ix;
    for my $i (0 .. $#$works) {
        my $f = _ooFeatures($works->[$i]);
        my %keys;
        $keys{"F$_"} = 1 for keys %{ $f->{full} };
        $keys{'B' . _strip_letter($_)} = 1 for keys %{ $f->{base} };
        $keys{"T$_"} = 1 for keys %{ $f->{tn} };
        $keys{'E' . join(' ', @{ _nocount($_) })} = 1 for grep { @$_ } @{ $f->{mains} };
        $keys{'W' . $_->[0][0]} = 1 for @{ $f->{real} };
        $keys{'W' . (split ' ', $_)[0]} = 1 for @{ $f->{nick} };
        $keys{"A$_"} = 1 for keys %{ $f->{all}{set} };
        push @{ $ix{$_} }, $i for keys %keys;
    }
    return \%ix;
}

sub _candidates {
    my ($L, $ix) = @_;
    my %c;
    my $add = sub { $c{$_} = 1 for @{ $ix->{ $_[0] } || [] } };
    $add->("F$_") for keys %{ $L->{full} };
    $add->('B' . _strip_letter($_)) for keys %{ $L->{base} };
    $add->("T$_") for keys %{ $L->{tn} };
    my $lm = _nocount($L->{main});
    $add->('E' . join(' ', @$lm)) if @$lm;
    $add->("W$_") for keys %{ $L->{all}{set} };
    $add->('A' . (split ' ', $_)[0]) for @{ $L->{nick} };
    return [ sort { $a <=> $b } keys %c ];    # the works' own order: ties take the first
}

sub _indexFor {
    my ($mbid, $works) = @_;
    my $m = $IDX{$mbid};
    return $m->{ix} if $m && $m->{works} == $works;
    %IDX = () if keys(%IDX) >= WORKS_MEMO_MAX;
    $IDX{$mbid} = { works => $works, ix => _index($works) };
    return $IDX{$mbid}{ix};
}

# ($index into $works, $rule) for a library work title, or (undef, $reason).
# $ix (optional): _index($works), so only the works that could match are scored.
sub match {
    my ($class, $libTitle, $works, $ix) = @_;
    my $L = lib_features($libTitle);
    my @C;
    for my $i ($ix ? @{ _candidates($L, $ix) } : (0 .. $#$works)) {
        my $w  = $works->[$i];
        my $sg = signals($L, _ooFeatures($w));
        $sg->{rec} = $w->{recommended} ? 1 : 0;
        $sg->{pop} = $w->{popular} ? 1 : 0;
        push @C, [ $i, $sg, $w->{title} ];
    }
    my $amb;
    for my $k (0 .. $#ORDER) {
        my $sig = $ORDER[$k];
        my @hits = grep { $_->[1]{$sig} } @C;
        if ($sig eq 'title_in' && @hits) {
            my ($best) = sort { $b <=> $a } map { $_->[1]{$sig} } @hits;
            @hits = grep { $_->[1]{$sig} == $best } @hits;
        }
        @hits = grep { $_->[1]{key_ok} } @hits if $KEYED{$sig};
        next unless @hits;
        return ($hits[0][0], $sig) if @hits == 1;
        # A tie: the weaker signals decide, then the key, then Open Opus's repeats collapse.
        for my $tb (@ORDER[$k + 1 .. $#ORDER], 'key_ok', @TIES) {
            if ($tb eq 'overlap') {
                my ($best) = sort { $b <=> $a } map { $_->[1]{$tb} } @hits;
                my @sub = grep { $_->[1]{$tb} == $best } @hits;
                return ($sub[0][0], "$sig+$tb") if @sub == 1;
                @hits = @sub;
                next;
            }
            my @sub = grep { $_->[1]{$tb} } @hits;
            return ($sub[0][0], "$sig+$tb") if @sub == 1;
            @hits = @sub if @sub;
        }
        my %bags = map { _bag($_->[2]) => 1 } @hits;
        return ($hits[0][0], "$sig (duplicate entries)") if keys(%bags) == 1;
        if ($sig eq 'cat_full') {            # pieces of one set: the set entry may decide
            $amb //= "$sig ambiguous";
            next;
        }
        return (undef, "$sig ambiguous");
    }
    return (undef, $amb // 'no rule');
}

# ---------------------------------------------------------------------------
# The library side (LMS's Works data, from the files' WORK tags)
# ---------------------------------------------------------------------------

sub _nameKey {
    (my $s = fold($_[0])) =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^ +| +$//g;
    return $s;
}

sub _query {
    my ($cmd) = @_;
    my $r = eval { Slim::Control::Request::executeRequest(undef, $cmd) };
    return $r;
}

# Library COMPOSER contributors whose name is one of these names exactly (the
# name tier's own match, _nameKey), deduplicated, in name order.
sub _composerIdsNamed {
    my ($names) = @_;
    my (%keys, %seen, @ids);
    for my $name (grep { defined && length } @{ $names || [] }) {
        my $k = _nameKey($name);
        next if !length $k || $keys{$k}++;
        my $r = _query(['artists', 0, 20, 'search:' . _chars($name), 'role_id:COMPOSER']) or next;
        push @ids, grep { !$seen{$_}++ }
                   map  { $_->{id} }
                   grep { $_->{id} && _nameKey($_->{artist}) eq $k }
                   @{ $r->getResult('artists_loop') || [] };
    }
    return @ids;
}

# The composer's library works: [ { work_id, title, album_id, artwork } ]. The
# composer's library ids come from the page's artist_id, else the library's
# MusicBrainz tag, else his name with the COMPOSER role (plan §9.5); each is
# tried only when the one before found no works. `works artist_id:` also lists
# works a contributor PERFORMED (measured on the rig, 9.1.2: Karajan's are
# Debussy's, Mussorgsky's and Ravel's), so only rows whose composer is one of
# these ids are kept.
sub libraryWorks {
    my ($class, %a) = @_;
    my $run = sub {
        my %ids = map { $_ => 1 } grep { defined && length } @_;
        return [] unless %ids;
        my (@out, %seen);
        for my $id (sort keys %ids) {
            my $r = _query(['works', 0, LIB_WORKS_MAX, "artist_id:$id"]) or next;
            for my $e (@{ $r->getResult('works_loop') || [] }) {
                next unless $e->{work_id} && defined $e->{work} && length $e->{work};
                next unless grep { $ids{$_} } split /\s*,\s*/, ($e->{composer_id} // '');
                next if $seen{ $e->{work_id} }++;
                push @out, { work_id => $e->{work_id}, title => _chars($e->{work}),
                             album_id => $e->{album_id}, artwork => $e->{artwork_track_id} };
            }
        }
        return \@out;
    };

    my %tried;
    if ($a{artist_id}) {
        $tried{ $a{artist_id} } = 1;
        my $r = $run->($a{artist_id});
        return $r if @$r;
    }
    if ($a{mbid} && Plugins::Discography::Sources->can('localArtistIdsByMbid')) {
        my @tag = grep { !$tried{$_}++ } Plugins::Discography::Sources::localArtistIdsByMbid($a{mbid});
        # With the tag, the composer's own UNTAGGED exact-name entries too: a
        # joint credit can carry his tag while his own entry carries none
        # (Sources::localArtistIdsByIdentity, 2026-10-07). One tagged with
        # another id stays out, as there.
        if (@tag && Plugins::Discography::Sources->can('_contributorTag')) {
            # Tag checked BEFORE marking tried: one tagged with another id is not
            # this tier's, and the name tier below still sees it as it did.
            push @tag, grep { !length(Plugins::Discography::Sources::_contributorTag($_) // '')
                              && !$tried{$_}++ }
                       _composerIdsNamed($a{names});
        }
        my $r = $run->(@tag);
        if (@$r) {
            _dbg("classical: library works by MusicBrainz tag (artist_id " . join('+', @tag) . ')');
            return $r;
        }
    }
    my %keys;
    for my $name (grep { defined && length } @{ $a{names} || [] }) {
        my $k = _nameKey($name);
        next if !length $k || $keys{$k}++;
        # One name at a time: the first name whose entries hold works decides.
        my @ids = grep { !$tried{$_}++ } _composerIdsNamed([ $name ]);
        my $w = $run->(@ids);
        if (@$w) {
            _dbg("classical: library works by name '$name' (artist_id " . join('+', @ids) . ')');
            return $w;
        }
    }
    return [];
}

# Which Open Opus works the library holds: { byWork => { id => [ library works ] },
# other => [ library works no Open Opus work matched ] }. Several library works
# can name one Open Opus work (movement-level tags). Kept per composer until his
# library works change.
sub owned {
    my ($class, $mbid, $works, $lib) = @_;
    $mbid = lc($mbid // '');
    my $sig = join "\n", map { "$_->{work_id}\x1f$_->{title}" } sort { $a->{work_id} <=> $b->{work_id} } @{ $lib || [] };
    my $memo = $OWNED{$mbid};
    return $memo->{answer} if $memo && $memo->{sig} eq $sig && $memo->{works} == $works;

    my (%by, @other);
    for my $lw (@{ $lib || [] }) {
        my ($i, $why) = $class->match($lw->{title}, $works, _indexFor($mbid, $works));
        if (defined $i) { push @{ $by{ $works->[$i]{id} } }, $lw }
        else            { push @other, $lw }
    }
    my $answer = { byWork => \%by, other => \@other };
    _dbg("classical: $mbid - " . scalar(@{ $lib || [] }) . ' library work(s), '
         . scalar(keys %by) . ' Open Opus work(s) owned, ' . scalar(@other) . ' other');
    $OWNED{$mbid} = { sig => $sig, works => $works, answer => $answer };
    @OWNED_ORDER = ((grep { $_ ne $mbid } @OWNED_ORDER), $mbid);
    delete $OWNED{ shift @OWNED_ORDER } while @OWNED_ORDER > OWNED_MEMO_MAX;
    return $answer;
}

# The library albums holding these LMS works, each with the work's own tracks:
# [ { name, image, _albumid, _year, _artist, _tracks => [ track ids ] } ], by
# year then title (the work page, plan §10.5 item 4). Several LMS works can be
# one Open Opus work (The Four Seasons: one per concerto, or per movement), so
# the tracks are gathered per album across them:
#   * `tracks work_id:` for each work, `performance:-1` (every performance:
#     without it LMS keeps only the tracks that have none), in the album's own
#     order (disc, track number), so playing the list plays the work as the
#     album has it, and "play from here" lands on the track tapped;
#   * then ONE `albums album_id:<list>` read for the title, year, cover and
#     artist: under `work_id:` LMS's `albums` answers no artist even for tag `a`
#     (measured on the rig 2026-10-08), with the album ids it does.
sub albumsFor {
    my ($class, $workIds) = @_;
    my (%tracks, @ids);
    for my $wid (@{ $workIds || [] }) {
        next unless defined $wid && $wid =~ /^\d+$/;
        my $r = _query(['tracks', 0, WORK_TRACKS_MAX, "work_id:$wid", 'performance:-1', 'tags:eit']) or next;
        for my $t (@{ $r->getResult('titles_loop') || [] }) {
            my ($tid, $al) = ($t->{id}, $t->{album_id});
            next unless defined $tid && $tid =~ /^\d+$/ && defined $al && $al =~ /^\d+$/;
            push @ids, $al unless $tracks{$al};
            $tracks{$al}{$tid} = [ $t->{disc} || 0, $t->{tracknum} || 0 ];
        }
    }
    splice @ids, WORK_ALBUMS_MAX if @ids > WORK_ALBUMS_MAX;
    return [] unless @ids;

    my $r = _query(['albums', 0, scalar @ids, 'album_id:' . join(',', @ids), 'tags:ljya']);
    my @out;
    for my $e (@{ ($r && $r->getResult('albums_loop')) || [] }) {
        next unless $e->{id} && defined $e->{album} && $tracks{ $e->{id} };
        my $t = $tracks{ $e->{id} };
        push @out, { name => _chars($e->{album}), _albumid => $e->{id}, _year => $e->{year},
                     _artist => _chars($e->{artist} // ''),
                     _tracks => [ sort { $t->{$a}[0] <=> $t->{$b}[0] || $t->{$a}[1] <=> $t->{$b}[1] || $a <=> $b } keys %$t ],
                     ($e->{artwork_track_id} ? (image => "/music/$e->{artwork_track_id}/cover") : ()) };
    }
    return [ sort { ($a->{_year} || 9999) <=> ($b->{_year} || 9999) || lc $a->{name} cmp lc $b->{name} } @out ];
}

1;
