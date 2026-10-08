#!/usr/bin/env perl
#
# REGRESSION TEST — one release-group browse per artist at a time (0.56.51).
#
# FIELD, 2026-10-07 (Stan Getz, server log 10:00:29-10:01:14): a Refresh
# discography run inside a burst of page requests left 13 requests each
# finding the release-group list gone, and each started its OWN browse:
#
#     fetching release groups: ...release-group?artist=8f2422ab...&offset=0   (x13, same second)
#     fetching release groups: ...&offset=100                                  (x13, 1.1 s apart)
#     ...                                                                       42 s in all
#
# 52 identical MusicBrainz requests, one at a time, with every one of those
# pages waiting. API::getReleaseGroups now runs one browse per (mbid, refresh)
# and answers every caller that arrives meanwhile from it, through the fleet's
# SingleFlight.pm (as Sources::_candFlight has done for pools since 0.56.15).
#
# The HTTP responses are HELD OPEN (@DEFERRED), so "a browse in flight" is a
# real state here: answering synchronously would cache the list before the
# second caller arrived and the coalescing would never be exercised.
#
# Standalone -- no LMS install needed:  perl tools/t_rgflight.pl
#
use strict;
use warnings;
use FindBin;

my %CACHE;
my $DATA;
my @QUERIES;
our @DEFERRED;
our @TIMERS;
our $FAIL_URL;      # a url matching this answers with an HTTP error

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
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Strings::cstring'} = sub { $_[1] };
    *{'Slim::Utils::Strings::string'}  = sub { $_[0] };
    push @{'Slim::Utils::Strings::ISA'}, 'Exporter';
    @{'Slim::Utils::Strings::EXPORT'} = qw(cstring string);
    # Timers are RECORDED, never fired: the only one this suite arms is the
    # flight's watchdog, which must not fire while a browse is merely slow.
    *{'Slim::Utils::Timers::setTimer'}     = sub { my $t = [@_]; push @main::TIMERS, $t; $t };
    *{'Slim::Utils::Timers::killSpecific'} = sub { my ($t) = @_; @main::TIMERS = grep { $_ != $t } @main::TIMERS; 1 };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { $DATA };
    *{'Slim::Networking::SimpleAsyncHTTP::new'} = sub {
        my ($cls, $cb, $errcb) = @_;
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
sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Resp;
sub new { bless {}, shift } sub content { '{}' } sub error { 'stub' }
package T::HTTP;
sub error { 'HTTP 503' }
sub get {
    my ($self, $url) = @_;
    push @QUERIES, $url;
    push @main::DEFERRED, sub {
        if (defined $main::FAIL_URL && index($url, $main::FAIL_URL) >= 0) {
            return $self->{err}->($self, 'HTTP 503', T::Resp->new);
        }
        $DATA = main::response_for($url);
        $self->{cb}->(T::Resp->new);
    };
}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::API;

# THE QUEUE IS NOT THIS SUITE'S SUBJECT (t_netqueue.pl owns it): every request
# goes straight to the deferred transport.
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::API::_netGet'} = sub {
        my ($url, $ok, $err, %opt) = @_;
        return Slim::Networking::SimpleAsyncHTTP->new($ok, $err, \%opt)->get($url);
    };
}
my $API = 'Plugins::Discography::API';

