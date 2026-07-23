#!/usr/bin/env perl
#
# REGRESSION TEST — who is allowed to record an "empty artist" verdict.
#
# FIELD (Simon, 2026-07-22): *"a first search for Nick Cave gave 4 hits, one was
# just Nick Cave which had albums in it ... now going back to search again it's
# hidden the solo Nick Cave and it shouldn't have."*
#
# The row was dropped by 0.46.6's dead-end filter:
#     search row DROP 'Nick Cave': proven empty on a previous render
#                                  (mbid=4aae17a7-9f0c-487b-b60e-f8eafb410b1d)
# and the verdict was WRONG — rendering that exact mbid live returns 75 items:
# Albums (9), Singles (5), Compilations (1), including CARNAGE and Seven Psalms.
#
# HOW A WRONG VERDICT GETS WRITTEN. The verdict is keyed by MBID *alone*, so it
# speaks for every search row that resolves to that artist — and more than one
# does. MusicBrainz has no artist called "Nick Cave & Warren Ellis" (verified:
# count=0, likewise "Panda Bear & Sonic Boom"; "Robert Plant & Alison Krauss"
# returns count=1, which is the ONLY reason that one behaves differently), so
# 0.47.0's joint-credit split correctly sends that row to the HEAD act. Its page
# is then built from a candidate pool searched under a name that is not the
# artist's — a fair render of a different question — and if that comes out empty
# the verdict condemns solo Nick Cave's own row too.
#
# Simon named the shape of it exactly: *"this never got implemented into search
# and is just row based."* The resolver learned about joint credits; the
# search-row layer did not.
#
# The rule this asserts: only a render that browsed the artist under a name
# genuinely THEIRS — MusicBrainz's canonical name, or one of its recorded
# aliases, which is what makes a rename like British Sea Power -> Sea Power
# still count — may record a verdict. Everything else declines.
#
# Standalone -- no LMS install needed:  perl tools/t_verdict.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Utils::Misc Slim::Menu::GlobalSearch
                  Slim::Plugin::OPMLBased
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Cache' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Strings::cstring'} = sub { $_[1] };
    *{'Slim::Utils::Strings::string'}  = sub { $_[0] };
    push @{'Slim::Utils::Strings::ISA'}, 'Exporter';
    @{'Slim::Utils::Strings::EXPORT'} = qw(cstring string);
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { {} };
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { 0 };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json string);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get { return $CACHE{ $_[1] } }
sub set { $CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;

my $self = \&Plugins::Discography::Browse::_browsedAsSelf;
my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    # STRUCTURAL GUARD — see t_norm.pl. A bare `=~`/grep/map in ok()'s argument
    # list returns the EMPTY LIST on failure, shifting the NAME into the
    # condition slot so a FAILING assertion prints as a pass.
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# The REAL mbid from the field report.
my $MBID = '4aae17a7-9f0c-487b-b60e-f8eafb410b1d';
sub canon { $CACHE{ 'dsc:mbname:1:' . $MBID } = $_[0] }
sub aliases { $CACHE{ 'dsc:alias:2:' . $MBID } = [ @_ ] }

# ---------------------------------------------------------------------------
# 1. BROWSING THE ARTIST UNDER THEIR OWN NAME — a verdict is legitimate.
# ---------------------------------------------------------------------------
%CACHE = (); canon('Nick Cave');
ok($self->($MBID, 'Nick Cave'), 'the canonical name IS the artist');
ok($self->($MBID, 'nick   cave'),
   '... compared NORMALISED, so spacing and case cannot refuse a fair render');

# ---------------------------------------------------------------------------
# 2. THE FIELD CASE — a joint credit is NOT the artist, so its render may not
#    condemn the head act's row. Every separator `_creditHead` knows.
# ---------------------------------------------------------------------------
for my $joint ('Nick Cave & Warren Ellis', 'Nick Cave and Warren Ellis',
               'Nick Cave feat. Warren Ellis', 'Nick Cave / Warren Ellis',
               'Nick Cave with Warren Ellis') {
    ok(!$self->($MBID, $joint), "'$joint' may NOT record a verdict");
}

# ---------------------------------------------------------------------------
# 3. A RENAME MUST STILL COUNT. MB's canonical name is "Sea Power" and the user
#    typed the band's old name — that is a real name for this artist (0.45.0),
#    not somebody else's, so the render is entitled to its verdict. Without
#    this, every renamed artist would silently lose dead-end filtering.
# ---------------------------------------------------------------------------
%CACHE = (); canon('Sea Power'); aliases('British Sea Power', 'BSP');
ok($self->($MBID, 'British Sea Power'), 'a recorded MB ALIAS counts as the artist');
ok($self->($MBID, 'Sea Power'),         '... and so does the canonical name itself');
ok(!$self->($MBID, 'Sea Power & Friends'),
   '... but a joint credit of the renamed artist still does not');

# ---------------------------------------------------------------------------
# 4. FAILS SAFE. Anything we cannot verify declines to record — a missing
#    verdict costs one thin search row, a wrong one hides a real artist for a
#    week (0.46.6's own stated principle, and the 0.44.5 lesson that a cold
#    cache must never be read as an answer).
# ---------------------------------------------------------------------------
%CACHE = ();
ok(!$self->($MBID, 'Nick Cave'),
   'no canonical name cached -> decline rather than guess');
canon('Nick Cave');
ok(!$self->(undef, 'Nick Cave'), 'no mbid -> decline');
ok(!$self->($MBID, ''),          'no browsed name -> decline');
ok(!$self->($MBID, undef),       'undef browsed name -> decline');
%CACHE = (); canon('');
ok(!$self->($MBID, 'Nick Cave'), 'an EMPTY canonical name proves nothing');

# ---------------------------------------------------------------------------
# 5. AND IT STILL SAYS NO TO A DIFFERENT ARTIST, which is the whole point of
#    the check — this is not merely "allow everything that looks close".
# ---------------------------------------------------------------------------
%CACHE = (); canon('Nick Cave');
ok(!$self->($MBID, 'Nick Cave & the Bad Seeds'),
   'the Bad Seeds are a different MB artist -> not self');
ok(!$self->($MBID, 'Warren Ellis'), 'the OTHER half of the credit -> not self');
ok(!$self->($MBID, 'Kate Bush'),    'an unrelated artist -> not self');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
