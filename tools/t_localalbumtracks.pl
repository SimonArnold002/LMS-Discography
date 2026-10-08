#!/usr/bin/env perl
#
# REGRESSION TEST — an owned release opened from a Discography page opens the
# way Material opens any library album, and follows Material's "Filter album
# tracks" setting.
#
# FIELD (Simon, 2026-10-07): *"when clicked into the releases in any of views
# from albums, appearances etc we are not getting all metadata as we would when
# looking at an album normally. So compilations dont show the artists per track
# and collaborations dont show either"*; *"the way to show just the artist and
# track is a material setting called filter album tracks which works when on an
# artist page"*; *"play behavious is also not the same as i dont get play play
# release starting at this track ... We need to copy exactly how LMS does this"*.
#
# READ / MEASURED (LMS 9.1.2, Material 6.4.10.x, 2026-10-07):
#   - the old drill-in asked `titles ... tags:u` and built bare rows, so the page
#     was a plugin list: no numbers, durations, artists or track menu.
#   - Material rewrites a row whose go action is `browselibrary items
#     mode:tracks album_id:X` into its OWN `tracks` request with the full tags
#     (browse-functions.js browseBuildCommand, "Convert local browse commands"),
#     so that row opens Material's native album page. LMS's BrowseLibrary gives
#     an album row exactly that go, and playlistcontrol for play/add/insert.
#   - "Play release starting at track" runs the clicked row's PLAY command plus
#     play_index:N (browseItemAction PLAY_ALBUM_ACTION), so the row's play must be
#     `playlistcontrol cmd:load album_id:X`, not a plugin command.
#   - the setting is plugin.material-skin's noArtistFilter (0 = only the current
#     artist's tracks, 1 = every track, Material's default); with it on Material
#     adds artist_id, and role_id unless LMS's server pref noRoleFilter is set.
#   - LMS's `tracks` honours both: Ella on "Greatest Divas" -> 1 of 22; role_id
#     COMPOSER -> 0; the performance roles -> her 1.
#
# Standalone, no LMS install needed:  perl tools/t_localalbumtracks.pl
#
use strict;
use warnings;
use FindBin;

