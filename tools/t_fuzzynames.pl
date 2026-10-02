#!/usr/bin/env perl
#
# REGRESSION TEST: THE CLOSEST NAMES FOR A SEARCH THAT FOUND NOTHING
# (0.56.38, resolver plan Part D step 2; API::fuzzyArtists, _fuzzyPick,
# _editDistance, _fuzzyFold).
#
# Measured on 0.56.37: "Beatels", "Hawkwnd", "Jandec" read "No artists found"
# after 4-7 s; only MusicBrainz's fuzzy query finds the act, and its scores are
# relative (Jandec -> George Frideric Handel 100, Jandek 87), so the pick is by
# edit distance from what was typed, then score, at most 3. Simon: "okay".
#
# The fixtures are the mirror's own replies to the query this sends
# (2026-10-02, scratchpad fuzzydesign.py; public answers the same, at its rate).
#
# Standalone, no LMS install needed:  perl tools/t_fuzzynames.pl
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


our %REPLY;   # url fragment => artists list (undef entry = request fails)
sub response_for {
    my ($url) = @_;
    for my $k (keys %REPLY) {
        next unless index($url, $k) >= 0;
        return defined $REPLY{$k} ? { artists => $REPLY{$k} } : undef;
    }
    return { artists => [] };
}
sub cold { %CACHE = (); @URLS = () }
sub names { join('|', map { $_->{name} } @{ $_[0] || [] }) }
sub pick  { names(Plugins::Discography::API::_fuzzyPick(@_)) }

my $BEATELS = [
    { id => 'b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d', name => "The Beatles", score => 100, disambiguation => "UK rock band" },
    { id => '82b37d51-51fa-4688-aee7-219e1a5556d3', name => "Joanie Bartels", score => 61 },
    { id => '653c9099-1411-464d-99e0-0cd4bfcf19a4', name => "Susanne Bertels", score => 59, disambiguation => "German author" },
    { id => '0f697bc6-6df7-41c9-b550-39981e520d70', name => "The Beatles Revival Band", score => 59 },
    { id => '62576db7-68be-49b0-9766-7534f4388c2c', name => "Beaters", score => 59 },
    { id => '5e685f9e-83bb-423c-acfa-487e34f15ffd', name => "The Tape-beatles", score => 58 },
    { id => 'fbe69047-e53a-40d6-bb5e-ff622aa52a2e', name => "Sam Bettens", score => 57 },
    { id => '7a706999-2a62-4285-b723-e4f313a0f6c7', name => "Beatless", score => 56 },
    { id => 'a48ab144-74cf-4699-bb15-e0225eca78ce', name => "Beatals", score => 56, disambiguation => "Beatles tribute band" },
    { id => '9b8fa0df-ae1e-4188-a5f1-728639b3b641', name => "Beatells", score => 56, disambiguation => "German producer" },
];
my $JANDEC = [
    { id => '27870d47-bb98-42d1-bf2b-c7e972e6befc', name => "George Frideric Handel", score => 100 },
    { id => '61a21fb6-ca24-4e7c-bb72-34a716be1cbb', name => "Jandek", score => 87 },
    { id => '972cde75-75fc-42ec-a836-e73f0f9fe32d', name => "Christian Handel", score => 66 },
    { id => '606f25d1-0b01-4d1f-b7c6-e72d80c22b6b', name => "Half-handed Cloud", score => 65 },
    { id => '586c06cd-2a02-45e3-8d0f-60e1672743a3', name => "Handel", score => 62, disambiguation => "lo-fi beatmaker" },
    { id => 'cd672160-494f-4829-aca6-684a0bf674d9', name => "Jander", score => 62 },
    { id => 'eccca77d-2642-4911-bd00-22bb732493f4', name => "Jandez", score => 61 },
    { id => 'e19a5db5-f04a-4f71-839f-3a399cb14aee', name => "Dander", score => 59 },
];
my $COSTELO = [
    { id => '01809552-4f87-45b0-afff-2c6f0730a3be', name => "Elvis Presley", score => 100 },
    { id => '8a338e06-d182-46f2-bd16-30a09bc840ba', name => "Elvis Costello", score => 98 },
    { id => '0ffb6573-a98e-412e-aa01-0a580e9d8b06', name => "Elvis Costello & The Attractions", score => 83 },
    { id => 'a86ee00f-bccb-4202-b37f-63375b3a51ad', name => "Matthew Costello", score => 78 },
    { id => '99d479c6-01fa-4616-828e-e347a18c20e3', name => "Donnacha Costello", score => 66 },
];
my $HAWKWND = [
    { id => '5a28f8c2-31fb-4047-ae57-c5c326989262', name => "Hawkwind", score => 100 },
    { id => '5c8cb181-38fe-4300-8153-650b2ed0258f', name => "Coleman Hawkins", score => 86 },
    { id => '185af318-55c7-405f-8b00-0fa308e56da9', name => "Screamin\x{2019} Jay Hawkins", score => 75 },
];

