#!/usr/bin/perl
# ONE ALBUM NEVER CLAIMS ANOTHER (0.56.43).
#
# Field (soak follow-up, 2026-10-03): Dean Martin's "Greatest Hits" tile (MB,
# 1988) read Local off Nancy Sinatra's "Greatest Hits" (1990), where he sings
# one duet. Simon: "all that needs to happen is to not try and claim tracks from
# one album for another ... If Dean Martin is credited on a song on a Nancy
# Sinatra album we link the song from that album to appearances. If it's a
# compilation album attributed to that artist it's that artist's album."
#
# localAlbums' performance-role join returns albums the artist is only credited
# ON, and matchesFor / claimedLocalIds gated every Local copy on the BROWSED
# artist (the Raising Sand co-credit rule, 2026-07-11), so a same-titled tile
# took one. Now an album not credited TO the artist (not one of its album
# artists or its band, and not filed under him) is marked `_otherArtist` and
# judged under its own album artist. Appearances is unchanged: such an album
# was never claimed there by anything else and still lands in it.
#
# Library shapes MEASURED live 2026-10-03 (Dean Martin 152539):
#   role_id:ARTIST,ALBUMARTIST,BAND,TRACKARTIST -> his 2 albums, Nancy Sinatra's
#     Greatest Hits, the Rat Pack's The Collection, VA compilations ...
#   role_id:ALBUMARTIST,BAND -> his 2 albums only
#   role_id:ALBUMARTIST alone -> his 2 + the 2 VA compilations (LMS adds ARTIST)
#   Raising Sand: album artist shown as Robert Plant, but Alison Krauss holds
#     ALBUMARTIST on it too (it is in her ALBUMARTIST,BAND list).
#
# Standalone: perl tools/t_otheralbum.pl
use strict;
use warnings;
use FindBin;