# Release groups per artist mbid, browsed 100 a page (two pages for GETZ).
my $GETZ  = '8f2422ab-0ec6-4c92-80c4-afe9622fab32';
my $OTHER = '11111111-2222-3333-4444-555555555555';
my %SPINE = (
    $GETZ  => [ map { { id => "rg-g$_", title => "Getz Album $_", 'first-release-date' => '1964',
                        'primary-type' => 'Album' } } 1 .. 150 ],
    $OTHER => [ { id => 'rg-o1', title => 'Other Album', 'first-release-date' => '2001',
                  'primary-type' => 'Album' } ],
);
sub response_for {
    my ($url) = @_;
    my ($mbid)   = $url =~ /artist=([0-9a-f-]{36})/;
    my ($offset) = $url =~ /offset=(\d+)/;
    my $all = $SPINE{ $mbid // '' } || [];
    $offset //= 0;
    my @page = @$all[ $offset .. ($offset + 99 < $#$all ? $offset + 99 : $#$all) ];
    return { 'release-groups' => \@page, 'release-group-count' => scalar @$all };
}
sub flush { while (my $d = shift @DEFERRED) { $d->() } }
sub reset_all { %CACHE = (); @QUERIES = (); @DEFERRED = (); @TIMERS = (); $FAIL_URL = undef;
                my $fl = $API->can('_rgFlight')->(); $fl->_reset if ref $fl }

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}
sub pages { scalar grep { /release-group\?artist=\Q$_[0]\E/ } @QUERIES }

# ================================================================== 1
print "# 1. two callers for one artist while its browse runs: ONE browse, both answered\n";
{
    reset_all();
    my $fl = $API->can('_rgFlight')->();
    ok(scalar(ref $fl), '1: the shared registry loads (SingleFlight.pm)');
    my (@a, @b, $errs);
    $API->getReleaseGroups(mbid => $GETZ, onDone => sub { push @a, shift }, onError => sub { $errs++ });
    $API->getReleaseGroups(mbid => $GETZ, onDone => sub { push @b, shift }, onError => sub { $errs++ });
    ok(scalar(pages($GETZ) == 1), '1: the second caller sends NOTHING while the first browse runs ('
       . pages($GETZ) . ' page request so far)');
    ok(scalar($fl->inFlight(lc $GETZ)), '1: the browse is registered as in flight');
    flush();
    ok(scalar(pages($GETZ) == 2), '1: ONE chain walked both pages (' . pages($GETZ) . ' page requests; it was one chain per caller)');
    ok(scalar(@a == 1 && @b == 1), '1: each caller answered exactly once');
    ok(scalar(@a && @b && ref $a[0] eq 'ARRAY' && @{ $a[0] } == 150 && @{ $b[0] } == 150),
       '1: both got the whole list (150 groups, both pages)');
    ok(scalar(!$errs), '1: nobody answered with an error');
    ok(scalar(!$fl->inFlight(lc $GETZ) && $fl->_count == 0), '1: the claim is released once it lands');
    ok(scalar(!@TIMERS), '1: its watchdog is disarmed once it lands');
}

# ================================================================== 2
print "# 2. the next caller after it lands reads the cache; another artist browses on its own\n";
{
    my @c;
    my $before = scalar @QUERIES;
    $API->getReleaseGroups(mbid => $GETZ, onDone => sub { push @c, shift });
    ok(scalar(@QUERIES == $before && @c == 1 && @{ $c[0] } == 150),
       '2: a caller after the browse is answered from the cache, nothing sent');

    reset_all();
    my (@g, @o);
    $API->getReleaseGroups(mbid => $GETZ,  onDone => sub { push @g, shift });
    $API->getReleaseGroups(mbid => $OTHER, onDone => sub { push @o, shift });
    ok(scalar(pages($GETZ) == 1 && pages($OTHER) == 1), '2: two artists are two browses, side by side');
    flush();
    ok(scalar(@g == 1 && @o == 1 && @{ $o[0] } == 1 && $o[0][0]{mbid} eq 'rg-o1'),
       '2: and each artist gets ITS OWN list');
}

# ================================================================== 3
print "# 3. a failed browse answers EVERY caller with the failure, and lets go\n";
{
    reset_all();
    $FAIL_URL = 'offset=0';
    my ($errA, $errB, $doneAny) = (0, 0, 0);
    $API->getReleaseGroups(mbid => $GETZ, onDone => sub { $doneAny++ }, onError => sub { $errA++ });
    $API->getReleaseGroups(mbid => $GETZ, onDone => sub { $doneAny++ }, onError => sub { $errB++ });
    flush();
    ok(scalar($errA == 1 && $errB == 1 && !$doneAny), '3: both callers get the error, once each');
    ok(scalar($API->can('_rgFlight')->()->_count == 0), '3: the claim is released after a failure');

    $FAIL_URL = undef; @QUERIES = ();
    my @r;
    $API->getReleaseGroups(mbid => $GETZ, onDone => sub { push @r, shift });
    flush();
    ok(scalar(pages($GETZ) == 2 && @r == 1 && @{ $r[0] } == 150),
       '3: the next visit browses afresh (a failure is not remembered)');
}

# ================================================================== 4
print "# 4. the watchdog sits far past a slow browse, and a forced browse coalesces too\n";
{
    reset_all();
    $API->getReleaseGroups(mbid => $GETZ, onDone => sub { });
    my ($t) = @TIMERS;
    my $max = $API->can('RG_FLIGHT_MAX')->();
    ok(scalar($t && ($t->[1] - CORE::time()) >= $max - 5),
       "4: one watchdog, $max s out (never inside a slow but live browse)");
    ok(scalar($max >= 300), '4: ... at least five minutes');
    flush();

    reset_all();
    my (@a, @b);
    $API->getReleaseGroups(mbid => $GETZ, force => 1, onDone => sub { push @a, shift });
    $API->getReleaseGroups(mbid => $GETZ, force => 1, onDone => sub { push @b, shift });
    ok(scalar(pages($GETZ) == 1), '4: two forced browses of one artist share one chain');
    flush();
    ok(scalar(@a == 1 && @b == 1 && @{ $b[0] } == 150), '4: ... and both are answered');
}

# ================================================================== 5
print "# 5. CONTROL: with the registry unavailable, each caller browses for itself (the old behaviour)\n";
{
    reset_all();
    no strict 'refs'; no warnings 'redefine';
    local *{'Plugins::Discography::API::_rgFlight'} = sub { 0 };
    my (@a, @b);
    $API->getReleaseGroups(mbid => $GETZ, onDone => sub { push @a, shift });
    $API->getReleaseGroups(mbid => $GETZ, onDone => sub { push @b, shift });
    ok(scalar(pages($GETZ) == 2), '5: two callers -> two first-page requests (proves section 1 tests the registry)');
    flush();
    ok(scalar(@a == 1 && @b == 1), '5: ... and each still gets its answer');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
