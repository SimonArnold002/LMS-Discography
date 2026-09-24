#!/usr/bin/env perl
#
# REGRESSION TEST — bio / review prose, ported from LBF (2026-09-24).
#
# MAI hands the artist biography AND the album review over as Wikipedia HTML
# (<p>, <h2>/<h3>, <ul><li>, inline <a>, a trailing "More online sources" <h4>
# over a link list). The old `_stripHtml` glued every section title onto the
# paragraph after it ("Description and historyInitially formed ...") and ended
# the text with the link list run together ("(Source: Wikipedia)More online
# sourcesAllMusicApple...").
#
# FIXTURES ARE CAPTURED, NOT WRITTEN (tools/fixtures/mai_*.html): the verbatim
# `biography` / `albumreview` fields MAI returned on the live server on
# 2026-09-24 for `["musicartistinfo","biography","html:1","artist:Lambchop"]`,
# `albumreview ... artist:Lambchop album:Nixon` and `... artist:Radiohead
# album:OK Computer`. A hand-built HTML sample would encode our belief about
# MAI's shape — exactly what a test must not share with the code.
#
# Drives the REAL subs: `_cleanBio`, `_bioParagraphs`, `_proseBlock`,
# `_proseSection`, `_cleanProse`, and both fetch sites (`_fetchArtistBio`,
# `_fetchAlbumReview`) with MAI stubbed to return the captured HTML.
#
# Standalone — no LMS install needed:  perl tools/t_prose.pl
#
use strict;
use warnings;
use FindBin;

our (%CACHE, $MAI_BIO, $MAI_REVIEW, @MAI_CALLS);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  Plugins::Discography::Plugin Plugins::Discography::API
                  Plugins::Discography::Sources)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Null' };
    # A real (in-memory) cache, so the fetch sites' key and stored shape can be
    # asserted. DbCache stores OCTETS; _cacheSetText encodes before set.
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { 1 };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # Browse.pm builds a table with it at load time (as t_detailshared.pl).
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    # MAI's direct functions, answering the way MAI does: the text in an item's
    # `name`, delivered to the callback. The HTML itself is the captured payload.
    *{'Plugins::MusicArtistInfo::ArtistInfo::getBiography'} = sub {
        my ($client, $cb, $params, $args) = @_;
        push @main::MAI_CALLS, ['bio', $args->{artist}];
        $cb->([ { name => $main::MAI_BIO } ]);
    };
    *{'Plugins::MusicArtistInfo::AlbumInfo::getAlbumReview'} = sub {
        my ($client, $cb, $params, $args) = @_;
        push @main::MAI_CALLS, ['review', $args->{album}];
        $cb->([ { name => $main::MAI_REVIEW } ]);
    };
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Cache;
sub get    { $main::CACHE{ $_[1] } }
sub set    { $main::CACHE{ $_[1] } = $_[2]; 1 }
sub remove { delete $main::CACHE{ $_[1] } }
sub DESTROY {}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';
sub f { my $n = shift; my $c = $B->can($n) or die "no sub $n\n"; $c->(@_) }

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

sub fixture {
    my $p = "$FindBin::Bin/fixtures/$_[0]";
    open my $fh, '<:encoding(UTF-8)', $p or die "fixture $p: $!";
    local $/; my $t = <$fh>; return $t;
}
my $LAMBCHOP = fixture('mai_bio_lambchop.html');
my $NIXON    = fixture('mai_review_lambchop_nixon.html');
my $OKC      = fixture('mai_review_radiohead_okcomputer.html');

sub heads  { map { $_->{text} } grep {  $_->{heading} } @_ }
sub bodies { map { $_->{text} } grep { !$_->{heading} } @_ }

