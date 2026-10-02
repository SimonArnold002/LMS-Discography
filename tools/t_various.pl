#!/usr/bin/env perl
#
# VARIOUS ARTISTS / VARIOUS COMPOSERS IS NEVER ONE ARTIST (0.56.41).
#
# Simon, 2026-10-02: "we should not allow a search for Various Artists or look
# up on albums tagged with various artists or various composers. MB uses this to
# put any non artist compilation under it would grind to a halt." Measured live
# on 0.56.40: a search listed MB's special Various Artists (89ad4ac3) and asked
# the community API for its discography (no answer in 30 s); the library's
# Various Composers, tagged 89ad4ac3, drew 600 unrelated compilations in 10 s; a
# Various Artists with a dead tag browsed 89ad4ac3's six pages to disambiguate
# (14 s, 12 requests), because the same-name set was the one name lookup that
# kept MB's special entities.
#
# What this pins, against the REAL API.pm:
#   1. API::isVarious: the two names in any case and spacing, LMS's own name
#      for various artists (characters or octets), every special mbid in any
#      case; NOT a name that only starts like it, a misspelling, the bare word,
#      an ordinary mbid, nothing; no LMS = the two names only, no error;
#   2. getArtistCandidates drops MB's special entities from the same-name set
#      (an ordinary act of the name stays), as every other name lookup does;
#   3. getReleaseGroups on a special mbid answers an empty list, asks nothing
#      and keeps nothing (t_fastpage.pl §8 pins the Refresh path).
#
# The search (t_searchflow.pl §12) and the page (t_chain.pl §13) pin the callers.
#
# Standalone -- no LMS install needed:  perl tools/t_various.pl
#
use strict;
use warnings;
use FindBin;
use JSON::XS ();

