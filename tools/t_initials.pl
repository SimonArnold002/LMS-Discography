#!/usr/bin/env perl
#
# REGRESSION TEST: THE INITIALS LIFT (0.56.36, resolver plan C1).
#
# "ELO" opened an obscure act literally named ELO, because the resolver prefers
# an act named exactly what was asked for (0.44.14). For a SHORT name (2-5
# letters once spaces and dots go) one combined query, `artist:"X" OR
# alias:"X"`, now lets an act take its place when MusicBrainz lists X as its
# ALIAS, its own name's initials spell X, and it scores above every act NAMED X
# (one must exist). Simon, 2026-10-02: "we should be looking at alieses for this
# if no alias for initials then we dont pass it, keep it simple".
#
# The fixtures are the PUBLIC API's own replies (scratchpad c1replay.pl,
# 2026-10-02): ELO lifts; Luna stays (DJ Luna has the alias but not the
# initials); OMD stays (no act is named OMD, and Of Mexican Descent would win).
# Then the resolver end to end (stubbed transport), and the shared-name guard,
# which must not call the lifted band a lesser act of a name it is not called.
#
# Standalone, no LMS install needed:  perl tools/t_initials.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;
my $DATA;
my @URLS;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request JSON::XS::VersionOneAndTwo
                  Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
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
sub get { return $_[1] eq 'mb_base_url' ? 'http://mirror:5000/ws/2/' : undef }
sub set { return 1 }
sub init { return 1 } sub setChange { return 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { 'stub error' }
package T::HTTP;
sub get {
    my ($self, $url) = @_;
    push @URLS, $url;
    my $r = main::response_for($url);
    if (!defined $r) { $self->{err}->(T::Resp->new); return }
    $DATA = $r;
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

# The queue is t_netqueue.pl's subject; bypass it (as t_canon.pl does).
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::API::_netGet'} = sub {
        my ($url, $ok, $err, %opt) = @_;
        return Slim::Networking::SimpleAsyncHTTP->new($ok, $err, \%opt)->get($url);
    };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# A cold start for each case: the cache, the requests, and the resolver's
# in-process memo of name replies (t_namesearch.pl's cold()).
sub cold {
    no warnings 'once';
    %CACHE = (); @URLS = ();
    %Plugins::Discography::API::NAME_MEMO = ();
    %Plugins::Discography::API::NAME_WAIT = ();
}
our $RESPONDER = sub { { artists => [] } };
sub response_for { return $RESPONDER->($_[0]) }
sub combinedUrl { scalar grep { index($_, '%20OR%20alias%3A') >= 0 } @URLS }
sub al { map { { name => $_ } } @_ }

# The public API's replies, 2026-10-02 (trimmed to what decides the case).
my $EL_ORCH = '0c502791-4ee9-4c5f-9696-0602b721ff3b';
my $ELO_KR  = '16868edf-a07a-44df-859f-6f2608f39d8c';
my @ELO = (
    { id => $EL_ORCH, name => 'Electric Light Orchestra', score => 100, aliases => [ al('ELO', 'E.L.O.') ] },
    { id => '11111111-0000-4000-8000-000000000001', name => 'Grupo Elo', score => 99, aliases => [ al('Elo') ] },
    { id => '11111111-0000-4000-8000-000000000002', name => 'Eloquent',  score => 82, aliases => [ al('elo') ] },
    { id => $ELO_KR, name => 'ELO', score => 71 },
    { id => '11111111-0000-4000-8000-000000000003', name => 'ELO', score => 69 },
);
my $LUNA = 'dda04604-0000-4000-8000-000000000000';
my @LUNA = (
    { id => '22222222-0000-4000-8000-000000000001', name => 'DJ Luna', score => 98, aliases => [ al('Luna') ] },
    { id => $LUNA, name => 'Luna', score => 96 },
);
# What the NAME pass (`artist:"ELO"`, the name field alone) answers: the acts
# named ELO at the top of their own field (the replay's "today" was 16868edf).
my @ELO_NAMEPASS = ({ id => $ELO_KR, name => 'ELO', score => 100 },
                    { id => '11111111-0000-4000-8000-000000000003', name => 'ELO', score => 95 });
my @OMD = (
    { id => '33333333-0000-4000-8000-000000000001', name => 'Of Mexican Descent', score => 79, aliases => [ al('OMD') ] },
    { id => '33333333-0000-4000-8000-000000000002', name => 'Orchestral Manoeuvres in the Dark', score => 70,
      aliases => [ al('OMD') ] },
);

# ---------------------------------------------------------------------------
# 1. The initials and the key.
# ---------------------------------------------------------------------------
my $ini = \&Plugins::Discography::API::_initials;
my $key = \&Plugins::Discography::API::_initialsKey;
ok(scalar($ini->('Electric Light Orchestra') eq 'elo'), '1: Electric Light Orchestra -> elo');
ok(scalar($ini->("Bachman\x{2013}Turner Overdrive") eq 'bto'), '1: Bachman-Turner Overdrive (en dash) -> bto');
ok(scalar($ini->('Everything but the Girl') eq 'ebtg'), '1: Everything but the Girl -> ebtg');
ok(scalar($ini->('B.o.B') eq '' && $ini->('R.E.M.') eq ''), '1: single letters (B.o.B, R.E.M.) have no initials');
ok(scalar($ini->('Luna') eq '' && $ini->('DJ Luna') eq 'dl'), '1: one word has none; DJ Luna -> dl');
ok(scalar($ini->('The KLF') eq 'tk'), '1: The KLF -> tk (so KLF never lifts it)');
ok(scalar($key->('ELO') eq 'elo' && $key->('R.E.M.') eq 'rem' && $key->('PiL') eq 'pil'), '1: the key folds case and dots');
ok(scalar($key->('A') eq '' && $key->('Radiohead') eq '' && $key->('ABCDEF') eq ''), '1: one letter or over five: no key');
ok(scalar($key->('EBTG') eq 'ebtg' && $key->('QOTSA') eq 'qotsa'), '1: four and five letters have a key');

# ---------------------------------------------------------------------------
# 2. The decision, on the public API's replies.
# ---------------------------------------------------------------------------
my $lift = \&Plugins::Discography::API::_liftFrom;
my $l = $lift->('ELO', \@ELO);
ok(scalar($l && $l->{id} eq $EL_ORCH), '2: ELO lifts Electric Light Orchestra (alias ELO, initials elo, 100 over 71)');
ok(scalar(!$lift->('Luna', \@LUNA)), '2: Luna stays: DJ Luna has the alias but its initials are dl');
ok(scalar(!$lift->('OMD', \@OMD)), '2: OMD: no act is named OMD, so nothing lifts (the resolver already answers)');
ok(scalar(!$lift->('Electric Light Orchestra', \@ELO)), '2: a long name asks nothing');
{
    my @tie = ({ %{ $ELO[0] }, score => 71 }, @ELO[3, 4]);
    ok(scalar(!$lift->('ELO', \@tie)), '2: a tie with the best act named it does not lift (must score ABOVE)');
    my @noalias = ({ %{ $ELO[0] }, aliases => [ al('Electric Light Orch.') ] }, @ELO[3, 4]);
    ok(scalar(!$lift->('ELO', \@noalias)), '2: no alias ELO, no lift (the initials alone are not enough)');
    my @two = ({ id => '44444444-0000-4000-8000-000000000001', name => 'Even Lower Octaves', score => 90,
                 aliases => [ al('ELO') ] }, @ELO);
    ok(scalar(($lift->('ELO', \@two) || {})->{id} eq $EL_ORCH), '2: two acts qualify: the higher score wins');
    my @special = ({ id => '89ad4ac3-39f7-470e-963a-56509c546377', name => 'Even Larger Orchestras', score => 100,
                     aliases => [ al('ELO') ] }, @ELO[3, 4]);
    ok(scalar(!$lift->('ELO', \@special)), '2: a MusicBrainz special entity never lifts');
    ok(scalar(!$lift->('ELO', undef) && !$lift->('ELO', [])), '2: no reply, no lift');
}

# ---------------------------------------------------------------------------
# 3. The resolver end to end. The name pass picks the act NAMED ELO (as today);
#    the lift then answers Electric Light Orchestra, and that is what is kept.
# ---------------------------------------------------------------------------
sub resolve {
    my ($name) = @_;
    my $got = 'UNSET';
    $API->_artistMbidByName($name, sub { $got = $_[0] }, 0, 8);
    return $got;
}
cold();
$RESPONDER = sub {
    my ($u) = @_;
    return { artists => \@ELO } if index($u, '%20OR%20alias%3A') >= 0;
    return { artists => \@ELO_NAMEPASS };
};
my $got = resolve('ELO');
ok(scalar(($got // '') eq $EL_ORCH), '3: "ELO" resolves to Electric Light Orchestra (the name pass alone gives the act named ELO, below)');
ok(scalar(combinedUrl() == 1), '3: one combined query, after the name pass');
ok(scalar(($CACHE{ Plugins::Discography::API::_mbidKey('ELO') } // '') eq $EL_ORCH), '3: the lifted answer is what is cached');
ok(scalar(index(Plugins::Discography::API::_mbidKey('ELO'), 'dsc:mbid:3:') == 0),
   '3: under key version 3, so an older "ELO" answer is not served');
ok(scalar(($CACHE{ Plugins::Discography::API::_mbNameKey($EL_ORCH) } // '') eq 'Electric Light Orchestra'),
   "3: the band's canonical name is STORED (the kept artist table), not only held in memory: the guard reads it after a restart");
@URLS = ();
$got = resolve('ELO');
ok(scalar(($got // '') eq $EL_ORCH && !@URLS), '3: the next lookup is a cache hit, no request');

cold();
$RESPONDER = sub {
    my ($u) = @_;
    return { artists => \@LUNA } if index($u, '%20OR%20alias%3A') >= 0;
    return { artists => [ $LUNA[1] ] };
};
ok(scalar((resolve('Luna') // '') eq $LUNA && combinedUrl() == 1), '3: "Luna" asks once and keeps the band named Luna');

cold();
$RESPONDER = sub {
    my ($u) = @_;
    return undef if index($u, '%20OR%20alias%3A') >= 0;      # the combined query fails
    return { artists => \@ELO_NAMEPASS };
};
ok(scalar((resolve('ELO') // '') eq $ELO_KR), "3: the combined query failing keeps the name pass's answer");

cold();
my $RH = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
$RESPONDER = sub { { artists => [ { id => $RH, name => 'Radiohead', score => 100 } ] } };
ok(scalar((resolve('Radiohead') // '') eq $RH && combinedUrl() == 0), '3: a long name sends no combined query');

# ---------------------------------------------------------------------------
# 4. The shared-name guard. The acts NAMED "ELO" put a Korean singer on top;
#    the page "ELO" that is Electric Light Orchestra is not a lesser act of it.
# ---------------------------------------------------------------------------
%CACHE = ();
$CACHE{ Plugins::Discography::API::_candKey('ELO') } = [
    { mbid => $ELO_KR, name => 'ELO', score => 100 },
    { mbid => '11111111-0000-4000-8000-000000000003', name => 'ELO', score => 90 } ];
Plugins::Discography::API::_setMbName($EL_ORCH, 'Electric Light Orchestra');
ok(scalar($API->sharesNameWithProminent('ELO', $EL_ORCH) == 0),
   '4: Electric Light Orchestra opened as "ELO" keeps its bio, similar artists and owned albums');
ok(scalar($API->sharesNameWithProminent('ELO', '11111111-0000-4000-8000-000000000003') == 1),
   '4: the second act literally named ELO is still the lesser one (unchanged)');
my $async = 'UNSET';
$API->sharesNameWithProminentAsync('ELO', $EL_ORCH, sub { $async = $_[0] });
ok(scalar($async eq '0'), '4: the async form agrees');
Plugins::Discography::API::_setMbName('55555555-0000-4000-8000-000000000001', 'Elo Lyrics Online');
ok(scalar($API->sharesNameWithProminent('ELO', '55555555-0000-4000-8000-000000000001') == 0),
   "4: any act whose name abbreviates to the page's name counts as its own act");
Plugins::Discography::API::_setMbName('55555555-0000-4000-8000-000000000002', 'Grupo Elo');
ok(scalar($API->sharesNameWithProminent('ELO', '55555555-0000-4000-8000-000000000002') == 1),
   '4: an act whose initials do not spell it is judged as before');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
