#!/usr/bin/env perl
#
# REGRESSION TEST — THE LADDER'S SERVICE CLIENTS (Prose.pm, 2026-10-08).
#
# Deezer, anonymous, no Deezer plugin (Simon: "We dont need deezer plugin you
# can query this without it"): the gw-light session and pageArtist, and the
# artist search for an artist MusicBrainz links no Deezer page for. Qobuz,
# through the plugin's handler: an artist's biography and an album's
# description.
#
# Drives the REAL Prose.pm over a fake HTTP layer and a fake cookie jar, with the
# REAL Sources::_norm and _spineScore. Replies are CAPTURED 2026-10-08
# (tools/fixtures/): pageArtist for Radiohead (399) and pageArtist with a wrong
# token (dz_pageartist_*.json); and for three search cases the public API's
# search reply, each same-name hit's album list (top 4 by fans) and the page's
# MusicBrainz release-group titles (dz_find_*.json): ABBA (180 is 5th in search
# order behind four "Abba"), the horrorcore Madness (1825, the ska band, has the
# most fans and must be refused), Holly Golightly (found).
#
# Standalone -- no LMS install needed:  perl tools/t_deezerbio.pl
#
use strict;
use warnings;
use FindBin;
use JSON::PP ();

our (@EV, @REQ, $RESPOND, $DEFER, @HELD, $LANG, @TIMERS, %QBIO, %QDESC, $QAPI, %QHOLD, @QASKS);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers
                  Slim::Control::Request Plugins::Discography::Plugin
                  Slim::Networking::SimpleAsyncHTTP)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'}   = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { $_[1] eq 'Plugins::Qobuz::Plugin' ? ($main::QAPI ? 1 : 0) : 1 };
    *{'Slim::Utils::Timers::setTimer'}     = sub { my $t = [@_]; push @main::TIMERS, $t; $t };
    *{'Slim::Utils::Timers::killSpecific'} = sub { my ($t) = @_; @main::TIMERS = grep { $_ != $t } @main::TIMERS; 1 };
    # LMS's one cookie jar: every clear is an event, in order with the requests.
    *{'Slim::Networking::Async::HTTP::cookie_jar'} = sub { bless {}, 'T::Jar' };
    push @{'Slim::Utils::Log::ISA'},   'Exporter';
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { $_[1] eq 'language' ? $main::LANG : 1 } sub set { 1 } sub init { 1 }
package T::Jar;   sub clear { push @main::EV, "clear $_[1]"; 1 }
package T::Res;   sub new { my ($c, %a) = @_; bless {%a}, $c } sub content { $_[0]{content} } sub code { $_[0]{code} }

