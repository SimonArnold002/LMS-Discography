#!/usr/bin/env perl
#
# REGRESSION TEST — the artist-field quoted pass HOLDS a top hit that is not the
# artist asked for, so the alias pass can run (0.49.1, "The La's").
#
# FIELD (Simon): browsing/searching "The La's" never showed Qobuz. Root cause,
# measured live against musicbrainz.org 2026-07-23:
#
#     artist:"The Las"  -> 100 The Las Vegas Boneheads   (The La's NOT in results;
#                           98 The Las Vegas Nines        Lucene tokenises [the][la][s])
#     alias:"The Las"   -> 100 The La’s                   <- the artist actually meant
#     artist:"Beatles"  -> 100 The Beatles                (the +1 control: must NOT be held)
#     artist:"La's"     -> 100 Yo La Tengo   / alias:"La's" -> 100 Various Artists (special)
#
# The quoted artist pass "succeeded" on Boneheads at score 100 (the >=90 gate is
# a near no-op), so the alias pass — which returns The La's — never ran. The fix:
# a quoted ARTIST-field top hit that merely CONTAINS the query with a WHOLE extra
# name (+2 tokens) is HELD (the same last-resort slot the zero-release hit uses),
# letting the alias pass run. A +1 addition (an article/honorific: "The Beatles",
# "Ms. Lauryn Hill") is accepted exactly as before, and MB's special entities
# (Various Artists, [unknown]) are dropped so a degenerate query cannot adopt one.
#
# THE HOLD IS A FALLBACK, so it cannot regress: if no later pass does better, the
# held hit is stored — byte-identical to the old behaviour (asserted below with
# a +2 hit whose alias pass finds nothing).
#
# Standalone -- no LMS install needed:  perl tools/t_thelas.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;
my $DATA;
my @QUERIES;
our $MB_BASE = 'http://mirror:5000/ws/2/';

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Timers::setTimer'}   = sub { $_[2]->() };
    *{'Slim::Utils::Timers::killTimers'} = sub { 1 };
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
sub get { return $_[1] eq 'mb_base_url' ? $main::MB_BASE : undef }
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
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# --- real measured mbids ---
my $LAS     = 'ff3e88b3-7354-4f30-967c-1a61ebc8c642';   # The La's
my $BONE    = 'c2ee229d-0b05-4ac1-8e57-9c774c8cb9b5';   # The Las Vegas Boneheads (+2)
my $NINES   = '88f17282-2901-4343-a7ae-30188228f0c0';   # The Las Vegas Nines
my $FABS    = 'b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d';   # The Beatles (+1)
my $MSHILL  = 'e8414012-4a1c-4ad4-be5e-fc55294e28cc';   # Ms. Lauryn Hill (+1)
my $HILL    = 'b14191fa-24c5-44d8-b42d-5017b22b0430';   # Lauryn Hill (score 84)
my $YOLA    = '3f542031-b054-454d-b57b-812fa2a81b11';   # Yo La Tengo
my $RADIO   = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';   # Radiohead (exact)
my $VA      = '89ad4ac3-39f7-470e-963a-56509c546377';   # Various Artists (special)
my $UNKNOWN = '125ec42a-7229-4250-afc5-e057484327fe';   # [unknown] (special)
my $PHANTOM = 'aaaa1111-0000-0000-0000-000000000001';   # synthetic +2, no alias rescue

my %ARTIST = (
    # THE FIX: artist field finds only the Boneheads; alias field finds The La's.
    'artist:the las'   => [ { id => $BONE,  name => 'The Las Vegas Boneheads', score => 100 },
                            { id => $NINES, name => 'The Las Vegas Nines',     score => 98 } ],
    'alias:the las'    => [ { id => $LAS,   name => "The La\x{2019}s",         score => 100 } ],

    # +1 controls: accepted at the artist pass, no alias pass.
    'artist:beatles'   => [ { id => $FABS,  name => 'The Beatles',   score => 100 } ],
    'artist:lauryn hill' => [ { id => $MSHILL, name => 'Ms. Lauryn Hill', score => 100 },
                              { id => $HILL,   name => 'Lauryn Hill',     score => 84 } ],

    # Exact: no extra work at all.
    'artist:radiohead' => [ { id => $RADIO, name => 'Radiohead', score => 100 } ],

    # Special-entity guard (real measured data): the artist field leads with Yo
    # La Tengo (100, not the meant artist -> held), and the ALIAS field leads
    # with Various Artists (100) + [unknown] (96) — both special, so both must
    # be dropped rather than adopted.
    "artist:la's"      => [ { id => $YOLA,    name => 'Yo La Tengo',     score => 100 } ],
    "alias:la's"       => [ { id => $VA,      name => 'Various Artists', score => 100 },
                            { id => $UNKNOWN, name => '[unknown]',       score => 96 },
                            { id => $YOLA,    name => 'Yo La Tengo',     score => 78 } ],

    # +2 with NO alias rescue -> must fall back to the held hit (no regression).
    'artist:the phantom' => [ { id => $PHANTOM, name => 'The Phantom Menace Band', score => 100 } ],
    'alias:the phantom'  => [],
);
# The count check fires for every INEXACT accepted winner; all real artists here
# have a discography, so none is mistaken for a zero-release hit.
my %RGCOUNT = ( $LAS => 3, $FABS => 800, $MSHILL => 50, $PHANTOM => 2, $YOLA => 40 );