# ---------------------------------------------------------------------------
# 1. The field case: Lambchop's biography.
# ---------------------------------------------------------------------------
{
    my $clean = f('_cleanBio', $LAMBCHOP);
    my @p     = f('_bioParagraphs', $clean);
    my $all   = join "\n", map { $_->{text} } @p;

    ok(scalar(grep { $_ eq 'Description and history' } heads(@p)), '1: "Description and history" is its own heading');
    ok(scalar(grep { $_ eq 'Personal lives' } heads(@p)),          '1: "Personal lives" is its own heading');
    ok(scalar(grep { $_ eq 'Personnel' } heads(@p)),               '1: "Personnel" is its own heading');
    ok(scalar($all !~ /historyInitially|livesSinger|PersonnelSummary/),
       '1: no heading is glued onto the paragraph after it (the old _stripHtml shape)');
    ok(scalar($all !~ /More online sources|AllMusic|Bandcamp|Rate Your Music/),
       '1: the "More online sources" link list is gone, heading and links');
    ok(scalar($p[0]{text} =~ /^Lambchop, originally Posterchild, is an American band/),
       '1: first block is the opening paragraph, inline <b> dropped without a stray space');
    ok(scalar($clean !~ /<|mai\.css/), '1: no markup and no MAI <link> stylesheet survives');
    ok(scalar(@p == 13), '1: 13 blocks (measured 2026-09-24; the old split gave 10 glued rows)');
    ok(scalar($p[-1]{text} eq '(Source: Wikipedia)'), '1: attribution kept as the last body block');
}

# ---------------------------------------------------------------------------
# 2. A review: Nixon, the same shape through the review path.
# ---------------------------------------------------------------------------
{
    my @p = f('_bioParagraphs', f('_cleanBio', $NIXON));
    ok(scalar(join('|', heads(@p)) eq 'Composition|Artwork and title|Release|Critical reception'),
       '2: the review carries its four section headings, in order');
    ok(scalar(!grep { /More online sources|Tidal|Spotify/ } map { $_->{text} } @p),
       '2: the review\'s link list is gone');
}

# ---------------------------------------------------------------------------
# 3. A LONG review is not cut in half, and its row count is what was measured.
#    LBF's BIO_MAX (20000) would have cut OK Computer's 39,776 chars in two.
# ---------------------------------------------------------------------------
{
    my $clean = f('_cleanBio', $OKC);
    my @p     = f('_bioParagraphs', $clean);
    ok(scalar(length($clean) > 20000), '3: OK Computer review is longer than LBF\'s 20000 cap');
    ok(scalar($clean !~ /\x{2026}\z/), '3: ... and is NOT truncated (PROSE_MAX is Discography\'s own)');
    ok(scalar($p[-1]{text} eq '(Source: Wikipedia)'), '3: the last block survives');
    ok(scalar(@p == 73), '3: 73 blocks (measured: the page stays under Material\'s 100-row scroller)');
    ok(scalar(grep { $_ eq 'Critical reception' } heads(@p)), '3: a late heading is still a heading');
}

