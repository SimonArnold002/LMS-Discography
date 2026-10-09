#!/usr/bin/env perl
#
# REGRESSION TEST — THE BIOGRAPHY LADDER (2026-10-08). Simon: "If a user has
# Qobuz then first look to get these from Qobuz, if it has none then ... the
# Deezer API ..., if this has none fall back to how we currently pull them", and
# "some bios are for multiple acts named the same ideally we pull whats correct".
# Then, on the plan: "why does Qobuz only do bios from MB artist links ... We
# could miss many relying purely on MB links" (so the pool's artist comes first)
# and "We dont need deezer plugin you can query this without it".
#
# Drives the REAL Browse::_bioStart, _serviceArtistOk, _withSource,
# _deezerSource and _fetchArtistBio, and the REAL Prose::isMixedArtistPage on
# MAI's answers captured from the live server 2026-10-08 (tools/fixtures/
# mai_bio_<name>.json). The service clients (Prose's Deezer and Qobuz calls) are
# stood in for: tools/t_deezerbio.pl drives the real ones. The identity cases
# are the field cases each rule exists for (Robert Plant & Alison Krauss, The
# Oscar Peterson Trio, Shostakovich, 王菲 / Faye Wong, the Rossini rapper).
#
# Standalone, no LMS install needed:  perl tools/t_bioladder.pl
#
use strict;
use warnings;
use utf8;
use FindBin;
use JSON::PP ();

