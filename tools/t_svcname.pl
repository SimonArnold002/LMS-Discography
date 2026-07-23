#!/usr/bin/env perl
#
# REGRESSION TEST — the search view re-queries the services under MB's canonical
# name in a spelling the SERVICES actually match (0.49.2, "The La's" / Qobuz).
#
# FIELD (Simon): searching "The Las" never showed Qobuz, while "The La's" did.
# Diagnosed live end to end:
#   * the 0.49.1 resolver fix DOES resolve "The Las" -> The La's;
#   * MB's canonical name is "The La\x{2019}s" with a CURLY apostrophe;
#   * Qobuz's artist search returns the band for the STRAIGHT apostrophe
#     ("The La's") but only junk for the curly one — measured on the live box;
#   * the 0.45.2 second-pass guard compared `_norm(canon)` with `_norm(query)`,
#     and `_norm` folds EVERY apostrophe away, so "The Las", "The La's" and
#     "The La\x{2019}s" all collapse to "the las" — the guard decided "canonical
#     == typed" and skipped the re-search, so Qobuz was never queried under a
#     spelling it matches.
#
# THE FIX: search the services under `_svcQueryName(canon)` (typographic marks
# folded to ASCII, everything else kept), and gate on THAT differing from the
# query — a comparison that preserves the punctuation the services key on. The
# gate is strictly WIDER than the old `_norm` one (`_norm` folds more, so
# _norm-equal implies svcName-equal), so it can only ADD second passes.
#
# Standalone -- no LMS install needed:  perl tools/t_svcname.pl
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
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/'//g; $s =~ s/[^a-z0-9]+/ /g;
        $s =~ s/^ +| +$//g; $s };
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
binmode STDOUT, ":encoding(UTF-8)";
my $B = 'Plugins::Discography::Browse';
my $svc = $B->can('_svcQueryName');

my ($pass, $fail) = (0, 0);
sub ok { my ($c, $n) = @_; die "no name\n" unless defined $n;
    if ($c) { $pass++; print "ok   - $n\n" } else { $fail++; print "FAIL - $n\n" } }

# --- _svcQueryName folds typographic marks to ASCII, keeps letters/case ---
ok($svc->("The La\x{2019}s") eq "The La's", 'curly apostrophe U+2019 -> straight');
ok($svc->("Rock \x{2018}n\x{2019} Roll") eq "Rock 'n' Roll", 'both curly single quotes -> straight');
ok($svc->("Sigur R\x{f3}s") eq "Sigur R\x{f3}s", 'accents are LEFT ALONE (services keep them)');
ok($svc->("Antony and the Johnsons") eq "Antony and the Johnsons", 'a plain name is unchanged');
ok($svc->("AC/DC") eq "AC/DC", 'a slash is not a typographic mark - untouched');
ok($svc->("Godspeed You\x{2021}") eq "Godspeed You\x{2021}", 'a non-punctuation glyph is left');
ok($svc->("Death \x{2013} From Above") eq "Death - From Above", 'en dash -> hyphen');

# --- the SECOND-PASS GATE decision: lc(svcName(canon)) ne lc(query) ---
# (the exact test _artistSearchView applies before re-searching the services)
sub runs { my ($q, $canon) = @_; lc($svc->($canon)) ne lc($q) ? 1 : 0 }

ok(runs("The Las",  "The La\x{2019}s"), 'apostrophe-less query vs curly canonical -> RE-SEARCH (the fix)');
ok(runs("The La\x{2019}s", "The La\x{2019}s"),
   'curly-apostrophe query still re-searches (first pass used curly, services need straight)');
ok(!runs("The La's", "The La\x{2019}s"),
   'straight-apostrophe query does NOT re-search (its first pass already matched Qobuz)');
ok(!runs("Radiohead", "Radiohead"), 'an identical canonical does not re-search');
ok(!runs("radiohead", "Radiohead"), 'a case-only difference does not re-search');
ok(runs("British Sea Power", "Sea Power"), 'a genuine rename still re-searches (0.45.2 case)');

# --- the WIDER-GATE INVARIANT: whenever the OLD _norm gate would have run, the
#     new one runs too (so nothing that worked is dropped). ---
my $norm = Plugins::Discography::Sources->can('_norm');
for my $pair (["The Las","The La\x{2019}s"], ["British Sea Power","Sea Power"],
              ["Bjork","Bj\x{f6}rk"], ["Radiohead","Radiohead"], ["the beatles","The Beatles"]) {
    my ($q, $c) = @$pair;
    my $oldRuns = ($norm->($c) ne $norm->($q)) ? 1 : 0;
    my $newRuns = runs($q, $c);
    ok(!$oldRuns || $newRuns, "wider gate: '$q' vs '$c' - new runs whenever old did");
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
