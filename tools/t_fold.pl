#!/usr/bin/env perl
#
# REGRESSION TEST — the SEARCH-ROW FOLD, end to end through the real
# `filterRowsWithContent`. Three field bugs in a row have lived in this block
# (0.46.2 attach, 0.46.3 missing canonical name, 0.46.5 relabel), and every one
# of them presented as "the wrong text in a row" while actually breaking
# MATCHING — because the row's name IS the artist identity everything
# downstream resolves by.
#
# THE 0.46.5 CASE (Simon, 2026-07-22): "still missing the artist artwork for
# The b52s". MB's canonical name for that band carries a U+2010 HYPHEN, and
# nothing else in the chain can resolve that string. Measured on the live LMS
# image proxy, same session:
#
#   "The B-52s"  (the library's spelling, ASCII) -> 1,966,381 bytes, a photo
#   "The B‐52s"  (MusicBrainz canonical)         ->     5,071 bytes, the
#                                                       silhouette placeholder
#
# The artwork is only the visible half: `localAlbums` resolves by name too, and
# so does the matcher's artist gate. So when a folded row already carries a
# library artist_id, the LIBRARY's spelling must win — MB canonical stays the
# answer for a row the library does not know (the 0.44.20 case, asserted here
# too so the fix cannot quietly disable it).
#
# Standalone -- no LMS install needed:  perl tools/t_fold.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;
my $DATA;
my @URLS;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { $DATA };
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my ($cls, $cb, $errcb, $opt) = @_;
        return bless { cb => $cb, err => $errcb }, 'T::HTTP';
    };
    # The Local search leg is not exercised here — rows are handed in directly,
    # exactly as mergeArtistHits produces them.
    *{'Slim::Control::Request::executeRequest'} = sub { undef };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get { return $CACHE{ $_[1] } }