our %TITLES;      # album_id -> [ titles_loop rows ]
our %ALBUMS;      # artist_id -> [ albums_loop rows ]
our %CONTRIB;     # `artists search:` string -> [ { id, artist } ]
our @TITLEQ;      # the argument list of every titles request, in order
our $MATERIAL;    # plugin.material-skin noArtistFilter
our $NOROLE;      # server noRoleFilter

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema JSON::XS::VersionOneAndTwo
                  Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    # Namespace-aware: Material's and the server's prefs read what the case set,
    # every other namespace answers 1 (so svc_priority_local is on).
    *{'Slim::Utils::Prefs::preferences'} = sub {
        my $ns = $_[0] // '';
        return bless({}, $ns eq 'plugin.material-skin' ? 'T::Material'
                       : $ns eq 'server'               ? 'T::Server' : 'T::Prefs');
    };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { {} };
    # A stubbed LMS whose `titles` narrows as the live one was measured to:
    # artist_id keeps the tracks naming that contributor; with role_id only in a
    # performance role, without it in any role (composer included).
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $args) = @_;
        my $cmd = $args->[0] // '';
        my %p = map { /^(\w+):(.*)$/ ? ($1 => $2) : () } @$args[1 .. $#$args];
        if ($cmd eq 'titles') {
            push @TITLEQ, { %p };
            my @rows = @{ $TITLES{ $p{album_id} // '' } || [] };
            if (defined $p{track_id}) {   # LMS: tracks.id IN (...)
                my %t = map { ($_ => 1) } split /,/, $p{track_id};
                @rows = grep { defined $_->{id} && $t{ $_->{id} } } @rows;
            }
            if (defined $p{artist_id}) {
                my @keys = qw(artist_ids albumartist_ids trackartist_ids band_ids);
                push @keys, qw(composer_ids conductor_ids) unless defined $p{role_id};
                @rows = grep { my $e = $_; grep { $_ eq $p{artist_id} }
                               map { split /,/, ($e->{$_} // '') } @keys } @rows;
            }
            return bless { titles_loop => \@rows }, 'T::Req';
        }
        if ($cmd eq 'artists') {
            return bless { artists_loop => $CONTRIB{ $p{search} // '' } || [] }, 'T::Req';
        }
        return bless { albums_loop => $ALBUMS{ $p{artist_id} // '' } || [] }, 'T::Req';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;     our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs;    sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Material; sub get { $main::MATERIAL }
package T::Server;   sub get { $_[1] eq 'noRoleFilter' ? $main::NOROLE : undef }
package T::Req;      sub getResult { return $_[0]->{ $_[1] } }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $S = 'Plugins::Discography::Sources';
my $PERF = 'ARTIST,ALBUMARTIST,BAND,TRACKARTIST';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    # STRUCTURAL GUARD: a bare `=~`/grep/map in ok()'s argument list returns the
    # EMPTY LIST on failure, shifting the NAME into the condition slot so a
    # FAILING assertion prints as a pass. A missing name is the fingerprint.
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}
sub kv { my $h = shift; join ' ', map { "$_:$h->{$_}" } sort keys %$h }

# --- fixtures, shaped as the live library answered ----------------------------
my $ELLA = 151861;
my @DIVAS = (
    [ 'Fever',            'Peggy Lee',       157555 ],
    [ 'Wild Is the Wind', 'Nina Simone',     154621 ],
    [ 'Misty Blue',       'Ella Fitzgerald', $ELLA  ],
    [ 'Chicago',          'Judy Garland',    157563 ],
);
sub divas_rows {
    my $n = 0;
    return [ map {
        $n++;
        {   id => 5224900 + $n, title => $_->[0], url => "file:///divas/$n.flac", tracknum => $n,
            artist => $_->[1], trackartist => $_->[1], albumartist => 'Various Artists',
            albumartist_ids => '151537', artist_ids => $_->[2], trackartist_ids => $_->[2],
        }
    } @DIVAS ];
}
$TITLES{52249} = divas_rows();
# "Ali": `artist` names the composer on some tracks; trackartist is the duo.
$TITLES{50802} = [ map { {
    title => "Track $_", url => "file:///ali/$_.flac", tracknum => $_,
    artist => ($_ % 2 ? 'Ali Farka Toure' : 'Vieux Farka Toure & Khruangbin'),
    trackartist => 'Vieux Farka Toure & Khruangbin', albumartist => 'Vieux Farka Toure & Khruangbin',
    albumartist_ids => '154066', trackartist_ids => '154066', composer_ids => '151928',
} } 1 .. 4 ];
$TITLES{52549} = [ map { {
    title => "Song $_", url => "file:///cole/$_.flac", tracknum => $_,
    artist => 'Ella Fitzgerald', trackartist => 'Ella Fitzgerald', albumartist => 'Ella Fitzgerald',
    albumartist_ids => $ELLA, artist_ids => $ELLA, trackartist_ids => $ELLA,
} } 1 .. 3 ];

# ---------------------------------------------------------------------------
# 1. THE SETTING: plugin.material-skin / noArtistFilter.
# ---------------------------------------------------------------------------
my $F = sub { $S->can('_filterAlbumTracks')->() };
$MATERIAL = 0;      ok($F->() == 1, 'noArtistFilter 0 = "Only display tracks from current artist": filter on');
$MATERIAL = '0';    ok($F->() == 1, 'the string "0" too (prefs come back as strings)');
$MATERIAL = '';     ok($F->() == 1, 'an empty value is false, as Material\'s own setChange treats it');
$MATERIAL = 1;      ok($F->() == 0, 'noArtistFilter 1 = "Display all tracks of album": filter off');
$MATERIAL = undef;  ok($F->() == 0, 'unset (Material absent, never saved) = Material\'s default: every track');

# ---------------------------------------------------------------------------
# 2. THE NARROWING PARAMS: what Material adds, decided in one place.
# ---------------------------------------------------------------------------
my $N = sub { my %h = $S->can('_albumNarrowing')->(@_); \%h };
$NOROLE = 0;
$MATERIAL = 0;
ok(kv($N->($ELLA)) eq "artist_id:$ELLA role_id:$PERF", 'filter on: artist_id + the performance role_id');
$NOROLE = 1;
ok(kv($N->($ELLA)) eq "artist_id:$ELLA", 'filter on, LMS noRoleFilter set: artist_id only, as Material');
$NOROLE = 0;
$MATERIAL = 1;
ok(!%{ $N->($ELLA) }, 'filter off: nothing (every track)');
$MATERIAL = 0;
ok(!%{ $N->(undef) },  'no artist known: nothing');
ok(!%{ $N->('12;3') }, 'a non-numeric id: nothing');

# ---------------------------------------------------------------------------
# 3. THE ROW'S ACTIONS: LMS's own BrowseLibrary album actions.
# ---------------------------------------------------------------------------
my $A = sub { $S->can('libraryAlbumActions')->(@_) };
$MATERIAL = 1;
my $a = $A->(52249, $ELLA);
ok(join(' ', @{ $a->{items}{command} }) eq 'browselibrary items',
   'open = browselibrary items (Material rewrites it into its native tracks request)');
ok(kv($a->{items}{fixedParams}) eq "album_id:52249 material_skin_artist_id:$ELLA mode:tracks",
   '... mode:tracks, the album, and the artist Material highlights; no narrowing with the filter off');
for my $c (qw(play add insert)) {
    ok(join(' ', @{ $a->{$c}{command} }) eq 'playlistcontrol', "$c = playlistcontrol (the native album action)");
}
ok(kv($a->{play}{fixedParams})   eq 'album_id:52249 cmd:load',   '... play loads the album (Material adds play_index for "starting at track")');
ok(kv($a->{add}{fixedParams})    eq 'album_id:52249 cmd:add',    '... add adds it');
ok(kv($a->{insert}{fixedParams}) eq 'album_id:52249 cmd:insert', '... insert inserts it');
# Every action defined, as BrowseLibrary's album row: XMLBrowser then sends no
# positional `params`, so Material under My Apps ids the row from its favourites
# URL (with a colon) instead of fixId(item_id) = "2", which threw on the album page
# (field 0.56.57). Five actions is also XMLBrowser's own threshold for the flag.
ok(($a->{allAvailableActionsDefined} // 0) == 1, 'all actions defined (no positional params: the My Apps empty-page fix)');
ok(join(' ', @{ $a->{info}{command} || [] }) eq 'albuminfo items', 'info = albuminfo items (XMLBrowser\'s `more`: LMS\'s own album menu)');
ok(kv($a->{info}{fixedParams} || {}) eq 'album_id:52249', '... on the album');
ok(scalar(grep { ref $a->{$_} eq 'HASH' } qw(info items play add insert)) == 5, 'all five actions XMLBrowser maps are present');

$MATERIAL = 0;
$a = $A->(52249, $ELLA);
ok(kv($a->{items}{fixedParams}) eq "album_id:52249 artist_id:$ELLA material_skin_artist_id:$ELLA mode:tracks role_id:$PERF",
   'filter on: the page is asked for her tracks (artist_id + role_id)');
ok(kv($a->{play}{fixedParams}) eq "album_id:52249 artist_id:$ELLA cmd:load role_id:$PERF",
   '... and play plays what the page shows, as Material\'s own album play does');
ok(kv($a->{info}{fixedParams} || {}) eq "album_id:52249 artist_id:$ELLA role_id:$PERF",
   '... and More carries the same narrowing, as BrowseLibrary\'s info does');
ok(($a->{allAvailableActionsDefined} // 0) == 1, '... still all actions defined');

$a = $A->(52249, undef);
ok(kv($a->{items}{fixedParams}) eq 'album_id:52249 mode:tracks', 'no artist (a works page, a joint album): the whole album, nothing highlighted');
ok(!defined $A->(undef, $ELLA) && !defined $A->('x', $ELLA), 'no album id: no actions (the row keeps its own)');

# ---------------------------------------------------------------------------
# 4. THE FALLBACK DRILL-IN (a client that is not Material, a legacy walk).
# ---------------------------------------------------------------------------
sub tracks {
    my ($p) = @_;
    my $got;
    Plugins::Discography::Sources::_localAlbumTracks(undef, sub { $got = $_[0] }, {}, $p);
    return $got ? $got->{items} : undef;
}
sub names { join '|', map { $_->{name} } @{ $_[0] } }
sub lines { join '|', map { $_->{line2} // '-' } @{ $_[0] } }

$MATERIAL = 1; @TITLEQ = ();
my $items = tracks({ album_id => 52249, artist_id => $ELLA });
ok(scalar(@TITLEQ) == 1 && !exists $TITLEQ[0]{artist_id}, 'filter off: one request, not narrowed');
ok(($TITLEQ[0]{tags} // '') =~ /a/ && ($TITLEQ[0]{tags} // '') =~ /A/ && ($TITLEQ[0]{tags} // '') =~ /u/,
   '... asking for the artist, the credits and the url');
ok(scalar(@$items) == 4 && lines($items) eq 'Peggy Lee|Nina Simone|Ella Fitzgerald|Judy Garland',
   '... every track, each naming its artist');
ok($items->[0]{type} eq 'audio' && $items->[0]{url} eq 'file:///divas/1.flac'
   && $items->[0]{play} eq $items->[0]{url} && $items->[0]{name} eq 'Fever',
   '... still playable audio rows');

$MATERIAL = 0; @TITLEQ = ();
$items = tracks({ album_id => 52249, artist_id => $ELLA });
ok(($TITLEQ[0]{artist_id} // '') eq "$ELLA" && ($TITLEQ[0]{role_id} // '') eq $PERF,
   'filter on: LMS is asked to narrow (artist_id + role_id), not filtered by us');
ok(names($items) eq 'Misty Blue' && lines($items) eq 'Ella Fitzgerald', '... her one track, named');

@TITLEQ = ();
$items = tracks({ album_id => 52249, artist_id => 99999 });
ok(scalar(@TITLEQ) == 2 && !exists $TITLEQ[1]{artist_id} && scalar(@$items) == 4,
   'filter on, an id naming no track: asked again unnarrowed, the whole album, never an empty page');

@TITLEQ = ();
$items = tracks({ album_id => 52249 });
ok(scalar(@TITLEQ) == 1 && !exists $TITLEQ[0]{artist_id} && scalar(@$items) == 4,
   'filter on, no artist (a works page): the whole album');

my $cmp = divas_rows();
$cmp->[3]{artist_ids} = '1'; $cmp->[3]{trackartist_ids} = '1'; $cmp->[3]{composer_ids} = $ELLA;
$TITLES{70001} = $cmp;
ok(names(tracks({ album_id => 70001, artist_id => $ELLA })) eq 'Misty Blue',
   'a composer-only credit is not hers under the role filter');
$NOROLE = 1;
ok(names(tracks({ album_id => 70001, artist_id => $ELLA })) eq 'Misty Blue|Chicago',
   '... and is, with LMS\'s noRoleFilter set (no role_id), as on Material\'s own page');
$NOROLE = 0;

$TITLES{70003} = [ { title => 'Gone', tracknum => 1, artist_ids => $ELLA }, { title => 'Here', url => 'u', tracknum => 2, artist_ids => $ELLA } ];
ok(names(tracks({ album_id => 70003, artist_id => $ELLA })) eq 'Here', 'a row with no url is skipped');
ok(lines(tracks({ album_id => 52549, artist_id => $ELLA })) eq '-|-|-', 'her own album: no artist lines');
ok(lines(tracks({ album_id => 50802 })) eq '-|-|-|-',
   'a joint album: trackartist is the duo on every track, no lines (the composer on `artist` is not a guest)');
my $none = tracks({ album_id => 424242 });
ok(ref($none) eq 'ARRAY' && !@$none, 'an album with no rows: an empty feed');

# ---------------------------------------------------------------------------
# 5. THE ARTIST LINE (the fallback's; Material draws its own): all or none.
# ---------------------------------------------------------------------------
my $L = sub { $S->can('_trackArtistLines')->(@_) };
my @l = @{ $L->(divas_rows()) };
ok(join('|', @l) eq 'Peggy Lee|Nina Simone|Ella Fitzgerald|Judy Garland', 'a compilation names each track\'s artist');
ok(!grep({ defined } @{ $L->($TITLES{52549}) }), 'a single-artist album stays bare');
ok(!grep({ defined } @{ $L->($TITLES{50802}) }), 'trackartist before artist (the joint album stays bare)');
my $guest = [ map { { %$_ } } @{ $TITLES{52549} } ];
$guest->[1]{trackartist} = 'Ella Fitzgerald & Louis Armstrong';
ok(join('|', map { $_ // '-' } @{ $L->($guest) }) eq 'Ella Fitzgerald|Ella Fitzgerald & Louis Armstrong|Ella Fitzgerald',
   'one differing credit names every track (Material\'s all-or-none)');
my $spaced = [ map { { %$_ } } @{ $TITLES{52549} } ];
$spaced->[0]{trackartist} = 'ella  FITZGERALD';
ok(!grep({ defined } @{ $L->($spaced) }), 'case and spacing alone are not a difference');
my $noaa = [ map { { %$_, albumartist => undef } } @{ divas_rows() } ];
ok(scalar(grep { defined } @{ $L->($noaa) }) == 4, 'no album artist, tracks differ: named');
ok(scalar(@{ $L->([]) }) == 0, 'an empty album gives an empty list');

# ---------------------------------------------------------------------------
# 6. THE STAMP: localAlbums records which contributor listed each album.
# ---------------------------------------------------------------------------
%ALBUMS = ( $ELLA => [ { id => 52249, album => 'Greatest Divas', year => 2005 } ] );
my $rows = $S->localAlbums($ELLA, 'Ella Fitzgerald');
ok(scalar(@$rows) == 1 && ($rows->[0]{_listedUnder} // '') eq "$ELLA", 'the row names the contributor that listed it');
ok(($rows->[0]{passthrough}[0]{artist_id} // '') eq "$ELLA" && $rows->[0]{passthrough}[0]{album_id} == 52249,
   '... and its passthrough carries it for the fallback drill-in');
ok($rows->[0]{url} == \&Plugins::Discography::Sources::_localAlbumTracks
   && ($rows->[0]{play} // '') eq 'db:album.id=52249',
   '... url and play string unchanged (the paths that are not Material)');

$MATERIAL = 0;
my $got;
$rows->[0]{url}->(undef, sub { $got = $_[0] }, {}, $rows->[0]{passthrough}[0]);
ok(names($got->{items}) eq 'Misty Blue', 'the row, run with its own passthrough, opens on her track (filter on)');

# A name resolving to several contributors (the artist + a joint credit naming
# it, localAlbums' name path): each album names the one that listed it.
%CONTRIB = ( 'Nick Cave' => [ { id => 10, artist => 'Nick Cave' },
                              { id => 11, artist => 'Nick Cave & Warren Ellis' } ] );
%ALBUMS  = ( 10 => [ { id => 500, album => 'And No More Shall We Part' }, { id => 502, album => 'Shared' } ],
             11 => [ { id => 501, album => 'Carnage' },                   { id => 502, album => 'Shared' } ] );
$rows = $S->localAlbums(undef, 'Nick Cave');
my %under = map { $_->{_albumid} => $_->{_listedUnder} } @$rows;
ok(scalar(keys %under) == 3, 'the name path finds the artist\'s and the joint contributor\'s albums');
ok(($under{500} // '') eq '10' && ($under{501} // '') eq '11' && ($under{502} // '') eq '10',
   '... each naming the contributor that listed it (the first for one both list)');

# A joint credit matched by intersection: the duo's own album, never narrowed.
%CONTRIB = (
    'Robert Plant & Alison Krauss' => [],
    'Robert Plant'  => [ { id => 56743, artist => 'Robert Plant' } ],
    'Alison Krauss' => [ { id => 56744, artist => 'Alison Krauss' } ],
);
%ALBUMS = (
    56743 => [ { id => 19127, album => 'Raising Sand' }, { id => 900, album => 'Band of Joy' } ],
    56744 => [ { id => 19127, album => 'Raising Sand' }, { id => 901, album => 'Forget About It' } ],
);
$rows = $S->localAlbums(undef, 'Robert Plant & Alison Krauss');
ok(scalar(@$rows) == 1 && $rows->[0]{_candTitle} eq 'Raising Sand', 'the duo\'s page finds Raising Sand only');
ok(!exists $rows->[0]{_listedUnder} && !exists $rows->[0]{passthrough}[0]{artist_id},
   '... with NO artist to narrow by: the duo\'s own album is never cut to one member');

# ---------------------------------------------------------------------------
# 5. A WORK'S ALBUM (the composer works page's work page, plan §10.5 item 4):
#    only the work's tracks, LMS's Works-view way. Measured on the rig
#    2026-10-08: `tracks album_id track_id:<list>` narrows to the list (3 of the
#    Four Seasons album's 21), work_id:-1 keeps the same tracks; Material keeps
#    the params when it rewrites `browselibrary items mode:tracks`, and draws a
#    work_id request with no track numbers, as LMS's own Works view.
# ---------------------------------------------------------------------------
my $W = sub { $S->can('libraryWorkActions')->(@_) };
my $w = $W->(52249, [5224903, 5224901]);
ok($w && $w->{allAvailableActionsDefined} && kv($w->{info}{fixedParams}) eq 'album_id:52249',
   'a work\'s album: every action defined, LMS\'s album menu as info');
ok(join(' ', @{ $w->{items}{command} }) eq 'browselibrary items'
   && kv($w->{items}{fixedParams}) eq 'album_id:52249 mode:tracks track_id:5224903,5224901 work_id:-1',
   'opens Material\'s album page with the work\'s tracks only (track ids as given, work_id:-1), no artist narrowing');
ok(kv($w->{play}{fixedParams}) eq 'cmd:load track_id:5224903,5224901 work_id:-1'
   && kv($w->{add}{fixedParams}) eq 'cmd:add track_id:5224903,5224901 work_id:-1'
   && kv($w->{insert}{fixedParams}) eq 'cmd:insert track_id:5224903,5224901 work_id:-1',
   'play/add/insert the same tracks, never the whole album (no album_id)');
ok(!defined $W->(52249, []) && !defined $W->(52249, undef), 'no tracks: no actions (the row keeps its own)');
ok(!defined $W->(undef, [1]) && !defined $W->('x', [1]), 'no album id: no actions');
ok(kv($W->(52249, ['7', 'x; drop', undef, '8'])->{play}{fixedParams}) eq 'cmd:load track_id:7,8 work_id:-1',
   'a track id that is not a number is left out');

# The drill-in for other clients: the work's tracks alone, never cut to an artist.
$MATERIAL = 0; @TITLEQ = ();    # "Filter album tracks" ON: must not apply here
$items = tracks({ album_id => 52249, artist_id => $ELLA, track_ids => [5224901, 5224903] });
ok(scalar(@TITLEQ) == 1 && ($TITLEQ[0]{track_id} // '') eq '5224901,5224903' && !exists $TITLEQ[0]{artist_id},
   'the work\'s tracks are asked for by id, with no artist narrowing even with the filter on');
ok(names($items) eq 'Fever|Misty Blue', '... and only those tracks come back, in album order');
@TITLEQ = ();
$items = tracks({ album_id => 52249, track_ids => [9999999] });
ok(scalar(@TITLEQ) == 2 && !exists $TITLEQ[1]{track_id} && scalar(@$items) == 4,
   'tracks no longer there (a rescan renumbered them): the whole album, as an empty narrowing does');
$MATERIAL = 1;

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