# --- 1. the distance ------------------------------------------------------
my $ed = \&Plugins::Discography::API::_editDistance;
ok(scalar($ed->('beatels', 'beatles') == 1), '1: a swap of neighbouring letters is one edit (beatels/beatles)');
ok(scalar($ed->('kitten', 'sitting') == 3), '1: kitten/sitting is 3');
ok(scalar($ed->('jandec', 'handel') == 2 && $ed->('jandec', 'jandek') == 1), '1: jandec is 2 from handel, 1 from jandek');
ok(scalar($ed->('', 'abc') == 3 && $ed->('abc', '') == 3 && $ed->('abc', 'abc') == 0), '1: empty sides and equal strings');
ok(scalar($ed->('ab', 'ba') == 1 && $ed->('abc', 'acb') == 1), '1: a swap anywhere is one edit');

# --- 2. the fold ----------------------------------------------------------
my $fold = \&Plugins::Discography::API::_fuzzyFold;
ok(scalar($fold->('The Beatles') eq 'beatles'), '2: a leading "the" goes');
# Names arrive as characters (MusicBrainz's JSON) or as UTF-8 octets (a typed
# query); both fold. (A literal "\x{f6}" is a Latin-1 byte string, which no
# caller sends.)
my $chars = "Bj\x{f6}rk"; utf8::upgrade($chars);
ok(scalar($fold->($chars) eq 'bjork' && $fold->("Bj\x{c3}\x{b6}rk") eq 'bjork'),
   '2: accents fold, from characters and from UTF-8 octets');
ok(scalar($fold->('Simon & Garfunkel') eq 'simon and garfunkel'), '2: & reads as and');
ok(scalar($fold->('Theatre of Tragedy') eq 'theatre of tragedy'), '2: "the" only as a whole leading word');

# --- 3. the pick ----------------------------------------------------------
ok(scalar(pick('Beatels', $BEATELS) eq 'The Beatles|Beaters|Beatals'),
   '3: Beatels -> The Beatles first; one edit each, then by score; at most 3');
ok(scalar(pick('Jandec', $JANDEC) eq 'Jandek|Jander|Jandez'),
   '3: Jandec -> Jandek, not the top-scored Handel (2 edits away, after three at 1)');
ok(scalar(pick('Elvis Costelo', $COSTELO) eq 'Elvis Costello'),
   '3: Elvis Costelo -> Elvis Costello alone (Presley scored 100, far in name)');
ok(scalar(pick('Hawkwnd', $HAWKWND) eq 'Hawkwind'), '3: Hawkwnd -> Hawkwind alone');
ok(scalar(pick('Hawkwnd', [ @$HAWKWND, { id => '9', name => 'Hawkeye', score => 99 } ]) eq 'Hawkwind'),
   '3: three edits away is never picked (Hawkwnd/Hawkeye)');