# LMS's SimpleAsyncHTTP, as Prose calls it: new($cb, $ecb, $params), then
# get($url, %headers) or post($url, %headers, $content). $RESPOND decides each
# answer: [code, body] (a 200 goes to $cb, anything else to $ecb), or 'TIMEOUT'.
package Slim::Networking::SimpleAsyncHTTP;
sub new { my ($c, $cb, $ecb, $p) = @_; bless { cb => $cb, ecb => $ecb, p => $p }, $c }
sub get  { my ($s, $url, %h) = @_; $s->_go('GET', $url, \%h, undef) }
sub post { my $s = shift; my $url = shift; my $content = pop; my %h = @_; $s->_go('POST', $url, \%h, $content) }
sub _go {
    my ($s, $verb, $url, $h, $content) = @_;
    my $r = { verb => $verb, url => $url, headers => $h, content => $content, timeout => $s->{p}{timeout} };
    push @main::REQ, $r;
    (my $short = $url) =~ s{^https://[^/]+/}{};
    $short =~ s/[?&]api_token=[^&]*//;
    push @main::EV, "$verb $short";
    my $fire = sub {
        my $a = $main::RESPOND->($r);
        if (ref $a eq 'ARRAY' && $a->[0] == 200) { $s->{cb}->(T::Res->new(code => 200, content => $a->[1])) }
        elsif (ref $a eq 'ARRAY') { $s->{ecb}->($s, "HTTP $a->[0]", T::Res->new(code => $a->[0], content => $a->[1] // '')) }
        else { $s->{ecb}->($s, 'Timed out waiting for data', undef) }
    };
    if ($main::DEFER) { push @main::HELD, $fire } else { $fire->() }
}

# The Qobuz plugin's handler, as Prose calls it.
package T::QAPI;
sub getArtist { my ($s, $cb, $id) = @_; push @main::QASKS, "artist $id";
    return if $main::QHOLD{$id};
    $cb->(exists $main::QBIO{$id} ? { biography => { content => $main::QBIO{$id} }, albums => { items => [] } } : { albums => { items => [] } }) }
sub getAlbum  { my ($s, $cb, $id) = @_; push @main::QASKS, "album $id";
    $cb->(exists $main::QDESC{$id} ? { id => $id, description => $main::QDESC{$id} } : { id => $id }) }
package Plugins::Qobuz::Plugin;
sub getAPIHandler { $main::QAPI }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
require Plugins::Discography::Prose;
my $P = 'Plugins::Discography::Prose';
my $S = 'Plugins::Discography::Sources';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}
sub slurp { my $f = "$FindBin::Bin/fixtures/$_[0]"; open my $fh, '<:raw', $f or die "fixture $f: $!"; local $/; scalar <$fh> }
my $J = JSON::PP->new->utf8;

my $PA399  = slurp('dz_pageartist_399.json');
my $BADTOK = slurp('dz_pageartist_badtoken.json');
my $USER   = $J->encode({ error => [], results => { checkForm => 'CSRF1', SESSION_ID => 'SID1' } });
my $USER2  = $J->encode({ error => [], results => { checkForm => 'CSRF2', SESSION_ID => 'SID2' } });
my $NOBIO  = $J->encode({ error => [], results => { DATA => { ART_ID => '7' } } });

sub fresh {
    @EV = (); @REQ = (); $DEFER = 0; @HELD = (); $LANG = 'EN'; @TIMERS = (); @QASKS = ();
    %QBIO = (); %QDESC = (); $QAPI = undef; %QHOLD = ();
}
# The session and the backoff live in Prose's file scope; a fresh module state is
# a fresh load.
sub reload {
    delete $INC{'Plugins/Discography/Prose.pm'};
    local $SIG{__WARN__} = sub { warn @_ unless $_[0] =~ /redefined|masks earlier/ };
    require Plugins::Discography::Prose;
}
sub gw_method { my ($r) = @_; ($r->{url} =~ /method=([^&]+)/)[0] // '' }
sub step { my @h = splice @HELD; $_->() for @h; scalar @h }

# A responder for the gw calls by method, the public API by path.
my %GW;
my $gw = sub {
    my ($r) = @_;
    if ($r->{url} =~ /gw-light/) {
        my $m = gw_method($r);
        my $a = $GW{$m};
        return ref $a eq 'CODE' ? $a->($r) : $a;
    }
    return [ 404, '' ];
};

# ---------------------------------------------------------------------------
# 1. THE ANONYMOUS SESSION, then pageArtist (Radiohead, the captured reply).
# ---------------------------------------------------------------------------
fresh(); reload();
%GW = ('deezer.getUserData' => [ 200, $USER ], 'deezer.pageArtist' => [ 200, $PA399 ]);
$RESPOND = $gw;
my $got;
$P->deezerBio(399, sub { $got = $_[0] });
ok(scalar(ref $got eq 'HASH' && $got->{text} =~ /<p>/ && $got->{source} eq 'Music Story'),
   '1: the captured pageArtist reply gives the HTML biography and its writer (Music Story)');
ok(scalar(@REQ == 2 && gw_method($REQ[0]) eq 'deezer.getUserData' && gw_method($REQ[1]) eq 'deezer.pageArtist'),
   '1: a session first (getUserData), then pageArtist');
ok(scalar($REQ[0]{url} =~ /api_token=(?:&|$)/ && !$REQ[0]{headers}{Cookie}),
   '1: the session is asked with an empty token and NO cookie (no account)');
ok(scalar($REQ[1]{url} =~ /api_token=CSRF1/ && ($REQ[1]{headers}{Cookie} // '') eq 'sid=SID1'),
   "1: pageArtist carries the session's token and its sid cookie, explicitly");
my $body = $J->decode($REQ[1]{content});
ok(scalar(($body->{art_id} // '') eq '399' && ($body->{lang} // '') eq 'en'),
   '1: ... asking for artist 399, in the LMS language (EN -> en)');
ok(scalar(join('|', @EV) eq 'clear .deezer.com|clear www.deezer.com|clear api.deezer.com|POST ajax/gw-light.php?method=deezer.getUserData&input=3&api_version=1.0'
          . '|clear .deezer.com|clear www.deezer.com|clear api.deezer.com|POST ajax/gw-light.php?method=deezer.pageArtist&input=3&api_version=1.0'),
   "1: LMS's jar is cleared of deezer.com cookies before EACH request (a user's arl is never sent)");
ok(scalar(($REQ[1]{timeout} // 0) == 10), '1: each request has its own timeout');

# The session is reused.
@REQ = (); @EV = ();
$P->deezerBio(399, sub { $got = $_[0] });
ok(scalar(@REQ == 1 && gw_method($REQ[0]) eq 'deezer.pageArtist' && $got->{text}),
   '1: a second biography reuses the session (no getUserData)');

# ---------------------------------------------------------------------------
# 2. A STALE TOKEN: one new session, then the answer; never a loop.
# ---------------------------------------------------------------------------
fresh(); reload();
my $n = 0;
%GW = ('deezer.getUserData' => sub { $n++ ? [ 200, $USER2 ] : [ 200, $USER ] },
       'deezer.pageArtist'  => sub { $_[0]{url} =~ /CSRF1/ ? [ 200, $BADTOK ] : [ 200, $PA399 ] });
$P->deezerBio(399, sub { $got = $_[0] });
ok(scalar($got && $got->{text} && @REQ == 4 && gw_method($REQ[2]) eq 'deezer.getUserData'
          && $REQ[3]{url} =~ /api_token=CSRF2/ && ($REQ[3]{headers}{Cookie} // '') eq 'sid=SID2'),
   "2: the captured 'Invalid CSRF token' reply: a new session once, then the biography");
fresh(); reload();
%GW = ('deezer.getUserData' => [ 200, $USER ], 'deezer.pageArtist' => [ 200, $BADTOK ]);
$got = 'unset';
$P->deezerBio(399, sub { $got = $_[0] });
ok(scalar(!defined $got && @REQ == 4), '2: refused again after the new session: could not tell (undef), no third try');

# ---------------------------------------------------------------------------
# 3. NO BIOGRAPHY: asked again in English when the LMS language is another.
# ---------------------------------------------------------------------------
fresh(); reload();
$LANG = 'FR';
%GW = ('deezer.getUserData' => [ 200, $USER ],
       'deezer.pageArtist'  => sub { $J->decode($_[0]{content})->{lang} eq 'en' ? [ 200, $PA399 ] : [ 200, $NOBIO ] });
$P->deezerBio(399, sub { $got = $_[0] });
my @langs = map { $J->decode($_->{content})->{lang} } grep { gw_method($_) eq 'deezer.pageArtist' } @REQ;
ok(scalar(join(',', @langs) eq 'fr,en' && $got->{text} && $got->{lang} eq 'en'),
   '3: none in French: asked once more in English, which has it');
fresh(); reload();
%GW = ('deezer.getUserData' => [ 200, $USER ], 'deezer.pageArtist' => [ 200, $NOBIO ]);
$P->deezerBio(7, sub { $got = $_[0] });
ok(scalar(ref $got eq 'HASH' && $got->{none} && (grep { gw_method($_) eq 'deezer.pageArtist' } @REQ) == 1),
   '3: none in English (the LMS language): a sure "none", asked once');
$got = 'unset';
$P->deezerBio('abc', sub { $got = $_[0] });
ok(scalar(!defined $got), '3: an id that is not a number: nothing asked, undef');

# ---------------------------------------------------------------------------
# 4. A REFUSAL HOLDS DEEZER OFF; a plain failure does not.
# ---------------------------------------------------------------------------
fresh(); reload();
%GW = ('deezer.getUserData' => [ 403, 'Forbidden' ]);
$P->deezerBio(399, sub { $got = $_[0] });
ok(scalar(!defined $got), '4: a 403: could not tell');
@REQ = ();
$got = 'unset';
$P->deezerBio(399, sub { $got = $_[0] });
$P->deezerFindArtist([ 'abba' ], { 'waterloo' => 1 }, 'ABBA', sub { });
ok(scalar(!defined $got && !@REQ), '4: ... and for the backoff nothing is asked of Deezer at all (gw or public)');

fresh(); reload();
%GW = ('deezer.getUserData' => [ 200, '<html><body>Please verify you are human</body></html>' ]);
$P->deezerBio(399, sub { $got = $_[0] });
@REQ = ();
$P->deezerBio(399, sub { $got = $_[0] });
ok(scalar(!defined $got && !@REQ), '4: an HTML challenge where JSON was due: held off too');

fresh(); reload();
my $t = 0;
%GW = ('deezer.getUserData' => sub { $t++ ? [ 200, $USER ] : 'TIMEOUT' }, 'deezer.pageArtist' => [ 200, $PA399 ]);
$P->deezerBio(399, sub { $got = $_[0] });
ok(scalar(!defined $got), '4: a timeout: could not tell');
$P->deezerBio(399, sub { $got = $_[0] });
ok(scalar($got && $got->{text}), '4: ... but no backoff: the next ask goes out and answers');

# ---------------------------------------------------------------------------
# 5. ONE GW CALL AT A TIME (the session is shared and refreshed in place).
# ---------------------------------------------------------------------------
fresh(); reload();
%GW = ('deezer.getUserData' => [ 200, $USER ], 'deezer.pageArtist' => [ 200, $PA399 ]);
$DEFER = 1;
my ($g1, $g2);
$P->deezerBio(399, sub { $g1 = $_[0] });
$P->deezerBio(323887691, sub { $g2 = $_[0] });
ok(scalar(@REQ == 1), '5: two asks at once: one request out');
step(); step(); step(); step();
ok(scalar($g1 && $g2 && @REQ == 3 && (grep { gw_method($_) eq 'deezer.getUserData' } @REQ) == 1),
   '5: ... both answered in turn, on ONE session');

# ---------------------------------------------------------------------------
# 6. deezerBioFor: linked ids lowest first, at most 3, the first with a bio.
# ---------------------------------------------------------------------------
fresh(); reload();
%GW = ('deezer.getUserData' => [ 200, $USER ],
       'deezer.pageArtist'  => sub { $J->decode($_[0]{content})->{art_id} eq '20' ? [ 200, $PA399 ] : [ 200, $NOBIO ] });
$P->deezerBioFor([ 10, 20, 30, 40 ], sub { $got = $_[0] });
my @asked = map { $J->decode($_->{content})->{art_id} } grep { gw_method($_) eq 'deezer.pageArtist' } @REQ;
ok(scalar($got && $got->{id} == 20 && join(',', @asked) eq '10,20'), '6: the first id with a bio wins, in order');
$P->deezerBioFor([ 1, 2, 3, 4, 5 ], sub { $got = $_[0] });
@asked = map { $J->decode($_->{content})->{art_id} } grep { gw_method($_) eq 'deezer.pageArtist' } @REQ;
ok(scalar(ref $got eq 'HASH' && $got->{none} && join(',', @asked[2 .. $#asked]) eq '1,2,3'),
   '6: none of them: a sure none, at most 3 asked');
$P->deezerBioFor([], sub { $got = $_[0] });
ok(scalar(ref $got eq 'HASH' && $got->{none}), '6: no ids: none');

# ---------------------------------------------------------------------------
# 7. THE SEARCH, when MusicBrainz links no Deezer page (captured replies).
# ---------------------------------------------------------------------------
sub find_case {
    my ($slug, %o) = @_;
    my $fx = $J->decode(slurp("dz_find_$slug.json"));
    my %spine = map { $S->can('_norm')->($_) => 1 } @{ $fx->{spine_titles} };
    delete $spine{''};
    fresh(); reload();
    my @albumAsks;
    $RESPOND = sub {
        my ($r) = @_;
        if ($r->{url} =~ m{search/artist\?q=([^&]+)}) { return [ 200, $J->encode($fx->{search}) ] }
        if ($r->{url} =~ m{artist/(\d+)/albums}) {
            push @albumAsks, $1;
            return 'TIMEOUT' if $o{fail} && $o{fail} eq $1;
            return [ 200, $J->encode($fx->{albums}{$1} // { data => [] }) ];
        }
        return [ 404, '' ];
    };
    my $res = 'unset';
    my $names = $o{names} // [ $S->can('_norm')->($fx->{name}) ];
    $P->deezerFindArtist($names, \%spine, $fx->{name}, sub { $res = $_[0] });
    return ($res, \@albumAsks, scalar(keys %spine), $fx);
}
my ($r, $asks, $nsp, $fx) = find_case('abba');
my @order = map { $_->{id} } grep { $S->can('_norm')->($_->{name}) eq 'abba' } @{ $fx->{search}{data} };
ok(scalar(($order[0] // 0) != 180), '7: (the capture: ABBA 180 is NOT first among Deezer\'s "abba" hits: ' . join(',', @order[0..4]) . ')');
ok(scalar(ref $r eq 'HASH' && ($r->{id} // 0) == 180 && $r->{score} >= 2),
   "7: ABBA: ordered by fans, 180 is read and chosen ($r->{score} of $nsp releases)");
ok(scalar($asks->[0] == 180 && @$asks <= 4), '7: ... its albums read first, at most 4 album lists in all');
ok(scalar($REQ[0]{url} =~ m{search/artist\?q=ABBA&limit=25}), '7: ... the search under the name, 25 hits');
ok(scalar(!grep { $_->{headers}{Cookie} } @REQ), '7: ... the public API carries no cookie');
ok(scalar((grep { /^clear / } @EV) == 3 * @REQ), "7: ... and LMS's jar is cleared before each of those requests too");

($r, $asks, $nsp) = find_case('madness_horrorcore');
ok(scalar(ref $r eq 'HASH' && $r->{none}),
   "7: the horrorcore Madness (one release, \"Open Corpse\"): the ska band 1825 has the most fans and is refused - none");
ok(scalar(grep { $_ == 1825 } @$asks), '7: ... (1825 was read, and none of its albums is the page\'s)');

($r) = find_case('holly_golightly');
ok(scalar(ref $r eq 'HASH' && ($r->{id} // 0) == 10623), '7: Holly Golightly: found (10623)');

($r) = find_case('abba', fail => '180');
ok(scalar(!defined $r), '7: an album list that fails and no other passes: could not tell (undef)');

($r) = find_case('abba', names => [ 'abba the band' ]);
ok(scalar(ref $r eq 'HASH' && $r->{none} && !@{ (find_case('abba', names => [ 'nobody' ]))[1] }),
   '7: no hit named as MusicBrainz names the act: none, and no album list read');

# The BEST corroborated hit wins, not the most famous one that merely passes.
# Hand-built in the captured shape: it pins OUR ordering (the sort a `my $a`
# once broke in this very sub, see the comment there).
fresh(); reload();
$RESPOND = sub {
    my ($r) = @_;
    return [ 200, $J->encode({ data => [ { id => 11, name => 'X', nb_fan => 900 },
                                        { id => 22, name => 'X', nb_fan => 50 },
                                        { id => 33, name => 'X', nb_fan => 10 } ] }) ]
        if $r->{url} =~ /search\/artist/;
    my ($id) = $r->{url} =~ m{artist/(\d+)/albums};
    my %t = (11 => [ 'One', 'Two' ], 22 => [ 'One', 'Two', 'Three', 'Four', 'Five' ], 33 => [ 'One', 'Two', 'Three' ]);
    return [ 200, $J->encode({ data => [ map { { title => $_ } } @{ $t{$id} } ] }) ];
};
my $best = 'unset';
$P->deezerFindArtist([ 'x' ], { map { $_ => 1 } qw(one two three four five six) }, 'X', sub { $best = $_[0] });
ok(scalar(ref $best eq 'HASH' && ($best->{id} // 0) == 22 && $best->{score} == 5),
   '7: three hits pass; the one matching MOST of the page wins (22: 5), not the most famous (11: 2)');

# ONE match on a long page is not enough (the pools' SPINE_STRONG): a namesake
# with one coincidental title, 0.47.2's Rossini rapper.
fresh(); reload();
$RESPOND = sub {
    my ($r) = @_;
    return [ 200, $J->encode({ data => [ { id => 44, name => 'X', nb_fan => 5000 } ] }) ] if $r->{url} =~ /search\/artist/;
    return [ 200, $J->encode({ data => [ { title => 'One' }, { title => 'Elsewhere' } ] }) ];
};
$best = 'unset';
$P->deezerFindArtist([ 'x' ], { map { $_ => 1 } qw(one two three four five six) }, 'X', sub { $best = $_[0] });
ok(scalar(ref $best eq 'HASH' && $best->{none}), '7: the only hit matches 1 of the page\'s 6 releases: refused (none)');
$best = 'unset';
$P->deezerFindArtist([ 'x' ], { one => 1 }, 'X', sub { $best = $_[0] });
ok(scalar(ref $best eq 'HASH' && ($best->{id} // 0) == 44), '7: ... but on a page of ONE release, one match is enough');

my $res = 'unset';
fresh(); reload(); $RESPOND = sub { [ 200, '{}' ] };
$P->deezerFindArtist([ 'abba' ], {}, 'ABBA', sub { $res = $_[0] });
ok(scalar(!defined $res && !@REQ), '7: a page with no releases: nothing to check against, nothing asked');

# ---------------------------------------------------------------------------
# 8. QOBUZ through the plugin's handler.
# ---------------------------------------------------------------------------
fresh(); reload();
$QAPI = bless {}, 'T::QAPI';
%QBIO = (2 => '<p>Qobuz bio two.</p>');
$P->qobuzArtistBio('client', [ 1, 2, 3 ], sub { $got = $_[0] });
ok(scalar($got && $got->{text} eq '<p>Qobuz bio two.</p>' && $got->{id} == 2 && join('|', @QASKS) eq 'artist 1|artist 2'),
   "8: the first linked Qobuz artist with a biography (biography.content)");
%QDESC = (7 => 'An album description.');
$P->qobuzAlbumDescription('client', [ 7 ], sub { $got = $_[0] });
ok(scalar($got && $got->{text} eq 'An album description.'), '8: an album description (album/get description)');
$P->qobuzAlbumDescription('client', [ 8 ], sub { $got = $_[0] });
ok(scalar(ref $got eq 'HASH' && $got->{none}), '8: none in the reply: a sure none');
$QAPI = undef;
$got = 'unset';
$P->qobuzArtistBio('client', [ 1 ], sub { $got = $_[0] });
ok(scalar(!defined $got), '8: no Qobuz handler: could not tell (undef)');
$QAPI = bless {}, 'T::QAPI';
%QHOLD = (1 => 1);
$got = 'unset';
$P->qobuzArtistBio('client', [ 1 ], sub { $got = $_[0] });
ok(scalar($got eq 'unset' && @TIMERS == 1), '8: no answer: a watchdog is armed');
$_->[2]->() for splice @TIMERS;
ok(scalar(!defined $got), '8: ... and on it: could not tell, once');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