our (%CACHE, %TTL, @TIMERS, %LINKS, $LINKS_DEFER, @LINKS_WAIT, $SHARED, %POOL, $QOBUZ_ON,
     $LOCAL_BIO, @LOCAL_ASKS, @ASKS, %NAME_OF, %ALIASES, $MAI_TEXT, $MAI_DEFER, @MAI_WAIT);

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
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    # cstring with its arguments, so the source line can be read back.
    *{'Slim::Utils::Strings::cstring'}   = sub { defined $_[2] ? "$_[1]=$_[2]" : $_[1] };
    *{'Slim::Utils::Strings::stringExists'} = sub { 0 };
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { 1 };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Timers::setTimer'}     = sub { my $t = [@_]; push @main::TIMERS, $t; $t };
    *{'Slim::Utils::Timers::killSpecific'} = sub { my ($t) = @_; @main::TIMERS = grep { $_ != $t } @main::TIMERS; 1 };

    # Sources: the matcher's fold (letters of every script kept, as the real one
    # does for a decoded name), the resolver's threshold, the pool reader.
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/[^\p{Alnum}]+/ /g; $s =~ s/^ +| +$//g; $s };
    *{'Plugins::Discography::Sources::SPINE_STRONG'}  = sub { 2 };
    *{'Plugins::Discography::Sources::orderedAdapters'} = sub { $main::QOBUZ_ON ? ({ name => 'Qobuz' }) : () };
    *{'Plugins::Discography::Sources::peekPoolMeta'}  = sub { $main::POOL{ lc $_[3] } };

    # API: the keys as API.pm spells them, the links, the same-name answer, the
    # names MusicBrainz holds.
    *{'Plugins::Discography::API::_bioPickKey'} = sub { 'dsc:bio:3:'  . lc($_[0] // '') };
    *{'Plugins::Discography::API::_dzIdKey'}    = sub { 'dsc:dzid:1:' . lc($_[0] // '') };
    *{'Plugins::Discography::API::warmServiceLinks'} = sub {
        my ($c, $mbid, $cb) = @_;
        return push @main::LINKS_WAIT, sub { $cb->($main::LINKS{ lc $mbid }) } if $main::LINKS_DEFER;
        $cb->($main::LINKS{ lc $mbid });
    };
    *{'Plugins::Discography::API::sharesNameWithProminentAsync'} = sub { $_[-1]->($main::SHARED) };
    *{'Plugins::Discography::API::peekArtistName'}    = sub { $main::NAME_OF{ lc $_[1] } };
    *{'Plugins::Discography::API::peekArtistAliases'} = sub { $main::ALIASES{ lc $_[1] } };

    # MAI's local-file reader, in the shape LocalFile.pm returns (an item list).
    *{'Plugins::MusicArtistInfo::LocalFile::getBiography'} = sub {
        my ($class, $client, $params, $args) = @_;
        push @main::LOCAL_ASKS, { %$args };
        return defined $main::LOCAL_BIO ? [ { name => $main::LOCAL_BIO } ] : undef;
    };

    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Cache;
sub get    { $main::CACHE{ $_[1] } }
sub set    { $main::CACHE{ $_[1] } = $_[2]; $main::TTL{ $_[1] } = $_[3]; 1 }
sub remove { delete $main::CACHE{ $_[1] }; 1 }
sub DESTROY {}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
require Plugins::Discography::Prose;
my $B = 'Plugins::Discography::Browse';
my $P = 'Plugins::Discography::Prose';
sub f { my $n = shift; my $c = $B->can($n) or die "no sub $n\n"; $c->(@_) }

binmode STDOUT, ':encoding(UTF-8)';
my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $MONTH = $B->BIO_FOUND_TTL;
my $DAY   = $B->BIO_EMPTY_TTL;

# The service clients, stood in for: each records its call and answers from
# %ANS (a code ref, or a fixed answer).
our %ANS;
my $realFetchArtistBio = \&Plugins::Discography::Browse::_fetchArtistBio;
{
    no strict 'refs'; no warnings 'redefine';
    for my $m (qw(deezerBioFor deezerBio deezerFindArtist qobuzArtistBio)) {
        *{"${P}::$m"} = sub {
            my $class = shift; my $cb = $_[-1];
            push @main::ASKS, [ $m, @_[0 .. $#_ - 1] ];
            my $a = $main::ANS{$m};
            $cb->(ref $a eq 'CODE' ? $a->(@_) : $a);
        };
    }
    *{"${B}::_fetchArtistBio"} = sub { my $cb = $_[-1]; push @main::ASKS, [ 'mai-name', $_[1] ];
        return push @main::MAI_WAIT, sub { $cb->($main::MAI_TEXT) } if $main::MAI_DEFER;
        $cb->($main::MAI_TEXT) };
    *{"${B}::_fetchExactBio"}  = sub { my $cb = $_[-1]; push @main::ASKS, [ 'mai-exact', $_[1], $_[2] ];
        $cb->($main::MAI_TEXT) };
}

sub fresh {
    %CACHE = (); %TTL = (); @TIMERS = (); %LINKS = (); $LINKS_DEFER = 0; @LINKS_WAIT = ();
    $SHARED = 0; %POOL = (); $QOBUZ_ON = 1; $LOCAL_BIO = undef; @LOCAL_ASKS = (); @ASKS = ();
    %NAME_OF = (); %ALIASES = (); $MAI_TEXT = 'MAI BIO'; $MAI_DEFER = 0; @MAI_WAIT = ();
    %ANS = (deezerBioFor => { none => 1 }, deezerBio => { none => 1 },
            deezerFindArtist => { none => 1 }, qobuzArtistBio => { none => 1 });
}
sub asked { my $m = shift; scalar grep { $_->[0] eq $m } @ASKS }
my $MB = 'aaaaaaaa-0000-4000-8000-000000000001';
# Run one ladder: returns (text, calls). %o: artist, artist_id, mbid, spine, pool
# (undef = the caller never says), nopool.
# $R holds the LAST run's answer and keeps being updated by its callback, for
# the cases that answer after run() has returned.
our $R;
sub run {
    my (%o) = @_;
    my $r = $R = { text => undef, calls => 0 };
    my $L = f('_bioStart', undef,
        { artist => $o{artist} // 'Somebody', artist_id => $o{artist_id}, mbid => $o{mbid} // $MB,
          ($o{nopool} ? (nopool => 1) : ()) },
        sub { $r->{text} = shift; $r->{calls}++ });
    $L->{spine}->($o{spine} // { 'one' => 1, 'two' => 1, 'three' => 1 }) unless $o{nospine};
    $L->{pool}->() unless $o{nopoolcall};
    return ($r->{text}, $r->{calls}, $L);
}
sub key { 'dsc:bio:3:' . lc($_[0] // $MB) }
my $SRC = 'PLUGIN_DISCOGRAPHY_SOURCE';

# ---------------------------------------------------------------------------
# 1. QOBUZ'S POOL ARTIST COMES FIRST, when it is the act on the page. Its bio is
#    in the reply the pool already read, so nothing is asked.
# ---------------------------------------------------------------------------
fresh();
$POOL{$MB} = { unresolved => 0, meta => { id => 43840, name => 'Radiohead', score => 36, spine => 561,
                                          bio => '<p>Radiohead are an English rock band.</p>' } };
$LINKS{$MB} = { qobuz => [ 43840 ], deezer => [ 399 ] };
my ($t, $n) = run(artist => 'Radiohead');
ok(scalar($n == 1 && defined $t && $t eq "Radiohead are an English rock band.\n\n$SRC=Qobuz"),
   '1: the pool artist passes: its Qobuz bio, cleaned, with "(Source: Qobuz)"');
ok(scalar(!asked('qobuzArtistBio')), '1: ... the MusicBrainz link is not asked (the pool answered)');
ok(scalar(($TTL{ key() } // 0) == $MONTH && $CACHE{ key() } =~ /^Radiohead are/),
   '1: ... kept a month under dsc:bio:3:<mbid> (every source above it answered)');

# Cached: the next page asks nothing at all.
@ASKS = (); @LOCAL_ASKS = ();
($t, $n) = run(artist => 'Radiohead');
ok(scalar($n == 1 && $t =~ /^Radiohead are/ && !@ASKS && !@LOCAL_ASKS),
   '1: the next page reads the kept pick and asks nothing');

# ---------------------------------------------------------------------------
# 2. THE IDENTITY CHECK, one field case each.
# ---------------------------------------------------------------------------
my $names = sub { [ map { Plugins::Discography::Sources::_norm($_) } @_ ] };
ok(scalar(!f('_serviceArtistOk', { name => 'Robert Plant', score => 7, spine => 9 },
             $names->('Robert Plant & Alison Krauss'))),
   '2: Robert Plant solo on the duo page (his albums match 7 of its releases) is refused by name');
ok(scalar(!f('_serviceArtistOk', { name => 'Maxim Shostakovich', score => 12, spine => 300 },
             $names->('Shostakovich', 'Дмитрий Дмитриевич Шостакович'))),
   '2: "Maxim Shostakovich" for "Shostakovich" is refused');
ok(scalar(f('_serviceArtistOk', { name => 'Faye Wong', score => 4, spine => 40 },
            $names->('王菲', 'Faye Wong'))),
   '2: 王菲 / Faye Wong passes by the alias');
ok(scalar(!f('_serviceArtistOk', { name => 'Rossini', score => 1, spine => 300 }, $names->('Rossini'))),
   '2: the Rossini rapper (1 title of a long page) is refused by the albums');
ok(scalar(f('_serviceArtistOk', { name => 'Holly Golightly', score => 1, spine => 1 }, $names->('Holly Golightly'))),
   '2: a page of ONE release needs one match');
ok(scalar(!f('_serviceArtistOk', { name => 'X', score => 5, spine => 0 }, $names->('X'))),
   '2: a page of no releases proves nothing');
ok(scalar(f('_serviceArtistOk', { name => 'Radiohead', score => 2, spine => 561 }, $names->('Radiohead'))
          && !f('_serviceArtistOk', { name => 'Radiohead', score => 1, spine => 561 }, $names->('Radiohead'))),
   '2: SPINE_STRONG is the bar (2 passes, 1 does not)');

# Through the ladder: the duo page never shows Robert Plant's solo bio.
fresh();
my $DUO = 'aaaaaaaa-0000-4000-8000-0000000000d0';
$POOL{$DUO} = { unresolved => 0, meta => { id => 35157, name => 'Robert Plant', score => 7, spine => 9,
                                           bio => '<p>Robert Plant is an English singer.</p>' } };
$LINKS{$DUO} = { qobuz => [], deezer => [] };
($t) = run(artist => 'Robert Plant & Alison Krauss', mbid => $DUO);
ok(scalar(defined $t && $t eq 'MAI BIO'), "2: the duo page: Robert Plant's solo bio is never used (MAI's instead)");

# The Trio: the leader's albums were the pool, so the pool carries no artist.
fresh();
my $TRIO = 'aaaaaaaa-0000-4000-8000-0000000000c0';
$POOL{$TRIO} = { unresolved => 0 };
$LINKS{$TRIO} = { qobuz => [], deezer => [] };
($t) = run(artist => 'The Oscar Peterson Trio', mbid => $TRIO);
ok(scalar(defined $t && $t eq 'MAI BIO'), "2: The Oscar Peterson Trio: no pool artist, so never Oscar Peterson's bio");

# 王菲 through the ladder, by the alias MusicBrainz holds.
fresh();
my $FW = 'aaaaaaaa-0000-4000-8000-0000000000f0';
$ALIASES{$FW} = [ 'Faye Wong' ];
$POOL{$FW} = { unresolved => 0, meta => { id => 9, name => 'Faye Wong', score => 4, spine => 40, bio => 'Faye Wong is a singer.' } };
($t) = run(artist => '王菲', mbid => $FW);
ok(scalar(defined $t && $t =~ /^Faye Wong is a singer\./), '2: 王菲: the pool artist "Faye Wong" passes by the alias');

# ---------------------------------------------------------------------------
# 3. QOBUZ BY MUSICBRAINZ'S LINK, only when the pool cannot answer.
# ---------------------------------------------------------------------------
fresh();
$POOL{$MB} = { unresolved => 1 };
$LINKS{$MB} = { qobuz => [ 111, 222 ], deezer => [] };
$ANS{qobuzArtistBio} = { text => '<p>Linked bio.</p>', id => 111 };
($t) = run();
ok(scalar(defined $t && $t eq "Linked bio.\n\n$SRC=Qobuz"), '3: an unresolved pool: the linked Qobuz id gives the bio');
ok(scalar(asked('qobuzArtistBio') == 1 && join(',', @{ (grep { $_->[0] eq 'qobuzArtistBio' } @ASKS)[0][2] }) eq '111,222'),
   '3: ... asked with the linked ids');

# MusicBrainz links the very entity the pool read: its bio is in hand, no request.
fresh();
$POOL{$MB} = { unresolved => 0, meta => { id => 43840, name => 'Somebody Else', score => 0, spine => 30, bio => 'Pool reply bio.' } };
$LINKS{$MB} = { qobuz => [ 43840 ], deezer => [] };
($t) = run();
ok(scalar(defined $t && $t =~ /^Pool reply bio\./ && !asked('qobuzArtistBio')),
   "3: the pool artist failed the check but MusicBrainz links that id: its bio is used, nothing asked");

# The pool's artist passes but has no bio: only OTHER linked ids are asked.
fresh();
$POOL{$MB} = { unresolved => 0, meta => { id => 43840, name => 'Somebody', score => 3, spine => 3 } };
$LINKS{$MB} = { qobuz => [ 43840, 50000 ], deezer => [] };
$ANS{qobuzArtistBio} = sub { { none => 1 } };
($t) = run();
my ($qa) = grep { $_->[0] eq 'qobuzArtistBio' } @ASKS;
ok(scalar($qa && join(',', @{ $qa->[2] }) eq '50000'), "3: the pool's own id (no bio) is never asked again");

# The pool passes with no bio and MusicBrainz links only that id: nothing asked.
fresh();
$POOL{$MB} = { unresolved => 0, meta => { id => 43840, name => 'Somebody', score => 3, spine => 3 } };
$LINKS{$MB} = { qobuz => [ 43840 ], deezer => [] };
($t) = run();
ok(scalar(!asked('qobuzArtistBio') && defined $t && $t eq 'MAI BIO'), '3: ... and when that is the only link, nothing is asked');

# Qobuz not in use: neither Qobuz tier, even with links.
fresh();
$QOBUZ_ON = 0;
$LINKS{$MB} = { qobuz => [ 111 ], deezer => [] };
($t) = run();
ok(scalar(!asked('qobuzArtistBio') && $t eq 'MAI BIO' && ($TTL{ key() } // 0) == $MONTH),
   '3: Qobuz not in use: no Qobuz tier, and the MAI pick is kept a month');

# ---------------------------------------------------------------------------
# 4. DEEZER, no Deezer plugin: the linked ids, else the search (kept per mbid).
# ---------------------------------------------------------------------------
fresh();
$POOL{$MB} = { unresolved => 0 };
$LINKS{$MB} = { qobuz => [], deezer => [ 399, 323887691 ] };
$ANS{deezerBioFor} = { text => '<p>From Deezer.</p>', source => 'Music Story', id => 399 };
($t) = run();
ok(scalar(defined $t && $t eq "From Deezer.\n\n$SRC=Music Story via Deezer"),
   '4: linked Deezer ids: the bio, "(Source: Music Story via Deezer)"');
ok(scalar(!asked('deezerFindArtist')), '4: ... and no search');

fresh();
$POOL{$MB} = { unresolved => 0 };
$LINKS{$MB} = { qobuz => [], deezer => [] };
$NAME_OF{$MB} = 'Holly Golightly';
$ANS{deezerFindArtist} = { id => 10623, name => 'Holly Golightly', score => 20, spine => 30 };
$ANS{deezerBio} = { text => 'Holly Golightly is a singer.', source => 'Deezer for Creators', id => 10623 };
my $sp = { map { $_ => 1 } qw(truly she is none other), 'god don t like it' };
($t) = run(artist => 'Holly Golightly', spine => $sp);
my ($fa) = grep { $_->[0] eq 'deezerFindArtist' } @ASKS;
ok(scalar(defined $t && $t eq "Holly Golightly is a singer.\n\n$SRC=Deezer for Creators"),
   '4: no link: Deezer\'s search finds the artist, its bio (written by the artist: "Deezer for Creators")');
ok(scalar($fa && ref $fa->[2] eq 'HASH' && $fa->[2] == $sp && $fa->[3] eq 'Holly Golightly'
          && join(',', @{ $fa->[1] }) eq 'holly golightly'),
   "4: ... searched under MusicBrainz's name, checked against the page's releases and names");
ok(scalar(($CACHE{"dsc:dzid:1:$MB"} // '') eq '10623' && ($TTL{"dsc:dzid:1:$MB"} // 0) == 30 * 86400),
   '4: ... the id it found is kept a month');
%CACHE = (); %TTL = (); @ASKS = ();
$CACHE{"dsc:dzid:1:$MB"} = '10623';
($t) = run(artist => 'Holly Golightly', spine => $sp);
ok(scalar(!asked('deezerFindArtist') && asked('deezerBio') == 1 && $t =~ /^Holly Golightly is/),
   '4: the next time, the kept id is asked straight away (no search)');

fresh();
$POOL{$MB} = { unresolved => 0 };
$LINKS{$MB} = { qobuz => [], deezer => [] };
$ANS{deezerFindArtist} = { none => 1 };
($t) = run();
ok(scalar(($CACHE{"dsc:dzid:1:$MB"} // 'x') eq '' && ($TTL{"dsc:dzid:1:$MB"} // 0) == 86400 && $t eq 'MAI BIO'),
   '4: the search finds none: "none" kept a day, MAI answers');
%CACHE = (); @ASKS = ();
$CACHE{"dsc:dzid:1:$MB"} = '';
run();
ok(scalar(!asked('deezerFindArtist') && !asked('deezerBio')), '4: ... and the kept "none" asks nothing');

# A page with no releases: nothing to check a hit against, so no search.
fresh();
$POOL{$MB} = { unresolved => 0 };
$LINKS{$MB} = { qobuz => [], deezer => [] };
($t) = run(spine => {});
ok(scalar(!asked('deezerFindArtist') && $t eq 'MAI BIO' && ($TTL{ key() } // 0) == $DAY),
   '4: no releases on the page: no search, and the MAI pick is kept only a day (Deezer could not tell)');

# The artist read failed: no links -> could not tell -> a day.
fresh();
$POOL{$MB} = { unresolved => 0 };
$LINKS{$MB} = undef;
($t) = run();
ok(scalar($t eq 'MAI BIO' && ($TTL{ key() } // 0) == $DAY && !asked('deezerFindArtist')),
   '4: the artist read failed: nothing asked of Deezer, the pick kept a day');

# ---------------------------------------------------------------------------
# 5. THE ORDER, and when a lower source may answer.
# ---------------------------------------------------------------------------
# The user's own file comes first, by the library id.
fresh();
$LOCAL_BIO = '<p>My own notes on this band.</p>';
$POOL{$MB} = { unresolved => 0, meta => { id => 1, name => 'Somebody', score => 3, spine => 3, bio => 'Q' } };
($t) = run(artist_id => 4242);
ok(scalar(defined $t && $t eq 'My own notes on this band.' && $LOCAL_ASKS[0]{artist_id} == 4242),
   "5: the user's own bio file wins, read by the library id, with no source line");
# On a shared name with no library id, never by name (it could be the other act's).
fresh();
$SHARED = 1;
$LOCAL_BIO = 'The other act\'s notes.';
($t) = run();
ok(scalar(!@LOCAL_ASKS && $t eq 'MAI BIO' && asked('mai-exact') == 1),
   '5: a shared name with no library id: the local file is not read by name; MAI takes the exact route');

# A lower source's text waits for the sources above it.
fresh();
$POOL{$MB} = { unresolved => 0 };
$LINKS{$MB} = { qobuz => [], deezer => [ 399 ] };
$LINKS_DEFER = 1;
$ANS{deezerBioFor} = { text => 'From Deezer.', source => 'Music Story' };
my $calls;
($t, $calls) = run();
ok(scalar($calls == 0), '5: MAI has answered but the links are still out: no pick yet');
$_->() for splice @LINKS_WAIT;
ok(scalar(defined $R->{text} && $R->{text} =~ /^From Deezer\./), '5: ... the links land: Deezer (above MAI) wins');

# A higher source's text does not wait for the lower ones.
fresh();
$MAI_DEFER = 1;
$POOL{$MB} = { unresolved => 0, meta => { id => 1, name => 'Somebody', score => 3, spine => 3, bio => 'Pool bio.' } };
($t, $calls) = run();
ok(scalar($calls == 1 && $t =~ /^Pool bio\./), '5: the pool answers while MAI is still out: picked at once');
$_->() for splice @MAI_WAIT;
ok(scalar($R->{calls} == 1), '5: ... a late MAI answer changes nothing (one answer, once)');

# ---------------------------------------------------------------------------
# 6. BIO_WAIT, and "could not tell" keeps a pick a day.
# ---------------------------------------------------------------------------
fresh();
$LINKS_DEFER = 1;
($t, $calls) = run();
ok(scalar($calls == 0 && @TIMERS == 1 && $TIMERS[0][1] > 0), '6: the links never land: the BIO_WAIT deadline is armed');
$_->[2]->() for splice @TIMERS;
ok(scalar($R->{calls} == 1 && ($R->{text} // '') eq 'MAI BIO' && ($TTL{ key() } // 0) == $DAY),
   '6: on the deadline: decided with MAI, kept only a day');
$_->() for splice @LINKS_WAIT;
ok(scalar($R->{calls} == 1), '6: ... the late links change nothing');

# BIO_WAIT passes while the page still waits for its cold pool (up to 20 s):
# the ladder waits with it, and the pool's Qobuz bio still wins.
fresh();
$LINKS{$MB} = { qobuz => [], deezer => [] };
my ($t6, $c6, $L6) = run(nopoolcall => 1);
ok(scalar($c6 == 0 && @TIMERS == 1), '6: the pool not told yet, MAI answered: no pick (Qobuz is above MAI)');
$_->[2]->() for splice @TIMERS;
ok(scalar($R->{calls} == 0), '6: BIO_WAIT passes while the page waits for its pool: still no pick (it would save nothing)');
$POOL{$MB} = { unresolved => 0, meta => { id => 5, name => 'Somebody', score => 3, spine => 3, bio => 'Late pool bio.' } };
$L6->{pool}->();
ok(scalar($R->{calls} == 1 && ($R->{text} // '') =~ /^Late pool bio\./ && ($TTL{ key() } // 0) == $MONTH),
   "6: ... the pool lands: its Qobuz bio wins, decided at once, kept a month");
# The same, but a tier above MAI is still out when the pool lands: cut there.
fresh();
$LINKS_DEFER = 1;
($t6, $c6, $L6) = run(nopoolcall => 1);
$_->[2]->() for splice @TIMERS;
$POOL{$MB} = { unresolved => 0 };
$L6->{pool}->();
ok(scalar($R->{calls} == 1 && ($R->{text} // '') eq 'MAI BIO' && ($TTL{ key() } // 0) == $DAY),
   '6: ... with the links still out when the late pool lands: decided then (MAI), kept a day');

# The pool not in yet (not cached when the page draws): could not tell.
fresh();
$LINKS{$MB} = { qobuz => [], deezer => [] };
($t) = run();
ok(scalar($t eq 'MAI BIO' && ($TTL{ key() } // 0) == $DAY), '6: no pool cached: Qobuz could not tell, the pick kept a day');
# The works page builds no pool: that is a sure answer.
fresh();
$LINKS{$MB} = { qobuz => [], deezer => [] };
($t) = run(nopool => 1);
ok(scalar($t eq 'MAI BIO' && ($TTL{ key() } // 0) == $MONTH), '6: the works page (no pool by design): kept a month');

# Nothing anywhere.
fresh();
$MAI_TEXT = undef;
$POOL{$MB} = { unresolved => 0 };
$LINKS{$MB} = { qobuz => [], deezer => [] };
($t, $calls) = run();
ok(scalar($calls == 1 && !defined $t && ($CACHE{ key() } // 'x') eq '' && ($TTL{ key() } // 0) == $DAY),
   '6: nothing anywhere: undef, kept as none for a day');

# No mbid: no ladder, no answer.
fresh();
my $L;
($t, $calls, $L) = (undef, 0);
$L = f('_bioStart', undef, { artist => 'X', mbid => '' }, sub { $t = shift; $calls++ });
$L->{spine}->({}); $L->{pool}->();
ok(scalar($calls == 1 && !defined $t && !@ASKS), '6: no mbid: answered at once with none, nothing asked');

# ---------------------------------------------------------------------------
# 7. THE SOURCE LINE.
# ---------------------------------------------------------------------------
ok(scalar(f('_deezerSource', 'Music Story') eq 'Music Story via Deezer'), '7: "Music Story" -> "Music Story via Deezer"');
ok(scalar(f('_deezerSource', 'Deezer for Creators') eq 'Deezer for Creators'), '7: "Deezer for Creators" stays as it is');
ok(scalar(f('_deezerSource', '') eq 'Deezer' && f('_deezerSource', undef) eq 'Deezer'), '7: no writer named -> "Deezer"');
ok(scalar(f('_withSource', undef, 'Text.', 'Qobuz') eq "Text.\n\n$SRC=Qobuz"), '7: the line is its own last paragraph');
ok(scalar(f('_withSource', undef, 'Text.', undef) eq 'Text.'), '7: no source, no line');

# ---------------------------------------------------------------------------
# 8. A PAGE ABOUT SEVERAL ACTS IS NO BIOGRAPHY (MAI's live answers, captured).
# ---------------------------------------------------------------------------
sub fx { my $f = "$FindBin::Bin/fixtures/mai_bio_$_[0].json";
         open my $fh, '<:raw', $f or die "fixture $f: $!"; local $/;
         JSON::PP::decode_json(scalar <$fh>)->{biography} }
my @mixed  = qw(hope echo pencil dark_star roswell kingfisher);
my @single = qw(madness jack bush genesis radiohead lambchop kraftwerk cocteau_twins nirvana);
for my $m (@mixed)  { ok(scalar($P->isMixedArtistPage(fx($m))),  "8: '$m' opens as several acts -> mixed") }
for my $s (@single) { ok(scalar(!$P->isMixedArtistPage(fx($s))), "8: '$s' is one act -> not mixed") }
ok(scalar($P->isMixedArtistPage('<p>There is more than one artist with this name.</p>')), '8: "more than one artist" -> mixed');
ok(scalar(!$P->isMixedArtistPage('There are three members in the band: A, B and C.')), '8: members of ONE band -> not mixed');
ok(scalar(!$P->isMixedArtistPage('') && !$P->isMixedArtistPage(undef)), '8: nothing -> not mixed');

# Through the name route: MAI's mixed page gives no biography. The REAL
# _fetchArtistBio (kept before the stand-in replaced it), with MAI's
# getBiography answering the captured page.
{
    no strict 'refs'; no warnings 'redefine';
    our $MAI_PAGE = fx('dark_star');
    local *{'Plugins::MusicArtistInfo::ArtistInfo::getBiography'} = sub {
        my ($client, $cb) = @_; $cb->([ { name => $main::MAI_PAGE } ]) };
    %CACHE = ();
    my $got = 'unset';
    $realFetchArtistBio->(undef, 'Dark Star', undef, sub { $got = shift });
    ok(scalar(!defined $got && ($CACHE{'dsc:bio:2:dark star'} // 'x') eq ''),
       "8: the name route: MAI's Dark Star page (five bands) -> no biography, kept as none");
    $MAI_PAGE = fx('jack');
    %CACHE = ();
    $realFetchArtistBio->(undef, 'Jack', undef, sub { $got = shift });
    ok(scalar(defined $got && $got =~ /^Jack were a British alternative rock band/),
       '8: control: Jack (one act) -> its biography');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