my %CACHE;
my @QUERIES;              # every URL sent, in order
our @DEFERRED;            # responses held open until flush()
our $MB_BASE = 'https://musicbrainz.org/ws/2/';
our %REPLY;               # url-prefix => reply hash, or 'ERROR'
our $LMS_VA;              # LMS's own name for various artists (undef = no LMS)

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
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Timers::setTimer'}   = sub { $_[2]->() };
    *{'Slim::Utils::Timers::killTimers'} = sub { 1 };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { JSON::XS::encode_json($_[0]) };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { JSON::XS::decode_json($_[0]) };
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
sub new     { my ($c, $body) = @_; bless { body => $body }, $c }
sub content { $_[0]{body} }
sub error   { 'stub error' }
sub code    { 500 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
require Plugins::Discography::API;
my $API = 'Plugins::Discography::API';

{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::API::_netGet'} = sub {
        my ($url, $ok, $err, %opt) = @_;
        push @QUERIES, $url;
        push @DEFERRED, sub {
            my ($hit) = grep { index($url, $_) == 0 } sort { length $b <=> length $a } keys %REPLY;
            my $r = defined $hit ? $REPLY{$hit} : 'ERROR';
            return $err->(T::Resp->new(''), 'stub error', T::Resp->new('')) if $r eq 'ERROR';
            $ok->(T::Resp->new(JSON::XS::encode_json($r)));
        };
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
sub flush {
    for (1 .. 20) {
        my @d = @DEFERRED;
        last unless @d;
        @DEFERRED = ();
        for my $cb (@d) {
            eval { $cb->(); 1 } or do { (my $e = $@) =~ s/\s+/ /g; ok(0, "a response callback died: $e") };
        }
    }
}
sub section {
    my ($n, $code) = @_;
    eval { $code->(); 1 } or do { (my $e = $@) =~ s/\s+/ /g; ok(0, "$n: the section died: $e") };
}
sub cold {
    no warnings 'once';
    %CACHE = (); @QUERIES = (); @DEFERRED = (); %REPLY = ();
    %Plugins::Discography::API::NAME_MEMO = ();
    %Plugins::Discography::API::NAME_WAIT = ();
}
sub id { sprintf('%08d-0000-0000-0000-000000000000', $_[0]) }

my $VA = '89ad4ac3-39f7-470e-963a-56509c546377';
my @SPECIAL = ($VA, '125ec42a-7229-4250-afc5-e057484327fe', 'eec63d3c-3b81-4ad4-b1e4-7c147d4d2b61',
               'f731ccc4-e22a-43af-a747-64213329e088', '9be7f096-97ec-4615-8957-8d40b5dcbc41');
sub va { $API->isVarious(@_) }

# ---------------------------------------------------------------------------
# 1. THE RULE.
# ---------------------------------------------------------------------------
section('1', sub {
    no strict 'refs'; no warnings 'redefine';
    local $LMS_VA = undef;
    # No LMS: Slim::Music::Info is not loaded, the lookup must not die.
    ok(scalar(!defined &Slim::Music::Info::variousArtistString), '1: (setup) no LMS name defined');
    ok(scalar(va('Various Artists') && va('various artists') && va('VARIOUS ARTISTS') && va('  Various  Artists ')),
       '1: Various Artists, any case and spacing');
    ok(scalar(va('Various Composers') && va('various COMPOSERS')), '1: Various Composers, any case');
    ok(scalar(!va('Various Artists - Duck Records') && !va('Various Artists Mixed By Dark-E')
              && !va('70\'s Various Artists') && !va('Suki & Ding & Various Composers')),
       '1: NOT a name that only contains it (the Qobuz rows the 0.56.40 search listed)');
    ok(scalar(!va('Various Artsts') && !va('Various') && !va('Various Artist') && !va('VA')),
       '1: NOT a misspelling, the bare word, the singular or VA (only the names seen; a tag catches the rest)');
    ok(scalar(!va('') && !va(undef) && !va(undef, undef) && !va('Radiohead', id(1))),
       '1: NOT nothing, nor an ordinary name and mbid');
    ok(scalar(!grep { !va(undef, $_) || !va('Anything', uc $_) } @SPECIAL) && scalar(@SPECIAL) == 5,
       '1: every one of MB\'s five special entities by mbid, any case, whatever the name');

    # LMS's own name (the variousArtistsString pref, which a user may rename).
    local *{'Slim::Music::Info::variousArtistString'} = sub { $main::LMS_VA };
    # CHARACTERS, as LMS hands a pref and a contributor name: flagged. A bare
    # "\x{fc}" literal is a Latin-1 string Perl never flags (the 0.56.38 trap),
    # so each is upgraded.
    my $chars = sub { my $s = shift; utf8::upgrade($s); $s };
    $LMS_VA = $chars->("Diverse K\x{fc}nstler");
    ok(scalar(va($chars->("Diverse K\x{fc}nstler")) && va($chars->("diverse k\x{fc}nstler"))),
       "1: LMS's own name (characters), any case");
    my $oct = "Diverse K\x{fc}nstler"; utf8::upgrade($oct); utf8::encode($oct);
    ok(scalar(va($oct)), "1: ... and the same name as UTF-8 octets (a cache or a URL)");
    $LMS_VA = $oct;
    ok(scalar(va($chars->("Diverse K\x{fc}nstler"))), "1: ... and LMS's name as octets against a name in characters");
    $LMS_VA = $chars->("Diverse K\x{fc}nstler");
    ok(scalar(va('Various Artists') && !va('Diverse')), "1: ... the two names still hold beside it; a part of it does not");
    $LMS_VA = '';
    ok(scalar(!va('') && va('Various Artists')), '1: an empty LMS name matches nothing');
    local *{'Slim::Music::Info::variousArtistString'} = sub { die "no prefs\n" };
    ok(scalar(va('Various Composers') && !va('Diverse Kunstler')), '1: an LMS lookup that dies: the two names, no error');
});

# ---------------------------------------------------------------------------
# 2. THE SAME-NAME SET DROPS MB'S SPECIAL ENTITIES. Before 0.56.41 it was the
#    one name lookup that kept them: the search listed 89ad4ac3 and asked the
#    community API for its discography; a dead library tag browsed its six
#    pages (Browse::_disambiguateByLibrary walks this set).
# ---------------------------------------------------------------------------
section('2', sub {
    cold();
    my $q = $MB_BASE . Plugins::Discography::API::_nameQuery('artist', 'Various Artists', 0);
    $REPLY{$q} = { count => 4, artists => [
        { id => $VA, name => 'Various Artists', score => 100, disambiguation => 'add compilations to this artist', type => 'Other' },
        { id => id(2), name => 'Various Artists', score => 59, disambiguation => 'UK band from Bristol' },
        { id => uc $SPECIAL[1], name => 'Various Artists', score => 50 },
        { id => id(4), name => 'Various Artists', score => 40, disambiguation => 'Seattle mashup artist' },
    ] };
    my $got;
    $API->getArtistCandidates('Various Artists', sub { $got = shift });
    flush();
    my @ids = map { $_->{mbid} } @{ $got || [] };
    ok(scalar("@ids" eq id(2) . ' ' . id(4)),
       '2: the same-name set holds the ordinary acts of the name, never a special entity (any case of its id)');
    ok(scalar(@QUERIES == 1), '2: ... from the one request');
    my ($kept) = grep { /acand/ } keys %CACHE;
    ok(scalar($kept && !grep { $_->{mbid} eq $VA } @{ $CACHE{$kept} || [] }),
       '2: ... and what is kept for the next visit holds none either');
});

# ---------------------------------------------------------------------------
# 3. ITS LIST IS NEVER ASKED FOR.
# ---------------------------------------------------------------------------
section('3', sub {
    for my $m (@SPECIAL[0, 4], uc $VA) {
        cold();
        my ($got, $n) = (undef, 0);
        $API->getReleaseGroups(mbid => $m, onDone => sub { $got = shift; $n++ }, onError => sub { $n += 10 });
        flush();
        ok(scalar($n == 1 && ref $got eq 'ARRAY' && !@$got && !@QUERIES && !%CACHE),
           "3: getReleaseGroups($m): an empty list, at once, nothing asked, nothing kept");
    }
    cold();
    my $n = 0;
    $API->getReleaseGroups(mbid => id(9), onDone => sub { $n++ }, onError => sub { $n++ });
    ok(scalar(@QUERIES >= 1 || @DEFERRED >= 1), '3: control: an ordinary mbid is still asked for');
});

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
