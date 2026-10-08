#!/usr/bin/env perl
#
# REGRESSION TEST — a page opened by a dispatched row keeps its ADDRESS (0.56.51).
#
# FIELD, 2026-10-07 (Simon, phone, Stan Getz > Getz / Gilberto > the first Qobuz
# version > Play): the album "played a track from the compilation Come into the
# Cool", the page was then stuck on Material's loading dots. Server log 10:00:23-
# 10:01:14, and Material's own source, give the chain:
#
#   - the version row is param-addressed (rg + item:v:Qobuz:0 + the artist), so
#     the album it opens is the TOP feed of that request, and XMLBrowser gives
#     its track rows a bare position, item_id "0".."N", nothing else;
#   - Material's Play on a list of tracks it does not own sends one command per
#     track (browseDoListAction: play the first, add the rest), each built from
#     the BASE action + that bare position: `discography playlist add item_id:3`;
#   - topLevel saw no artist in those, so it rebuilt the ARTIST PAGE stashed for
#     the player (%lastCtx) and XMLBrowser walked position 3 of THAT: about 20
#     walks in a second, which flipped Albums to Singles, opened More options,
#     ran Refresh discography (13 duplicate browses, 42 s: t_rgflight.pl), and
#     played the tiles they landed on.
#
# The fix is LBF's (0.9.199, _bindReleaseContext), in two halves:
#   1. the dispatched page's `query` is the request's address, so XMLBrowser's
#      BASE actions send it with every position (XMLBrowser.pm: `if ($feed->
#      {query}) { $params = {%$params, %{$feed->{query}}} }` for go/play/add/
#      add-hold/more);
#   2. every row also gets its OWN items/play/add/insert carrying the address and
#      its path, because the long-press menu's play actions (_makePlayAction)
#      read a row's itemActions and never the query; Material too prefers a
#      row's own action (browseBuildCommand: item.actions[cmd] first).
#
# Standalone, no LMS install needed:  perl tools/t_bindaddr.pl
#
use strict;
use warnings;
use FindBin;

our (@CALLS, %PREF, $LAST_PASS);

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
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
    *{'Slim::Control::Request::executeRequest'} = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Timers::setTimer'}   = sub { };
    *{'Slim::Utils::Timers::killTimers'} = sub { };

    my $S = 'Plugins::Discography::Sources';
    my $A = 'Plugins::Discography::API';
    *{"${S}::_localAlbumTracks"} = sub { my ($c, $cb, $a, $p) = @_; push @main::CALLS, "tracks $p->{album_id}";
        $cb->({ items => [ map { { name => "track $_", type => 'audio', url => "file:///$_.flac",
                                   play => "file:///$_.flac" } } 1 .. 3 ] }) };
    *{"${A}::isVarious"}        = sub { 0 };
    *{"${A}::getReleaseGroups"} = sub { my ($c, %a) = @_; push @main::CALLS, "getReleaseGroups $a{mbid}";
        $a{onDone}->([ { mbid => 'b248d212-aace-3c3e-a23d-e13aaac1f87a', title => 'Getz / Gilberto',
                         type => 'Album', secondary => [], date => '1964-03' } ]) };
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Prefs; our $AUTOLOAD; sub get { $main::PREF{ $_[1] } } sub AUTOLOAD { return } sub DESTROY {}
package T::Client; sub id { $_[0][0] }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $GETZ = '8f2422ab-0ec6-4c92-80c4-afe9622fab32';
my $RG   = 'b248d212-aace-3c3e-a23d-e13aaac1f87a';

# The album a Qobuz version row opens, in the shape QobuzGetTracks renders it
# (read live 2026-10-07: 18 tracks with play urls, then "Artist: Stan Getz"
# links, a favourites row, text rows). Abridged: 3 tracks.
my @TRACKS = ('The Girl From Ipanema', 'Doralice', 'Para Machuchar Meu Coracao');
my $artistKids = [ { name => 'Releases', url => sub { $_[1]->({ items => [
                       { name => 'Getz/Gilberto', type => 'playlist', url => sub { $_[1]->({ items => [] }) } } ] }) } } ];
