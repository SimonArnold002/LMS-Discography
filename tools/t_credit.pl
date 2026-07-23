#!/usr/bin/env perl
#
# REGRESSION TEST — a JOINT CREDIT is not an artist name.
#
# FIELD (full-library sweep, diagnosed 2026-07-22): albums whose ALBUMARTIST is
# a joint credit dead-ended on "Couldn't identify this artist on MusicBrainz":
#
#     Stan Getz / João Gilberto feat. Antônio Carlos Jobim
#     Charlie Parker & Dizzy Gillespie
#     Django Reinhardt & Jean Sablon
#
# MusicBrainz has no ARTIST with those names — it models them as an artist
# CREDIT of two artists on the release, so every resolver pass was asking for
# something that cannot exist.
#
# MEASURED SCOPE, and it is why the miss-guard is the whole design: 49 of 1107
# album artists in the library LOOK like joint credits, but 36 are real band
# names that resolve perfectly well (Belle and Sebastian, Nick Cave & the Bad
# Seeds, Booker T. & the MG's). Of the 13 that failed on MusicBrainz, the
# plugin's existing alias/unquoted passes already rescued 2 — measured through
# the real chain, NOT inferred from the mirror, which is what stopped an
# `&`/`and` variant pass being built as dead code.
#
# So these assertions come in two halves: the splitter must fire on a real
# joint credit, and must NOT mangle a band name — the second half is the one
# that matters, because the cost of being wrong is showing a confidently WRONG
# discography instead of an honest miss.
#
# Standalone -- no LMS install needed:  perl tools/t_credit.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;
my $DATA;
my @QUERIES;   # every MB search URL, in order

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { $DATA };
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my ($cls, $cb, $errcb, $opt) = @_;
        return bless { cb => $cb, err => $errcb }, 'T::HTTP';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get { return $CACHE{ $_[1] } }
sub set { $CACHE{ $_[1] } = $_[2]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
# A MIRROR base: un-throttled, which is where the extra passes are allowed.
sub get { return $_[1] eq 'mb_base_url' ? 'http://mirror:5000/ws/2/' : undef }
sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { 'stub error' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @QUERIES, $url;
    $DATA = main::response_for($url);
    $self->{cb}->(T::Resp->new);
}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;
my $API = 'Plugins::Discography::API';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    # STRUCTURAL GUARD against the list-context trap that has cost time five
    # times in this repo: a bare `=~` (or grep/map) in ok()'s argument list
    # returns the EMPTY LIST on failure, which shifts the test NAME into the
    # condition slot so a FAILING assertion prints as a pass. A missing name is
    # the fingerprint, so refuse it loudly instead of scoring it.
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# MB answers ONLY for these names — everything else returns nothing, exactly as
# the mirror does for a joint credit.
my %KNOWN = (
    'stan getz'                => ['8f2422ab-0ec6-4c92-80c4-afe9622fab32', 'Stan Getz'],
    'charlie parker'           => ['bfa0f2a9-1c3c-4b53-bbb6-1a9d1e6a1a7c', 'Charlie Parker'],
    'belle and sebastian'      => ['e5c7b94f-e264-473c-bb0f-37c85d4d5c70', 'Belle and Sebastian'],
    'nick cave & the bad seeds'=> ['172e1f1a-504d-4488-b053-6344c63a2b0a', 'Nick Cave & the Bad Seeds'],
);
sub response_for {
    my ($url) = @_;
    my ($q) = $url =~ /query=([^&]*)/;
    $q = '' unless defined $q;
    $q =~ s/%([0-9a-f]{2})/chr hex $1/gie;
    $q =~ s/\+/ /g;
    my ($want) = $q =~ /(?:artist|alias):"?([^"]*)"?/;
    $want = '' unless defined $want;
    $want =~ s/^\s+|\s+$//g;
    if (my $hit = $KNOWN{ lc $want }) {
        return { artists => [ { id => $hit->[0], name => $hit->[1], score => 100 } ] };
    }
    return { artists => [] };
}