sub response_for {
    my ($url) = @_;
    if ($url =~ m{release-group\?artist=([^&]+)}) {
        return { 'release-group-count' => ($RGCOUNT{$1} // 0) };
    }
    my ($q) = $url =~ /query=([^&]*)/;
    $q = '' unless defined $q;
    $q =~ s/%([0-9a-f]{2})/chr hex $1/gie;
    $q =~ s/\+/ /g;
    my ($field, $want) = $q =~ /^(artist|alias):"?([^"]*)"?/;
    return { artists => [] } unless defined $field;
    $want =~ s/^\s+|\s+$//g;
    return { artists => $ARTIST{ lc "$field:$want" } || [] };
}

sub resolve {
    my ($name) = @_;
    %CACHE = (); @QUERIES = ();
    my $got = 'UNSET';
    $API->_artistMbidByName($name, sub { $got = $_[0] });
    return $got;
}
sub fields_asked { join ',', map { /query=(artist|alias)%3A/i ? lc $1 : () } @QUERIES }

# ---------------------------------------------------------------------------
# 1. THE FIX — "The Las" resolves to The La's, via the alias pass.
# ---------------------------------------------------------------------------
ok((resolve('The Las') // '') eq $LAS,
   "'The Las' resolves to The La's (not the Vegas Boneheads)");
ok(scalar(fields_asked() =~ /artist.*alias/s),
   '... because the +2 artist-field hit was HELD and the alias pass ran');

# ---------------------------------------------------------------------------
# 2. THE +1 CONTROLS — an article/honorific is accepted at the artist pass,
#    with NO alias pass (proves the gate is surgical, not a blanket hold).
# ---------------------------------------------------------------------------
ok((resolve('Beatles') // '') eq $FABS, "'Beatles' still resolves to The Beatles (+1, accepted)");
ok(scalar(fields_asked() !~ /alias/),   '... and no alias pass ran for it');

ok((resolve('Lauryn Hill') // '') eq $MSHILL, "'Lauryn Hill' resolves to Ms. Lauryn Hill (+1, accepted)");
ok(scalar(fields_asked() !~ /alias/),         '... and no alias pass ran for it either');

# ---------------------------------------------------------------------------
# 3. EXACT — no extra passes, no count request.
# ---------------------------------------------------------------------------
ok((resolve('Radiohead') // '') eq $RADIO, "'Radiohead' resolves exactly");
ok(scalar(fields_asked() eq 'artist'),     '... with a single artist-field query and nothing more');

# ---------------------------------------------------------------------------
# 4. SPECIAL-ENTITY GUARD + no regression — "La's" must never adopt Various
#    Artists; it falls back to the same (wrong-but-unchanged) Yo La Tengo.
# ---------------------------------------------------------------------------
my $las = resolve("La's") // '';
ok(scalar($las ne $VA && $las ne $UNKNOWN), "'La's' never resolves to a special MB entity");
ok($las eq $YOLA, "... it falls back to the held hit (Yo La Tengo), unchanged from before");

# ---------------------------------------------------------------------------
# 5. HELD-FALLBACK SAFETY — a +2 hit whose alias pass finds nothing is stored,
#    exactly as the old code would have returned it (this is what makes the
#    change impossible to regress).
# ---------------------------------------------------------------------------
ok((resolve('The Phantom') // '') eq $PHANTOM,
   "a +2 hit with no alias rescue falls back to the held hit (no regression)");
ok(scalar(fields_asked() =~ /artist.*alias/s),
   '... having still tried the alias pass first');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