my $p = Plugins::Discography::API::_fuzzyPick('Beatels', $BEATELS)->[0] || {};
ok(scalar(($p->{mbid} // '') eq 'b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d' && ($p->{disambiguation} // '') eq 'UK rock band'
          && ($p->{score} // 0) == 100),
   '3: each pick carries its id, description and score');
my $SHORT = [ { id => '1', name => 'ABBA', score => 100 }, { id => '2', name => 'Abby', score => 90 },
              { id => '3', name => 'Abra', score => 80 } ];
ok(scalar(pick('Aba', $SHORT) eq 'ABBA|Abra'), '3: four letters or fewer: one edit only (Abby is two)');
ok(scalar(pick('Beatels', [ { id => '89ad4ac3-39f7-470e-963a-56509c546377', name => 'Beatles', score => 100 },
                            @$BEATELS ]) eq 'The Beatles|Beaters|Beatals'),
   "3: MusicBrainz's special artists are never picked");
ok(scalar(pick('Beatels', [ { name => 'Beatles', score => 100 }, @$BEATELS ]) eq 'The Beatles|Beaters|Beatals'),
   '3: a hit with no id is never picked');
ok(scalar(pick('Xqzvw', $BEATELS) eq ''), '3: nothing close -> nothing');
ok(scalar(pick('', $BEATELS) eq '' && pick('Beatels', undef) eq ''), '3: no name or no reply -> nothing');

# --- 4. the request -------------------------------------------------------
my $got;
my $ask = sub { $got = undef; $API->fuzzyArtists($_[0], sub { $got = $_[0] }); return names($got) };
cold();
%REPLY = ('artist%3A%28beatels%7E%29' => $BEATELS, 'artist%3A%28elvis%7E%20costelo%7E%29' => $COSTELO);
ok(scalar($ask->('Beatels') eq 'The Beatles|Beaters|Beatals' && @URLS == 1),
   '4: one request, answered with the pick');
ok(scalar(@URLS && $URLS[0] =~ m{^http://mirror:5000/ws/2/artist\?query=artist%3A%28beatels%7E%29&fmt=json&limit=25$}),
   '4: the query is each word fuzzy, on the artist field, at 25');
ok(scalar($ask->('Elvis Costelo') eq 'Elvis Costello' && $URLS[-1] =~ /artist%3A%28elvis%7E%20costelo%7E%29/),
   '4: two words: each fuzzy');
@URLS = ();
ok(scalar($ask->('Beatels') eq 'The Beatles|Beaters|Beatals' && !@URLS), '4: asked again: from the cache, no request');
ok(scalar($ask->('The Beatels') eq 'The Beatles|Beaters|Beatals' && @URLS == 1 && $URLS[0] =~ /artist%3A%28beatels%7E%29/),
   '4: a typed leading "the" is not sent');
cold();
ok(scalar($ask->('Xqzvw') eq '' && @URLS == 1), '4: nothing close: an empty answer');
@URLS = ();
ok(scalar($ask->('Xqzvw') eq '' && !@URLS), '4: ... which is kept too (a real answer)');
cold();
%REPLY = ('artist%3A%28beatels%7E%29' => undef);
ok(scalar($ask->('Beatels') eq '' && defined $got && @URLS == 1), '4: a failed request answers nothing');
%REPLY = ('artist%3A%28beatels%7E%29' => $BEATELS);
ok(scalar($ask->('Beatels') eq 'The Beatles|Beaters|Beatals' && @URLS == 2), '4: ... and is not kept: the next search asks again');
cold();
my $kenshi = "\x{7c73}\x{6d25}\x{7384}\x{5e2b}"; utf8::upgrade($kenshi);
$ask->($kenshi);
ok(scalar(@URLS == 1 && $URLS[0] =~ /artist%3A%28%E7%B1%B3%E6%B4%A5%E7%8E%84%E5%B8%AB%7E%29/),
   '4: a non-Latin name is sent as UTF-8');
cold();
ok(scalar($ask->('  ') eq '' && defined $got && !@URLS), '4: a blank name: no request');
ok(scalar(defined($ask->('!!')) && defined $got), '4: a name of marks alone answers (it does not die)');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
