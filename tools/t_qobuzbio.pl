#!/usr/bin/env perl
#
# REGRESSION TEST — THE QOBUZ POOL KEEPS THE ARTIST IT SETTLED ON, FOR THE
# BIOGRAPHY LADDER (2026-10-08). Simon: "why does Qobuz only do bios from MB
# artist links as it links albums at that point we have matched artist and
# should be able to get it then? We could miss many relying purley on MB links".
#
# Qobuz's artist/get carries `biography.content` (the Qobuz plugin's own artist
# menu shows it), and every candidate the resolver fetches comes through
# Sources::_searchQobuz's $fetch. So the artist the lookup SETTLES ON is kept
# with the pool (getCandidates -> _cacheCands `meta`): its id, name, how many of
# the page's releases its albums matched (_spineScore), the page's size, and its
# biography. Browse::_bioStart reads it back with peekPoolMeta.
#
# Drives the REAL _searchQobuz, getCandidates and peekPoolMeta against a fake
# Qobuz API in the plugin's shapes (API.pm getArtist: {albums}{items},
# {biography}{content}; search: {artists}{items}).
#
# Standalone -- no LMS install needed:  perl tools/t_qobuzbio.pl
#
use strict;
use warnings;
use FindBin;

our (%ARTISTS, %ALBUMS, %BIO, @FETCHED, %HOLD, @HELD, @TIMERS, %CACHE, %PREF);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers
                  Slim::Control::Request Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'}   = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::PluginManager::dataForPlugin'} = sub { { version => 'test' } };
    *{'Slim::Utils::Timers::setTimer'}     = sub { my $t = [@_]; push @main::TIMERS, $t; $t };
    *{'Slim::Utils::Timers::killSpecific'} = sub { my ($t) = @_; @main::TIMERS = grep { $_ != $t } @main::TIMERS; 1 };
    push @{'Slim::Utils::Log::ISA'},   'Exporter';
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { exists $main::PREF{ $_[1] } ? $main::PREF{ $_[1] } : 1 } sub set { 1 } sub init { 1 }
package T::Cache;
sub get    { $main::CACHE{ $_[1] } }
sub set    { $main::CACHE{ $_[1] } = $_[2]; 1 }
sub remove { delete $main::CACHE{ $_[1] }; 1 }

