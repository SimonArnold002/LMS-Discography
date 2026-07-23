#!/usr/bin/env perl
#
# REGRESSION TEST — _resolveOne picks the best spine-corroborated artist.
#
# WHY THIS EXISTS: 0.44.18 fixed a bug that NO other gate in this repo can see.
# The scoring loop was `for my $a (@same)`, and a lexical $a in scope MASKS
# sort's own $a, so `sort { $b->{score} <=> $a->{score} }` compared against
# undef and did not sort. The wrong service artist was adopted, and a
# misordered zero-scoring head reported UNRESOLVED even when a candidate
# corroborated.
#
# It is invisible to every other check: `perl -c` cannot see it, and Sources.pm
# has no `use warnings`, so the "uninitialized value in numeric comparison"
# that would have exposed it never fires. Hence a behavioural test.
#
# THIS TEST WAS VERIFIED TO FAIL ON THE PRE-FIX CODE (it picked the score-1
# artist and returned 1 album instead of 3). A test that only ever passes
# proves nothing about the bug it claims to guard — if you change it, re-check
# that it still goes red when the loop variable is renamed back to $a.
#
# Standalone: stubs the Slim modules itself, so it needs no LMS install and no
# stub tree. Run from the repo root:  perl tools/t_resolve.pl
#
use strict;
use warnings;
use FindBin;

BEGIN {
    # Minimal Slim + Plugin stubs, registered in %INC so Sources.pm's `use`
    # lines are satisfied without an LMS install.
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers
                  Slim::Control::Request Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}       = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
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
sub get { return 1 }
sub set { return 1 }
sub init { return 1 }

package main;

# The modules live in <repo>/Discography/ but load as Plugins::Discography::*,
# so build a throwaway Plugins/ tree that symlinks to them (same trick as
# tools/syntax_check.sh).
use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography"
    or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;

my $norm = \&Plugins::Discography::Sources::_norm;
my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $name) = @_;
    # STRUCTURAL GUARD against the list-context trap that has cost time five
    # times in this repo: a bare `=~` (or grep/map) in ok()'s argument list
    # returns the EMPTY LIST on failure, which shifts the test NAME into the
    # condition slot so a FAILING assertion prints as a pass. A missing name is
    # the fingerprint, so refuse it loudly instead of scoring it.
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $name;
    # scalar() deliberately: `ok($x =~ /re/, 'name')` puts the match in LIST
    # context, and on failure the empty list shifts the NAME into the condition
    # slot so the assertion "passes" (0.43.5 lesson).
    if (scalar $cond) { $pass++; print "ok   - $name\n" }
    else              { $fail++; print "FAIL - $name\n" }
}

# Three same-name service artists. Only 200 corroborates the MB spine twice;
# 300 corroborates once; 100 not at all. The spread matters: with the shadowed
# sort the head of the list was NOT the best scorer.
my %CAT = (
    100 => [ { title => 'Unrelated Junk' }, { title => 'More Junk' } ],
    200 => [ { title => 'Open Corpse' }, { title => 'Classy' }, { title => 'Filler' } ],
    300 => [ { title => 'Classy' } ],
);
my $spine   = { map { $norm->($_) => 1 } ('Open Corpse', 'Classy') };
my @artists = map { { id => $_, name => 'Madness' } } (100, 200, 300);
my $fetch   = sub { my ($id, $done) = @_; $done->($CAT{$id}) };

my ($gotArtist, $gotAlbums);
Plugins::Discography::Sources::_resolveOne(
    'TestSvc', 'Madness', \@artists, $spine, $fetch,
    sub { ($gotArtist, $gotAlbums) = @_ }, 0);

ok(defined $gotArtist, 'a corroborating candidate resolves');
ok(defined $gotArtist && $gotArtist->{id} eq '200',
   'the BEST-scoring candidate wins (not merely the first)');

# The winner's albums must be the ones fetched for IT — the shadowed sort could
# desync artist from albums, handing back another candidate's catalogue.
my $titles = $gotAlbums ? join(',', map { $_->{title} } @$gotAlbums) : '';
ok($titles eq 'Open Corpse,Classy,Filler',
   "winner's albums travel with the winner (got: $titles)");

# Control: nothing corroborates -> UNRESOLVED, never a silent adoption.
my $a2 = 'sentinel';
Plugins::Discography::Sources::_resolveOne(
    'TestSvc', 'Madness', \@artists, { 'nothing here' => 1 }, $fetch,
    sub { $a2 = $_[0] }, 0);
ok(!defined $a2, 'no corroboration -> UNRESOLVED (releases stay visible)');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