sub resolve {
    my ($name) = @_;
    %CACHE = (); @QUERIES = ();
    my $got = 'UNSET';
    $API->_artistMbidByName($name, sub { $got = $_[0] });
    return $got;
}

# ---------------------------------------------------------------------------
# 1. THE FIELD CASES. Each must resolve to the FIRST act named.
# ---------------------------------------------------------------------------
ok((resolve("Stan Getz / Jo\x{e3}o Gilberto feat. Ant\x{f4}nio Carlos Jobim") // '')
   eq $KNOWN{'stan getz'}[0], 'a "/" credit resolves to the first act');
ok((resolve('Charlie Parker & Dizzy Gillespie') // '')
   eq $KNOWN{'charlie parker'}[0], 'an "&" credit resolves to the first act');
ok((resolve('Stan Getz with Charlie Parker') // '')
   eq $KNOWN{'stan getz'}[0], '"with" is a credit separator too');
ok((resolve('Stan Getz feat. Someone Else') // '')
   eq $KNOWN{'stan getz'}[0], 'so is "feat."');

# The joint name caches to the SAME mbid, so it costs one lookup per 30 days.
%CACHE = (); @QUERIES = ();
$API->_artistMbidByName('Charlie Parker & Dizzy Gillespie', sub { });
my $n1 = scalar @QUERIES;
$API->_artistMbidByName('Charlie Parker & Dizzy Gillespie', sub { });
ok(scalar(@QUERIES) == $n1, 'the joint name is cached — a repeat costs no request');

# ---------------------------------------------------------------------------
# 2. THE HALF THAT MATTERS: a real BAND NAME must never be split. Each of these
#    resolves whole, so the splitter must never be reached.
# ---------------------------------------------------------------------------
ok((resolve('Belle and Sebastian') // '') eq $KNOWN{'belle and sebastian'}[0],
   '"Belle and Sebastian" resolves WHOLE and is never split');
ok((resolve('Nick Cave & the Bad Seeds') // '') eq $KNOWN{'nick cave & the bad seeds'}[0],
   '"Nick Cave & the Bad Seeds" resolves WHOLE and is never split');
%CACHE = (); @QUERIES = ();
$API->_artistMbidByName('Belle and Sebastian', sub { });
ok(!(grep { /query=[^&]*Belle(?:%22|")/i && !/Sebastian/i } @QUERIES),
   '... and "Belle" alone is never asked for');

# A name that fails AND has no separator stays an honest miss.
ok(!defined resolve('Nobody At All Xyzzy'), 'an unknown single name still misses');

# ---------------------------------------------------------------------------
# 3. THE SPLITTER ITSELF, unit-tested — including what it must REFUSE.
# ---------------------------------------------------------------------------
my $head = \&Plugins::Discography::API::_creditHead;
ok(($head->('Stan Getz / Jo\x{e3}o Gilberto') // '') eq 'Stan Getz', 'head of a "/" credit');
ok(!defined $head->('A & B'), 'a head under 3 characters is refused outright');
ok(!defined $head->('Radiohead'), 'a plain name is not a credit');
ok(!defined $head->('AC/DC'), 'no spaces around the slash — AC/DC is one name');
# Asserted EXACTLY rather than "either is fine": a vague assertion here would
# hide a change in where the split lands. Earth, Wind & Fire resolves whole in
# reality, so this path is unreachable for it — the point is the shape.
ok(($head->('Earth, Wind & Fire') // '') eq 'Earth, Wind',
   'a comma list splits at the ampersand, keeping the comma part');
ok(($head->('Django Reinhardt & Jean Sablon') // '') eq 'Django Reinhardt',
   'head of an "&" credit');
ok(($head->('Stan Getz / A / B') // '') eq 'Stan Getz', 'splits on the FIRST separator only');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