sub set { $CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
# A MIRROR base, which is what makes this reachable at all: the whole filter
# is skipped when MusicBrainz is throttled (API.pm's mbGap gate).
sub get { return $_[1] eq 'mb_base_url' ? 'http://mirror:5000/ws/2/' : undef }
sub set { return 1 } sub init { return 1 } sub setChange { return 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { 'stub error' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @URLS, $url;
    $DATA = main::response_for($url);
    $self->{cb}->(T::Resp->new);
}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;
my $API = 'Plugins::Discography::API';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    # STRUCTURAL GUARD against the list-context trap that has cost time five
    # times in this repo: a bare `=~` (or grep/map) in ok()'s argument list
    # returns the EMPTY LIST on failure, which shifts the test NAME into the
    # condition slot so a FAILING assertion prints as a pass. A missing name is
    # the fingerprint, so refuse it loudly instead of scoring it.
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# THE REAL RECORD from the mirror (canonical name carries U+2010 HYPHEN).
my $MBID  = '127f591a-7e27-4435-92db-0780f219f3a1';
my $CANON = "The B\x{2010}52s";
my @ALIAS = ('B-52s', "B52's", "The B-52's", 'The B52s');

# Every row resolves to the same artist; the alias list gates the fold.
# $FIX lets one section swap in a different MB record (a canonical name with NO
# aliases), which is what isolates the joint-credit fold from the alias fold.
our $FIX;
sub response_for {
    my ($url) = @_;
    my $canon = $FIX ? $FIX->{canon}   : $CANON;
    my @al    = $FIX ? @{ $FIX->{aliases} } : @ALIAS;
    return { artists => [ { id => $MBID, name => $canon, score => 100 } ] }
        if $url =~ /artist\?query=/;
    return { 'release-group-count' => 80 } if $url =~ /release-group\?artist=/;
    return { name => $canon, aliases => [ map { { name => $_ } } @al ] }
        if $url =~ /artist\/[0-9a-f-]+\?inc=aliases/;
    return {};
}

sub fold {
    my (@rows) = @_;
    %CACHE = (); @URLS = ();
    my $out;
    $API->filterRowsWithContent([@rows], sub { $out = $_[0] });
    return $out;
}

# Same, against an MB record with a different canonical name and no aliases.
sub foldAs {
    my ($canon, $aliases, @rows) = @_;
    local $FIX = { canon => $canon, aliases => $aliases };
    return fold(@rows);
}

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE. A service-spelled row and the LIBRARY's row fold together;
#    the survivor must wear the library's ASCII spelling, NOT MB's U+2010 one.
# ---------------------------------------------------------------------------
my $out = fold(
    { name => "B52's",     sources => ['Qobuz'] },
    { name => 'The B-52s', sources => ['Local'], artist_id => 62125 },
);
ok(ref $out eq 'ARRAY' && scalar(@$out) == 1, 'the two rows fold into one');
ok(($out->[0]{name} // '') eq 'The B-52s',
   'the folded row keeps the LIBRARY spelling, not MB canonical');
ok(($out->[0]{name} // '') ne $CANON, '... which is NOT the U+2010 canonical name');
ok(($out->[0]{artist_id} // 0) == 62125, '... and carries the library artist_id');
ok(scalar(@{ $out->[0]{sources} }) == 2, '... speaking for BOTH services');

# ---------------------------------------------------------------------------
# 2. 0.44.20 MUST STILL WORK. With no library artist, neither service spelling
#    is authoritative and MB's canonical name is exactly the right answer —
#    this is the bug that entry was written for ("Layo and bushwacka" vs
#    "Layo & Bushwacka!" depending on what was typed).
# ---------------------------------------------------------------------------
$out = fold(
    { name => "B52's",      sources => ['Qobuz'] },
    { name => "The B-52's", sources => ['Deezer'] },
);
ok(scalar(@$out) == 1, 'with no library artist the rows still fold');
ok(($out->[0]{name} // '') eq $CANON,
   '... and MB canonical still labels the row (0.44.20 intact)');

# ---------------------------------------------------------------------------
# 3. A LONE row is never relabelled — only duplicated groups fetch aliases, and
#    a per-row MB request at search time is the cost this design avoids.
# ---------------------------------------------------------------------------
$out = fold({ name => "B52's", sources => ['Qobuz'] });
ok(scalar(@$out) == 1 && ($out->[0]{name} // '') eq "B52's",
   'a lone row keeps its own name');

# ---------------------------------------------------------------------------
# 4. A row that leads NOWHERE is still dropped (0.44.7), and a row the MB
#    lookup cannot resolve must not take the others down with it.
# ---------------------------------------------------------------------------
{
    no warnings 'redefine';
    local *main::response_for = sub {
        my ($url) = @_;
        return { artists => [] } if $url =~ /artist\?query=/;
        return { 'release-group-count' => 0 } if $url =~ /release-group\?artist=/;
        return {};
    };
    $out = fold({ name => 'Nobody At All', sources => ['Tidal'] });
    ok(ref $out eq 'ARRAY' && !@$out, 'an unresolvable row is still dropped');
}

# ---------------------------------------------------------------------------
# 5. A LIBRARY row is never filtered away (0.44.7) — an artist the user owns
#    that MB does not list must not vanish from search.
# ---------------------------------------------------------------------------
{
    no warnings 'redefine';
    local *main::response_for = sub {
        my ($url) = @_;
        return { artists => [] } if $url =~ /artist\?query=/;
        return {};
    };
    $out = fold({ name => 'Home Taping', sources => ['Local'], artist_id => 99 });
    ok(scalar(@$out) == 1 && ($out->[0]{name} // '') eq 'Home Taping',
       'a library row survives even when MB knows nothing');
}

# ---------------------------------------------------------------------------
# 6. THE EMPTY-ARTIST VERDICT (0.46.6). Field (Simon): dead-end rows "still
#    popping up". Measured live on a "bush" search: Luke Bushell has 8 release
#    groups in MB — so the release-COUNT filter rightly keeps him — but
#    `pool: Deezer=1, Qobuz=1, Tidal=1` with every group NO MATCH, so the page
#    reads "No releases found". Once a render has proven that, the row goes.
#
#    The WRITE side and its four guards live in Browse::_buildList; what is
#    asserted here is that the verdict is honoured, survives nothing it
#    shouldn't, and is undone by Refresh.
# ---------------------------------------------------------------------------
$out = fold({ name => "B52's", sources => ['Qobuz'] });
ok(scalar(@$out) == 1, 'control: with no verdict recorded the row is kept');

# fold() resets the cache, so the verdict is seeded through the same call.
%CACHE = (); @URLS = ();
$CACHE{ 'dsc:empty:1:' . $MBID } = 1;
$out = undef;
$API->filterRowsWithContent([{ name => "B52's", sources => ['Qobuz'] }],
                            sub { $out = $_[0] });
ok(ref $out eq 'ARRAY' && !@$out, 'a row PROVEN empty by an earlier render is dropped');
# The verdict still OUTRANKS the filter's own release-count pass — the filter
# adds nothing of its own once the row is known empty. What it can no longer
# claim is "no release-group request at all": since 0.47.1 the RESOLVER counts
# release groups when MB's winner is not named as typed (the Shostakovich Trio
# case), and that runs before any verdict can be read. One local request on a
# mirror, which is the only place this filter ever runs.
ok(scalar(grep { m|release-group\?artist=| } @URLS) <= 1,
   '... adding no count pass of its own (the resolver\'s identity check aside)');

# A library row never reaches the check — owning the music outranks any verdict.
%CACHE = (); @URLS = ();
$CACHE{ 'dsc:empty:1:' . $MBID } = 1;
$out = undef;
$API->filterRowsWithContent(
    [{ name => 'The B-52s', sources => ['Local'], artist_id => 62125 }],
    sub { $out = $_[0] });
ok(scalar(@$out) == 1, 'a LIBRARY row survives the verdict (0.44.7 exemption)');

# Refresh must be able to say "look again".
%CACHE = ();
$API->markArtistEmpty($MBID, 'Test Artist');
ok($API->peekArtistEmpty($MBID), 'markArtistEmpty records the verdict');
$API->clearArtistCache(mbid => $MBID);
ok(!$API->peekArtistEmpty($MBID), '... and clearArtistCache (Refresh) drops it');
ok(!$API->peekArtistEmpty(undef), 'no mbid is never "empty"');

# ---------------------------------------------------------------------------
# 7. clearArtistCache REPORTS THE MBID IT RESOLVED (0.46.7). Cleared by name,
#    it recovers the mbid from the name cache — and then clears that cache, so
#    the caller cannot look it up afterwards. The CLI reply used to echo the
#    mbid PASSED IN, reporting mbid="" while the log showed a real one being
#    cleared. It also matters functionally: candidate pools are mbid-scoped
#    (0.43.2), so the recovered mbid is what lets a clear-by-name reach them.
# ---------------------------------------------------------------------------
%CACHE = ();
my $nameKey = 'dsc:mbid:2:luke bushell';
$CACHE{$nameKey} = $MBID;
$API->markArtistEmpty($MBID, 'Luke Bushell');
my ($cleared, $used) = $API->clearArtistCache(name => 'Luke Bushell');
ok(($used // '') eq lc $MBID, 'clearing by NAME reports the mbid it resolved');
ok(ref $cleared eq 'ARRAY' && (grep { $_ eq 'empty' } @$cleared),
   '... and says it cleared the empty verdict');
ok(!$API->peekArtistEmpty($MBID), '... which is genuinely gone');
my $scalar = $API->clearArtistCache(name => 'Nobody');
ok(ref $scalar eq 'ARRAY',
   'SCALAR context still returns just the cleared list (existing callers)');

# ---------------------------------------------------------------------------
# A JOINT CREDIT FOLDS TOO (0.48.5).
#
# Simon: *"Nick Cave & Warren Ellis is the same as Panda Bear & Sonic Boom ...
# why is it being treated differently as we sorted our conjoined artists some
# time ago"* and *"this never got implemented into search and is just row
# based."* 0.47.0 taught the RESOLVER about joint credits — verified live that
# MusicBrainz has no such artist (`artist:"Nick Cave & Warren Ellis"` count=0,
# same for Panda Bear & Sonic Boom, while Robert Plant & Alison Krauss count=1,
# which is the only reason that one behaved differently) — but this gate still
# demanded an MB ALIAS, so the split row stayed a duplicate. Straight from one
# log window: Neil Young & The Chrome Hearts, Lou Reed and Kris Kristofferson,
# Lou Reed & John Cale, Nick Cave & Warren Ellis — all "NOT folding".
#
# The MB record here carries NO aliases, so ONLY the credit split can fold it.
# ---------------------------------------------------------------------------
$out = foldAs('Nick Cave', [],
    { name => 'Nick Cave',                sources => ['Qobuz'], artist_id => 46825 },
    { name => 'Nick Cave & Warren Ellis', sources => ['Tidal'] },
);
ok(ref $out eq 'ARRAY' && scalar(@$out) == 1,
   'a joint-credit row folds into the head artist it resolved to');
ok(($out->[0]{name} // '') eq 'Nick Cave', '... keeping the head artist as the row');
ok(scalar(@{ $out->[0]{sources} || [] }) == 2, '... and speaking for BOTH services');

# Order must not matter: the joint credit can be the SURVIVOR just as easily,
# since which row survives depends on the merge ranking (0.44.20's lesson).
$out = foldAs('Nick Cave', [],
    { name => 'Nick Cave & Warren Ellis', sources => ['Tidal'] },
    { name => 'Nick Cave',                sources => ['Qobuz'] },
);
ok(scalar(@$out) == 1, '... and folds with the joint credit listed FIRST too');

# Every separator `_creditHead` knows, since the field cases used several.
for my $joint ('Lou Reed and Kris Kristofferson', 'Lou Reed & John Cale',
               'Lou Reed feat. John Cale', 'Lou Reed / John Cale') {
    my $o = foldAs('Lou Reed', [],
        { name => 'Lou Reed', sources => ['Qobuz'] },
        { name => $joint,     sources => ['Tidal'] },
    );
    ok(scalar(@$o) == 1, "'$joint' folds into Lou Reed");
}

# ---------------------------------------------------------------------------
# THE GUARD THAT MAKES IT SAFE — and it is the 0.44.13 withdrawal in test form.
# Two rows sharing an mbid whose names are neither an alias NOR a credit split
# of one another must STILL stay apart. That is the rule that stopped
# "Kate Bush" being folded into "Bush" when the resolver mis-scored them.
# ---------------------------------------------------------------------------
$out = foldAs('Bush', [],
    { name => 'Bush',      sources => ['Qobuz'] },
    { name => 'Kate Bush', sources => ['Tidal'] },
);
ok(scalar(@$out) == 2,
   'CONTROL: same mbid but no alias and no credit split -> rows stay SEPARATE');

# A credit head must match the OTHER row, not merely exist. "Belle and
# Sebastian" splits to "Belle", which is nobody here.
$out = foldAs('Belle and Sebastian', [],
    { name => 'Belle and Sebastian', sources => ['Qobuz'] },
    { name => 'Isobel Campbell',     sources => ['Tidal'] },
);
ok(scalar(@$out) == 2,
   'CONTROL: a split head that matches neither the other row nor canonical -> no fold');

# ---------------------------------------------------------------------------
# THE 0.48.7 FIELD BUG — a joint credit MusicBrainz has a real artist for must
# NOT be folded into a member. Simon: searching "Robert Plant" lost the "Robert
# Plant & Alison Krauss" row, while "Alison Krauss" kept it. The duo IS a real
# MB artist whose canonical name is the whole credit; the two rows shared its
# mbid only because the user's library tagged the MEMBER contributor with the
# DUO's id, dropping the member row into the duo's fold group where its head
# matched. The discriminator: the credit's own name IS the canonical name here
# (unlike Nick Cave & Warren Ellis, whose group is the head's mbid).
# ---------------------------------------------------------------------------
$out = foldAs('Robert Plant & Alison Krauss', [],
    { name => 'Robert Plant',                sources => ['Qobuz'], artist_id => 65658 },
    { name => 'Robert Plant & Alison Krauss', sources => ['Tidal'] },
);
ok(scalar(@$out) == 2,
   'a real MB duo is NOT folded into a member (its name IS the canonical name)');
ok(scalar(grep { ($_->{name} // '') eq 'Robert Plant & Alison Krauss' } @$out),
   '... so the duo keeps its own search row');

# And the reverse pairing (the member listed second) must behave identically —
# folding must not depend on which row happens to survive.
$out = foldAs('Robert Plant & Alison Krauss', [],
    { name => 'Robert Plant & Alison Krauss', sources => ['Tidal'] },
    { name => 'Robert Plant',                sources => ['Qobuz'], artist_id => 65658 },
);
ok(scalar(@$out) == 2, '... whichever order the two rows arrive in');

# ---------------------------------------------------------------------------
# THE VERDICT IS NOW FALSIFIABLE (0.48.5). Field: solo Nick Cave vanished from
# search behind a verdict his own page disproves on sight (9 albums, 5 singles,
# a compilation — rendered live). It could only ever be SET.
# ---------------------------------------------------------------------------
%CACHE = ();
ok(!$API->clearArtistEmpty($MBID), 'clearing an absent verdict reports nothing done');
$API->markArtistEmpty($MBID, 'Nick Cave');
ok($API->peekArtistEmpty($MBID), 'the verdict is set');
ok($API->clearArtistEmpty($MBID), '... a render with content clears it');
ok(!$API->peekArtistEmpty($MBID), '... and it is genuinely gone');
ok(!$API->clearArtistEmpty(undef), 'no mbid clears nothing');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