sub qobuzAlbum {
    return { items => [
        (map { { name => $TRACKS[$_], type => 'audio', url => "qobuz://t$_.flac", play => "qobuz://t$_.flac",
                 on_select => 'play', playall => 1 } } 0 .. $#TRACKS),
        { name => 'Artist: Stan Getz', url => sub { $_[1]->({ items => $artistKids }) }, passthrough => [{}] },
        { name => 'Credits', type => 'link', items => [ { name => 'Stan Getz', type => 'text' },
                                                         { name => 'Bonus', type => 'audio', play => 'qobuz://b.flac' } ] },
        { name => 'Search Qobuz', type => 'search', url => sub { $_[1]->({ items => [] }) } },
        { name => 'Genre: Jazz', type => 'text' },
        { name => 'Native', type => 'audio', play => 'qobuz://n.flac',
          itemActions => { info => { command => ['qobuz_info'], fixedParams => { id => 9 } } } },
    ] };
}
our $ARTIST_PAGE_BUILT = 0;
{
    no warnings 'redefine'; no strict 'refs';
    *{"${B}::_releaseDetail"} = sub {
        my ($c, $cb, $pass) = @_;
        push @CALLS, 'releaseDetail';
        $main::LAST_PASS = $pass;
        $cb->({ items => [ { id => 'v:Qobuz:0', name => 'Getz/Gilberto', type => 'playlist',
                             url => sub { $_[1]->(qobuzAlbum()) } } ] });
    };
    *{"${B}::_discographyView"} = sub {
        my ($c, $cb, $o) = @_;
        $ARTIST_PAGE_BUILT++;
        $cb->({ items => [
            { id => 'lib:52236', name => 'Come into the Cool', type => 'playlist', play => 'db:album.id=52236',
              url => sub { $_[1]->({ items => [ { name => 'track 1', type => 'audio', play => 'db:track.id=1' } ] }) } },
            { id => 'sect:ALBUMS', name => 'Albums', url => sub { $_[1]->({ items => [ { name => 'tile', type => 'playlist',
              itemActions => { items => { command => ['discography','items'], fixedParams => { rg => 'x' } } } } ] }) } },
        ] });
    };
    *{'Plugins::Discography::Covers::noteBrowse'} = sub { };
}

my $client = bless ['02:9b:5c:f3:fc:32'], 'T::Client';
my %VERSION_TAP = (artist => 'Stan Getz', mbid => $GETZ, rg => $RG, item => 'v:Qobuz:0',
                   features => 'hi', sort => 'newest', menu => 1);
sub top { my ($params) = @_; my $got; $B->can('topLevel')->($client, sub { $got = shift }, { params => { %$params } }); $got }
sub row { my ($feed, $name) = @_; (grep { ($_->{name} // '') eq $name } @{ $feed->{items} || [] })[0] }
sub fp  { my ($r, $act) = @_; ($r->{itemActions}{$act} || {})->{fixedParams} || {} }

# ================================================================== 1
print "# 1. the album a version row opens carries the request's address as its query\n";
my $album = top(\%VERSION_TAP);
{
    ok(scalar($album && row($album, 'Doralice')), '1: topLevel (rg + item:v:Qobuz:0) answers with the Qobuz album');
    my $q = $album->{query} || {};
    ok(scalar(($q->{rg} // '') eq $RG && ($q->{item} // '') eq 'v:Qobuz:0' && ($q->{mbid} // '') eq $GETZ
              && ($q->{artist} // '') eq 'Stan Getz' && ($q->{features} // '') eq 'hi'),
       '1: query = the address (rg, item, artist, mbid, features)');
    ok(scalar(!exists $q->{menu} && !exists $q->{item_id}), '1: ... and nothing else (no menu, no item_id)');
}

# ================================================================== 2
print "# 2. every row gets its own address-carrying actions, at its own position\n";
{
    my $t = row($album, 'Doralice');
    my $p = fp($t, 'play');
    ok(scalar(($p->{item_id} // '') eq '1' && ($p->{rg} // '') eq $RG && ($p->{item} // '') eq 'v:Qobuz:0'
              && ($p->{artist} // '') eq 'Stan Getz' && ($p->{mbid} // '') eq $GETZ),
       '2: track 2 plays as rg + item + artist + item_id:1 (not a bare position)');
    ok(scalar(join(' ', @{ $t->{itemActions}{play}{command} || [] }) eq 'discography playlist play'),
       '2: ... through discography playlist play');
    ok(scalar((fp($t, 'add')->{item_id} // '') eq '1' && (fp($t, 'insert')->{item_id} // '') eq '1'),
       '2: add and insert too (Material\'s per-track Play sends add for the rest)');
    ok(scalar(!$t->{itemActions}{items}), '2: an audio row gets no items action');
    my $first = row($album, 'The Girl From Ipanema');
    ok(scalar((fp($first, 'play')->{item_id} // '') eq '0'), '2: positions count from 0');

    my $art = row($album, 'Artist: Stan Getz');
    ok(scalar((fp($art, 'items')->{item_id} // '') eq '3' && (fp($art, 'items')->{rg} // '') eq $RG),
       '2: a link row drills by address + its position');
    my $srch = row($album, 'Search Qobuz');
    ok(scalar(!$srch->{itemActions}{items}), '2: a search row keeps XMLBrowser\'s own go (it carries the input)');
    ok(scalar(!%{ row($album, 'Genre: Jazz')->{itemActions} || {} }), '2: a text row gets nothing');
    my $nat = row($album, 'Native');
    ok(scalar($nat->{itemActions}{info} && (fp($nat, 'info')->{id} // 0) == 9 && fp($nat, 'play')->{rg}),
       '2: a row\'s own action is kept (info), the missing ones are added');

    my $cred = row($album, 'Credits');
    my ($bonus) = grep { $_->{name} eq 'Bonus' } @{ $cred->{items} || [] };
    ok(scalar((fp($bonus, 'play')->{item_id} // '') eq '4.1'),
       '2: inline items are bound at "parent.child" (4.1); LBF\'s port dropped this result');
}

# ================================================================== 3
print "# 3. a row opened from that page is bound under its parent's position\n";
{
    my $art = row($album, 'Artist: Stan Getz');
    my $kids;
    $art->{url}->($client, sub { $kids = shift }, { params => {} });
    my $rel = ($kids->{items} || [])->[0];
    ok(scalar((fp($rel, 'items')->{item_id} // '') eq '3.0' && (fp($rel, 'items')->{item} // '') eq 'v:Qobuz:0'),
       '3: its child drills as item_id 3.0 with the same address');
    my $grand;
    $rel->{url}->($client, sub { $grand = shift }, {});
    my $g = ($grand->{items} || [])->[0];
    ok(scalar((fp($g, 'play')->{item_id} // '') eq '3.0.0'), '3: and a grandchild as 3.0.0');
    ok(scalar(ref $artistKids->[0]{url} eq 'CODE' && !$artistKids->[0]{itemActions}),
       '3: the service\'s own rows are not touched (bound on a copy)');
}

# ================================================================== 4
print "# 4. the row's own command reaches the ALBUM, not the artist page\n";
{
    my $t = row($album, 'Doralice');
    $ARTIST_PAGE_BUILT = 0; @CALLS = ();
    my $again = top({ %{ fp($t, 'play') } });
    ok(scalar($again && ($again->{items}[ fp($t, 'play')->{item_id} ]{name} // '') eq 'Doralice'),
       '4: its own play command resolves to the album, at the position XMLBrowser walks (item_id 1 = Doralice)');
    ok(scalar(!$ARTIST_PAGE_BUILT), '4: ... without building the artist page');

    # The base action, as XMLBrowser builds it: query + the row's params.
    my %base = (%{ $album->{query} }, menu => 'discography', item_id => 2);
    my $viaBase = top(\%base);
    ok(scalar($viaBase && ($viaBase->{items}[2]{name} // '') eq 'Para Machuchar Meu Coracao' && !$ARTIST_PAGE_BUILT),
       '4: the BASE action (query + item_id) reaches the album too');

    # CONTROL: the command the phone sent on 0.56.50, a bare position.
    $ARTIST_PAGE_BUILT = 0;
    top({ %VERSION_TAP, item => 'none' });   # a fresh entry stashes the artist, as on the phone
    $ARTIST_PAGE_BUILT = 0;
    top({ menu => 'discography', item_id => 1 });
    ok(scalar($ARTIST_PAGE_BUILT), '4: CONTROL: a bare item_id still walks the artist page (what the address now avoids)');
}

# ================================================================== 5
print "# 5. every dispatch branch binds: library tile, section header, work album\n";
{
    my %lib = (artist_id => 151700, artist => 'Stan Getz', item => 'lib:52236', features => 'hi', menu => 1);
    my $tr = top(\%lib);
    my $t1 = ($tr->{items} || [])->[0];
    ok(scalar(($tr->{query}{item} // '') eq 'lib:52236' && ($tr->{query}{artist_id} // '') eq '151700'),
       '5: a library tile\'s tracklist carries its address (artist_id, item lib:52236)');
    ok(scalar((fp($t1, 'play')->{item_id} // '') eq '0' && (fp($t1, 'play')->{item} // '') eq 'lib:52236'),
       '5: its tracks play by address');

    my $sec = top({ %lib, item => 'sect:ALBUMS' });
    my $tile = ($sec->{items} || [])->[0];
    ok(scalar((fp($tile, 'items')->{rg} // '') eq 'x' && !exists fp($tile, 'items')->{item_id}),
       '5: a section\'s tile keeps its OWN param-addressed tap');

    my $wka = top({ artist => 'Wolfgang Amadeus Mozart', mbid => 'f7b6c8b5-6000-4c4f-9d1f-6a8a9a8a9a8a',
                    item => 'wka:49625', features => 'hi' });
    my $w1 = ($wka->{items} || [])->[0];
    ok(scalar(($wka->{query}{item} // '') eq 'wka:49625' && (fp($w1, 'play')->{item} // '') eq 'wka:49625'),
       '5: a work\'s album tracks carry wka:<id>');

    my $band = top({ artist => 'Stan Getz Quartet', mbid => '6d55baf9-875e-4a62-8829-a3ba629ea8cd',
                     item => 'lib:52236' });
    ok(scalar(($band->{query}{mbid} // '') eq '6d55baf9-875e-4a62-8829-a3ba629ea8cd'),
       '5: a band link\'s page keeps its mbid (the address is replayed, never rebuilt from $opts)');
}

# ================================================================== 6
print "# 6. pages that are not dispatched rows are unchanged\n";
{
    my $detail = top({ artist => 'Stan Getz', mbid => $GETZ, rg => $RG, features => 'hi' });
    ok(scalar($detail && !exists $detail->{query}), '6: the release page itself (rg, no item) gets no query');
    ok(scalar(!$detail->{items}[0]{itemActions}), '6: ... and its rows keep exactly the actions they were built with');
    my $page = top({ artist => 'Stan Getz', features => 'hi' });
    ok(scalar($page && !exists $page->{query}), '6: the artist page gets no query');
}

# ================================================================== 7
print "# 7. the helpers\n";
{
    my $a = $B->can('_addrOf')->({ artist => 'X', mbid => 'm', item_id => '3', menu => 1, search => 's',
                                   features => '', rg => [1], item => 'v:Q:0', local_only => 1 });
    ok(scalar(join(',', sort keys %$a) eq 'artist,item,local_only,mbid'),
       '7: _addrOf keeps the identity keys, drops item_id/menu/search, empties and refs: ' . join(',', sort keys %$a));
    my $bound = $B->can('_bindAddr')->({ offset => 10, items => [ { name => 'a', type => 'audio', play => 'p' } ] }, { artist => 'X' }, '');
    ok(scalar((fp($bound->{items}[0], 'play')->{item_id} // '') eq '10'), '7: a windowed feed\'s offset is honoured');
    my $in = [ { name => 'a', type => 'audio', play => 'p' } ];
    $B->can('_bindAddr')->($in, { artist => 'X' }, '');
    ok(scalar(!$in->[0]{itemActions}), '7: the input rows are never modified');
    ok(scalar(!defined $B->can('_bindAddr')->(undef, {}, '')), '7: undef passes through');
}

# ================================================================== 8
print "# 8. an accented address rides ASCII (Material's command-list drops a batch that is not)\n";
{
    # FIELD, 2026-10-07 15:28 (iPhone, Dining Room): opened from the library
    # artist "Stan Getz, João Gilberto feat. Antônio Carlos Jobim", Play inside
    # the Expanded Edition sent 19 commands in one command-list and none ran:
    # MaterialSkin Plugin.pm `eval { decode_json($json) }` on a character
    # string. Measured: the same batch with a plain name ran 1, accented 0.
    require JSON::XS;
    my $NAME = "Stan Getz, Jo\x{e3}o Gilberto feat. Ant\x{f4}nio Carlos Jobim";
    my %tap  = (%VERSION_TAP, artist => $NAME, artist_id => '155370');
    my $a = $B->can('_addrOf')->(\%tap);
    ok(scalar(!exists $a->{artist} && defined $a->{artist_u8} && $a->{artist_u8} !~ /[^\x00-\x7F]/),
       "8: an accented artist rides as artist_u8, ASCII only: " . ($a->{artist_u8} // 'undef'));
    ok(scalar(($a->{artist_id} // '') eq '155370' && ($a->{item} // '') eq 'v:Qobuz:0' && ($a->{rg} // '') eq $RG),
       '8: the plain keys ride as they came');
    my $back = $B->can('_addrDecode')->($a);
    ok(scalar(($back->{artist} // '') eq $NAME), '8: _addrDecode gives the name back, characters intact');

    # The batch Material would build from the bound rows decodes the way
    # Material's handler decodes it: from the CHARACTER string.
    my $page = top(\%tap);
    my $t = row($page, 'Doralice');
    my @cmd = ('discography', 'playlist', 'add', map { "$_:" . fp($t, 'add')->{$_} } sort keys %{ fp($t, 'add') });
    my $json = JSON::XS->new->encode([ \@cmd ]);   # characters, as JSON-RPC hands it on
    my $got  = eval { JSON::XS::decode_json($json) };
    ok(scalar($got && @$got == 1), '8: the bound row\'s command survives decode_json (Material command-list)');
    my $q = $page->{query} || {};
    ok(scalar(!grep { /[^\x00-\x7F]/ } values %$q), '8: the page query (XMLBrowser base actions) is ASCII too');
    # Anti-test: the name as it came would not.
    my $raw = JSON::XS->new->encode([ [ 'discography', 'playlist', 'add', "artist:$NAME" ] ]);
    ok(scalar(!eval { JSON::XS::decode_json($raw) }), '8: control: the raw accented name dies in decode_json');

    # The encoded address re-enters topLevel as the name.
    local $main::LAST_PASS;
    my %again = (%{ fp($t, 'add') });
    top(\%again);
    ok(scalar(ref $main::LAST_PASS eq 'HASH' && ($main::LAST_PASS->{artist} // '') eq $NAME),
       '8: a request carrying artist_u8 reaches the page as the decoded name');
    my $both = $B->can('_addrDecode')->({ artist => 'Plain', artist_u8 => 'Other' });
    ok(scalar($both->{artist} eq 'Plain'), '8: a plain key that came too wins');
    my $bad = $B->can('_addrDecode')->({ artist_u8 => '%FF%FEx' });
    ok(scalar(defined $bad->{artist} && length $bad->{artist}), '8: a value that is not UTF-8 is used as it unescapes');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