# ---------------------------------------------------------------------------
# 4. _proseSection: the three shapes, on real text.
# ---------------------------------------------------------------------------
{
    my $clean = f('_cleanBio', $LAMBCHOP);

    my ($rows, $trunc) = f('_proseSection', $clean, 0);
    ok(scalar(@$rows == 1 && $trunc), '4: collapsed = ONE summary row, toggle needed');
    my $sum = $rows->[0]{name};
    ok(scalar($sum !~ /---/),                '4: the summary carries no setext underline');
    ok(scalar($sum !~ /Description and history/), '4: the summary is built from BODY blocks, not headings');
    ok(scalar($sum =~ /\x{2026}<\/div>\z/),  '4: the summary ends with an ellipsis');
    ok(scalar($sum =~ /^<div style='margin-left:72px'>Lambchop, originally/), '4: summary on the 72px indent');

    # Lambchop's first 380 chars hold no heading, so the assertion above cannot
    # tell a body-built summary from a whole-text one. This can: a heading sits
    # inside the summary window (the shape of Nixon's "Composition", measured).
    my $early = "Nixon is the fifth studio album.\n\nComposition\n----------\n\n"
              . join(' ', ('It merges chamber pop and soul.') x 20);
    my ($er) = f('_proseSection', $early, 0);
    ok(scalar($er->[0]{name} !~ /Composition/ && $er->[0]{name} =~ /album\. It merges/),
       '4: a heading inside the summary window is left out, body joined across it');

    my ($full, $t2) = f('_proseSection', $clean, 1);
    ok(scalar(@$full == 13 && $t2), '4: expanded = every block, one row each, toggle needed');
    my ($h) = grep { $_->{name} =~ />Personnel</ } @$full;
    ok(scalar($h && $h->{name} =~ /font-weight:bold/), '4: a heading row is bold by explicit weight');
    ok(scalar(!grep { $_->{name} =~ /<b>/ } @$full), '4: no bare <b> anywhere (Material inherits weight 200)');
    ok(scalar(!grep { ($_->{type} // '') ne 'text' } @$full), '4: every prose row is a plain text row (no image)');

    my ($short, $t3) = f('_proseSection', 'A short review. Nothing more to say.', 0);
    ok(scalar(@$short == 1 && !$t3 && $short->[0]{name} =~ /A short review/),
       '4: short text = inline, no toggle');

    my ($shead, $t4) = f('_proseSection', "Intro line here.\n\nReception\n----------\n\nIt was liked.", 0);
    ok(scalar(!$t4 && @$shead == 3 && $shead->[1]{name} =~ /font-weight:bold/),
       '4: short text WITH a heading still renders the heading, no toggle');

    # Whole text over the cut, BODY under it: must still collapse (and say so).
    my $longHeads = join "\n\n", map { "Section title number $_\n----------\nBody $_." } 1 .. 15;
    my ($lh, $t5) = f('_proseSection', $longHeads, 0);
    ok(scalar($t5 && @$lh == 1 && $lh->[0]{name} =~ / \x{2026}<\/div>\z/),
       '4: long-but-mostly-headings text collapses, with the ellipsis, instead of losing its rest');

    my ($none, $t6) = f('_proseSection', '', 0);
    ok(scalar(!@$none && !$t6), '4: empty text = no rows, no toggle');
}

# ---------------------------------------------------------------------------
# 5. _proseBlock: duplicate names, escaping, bullets.
# ---------------------------------------------------------------------------
{
    my @r = f('_proseBlock',
        { text => 'Personnel', heading => 1, bullet => 0 },
        { text => 'One.',      heading => 0, bullet => 0 },
        { text => 'Personnel', heading => 1, bullet => 0 },
        { text => 'Personnel', heading => 1, bullet => 0 });
    my %n; $n{ $_->{name} }++ for @r;
    ok(scalar(keys %n == 4), '5: repeated headings get DISTINCT row names (Material keys by title)');
    ok(scalar($r[0]{name} !~ /<!--/), '5: the first occurrence is untouched');
    ok(scalar($r[2]{name} =~ /Personnel<\/div><!--1-->$/ && $r[3]{name} =~ /<!--2-->$/),
       '5: later ones carry an invisible, counted comment');

    my ($e) = f('_proseBlock', { text => 'Tom & Jerry <live>', heading => 0, bullet => 0 });
    ok(scalar($e->{name} =~ /Tom &amp; Jerry &lt;live&gt;/), '5: decoded entities are escaped again');

    my @b = f('_bioParagraphs', f('_cleanBio',
        '<p>Members:</p><ul><li>Kurt Wagner - vocals</li><li>Tony Crow - piano</li></ul>'));
    my @br = f('_proseBlock', @b);
    ok(scalar(@b == 3 && $b[1]{bullet} && $b[2]{bullet}), '5: <li> items become bullet blocks');
    ok(scalar($br[1]{name} =~ /padding-left:1\.2em;text-indent:-1\.2em'>\x{2022}\x{00A0}Kurt Wagner/),
       '5: a bullet row has the bullet glyph and a hanging indent');

    my @inl = f('_bioParagraphs', f('_cleanBio',
        '<p>The band signed to <a href="x">Merge Records</a> in 1994.</p>'));
    ok(scalar($inl[0]{text} eq 'The band signed to Merge Records in 1994.'),
       '5: an inline link keeps its words');
}

# ---------------------------------------------------------------------------
# 6. _cleanProse: what counts as "no text".
# ---------------------------------------------------------------------------
{
    my $linksOnly = '<link rel="stylesheet" href="/x.css" /><h4>More online sources</h4>'
                  . '<ul><li><a href="a">AllMusic</a></li><li><a href="b">Discogs</a></li></ul>';
    ok(scalar(!defined f('_cleanProse', $linksOnly)), '6: a links-only MAI answer is NO text (no lone bold title)');
    ok(scalar(!defined f('_cleanProse', '')),    '6: empty is no text');
    ok(scalar(!defined f('_cleanProse', undef)), '6: undef is no text');
    ok(scalar(!defined f('_cleanProse', {})),    '6: a ref is no text');
    my $q = f('_cleanProse', "A Qobuz blurb.<br />Second line.\x{2028}Third line.");
    ok(scalar(defined $q && $q eq "A Qobuz blurb.\nSecond line.\nThird line."),
       '6: plain text with <br> and U+2028 is kept, breaks as newlines');
}

# ---------------------------------------------------------------------------
# 7. The fetch sites: MAI (stubbed with the captured HTML) -> cleaned -> cached
#    under the v2 key, and a links-only review falls through to Qobuz.
# ---------------------------------------------------------------------------
{
    %CACHE = (); @MAI_CALLS = ();
    $MAI_BIO = $LAMBCHOP;
    my $got;
    f('_fetchArtistBio', undef, 'Lambchop', undef, sub { $got = shift });
    ok(scalar(defined $got && $got =~ /\nDescription and history\n-{10}\n/),
       '7: bio fetch hands back the CLEANED text (setext heading), not stripped HTML');
    ok(scalar(exists $CACHE{'dsc:bio:2:lambchop'}), '7: bio cached under dsc:bio:2');
    ok(scalar(!grep { /^dsc:bio:1:/ } keys %CACHE), '7: nothing written under the old dsc:bio:1 key');

    my $again;
    f('_fetchArtistBio', undef, 'Lambchop', undef, sub { $again = shift });
    ok(scalar(@MAI_CALLS == 1 && defined $again && $again eq $got),
       '7: a second fetch is served from the cache, identical text');

    %CACHE = (); @MAI_CALLS = ();
    $MAI_REVIEW = $NIXON;
    my $rev;
    f('_fetchAlbumReview', undef, 'Lambchop', 'Nixon', 'rg-nixon', [], sub { $rev = shift });
    ok(scalar(defined $rev && $rev =~ /\nComposition\n-{10}\n/), '7: review fetch returns cleaned text');
    ok(scalar(exists $CACHE{'dsc:rev:2:rg-nixon'}), '7: review cached under dsc:rev:2');

    %CACHE = ();
    $MAI_REVIEW = '<h4>More online sources</h4><ul><li><a href="a">Tidal</a></li></ul>';
    my $sections = [ { items => [ { _desc => '<p>Qobuz says <b>hello</b> &amp; welcome.</p>' } ] } ];
    my $fb;
    f('_fetchAlbumReview', undef, 'Lambchop', 'Nixon', 'rg-x', $sections, sub { $fb = shift });
    ok(scalar(defined $fb && $fb eq 'Qobuz says hello & welcome.'),
       '7: a links-only MAI review falls back to the Qobuz description, cleaned the same way');

    %CACHE = ();
    my $none = 'unset';
    f('_fetchAlbumReview', undef, 'Lambchop', 'Nixon', 'rg-y', [], sub { $none = shift });
    ok(scalar(!defined $none && defined $CACHE{'dsc:rev:2:rg-y'} && $CACHE{'dsc:rev:2:rg-y'} eq ''),
       '7: nothing anywhere = undef, cached as confirmed-none');
}

# ---------------------------------------------------------------------------
# 8. Source-level: the old cleaner and old keys are gone, and the key the
#    clear-cache path removes is the key the fetch writes.
# ---------------------------------------------------------------------------
{
    my $src = do { local (@ARGV, $/) = ("$FindBin::Bin/../Discography/Browse.pm"); <> };
    my $api = do { local (@ARGV, $/) = ("$FindBin::Bin/../Discography/API.pm");    <> };
    (my $code = $src) =~ s/^\s*#.*$//mg;
    ok(scalar($code !~ /_stripHtml/), '8: no code path still calls _stripHtml');
    ok(scalar($code !~ /dsc:(?:bio|rev):1:/), '8: no code path still uses a v1 bio/review key');
    my ($bw) = $code =~ /'(dsc:bio:\d+:)'/;
    my ($bc) = $api  =~ /my \$bk = '(dsc:bio:\d+:)'/;
    ok(scalar(defined $bw && defined $bc && $bw eq $bc),
       "8: clearArtistCache clears the key _fetchArtistBio writes ($bc)");
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