# The Qobuz plugin's API handler, as _searchQobuz calls it.
package T::QAPI;
sub search {
    my ($s, $cb, $q, $type) = @_;
    return $cb->({ albums => { items => [] } }) if ($type // '') eq 'albums';
    $cb->({ artists => { items => $main::ARTISTS{$q} || [] } });
}
sub getArtist {
    my ($s, $cb, $id) = @_;
    push @main::FETCHED, $id;
    my $r = { albums => { items => [ map { +{ %$_ } } @{ $main::ALBUMS{$id} || [] } ] },
              (exists $main::BIO{$id} ? (biography => { content => $main::BIO{$id} }) : ()) };
    return push @main::HELD, [ $cb, $r ] if $main::HOLD{$id};
    $cb->($r);
}
package Plugins::Qobuz::Plugin;
sub getAPIHandler  { bless {}, 'T::QAPI' }
sub _albumItem     { my ($c, $al) = @_; return { name => $al->{title}, type => 'playlist' } }
sub QobuzGetTracks { 'qobuz-rebuild' }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $S = 'Plugins::Discography::Sources';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

sub al { my ($id, $title, $aid, $aname) = @_;
         +{ id => $id, title => $title, artist => { id => $aid, name => $aname },
            artists => [ { id => $aid, name => $aname, roles => [ 'main-artist' ] } ] } }
sub fresh {
    %ARTISTS = (); %ALBUMS = (); %BIO = (); @FETCHED = (); %HOLD = (); @HELD = (); @TIMERS = ();
    %CACHE = (); %PREF = ();
}
# _searchQobuz alone: what it hands its collector.
sub search {
    my (%o) = @_;
    my @got;
    $S->can('_searchQobuz')->('client', $o{query}, 'Qobuz', sub { push @got, [ @_ ] },
        $o{spine}, $o{aliases}, $o{strict} // 0, 0, $o{leaders});
    return @got;
}
my $sp = sub { +{ map { $S->can('_norm')->($_) => 1 } @_ } };

# ---------------------------------------------------------------------------
# 1. AN UNAMBIGUOUS ARTIST: the one it settles on, with its bio and evidence.
# ---------------------------------------------------------------------------
fresh();
%ARTISTS = ('radiohead' => [ { id => 43840, name => 'Radiohead' } ]);
%ALBUMS  = (43840 => [ al('a1', 'OK Computer', 43840, 'Radiohead'), al('a2', 'Kid A', 43840, 'Radiohead'),
                       al('a3', 'Amnesiac', 43840, 'Radiohead'), al('a4', 'A Live Thing', 43840, 'Radiohead') ]);
%BIO = (43840 => '<p>Radiohead are an English rock band.</p>');
my @got = search(query => 'Radiohead', spine => $sp->('OK Computer', 'Kid A', 'Amnesiac', 'The Bends'));
my $meta = $got[0][1];
ok(scalar(@got == 1 && ref $got[0][0] eq 'ARRAY' && @{ $got[0][0] } == 4), '1: the pool: its four albums');
ok(scalar(ref $meta eq 'HASH' && $meta->{id} == 43840 && $meta->{name} eq 'Radiohead'),
   '1: ... and, beside them, the artist it settled on');
ok(scalar($meta->{score} == 3 && $meta->{spine} == 4), "1: ... with its evidence: 3 of the page's 4 releases matched");
ok(scalar(($meta->{bio} // '') eq '<p>Radiohead are an English rock band.</p>'),
   "1: ... and its biography, from the reply the pool already read");
ok(scalar(@FETCHED == 1), '1: ... no request of its own (one artist fetch, as before)');

# No biography in the reply: none kept, the rest unchanged.
fresh();
%ARTISTS = ('radiohead' => [ { id => 43840, name => 'Radiohead' } ]);
%ALBUMS  = (43840 => [ al('a1', 'OK Computer', 43840, 'Radiohead') ]);
($meta) = map { $_->[1] } search(query => 'Radiohead', spine => $sp->('OK Computer'));
ok(scalar(ref $meta eq 'HASH' && !exists $meta->{bio} && $meta->{score} == 1), '1: no biography in the reply: none kept');
%BIO = (43840 => "  \n ");
fresh();
%ARTISTS = ('radiohead' => [ { id => 43840, name => 'Radiohead' } ]);
%ALBUMS  = (43840 => [ al('a1', 'OK Computer', 43840, 'Radiohead') ]);
%BIO = (43840 => "  \n ");
($meta) = map { $_->[1] } search(query => 'Radiohead', spine => $sp->('OK Computer'));
ok(scalar(!exists $meta->{bio}), '1: a blank biography counts as none');

# ---------------------------------------------------------------------------
# 2. A SHARED NAME: the corroborated act's biography, never the other's.
# ---------------------------------------------------------------------------
fresh();
%ARTISTS = ('madness' => [ { id => 1825, name => 'Madness' }, { id => 99, name => 'Madness' } ]);
%ALBUMS  = (1825 => [ al('s1', 'One Step Beyond...', 1825, 'Madness'), al('s2', 'Absolutely', 1825, 'Madness') ],
            99   => [ al('h1', 'Open Corpse', 99, 'Madness') ]);
%BIO = (1825 => 'Madness are an English ska band.', 99 => 'Madness is a horrorcore rapper.');
($meta) = map { $_->[1] } search(query => 'Madness', spine => $sp->('Open Corpse'), strict => 1);
ok(scalar(ref $meta eq 'HASH' && $meta->{id} == 99 && $meta->{score} == 1 && $meta->{spine} == 1),
   "2: the horrorcore rapper's page: the artist whose album matches (99)");
ok(scalar(($meta->{bio} // '') eq 'Madness is a horrorcore rapper.'),
   "2: ... with HIS biography, though the ska band's reply (fetched to score it) carried one too");
ok(scalar((grep { $_ == 1825 } @FETCHED) && (grep { $_ == 99 } @FETCHED)), '2: (both were fetched to score them)');

# Nothing corroborates: unresolved, no meta.
fresh();
%ARTISTS = ('madness' => [ { id => 1825, name => 'Madness' }, { id => 98, name => 'Madness' } ]);
%ALBUMS  = (1825 => [ al('s1', 'One Step Beyond...', 1825, 'Madness') ], 98 => [ al('x', 'Elsewhere', 98, 'Madness') ]);
%BIO = (1825 => 'Ska.', 98 => 'Other.');
@got = search(query => 'Madness', spine => $sp->('Open Corpse'), strict => 1);
ok(scalar(@got == 1 && !defined $got[0][0] && !defined $got[0][1]),
   '2: nothing corroborates: unresolved, and no artist kept (the ladder goes to the link)');

# ---------------------------------------------------------------------------
# 3. NO ARTIST OF ITS OWN: no meta, whatever the albums.
# ---------------------------------------------------------------------------
# The band has no entity: the leader's albums are the pool (0.56.60).
fresh();
my $TRIO = 'The Oscar Peterson Trio';
%ARTISTS = (lc($TRIO) => [ { id => 700, name => 'Oscar Peterson Trio Tribute' } ],
            'oscar peterson' => [ { id => 500, name => 'Oscar Peterson' } ]);
%ALBUMS  = (700 => [ al('x1', 'Some Tribute', 700, 'Oscar Peterson Trio Tribute') ],
            500 => [ al('p1', 'Night Train', 500, 'Oscar Peterson'), al('p2', 'We Get Requests', 500, 'Oscar Peterson') ]);
%BIO = (500 => 'Oscar Peterson was a Canadian jazz pianist.');
@got = search(query => $TRIO, spine => $sp->('Night Train', 'We Get Requests'), leaders => [ 'Oscar Peterson' ]);
ok(scalar(@got == 1 && ref $got[0][0] eq 'ARRAY' && @{ $got[0][0] } == 2 && !defined $got[0][1]),
   "3: the Trio (no entity of its own): the leader's albums are the pool, but NO artist is kept - never Oscar's bio");

# No spine: the album-search fallback, no artist.
fresh();
%ARTISTS = ();
@got = search(query => 'Nobody Known', spine => {});
ok(scalar(@got == 1 && !defined $got[0][1]), '3: the album-search fallback (no artist found): no artist kept');

# A joint entry beside the artist is never the artist kept.
fresh();
%ARTISTS = ('james yorkston' => [ { id => 409047, name => 'James Yorkston' },
                                  { id => 9001, name => 'James Yorkston & The Big Eyes Family Players' } ]);
%ALBUMS  = (409047 => [ al('a1', 'The Year of the Leopard', 409047, 'James Yorkston'), al('a3', 'When the Haar Rolls In', 409047, 'James Yorkston') ],
            9001   => [ al('j1', 'Folk Songs', 9001, 'James Yorkston & The Big Eyes Family Players') ]);
%BIO = (409047 => 'James Yorkston is a Scottish musician.', 9001 => 'A joint entry.');
($meta) = map { $_->[1] } search(query => 'James Yorkston', spine => $sp->('The Year of the Leopard', 'When the Haar Rolls In', 'Folk Songs'));
ok(scalar(ref $meta eq 'HASH' && $meta->{id} == 409047 && ($meta->{bio} // '') =~ /^James Yorkston is/),
   '3: James Yorkston + a joint entry beside him: the artist kept is him, with his bio, not the joint one');

# ---------------------------------------------------------------------------
# 4. KEPT WITH THE POOL, read back by peekPoolMeta (the key peekPool reads).
# ---------------------------------------------------------------------------
my $MB = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
fresh();
%ARTISTS = ('radiohead' => [ { id => 43840, name => 'Radiohead' } ]);
%ALBUMS  = (43840 => [ al('a1', 'OK Computer', 43840, 'Radiohead'), al('a2', 'Kid A', 43840, 'Radiohead') ]);
%BIO = (43840 => 'RH bio');
my $pool;
$S->getCandidates('client', 'Radiohead', 0, sub { $pool = $_[0] },
                  { mbid => $MB, spine => $sp->('OK Computer', 'Kid A', 'The Bends') });
my $pm = $S->peekPoolMeta('Qobuz', 'Radiohead', $MB);
ok(scalar(ref $pool eq 'HASH' && @{ $pool->{Qobuz} || [] } == 2), '4: getCandidates answers the pool as before');
ok(scalar(ref $pm eq 'HASH' && !$pm->{unresolved} && $pm->{meta}{id} == 43840 && $pm->{meta}{bio} eq 'RH bio'
          && $pm->{meta}{score} == 2 && $pm->{meta}{spine} == 3),
   '4: peekPoolMeta reads the artist kept with the pool (id, bio, 2 of 3)');
my ($k) = grep { /^dsc:cand:/ } keys %CACHE;
ok(scalar($k && $k =~ /:qobuz:mb:\Q$MB\E$/ && $CACHE{$k}{meta}{id} == 43840),
   '4: ... stored in the very entry peekPool reads (mbid-keyed)');
ok(scalar(!grep { exists $_->{meta} } @{ $pool->{Qobuz} }), '4: ... and never on the pool items themselves');

# A cached pool from the last visit: read the same way, nothing fetched.
@FETCHED = ();
$S->getCandidates('client', 'Radiohead', 0, sub {}, { mbid => $MB, spine => $sp->('OK Computer') });
ok(scalar(!@FETCHED && $S->peekPoolMeta('Qobuz', 'Radiohead', $MB)->{meta}{id} == 43840),
   '4: the next visit: the cached pool, the same artist, nothing fetched');

# Unresolved: the entry says so, no meta.
fresh();
%ARTISTS = ('madness' => [ { id => 1825, name => 'Madness' }, { id => 98, name => 'Madness' } ]);
%ALBUMS  = (1825 => [ al('s1', 'One Step Beyond...', 1825, 'Madness') ], 98 => [ al('x', 'Elsewhere', 98, 'Madness') ]);
my $MAD = '5d500d2e-f779-4444-a93a-e61ace50abe5';
$S->getCandidates('client', 'Madness', 0, sub {}, { mbid => $MAD, spine => $sp->('Open Corpse'), ambiguous => 1 });
$pm = $S->peekPoolMeta('Qobuz', 'Madness', $MAD);
ok(scalar(ref $pm eq 'HASH' && $pm->{unresolved} && !$pm->{meta}), '4: an unresolved pool: {unresolved}, no artist');

# Not asked yet: undef ("could not tell").
ok(scalar(!defined $S->peekPoolMeta('Qobuz', 'Somebody', 'aaaaaaaa-0000-4000-8000-000000000009')),
   '4: no pool cached: undef');
# Qobuz switched off in Discography (priority 0): undef, whatever is cached.
$PREF{svc_priority_qobuz} = 0;
ok(scalar(!defined $S->peekPoolMeta('Qobuz', 'Madness', $MAD)), '4: Qobuz not in use (priority 0): undef');
delete $PREF{svc_priority_qobuz};

# A second page waiting on the same fetch (SingleFlight): the one entry, meta in it.
fresh();
%ARTISTS = ('radiohead' => [ { id => 43840, name => 'Radiohead' } ]);
%ALBUMS  = (43840 => [ al('a1', 'OK Computer', 43840, 'Radiohead') ]);
%BIO = (43840 => 'RH bio');
%HOLD = (43840 => 1);
my ($w1, $w2) = (0, 0);
$S->getCandidates('client', 'Radiohead', 0, sub { $w1++ }, { mbid => $MB, spine => $sp->('OK Computer') });
$S->getCandidates('client', 'Radiohead', 0, sub { $w2++ }, { mbid => $MB, spine => $sp->('OK Computer') });
ok(scalar(@FETCHED == 1 && !$w1 && !$w2), '4: two pages at once: one fetch, both waiting');
$_->[0]->($_->[1]) for splice @HELD;
ok(scalar($w1 == 1 && $w2 == 1 && $S->peekPoolMeta('Qobuz', 'Radiohead', $MB)->{meta}{bio} eq 'RH bio'),
   '4: ... both answered, and the artist is kept for either to read');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
