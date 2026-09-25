#!/usr/bin/env perl
#
# ADAPTER CONTRACT — how a cached candidate gets its play/browse coderef back.
#
# WHY THIS EXISTS: the candidate cache cannot hold a coderef, so `_cacheCands`
# strips `url` on write and `_reattach` puts the service's own rebuild sub back
# on read. Until the Spotify work that sub came from a %REATTACH map keyed by
# service name; it now rides on the adapter entry (`rebuild`), PFR's shape, so a
# new service is one entry instead of an entry plus a map (D1 in
# docs/spotify-adapter-plan.md, Simon 2026-09-25).
#
# PART A is behaviour through the PUBLIC paths (adapters, orderedAdapters,
# getCandidates' cache hit, peekPool). It was run against the pre-refactor code
# and passed, so it pins that the refactor changed nothing a caller can see.
# PART B is the new contract (`rebuild` on each entry, `_reattach` reading it);
# it was red before the refactor and green after.
#
# Standalone, like t_resolve.pl. Run from the repo root:  perl tools/t_adapters.pl
#
use strict;
use warnings;
use FindBin;

our (%PREF, %CACHE);

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
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    push @{'Slim::Utils::Log::ISA'},   'Exporter';
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}

package T::Null;
our $AUTOLOAD;
sub AUTOLOAD { return }
sub DESTROY  { }

package T::Prefs;
sub get  { return $main::PREF{ $_[1] } }
sub set  { $main::PREF{ $_[1] } = $_[2]; 1 }
sub init { 1 }

package T::Cache;
use Storable ();
# Storable round-trip, as LMS's cache does: a stored coderef would die here,
# which is exactly the constraint `_reattach` exists for.
sub get    { my $v = $main::CACHE{ $_[1] }; defined $v ? Storable::thaw($v) : undef }
sub set    { $main::CACHE{ $_[1] } = Storable::nfreeze($_[2]); 1 }
sub remove { delete $main::CACHE{ $_[1] }; 1 }

# Fake service plugins: exactly the subs adapters() probes for, each rebuild
# sub distinct so a crossed wire is visible.
package Plugins::Qobuz::Plugin;
sub getAPIHandler { undef }  sub _albumItem { {} }  sub QobuzGetTracks { 'qobuz-rebuild' }
package Plugins::TIDAL::Plugin;
sub getAPIHandler { undef }  sub getAlbum { 'tidal-rebuild' }  sub _renderAlbum { {} }
package Plugins::Deezer::Plugin;
sub getAPIHandler { undef }  sub _renderAlbum { {} }  sub getAlbum { 'deezer-rebuild' }

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
    my ($cond, $name) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $name && length $name;
    if ($cond) { $pass++; print "ok   - $name\n" }
    else       { $fail++; print "FAIL - $name\n" }
}

my %REBUILD = (
    Qobuz  => \&Plugins::Qobuz::Plugin::QobuzGetTracks,
    Tidal  => \&Plugins::TIDAL::Plugin::getAlbum,
    Deezer => \&Plugins::Deezer::Plugin::getAlbum,
);
%PREF = (svc_priority_qobuz => 2, svc_priority_tidal => 3, svc_priority_deezer => 4);

# Seed one cached pool per service, written through the module's own writer so
# the key and the stored shape are exactly what production writes.
my $artist = 'Radiohead';
my $mbid   = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
sub seed {
    my ($mb) = @_;
    for my $svc (sort keys %REBUILD) {
        my $key = Plugins::Discography::Sources::_candKey($svc, $artist, $mb);
        Plugins::Discography::Sources::_cacheCands($key, [
            { name => "$svc OK Computer", _svc => $svc, _albumid => "$svc-1",
              _candTitle => 'OK Computer', _candArtist => $artist,
              passthrough => [{ id => "$svc-1" }], url => sub { 'live coderef' } },
            { name => "$svc Kid A", _svc => $svc, _albumid => "$svc-2",
              _candTitle => 'Kid A', _candArtist => $artist },
        ], 3600);
    }
}
seed($mbid);

# ------------------------------------------------------------------ PART A
print "# PART A - behaviour through the public paths (must hold before AND after)\n";

my @ad = $S->can('adapters')->();
ok(scalar(@ad) == 3, 'adapters(): all three fake services detected');
ok(join(',', map { $_->{name} } @ad) eq 'Qobuz,Tidal,Deezer', 'adapters(): order unchanged');

my @oa = Plugins::Discography::Sources::orderedAdapters();
ok(join(',', map { $_->{name} } @oa) eq 'Qobuz,Tidal,Deezer', 'orderedAdapters(): priority order');

ok(!grep({ exists $_->{url} } map { @{ Storable::thaw($_)->{items} } } values %CACHE),
   'cache holds no url (stripped on write)');