our (%PERF, %CREDITED, @ASKED, $CREDITS_DIE);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # Stubbed LMS `albums` by artist_id, answering by the ROLE LIST asked, as
    # the live server does: the performance join from %PERF, the album-artist
    # / band list from %CREDITED. Every role list is recorded.
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $args) = @_;
        my ($aid)  = map { /^artist_id:(\d+)$/ ? $1 : () } @$args;
        my ($role) = map { /^role_id:(.+)$/   ? $1 : () } @$args;
        push @main::ASKED, $role // '';
        if (($role // '') eq 'ALBUMARTIST,BAND') {
            die "db gone\n" if $main::CREDITS_DIE;
            return bless { loop => [ map { { id => $_ } } @{ $main::CREDITED{$aid // ''} || [] } ] }, 'T::Req';
        }
        # The album's contributor id comes back only when `S` is in the tags,
        # as on the live server.
        my ($tags) = map { /^tags:(.*)$/ ? $1 : () } @$args;
        my $withId = ($tags // '') =~ /S/;
        return bless { loop => [ map { my %r = %$_; delete $r{artist_id} unless $withId; \%r }
                                 @{ $main::PERF{$aid // ''} || [] } ] }, 'T::Req';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs)) { push @{"${p}::ISA"}, 'Exporter' }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}
package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Req;
sub getResult { my ($s, $w) = @_; $w eq 'count' ? scalar @{ $s->{loop} } : $s->{loop} }
package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $SRC = 'Plugins::Discography::Sources';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" } else { $fail++; print "FAIL - $n\n" }
}

my ($DEAN, $NANCY, $RATPACK, $VA, $ALISON, $PLANT) = (152539, 154506, 156066, 151537, 155065, 155064);
my $row = sub { my ($id, $album, $year, $artist, $artistId) = @_;
                { id => $id, album => $album, year => $year, artist => $artist, artist_id => $artistId } };

# ---------------------------------------------------------------------------
# 1. localAlbums marks what is NOT credited to the artist, and nothing else.
# ---------------------------------------------------------------------------
%PERF = (
    $DEAN => [
        $row->(50228, 'A Winter Romance', 1959, 'Dean Martin', $DEAN),
        $row->(50229, 'The Best of Dean Martin: The Singles Collection', 1997, 'Dean Martin', $DEAN),
        $row->(51065, 'Greatest Hits', 1990, 'Nancy Sinatra', $NANCY),
        $row->(52017, 'The Collection', 2006, 'The Rat Pack', $RATPACK),
        $row->(52305, 'Welcome to the Ultra-Lounge', 1996, 'Various Artists', $VA),
        # Filed under him with no album-artist tag: LMS's album contributor is
        # him, but he holds no ALBUMARTIST role on it.
        $row->(60001, 'Untagged Own Album', 1964, 'Dean Martin', $DEAN),
    ],
    $ALISON => [ $row->(51365, 'Raising Sand', 2007, 'Robert Plant', $PLANT) ],
);
%CREDITED = ( $DEAN => [ 50228, 50229 ], $ALISON => [ 51365 ] );

@ASKED = ();
my $dean = $SRC->localAlbums($DEAN, 'Dean Martin');
my %other = map { $_->{_albumid} => ($_->{_otherArtist} ? 1 : 0) } @$dean;
ok(scalar(@$dean == 6), 'every album he performs on is still returned (6)');
ok($other{51065}, "Nancy Sinatra's Greatest Hits is marked as credited to someone else");
ok($other{52017}, "the Rat Pack's The Collection is marked");
ok($other{52305}, 'a Various Artists compilation is marked');
ok(!$other{50228} && !$other{50229}, 'his own albums, incl. his own compilation, are not marked');
ok(!$other{60001}, 'an album filed under him with no album-artist tag is not marked');
ok(scalar(grep { $_ eq 'ALBUMARTIST,BAND' } @ASKED),
   'the credits are asked as ALBUMARTIST,BAND together (ALBUMARTIST alone makes LMS add ARTIST)');
ok(!scalar(grep { $_ eq 'ALBUMARTIST' } @ASKED), '... never as ALBUMARTIST alone');

my $alison = $SRC->localAlbums($ALISON, 'Alison Krauss');
ok(scalar(@$alison == 1 && !$alison->[0]{_otherArtist}),
   'Raising Sand on Alison Krauss: shown as Robert Plant, but she is an album artist on it, so not marked');

{
    local $CREDITS_DIE = 1;
    my $d = $SRC->localAlbums($DEAN, 'Dean Martin');
    ok(scalar(@$d == 6 && !grep { $_->{_otherArtist} } @$d),
       'credits that cannot be read mark nothing (today\'s matching)');
}

# ---------------------------------------------------------------------------
# 2. matchesFor: a copy credited to someone else never claims a same-titled
#    tile; one credited to the artist (alone or jointly) still does.
# ---------------------------------------------------------------------------
my @SOURCES = ( { name => 'Local', local => 1 } );
my %by = map { $_->{_albumid} => $_ } @$dean, @$alison;
my $ids = sub { join ',', sort map { $_->{_albumid} } map { @{ $_->{items} } } @{ $_[0] || [] } };
my $mf  = sub {
    my ($artist, $title, $local, $rg, $relMap) = @_;
    $SRC->matchesFor({}, $artist, $title, $local, $rg // 'rg-x', $relMap || {}, undef,
                     { sources => \@SOURCES, rgType => 'Album' });
};
my $unflag = sub { my %c = %{ $_[0] }; delete $c{_otherArtist}; \%c };

ok($ids->($mf->('Dean Martin', 'Greatest Hits', [ $by{51065} ], 'rg-gh')) eq '',
   "THE FIELD CASE: Dean Martin's \"Greatest Hits\" tile no longer takes Nancy Sinatra's album");
ok($ids->($mf->('Dean Martin', 'Greatest Hits', [ $unflag->($by{51065}) ], 'rg-gh')) eq '51065',
   'control: the same copy without the mark is taken, as before (the mark is what changed it)');
ok($ids->($mf->('Dean Martin', 'The Collection', [ $by{52017} ])) eq '',
   "the Rat Pack's The Collection does not take his \"The Collection\"");
ok($ids->($mf->('Dean Martin', 'Welcome to the Ultra-Lounge', [ $by{52305} ])) eq '',
   'a Various Artists compilation does not take a same-titled album of his');
ok($ids->($mf->('Dean Martin', 'A Winter Romance', [ $by{50228} ])) eq '50228',
   'his own album still matches its tile');
ok($ids->($mf->('Dean Martin', 'The Best of Dean Martin: The Singles Collection', [ $by{50229} ])) eq '50229',
   'his own compilation is his album and still matches');
ok($ids->($mf->('Dean Martin', 'Untagged Own Album', [ $by{60001} ])) eq '60001',
   'an album filed under him with no album-artist tag still matches');
ok($ids->($mf->('Alison Krauss', 'Raising Sand', [ $by{51365} ])) eq '51365',
   'Raising Sand still matches on Alison Krauss (the 2026-07-11 co-credit rule holds)');
ok($ids->($mf->('Dean Martin', 'Greatest Hits', [ { %{ $by{51065} }, _mbid => 'rel-gh' } ],
                'rg-gh', { 'rel-gh' => 'rg-gh' })) eq '51065',
   'a MusicBrainz id placing the copy IN this group is the same album, not another: it still matches');

# ---------------------------------------------------------------------------
# 3. claimedLocalIds agrees, so an unclaimed copy reaches Appearances as today.
# ---------------------------------------------------------------------------
{
    my $rgs = [ { mbid => 'rg-gh', title => 'Greatest Hits',    type => 'Album', secondary => [] },
                { mbid => 'rg-co', title => 'The Collection',   type => 'Album', secondary => [] },
                { mbid => 'rg-wr', title => 'A Winter Romance', type => 'Album', secondary => [] } ];
    my $c = $SRC->claimedLocalIds($rgs, 'Dean Martin', $dean, {});
    ok(!$c->{51065} && !$c->{52017}, 'claimedLocalIds: neither album credited to someone else is claimed');
    ok($c->{50228}, 'claimedLocalIds: his own album is claimed by its tile');
    my $c0 = $SRC->claimedLocalIds($rgs, 'Dean Martin', [ $unflag->($by{51065}) ], {});
    ok($c0->{51065}, 'claimedLocalIds control: without the mark it is claimed, as before');
    my $ca = $SRC->claimedLocalIds([ { mbid => 'rg-rs', title => 'Raising Sand', type => 'Album', secondary => [] } ],
                                   'Alison Krauss', $alison, {});
    ok($ca->{51365}, 'claimedLocalIds: Raising Sand still claimed on Alison Krauss');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
