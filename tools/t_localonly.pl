#!/usr/bin/env perl
#
# REGRESSION TEST — the "Show only what you own" view toggle (0.49.0).
#
# Simon asked for an Options toggle that narrows the discography view to what
# the user OWNS. It is implemented like the sort toggle: a fresh drill-in entry
# carrying an explicit `local_only` param, threaded through `_identParams` so a
# filtered view's own rows (sort / paging / drill) re-issue the command with the
# flag still set and the filter STICKS. The actual owned-only filtering lives in
# `_buildList` (integration-heavy, exercised live); what a silent bug would most
# likely break is this PLUMBING — whether the flag is emitted, flips both ways,
# and survives a sort — so that is what is pinned here, through the REAL subs.
#
# Standalone — no LMS install needed:  perl tools/t_localonly.pl
#
use strict;
use warnings;
use FindBin;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Plugins::Discography::Plugin Plugins::Discography::API
                  Plugins::Discography::Sources)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };   # returns the token
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    # Browse builds %GENERIC_TITLE via Sources::_norm at load — a light stub is
    # enough (this suite never depends on real normalisation).
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

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
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# _identParams threads local_only ONLY when on (off must be absent, so a flipped
# command genuinely means "all sources", not local_only=0 lingering).
my %on  = $B->can('_identParams')->({ artist => 'X', local_only => 1 });
my %off = $B->can('_identParams')->({ artist => 'X', local_only => 0 });
ok(scalar($on{local_only} && $on{local_only} == 1), '_identParams emits local_only=1 when on');
ok(scalar(!exists $off{local_only}), '_identParams omits local_only when off (= all sources)');

# The toggle: label names the ACTION, and fixedParams/passthrough flip both ways.
my $offRow = $B->can('_localOnlyToggleItem')->(undef, { artist => 'X', local_only => 0 });
my $onRow  = $B->can('_localOnlyToggleItem')->(undef, { artist => 'X', local_only => 1 });
ok(scalar($offRow->{name} eq 'PLUGIN_DISCOGRAPHY_SHOW_LOCAL_ONLY'), 'off-state label = Show local only');
ok(scalar($onRow->{name}  eq 'PLUGIN_DISCOGRAPHY_SHOW_ALL_SOURCES'), 'on-state label = Show all sources');
my $offFP = $offRow->{itemActions}{items}{fixedParams};
my $onFP  = $onRow->{itemActions}{items}{fixedParams};
ok(scalar($offFP->{local_only} && $offFP->{local_only} == 1), 'from OFF, tapping sets local_only=1');
ok(scalar(!exists $onFP->{local_only}), 'from ON, tapping clears local_only (all sources)');
ok(scalar($offRow->{passthrough}[0]{local_only} == 1 && $onRow->{passthrough}[0]{local_only} == 0),
   'passthrough (legacy walk path) flips the same way');

# A sort inside a local-only view must keep the filter (both toggles live in
# Options; sorting must not silently drop local_only).
my $sortRow = $B->can('_sortToggleItem')->(undef, { artist => 'X', sort => 'newest', local_only => 1 });
ok(scalar($sortRow->{itemActions}{items}{fixedParams}{local_only} == 1),
   'sorting inside a local-only view keeps local_only=1');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