# getCandidates, cache-hit path.
my $got;
$S->getCandidates(bless({}, 'T::Null'), $artist, 0, sub { $got = shift }, { mbid => $mbid });
ok(ref $got eq 'HASH', 'getCandidates: callback fired synchronously on a full cache hit');
for my $svc (sort keys %REBUILD) {
    my $items = $got->{$svc} || [];
    ok(scalar(@$items) == 2, "getCandidates $svc: both cached items returned");
    ok(!grep({ !(ref $_->{url} eq 'CODE' && $_->{url} == $REBUILD{$svc}) } @$items),
       "getCandidates $svc: every item's url is $svc\'s OWN rebuild sub");
    ok($items->[0]{name} eq "$svc OK Computer" && $items->[0]{_albumid} eq "$svc-1"
       && ref $items->[0]{passthrough} eq 'ARRAY' && $items->[0]{passthrough}[0]{id} eq "$svc-1",
       "getCandidates $svc: other fields and passthrough preserved");
}

# peekPool.
my $pool = $S->peekPool($artist, $mbid);
ok($pool->{resolved} == 1 && $pool->{cold} == 0, 'peekPool: resolved, not cold');
for my $svc (sort keys %REBUILD) {
    my $items = $pool->{bySvc}{$svc} || [];
    ok(scalar(@$items) == 2
       && !grep({ !(ref $_->{url} eq 'CODE' && $_->{url} == $REBUILD{$svc}) } @$items),
       "peekPool $svc: items carry $svc\'s own rebuild sub");
    ok(scalar(keys %{ $pool->{index}{$svc} || {} }) > 0, "peekPool $svc: title index built");
}

# Reattach works on a COPY: the next read must be unaffected by callers
# decorating what they were handed.
$pool->{bySvc}{Qobuz}[0]{name} = 'mutated by caller';
my $again = $S->peekPool($artist, $mbid);
ok($again->{bySvc}{Qobuz}[0]{name} eq 'Qobuz OK Computer', 'peekPool: a caller mutating its items does not reach the cache');

# A service switched off (priority 0) contributes nothing, cached or not.
$PREF{svc_priority_tidal} = 0;
my $off = $S->peekPool($artist, $mbid);
ok(!exists $off->{bySvc}{Tidal} && exists $off->{bySvc}{Qobuz}, 'peekPool: a priority-0 service is not read');
my $got2;
$S->getCandidates(bless({}, 'T::Null'), $artist, 0, sub { $got2 = shift }, { mbid => $mbid });
ok(!exists $got2->{Tidal} && scalar(@{ $got2->{Deezer} || [] }) == 2, 'getCandidates: a priority-0 service is not read');
$PREF{svc_priority_tidal} = 3;

# An UNRESOLVED marker survives the reattach path (hide_unmatched depends on it).
%CACHE = ();
for my $svc (sort keys %REBUILD) {
    Plugins::Discography::Sources::_cacheCands(
        Plugins::Discography::Sources::_candKey($svc, $artist, $mbid), [], 3600, 1);
}
my $unres = $S->peekPool($artist, $mbid);
ok($unres->{resolved} == 0 && $unres->{cold} == 0, 'peekPool: all-unresolved pools read as NOT resolved and NOT cold');
seed($mbid);

# ------------------------------------------------------------------ PART B
print "# PART B - the adapter-field contract (D1)\n";

for my $a (@ad) {
    ok(ref $a->{rebuild} eq 'CODE' && $a->{rebuild} == $REBUILD{ $a->{name} },
       "adapters(): $a->{name} carries its own rebuild sub");
    ok(!$a->{native_favurl}, "adapters(): $a->{name} is not native_favurl (the ListenLater favurl is built)");
}
ok(!grep({ ref $_->{rebuild} ne 'CODE' } @oa), 'orderedAdapters(): the rebuild field survives the priority copy');

my $cached = [ { name => 'x', _svc => 'Qobuz' } ];
my $re = Plugins::Discography::Sources::_reattach($ad[0], $cached);
ok(ref $re eq 'ARRAY' && @$re == 1 && $re->[0]{url} == $REBUILD{Qobuz}, '_reattach(adapter): url set from the entry');
ok(!exists $cached->[0]{url}, '_reattach: the cached list is not mutated');
ok(scalar(@{ Plugins::Discography::Sources::_reattach({ name => 'Nope' }, $cached) }) == 0,
   '_reattach: an entry without a rebuild sub yields nothing (items dropped, not left without a url)');
ok(scalar(@{ Plugins::Discography::Sources::_reattach($ad[1], undef) }) == 0, '_reattach: undef cache list is empty');
# Source-level: %REATTACH was a `my`, so no symbol-table check can see it.
my $src = do { local (@ARGV, $/) = ("$FindBin::Bin/../Discography/Sources.pm"); <> };
$src =~ s/^\s*#.*$//mg;
ok(scalar($src !~ /%REATTACH|\$REATTACH\{/), 'the %REATTACH map is gone from the code (one source of truth)');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
