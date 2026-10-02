#!/usr/bin/env perl
#
# AN UNTAGGED LIBRARY ARTIST IS NAMED BY ITS OWN ALBUMS (resolver plan C2).
#
# With no MusicBrainz tag on the files, a library artist's page resolved by name
# and opened the best-scoring act of that name (Simon's Welsh band Jack opened
# Jack Johnson). API::getArtistMbid now asks MusicBrainz about the artist's own
# albums first: `releasegroup:"<title>" AND artist:"<name>"`, the act credited on
# the hits with that very title. Measured 2026-10-02 over his library as if
# untagged and over 436 pretend libraries of a lesser same-name act (resolver
# plan C2, MEASURED); every section below is one of the rules that measurement
# forced, or a guard around them, run through the REAL resolver:
#   1. Jack: two titles name the Welsh band, the name's Jack Johnson is overruled;
#      kept per contributor, never under the name;
#   2. the first title agreeing with the name ends it (one request);
#   3. an act NAMED as the library beats one whose name only holds it (Nat King
#      Cole / The Nat King Cole Trio), and a name-inside act wins when no act
#      named so votes (Roswell / Roswell Road);
#   4. a title two acts of the name both hold counts for neither; a self-titled
#      title ONE act holds counts (Muzz);
#   5. the name check: another name is not counted (a composer), spacing and a
#      leading "The" do not make another act (the Chocolate Watchband), the
#      query drops the "The"; MusicBrainz's special entities never count;
#   6. the edition-less title is asked only when the title found nobody;
#   7. a tie decides nothing; a failed or unreadable reply keeps nothing;
#   8. a tag wins, a speculative call (the search row check) asks no album, a
#      kept answer (or a kept "nothing") is served without a request, no own
#      album = the name, the key is the id AND the name;
#   9. at most LIBMBID_TITLES titles, distinctive first;
#  10. peekLibraryMbid, and Refresh (clearArtistCache) forgets the answer and
#      clears the act it named;
#  11. Sources::ownAlbumTitles: the artist's OWN albums only, one per spelling,
#      oldest first; _titleWeight as Browse used it;
#  12. the query: Lucene characters escaped, _editionless.
#
# Standalone -- no LMS install needed:  perl tools/t_libmbid.pl
#
use strict;
use warnings;
use utf8;
use FindBin;
use JSON::XS ();

binmode STDOUT, ':encoding(UTF-8)';

my %CACHE;
our @QUERIES;              # every URL sent, in order
our %RG;                   # release-group query URL => reply hash | 'ERROR' | 'GARBAGE'
our %TITLES;               # contributor id => [ own album titles ] (ownAlbumTitles)
our %CONTRIB;              # contributor id => { name, mbid }
our $ALBUMS_LOOP;          # section 11: what the `albums` query answers
our $MB_BASE = 'https://musicbrainz.org/ws/2/';

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
    # The library: a contributor's name and tag (Slim::Schema), its albums
    # (`albums` through executeRequest).
    *{'Slim::Schema::find'} = sub {
        my ($class, $table, $id) = @_;
        return undef unless $table eq 'Contributor' && $main::CONTRIB{$id};
        return bless { %{ $main::CONTRIB{$id} } }, 'T::Contrib';
    };
    *{'Slim::Control::Request::executeRequest'} = sub {
        my (undef, $args) = @_;
        push @main::ALBUM_ASKS, [ @$args ];
        return bless { loop => $main::ALBUMS_LOOP }, 'T::Req';
    };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}
our @ALBUM_ASKS;

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Cache;
sub get { return $CACHE{ $_[1] } }
sub set { $CACHE{ $_[1] } = $_[2]; $main::TTL{ $_[1] } = $_[3]; return 1 }
sub remove { delete $CACHE{ $_[1] }; return 1 }
package T::Prefs;
sub get { return $_[1] eq 'mb_base_url' ? $main::MB_BASE : undef }
sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Contrib;
sub name           { $_[0]{name} }
sub musicbrainz_id { $_[0]{mbid} }
package T::Req;
sub getResult { return $_[1] eq 'albums_loop' ? $_[0]{loop} : undef }
package T::Resp;
sub new     { my ($c, $body) = @_; bless { body => $body }, $c }
sub content { $_[0]{body} }
sub error   { 'stub error' }
sub code    { 500 }

package main;
our %TTL;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
require Plugins::Discography::API;
my $API = 'Plugins::Discography::API';
my $SRC = 'Plugins::Discography::Sources';
my $realOwn = \&Plugins::Discography::Sources::ownAlbumTitles;

# Every request answered at once from %RG by exact URL; a name search (none is
# expected: the name's answer is seeded in the cache) is recorded and errors.
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::API::_netGet'} = sub {
        my ($url, $ok, $err, %opt) = @_;
        push @QUERIES, $url;
        my $r = $RG{$url} // 'ERROR';
        return $err->(T::Resp->new(''), 'stub error', T::Resp->new('')) if !ref $r && $r eq 'ERROR';
        return $ok->(T::Resp->new('{"not json')) if !ref $r && $r eq 'GARBAGE';
        $ok->(T::Resp->new(JSON::XS::encode_json($r)));
    };
    *{'Plugins::Discography::Sources::ownAlbumTitles'} = sub { [ @{ $main::TITLES{ $_[1] } || [] } ] };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}
sub section {
    my ($n, $code) = @_;
    eval { $code->(); 1 } or do {
        (my $e = $@) =~ s/\s+/ /g;
        ok(0, "$n: the section died: $e");
    };
}
sub cold {
    %CACHE = (); %TTL = (); @QUERIES = (); %RG = (); %TITLES = (); %CONTRIB = ();
    @ALBUM_ASKS = ();
    %Plugins::Discography::API::NAME_MEMO = ();
    %Plugins::Discography::API::NAME_WAIT = ();
}
sub id { sprintf('%08d-0000-0000-0000-000000000000', $_[0]) }
# A library contributor, untagged unless $mbid, and the name's own answer.
sub contrib {
    my ($cid, $name, $byName, $mbid) = @_;
    $CONTRIB{$cid} = { name => $name, mbid => $mbid };
    $CACHE{ Plugins::Discography::API::_mbidKey($name) } = $byName // '';
}
# A release-group search reply: [title, [ [act id, act name], ... ]] per hit.
sub rgs { return { count => scalar @_, 'release-groups' => [ map {
    my ($t, $credits) = @$_;
    { title => $t, score => 100,
      'artist-credit' => [ map { { name => $_->[1], artist => { id => $_->[0], name => $_->[1] } } } @$credits ] }
} @_ ] } }
# The URL for asking $title under the library $name (the query drops a "The").
sub url { my ($title, $name) = @_; (my $a = $name) =~ s/^\s*the\s+(?=\S)//i;
          return Plugins::Discography::API::_rgQueryUrl($title, $a) }
sub resolve {
    my (%a) = @_;
    my @got;
    $API->getArtistMbid(%a, onDone => sub { @got = @_ });
    return @got;
}
sub nrg { scalar grep { index($_, 'release-group?query=') >= 0 } @QUERIES }
my $LK = sub { Plugins::Discography::API::_libMbidKey(@_) };

my ($JJ, $WJ) = (id(1), id(2));    # Jack Johnson, Jack (Welsh band)

# ---------------------------------------------------------------------------
# 1. JACK: both titles name the Welsh band; the name's Jack Johnson is overruled.
# ---------------------------------------------------------------------------
section('1', sub {
cold();
contrib(153744, 'Jack', $JJ);
$TITLES{153744} = [ 'Pioneer Soundtracks', 'The Jazz Age' ];
$RG{ url('Pioneer Soundtracks', 'Jack') } = rgs([ 'Pioneer Soundtracks', [ [ $WJ, 'Jack' ] ] ]);
$RG{ url('The Jazz Age', 'Jack') }        = rgs([ 'The Jazz Age', [ [ $WJ, 'Jack' ] ] ]);
my ($m, $fromTag) = resolve(artist_id => 153744, artist => 'Jack');
ok($m eq $WJ, '1: an untagged "Jack" opens the act its albums name, not the name\'s Jack Johnson');
ok(defined $fromTag && $fromTag == 0, '1: and says it is not from a tag (no wrong-tag fallback)');
ok(nrg() == 2, '1: both titles asked (the first disagreed with the name)');
ok(($CACHE{ $LK->(153744, 'Jack') } // '') eq $WJ, '1: the answer is kept per contributor (id and name)');
ok($TTL{ $LK->(153744, 'Jack') } == $API->LIBMBID_TTL, '1: for LIBMBID_TTL');
ok(($CACHE{ Plugins::Discography::API::_mbidKey('Jack') } // '') eq $JJ,
   '1: and never under the name - "Jack" by name still opens what the name opens');
ok($LK->(153744, 'Jack') =~ /^dsc:libmbid:1:153744:jack$/, '1: key dsc:libmbid:1:<id>:<name>');
});

# ---------------------------------------------------------------------------
# 2. THE FIRST TITLE AGREEING WITH THE NAME ENDS IT: one request.
# ---------------------------------------------------------------------------
section('2', sub {
cold();
my $RH = id(10);
contrib(5, 'Radiohead', $RH);
$TITLES{5} = [ 'OK Computer', 'Kid A', 'Amnesiac' ];
$RG{ url('OK Computer', 'Radiohead') } = rgs([ 'OK Computer', [ [ $RH, 'Radiohead' ] ] ]);
$RG{ url('Kid A', 'Radiohead') }       = rgs([ 'Kid A', [ [ id(11), 'Radiohead' ] ] ]);
my ($m) = resolve(artist_id => 5, artist => 'Radiohead');
ok($m eq $RH, '2: the name\'s act, which the first title confirms');
ok(nrg() == 1, '2: one release-group request: the first title agreed, the rest not asked');
ok(($CACHE{ $LK->(5, 'Radiohead') } // '') eq $RH, '2: the agreed answer is kept too');
# Control: without the early stop the second title (another act) would be counted.
cold();
contrib(5, 'Radiohead', id(12));    # the name answers another act
$TITLES{5} = [ 'OK Computer', 'Kid A' ];
$RG{ url('OK Computer', 'Radiohead') } = rgs([ 'OK Computer', [ [ $RH, 'Radiohead' ] ] ]);
$RG{ url('Kid A', 'Radiohead') }       = rgs([ 'Kid A', [ [ $RH, 'Radiohead' ] ] ]);
($m) = resolve(artist_id => 5, artist => 'Radiohead');
ok($m eq $RH && nrg() == 2, '2: control - a first title naming ANOTHER act than the name goes on to the next');
});

# ---------------------------------------------------------------------------
# 3. AN ACT NAMED AS THE LIBRARY BEATS ONE WHOSE NAME ONLY HOLDS IT.
# ---------------------------------------------------------------------------
section('3', sub {
cold();
my ($NKC, $TRIO) = (id(20), id(21));
contrib(7, 'Nat King Cole', id(22));    # the name's answer: neither (so no early stop)
$TITLES{7} = [ 'Mis Mejores Canciones', 'The Best of the Nat King Cole Trio', 'The Collection' ];
$RG{ url('Mis Mejores Canciones', 'Nat King Cole') } = rgs();
$RG{ url('The Best of the Nat King Cole Trio', 'Nat King Cole') }
    = rgs([ 'The Best of the Nat King Cole Trio', [ [ $TRIO, 'The Nat King Cole Trio' ] ] ]);
$RG{ url('The Collection', 'Nat King Cole') } = rgs([ 'The Collection', [ [ $NKC, 'Nat King Cole' ] ] ]);
my ($m) = resolve(artist_id => 7, artist => 'Nat King Cole');
ok($m eq $NKC, '3: Nat King Cole: his own "The Collection" (0.5) beats the Trio\'s 1.0 - named as the library');
# Roswell: no act NAMED Roswell votes, the act whose name holds it wins.
cold();
my $RR = id(23);
contrib(8, 'Roswell', id(24));
$TITLES{8} = [ 'Come Home', 'Remedy' ];
$RG{ url('Come Home', 'Roswell') } = rgs([ 'Come Home', [ [ $RR, 'Roswell Road' ] ] ]);
$RG{ url('Remedy', 'Roswell') }    = rgs([ 'Remedy', [ [ $RR, 'Roswell Road' ] ] ]);
($m) = resolve(artist_id => 8, artist => 'Roswell');
ok($m eq $RR, '3: Roswell: Roswell Road, the only act its albums name (name inside)');
});

# ---------------------------------------------------------------------------
# 4. A TITLE TWO ACTS OF THE NAME HOLD COUNTS FOR NEITHER; ONE ACT'S COUNTS.
# ---------------------------------------------------------------------------
section('4', sub {
cold();
my $NAMED = id(30);
contrib(9, 'Fever', $NAMED);
$TITLES{9} = [ 'Fever' ];
$RG{ url('Fever', 'Fever') } = rgs([ 'Fever', [ [ id(31), 'Fever' ] ] ], [ 'Fever', [ [ id(32), 'Fever' ] ] ]);
my ($m) = resolve(artist_id => 9, artist => 'Fever');
ok($m eq $NAMED, '4: a self-titled album two Fevers hold decides nothing - the name\'s answer');
ok(exists $CACHE{ $LK->(9, 'Fever') } && $CACHE{ $LK->(9, 'Fever') } eq '',
   '4: and "nothing decided" is kept');
ok($TTL{ $LK->(9, 'Fever') } == $API->LIBMBID_NONE_TTL, '4: for LIBMBID_NONE_TTL (albums were found)');
cold();
my $NYC = id(33);
contrib(10, 'Muzz', id(34));
$TITLES{10} = [ 'Muzz' ];
$RG{ url('Muzz', 'Muzz') } = rgs([ 'Muzz', [ [ $NYC, 'Muzz' ] ] ]);
($m) = resolve(artist_id => 10, artist => 'Muzz');
ok($m eq $NYC, '4: Muzz: a self-titled album ONE act holds decides (0.5 is enough alone)');
# Only a hit whose title IS the one asked counts: MusicBrainz also answers near
# titles (another act's "Muzz Live" scores on both words).
cold();
contrib(10, 'Muzz', id(34));
$TITLES{10} = [ 'Muzz' ];
$RG{ url('Muzz', 'Muzz') } = rgs([ 'Muzz', [ [ $NYC, 'Muzz' ] ] ], [ 'Muzz Live', [ [ id(35), 'Muzz' ] ] ]);
($m) = resolve(artist_id => 10, artist => 'Muzz');
ok($m eq $NYC, '4: a hit with another title (another act\'s "Muzz Live") is not counted');
});

# ---------------------------------------------------------------------------
# 5. THE NAME CHECK.
# ---------------------------------------------------------------------------
section('5', sub {
cold();
my $NAMED = id(40);
contrib(11, 'Chicago Symphony Orchestra', $NAMED);
$TITLES{11} = [ 'Symphony No. 6' ];
$RG{ url('Symphony No. 6', 'Chicago Symphony Orchestra') }
    = rgs([ 'Symphony No. 6', [ [ id(41), 'Пётр Ильич Чайковский' ] ] ]);
my ($m) = resolve(artist_id => 11, artist => 'Chicago Symphony Orchestra');
ok($m eq $NAMED, '5: a hit credited to another name (the composer) is not counted');
cold();
my $CW = id(42);
contrib(12, 'The Chocolate Watch Band', id(43));
$TITLES{12} = [ 'No Way Out' ];
$RG{ url('No Way Out', 'The Chocolate Watch Band') } = rgs([ 'No Way Out', [ [ $CW, 'The Chocolate Watchband' ] ] ]);
($m) = resolve(artist_id => 12, artist => 'The Chocolate Watch Band');
ok($m eq $CW, '5: "The Chocolate Watch Band" = MusicBrainz\'s "The Chocolate Watchband" (spacing aside)');
ok(scalar(grep { /artist%3A%22Chocolate%20Watch%20Band%22/ } @QUERIES) == 1,
   '5: the query asks for the artist without its leading "The"');
ok(Plugins::Discography::API::_libNameMatch('The Go-Go\'s', 'Go‐Go’s') == 2,
   '5: "The Go-Go\'s" and MusicBrainz\'s "Go‐Go’s" are the same name');
ok(Plugins::Discography::API::_libNameMatch('Chocolate Watchband', 'The Chocolate Watch Band') == 2,
   '5: and the other way round');
ok(Plugins::Discography::API::_libNameMatch('Roswell', 'Roswell Road') == 1,
   '5: Roswell inside Roswell Road: 1');
ok(Plugins::Discography::API::_libNameMatch('Jack', 'Jack Johnson') == 1
   && Plugins::Discography::API::_libNameMatch('Jack', 'Jill') == 0, '5: Jack in Jack Johnson 1, Jill 0');
ok(Plugins::Discography::API::_libNameMatch('The The', 'The The') == 2, '5: "The The" is itself');
cold();
contrib(13, 'Various', id(44));
$TITLES{13} = [ 'Hits' ];
$RG{ url('Hits', 'Various') } = rgs([ 'Hits', [ [ '89ad4ac3-39f7-470e-963a-56509c546377', 'Various Artists' ] ] ]);
($m) = resolve(artist_id => 13, artist => 'Various');
ok($m eq id(44), '5: MusicBrainz\'s Various Artists never counts, whatever the name check says');
});

# ---------------------------------------------------------------------------
# 6. THE EDITION-LESS TITLE, ONLY WHEN THE TITLE FOUND NOBODY.
# ---------------------------------------------------------------------------
section('6', sub {
cold();
my $B = id(50);
contrib(14, 'Bandit', id(51));
$TITLES{14} = [ 'Partners in Crime (Remastered)' ];
$RG{ url('Partners in Crime (Remastered)', 'Bandit') } = rgs();
$RG{ url('Partners in Crime', 'Bandit') } = rgs([ 'Partners in Crime', [ [ $B, 'Bandit' ] ] ]);
my ($m) = resolve(artist_id => 14, artist => 'Bandit');
ok($m eq $B, '6: "(Remastered)" found nobody, "Partners in Crime" names the act');
ok(nrg() == 2, '6: two requests');
cold();
contrib(14, 'Bandit', id(51));
$TITLES{14} = [ 'Partners in Crime (Remastered)' ];
$RG{ url('Partners in Crime (Remastered)', 'Bandit') } = rgs([ 'Partners in Crime', [ [ $B, 'Bandit' ] ] ]);
($m) = resolve(artist_id => 14, artist => 'Bandit');
ok($m eq $B && nrg() == 1, '6: a title that found its act is not asked again without its edition words');
});

# ---------------------------------------------------------------------------
# 7. A TIE DECIDES NOTHING; A FAILED OR UNREADABLE REPLY KEEPS NOTHING.
# ---------------------------------------------------------------------------
section('7', sub {
cold();
my $NAMED = id(60);
contrib(15, 'Rico', $NAMED);
$TITLES{15} = [ 'Alpha', 'Beta' ];
$RG{ url('Alpha', 'Rico') } = rgs([ 'Alpha', [ [ id(61), 'Rico Rodriguez' ] ] ]);
$RG{ url('Beta', 'Rico') }  = rgs([ 'Beta', [ [ id(62), 'Rico Suave' ] ] ]);
my ($m) = resolve(artist_id => 15, artist => 'Rico');
ok($m eq $NAMED, '7: two acts one title each: a tie decides nothing - the name\'s answer');
cold();
contrib(15, 'Rico', $NAMED);
$TITLES{15} = [ 'Alpha', 'Beta' ];
$RG{ url('Alpha', 'Rico') } = rgs([ 'Alpha', [ [ id(61), 'Rico Rodriguez' ] ] ]);
$RG{ url('Beta', 'Rico') }  = 'ERROR';
($m) = resolve(artist_id => 15, artist => 'Rico');
ok($m eq $NAMED, '7: a failed request: the name\'s answer, not the half-counted vote');
ok(!exists $CACHE{ $LK->(15, 'Rico') }, '7: and nothing kept, so the next visit asks again');
cold();
contrib(15, 'Rico', $NAMED);
$TITLES{15} = [ 'Alpha' ];
$RG{ url('Alpha', 'Rico') } = 'GARBAGE';
($m) = resolve(artist_id => 15, artist => 'Rico');
ok($m eq $NAMED && !exists $CACHE{ $LK->(15, 'Rico') }, '7: an unreadable reply: the same');
cold();
contrib(15, 'Rico', $NAMED);
$TITLES{15} = [ 'Alpha' ];
$RG{ url('Alpha', 'Rico') } = rgs();
($m) = resolve(artist_id => 15, artist => 'Rico');
ok($m eq $NAMED && ($CACHE{ $LK->(15, 'Rico') } // 'x') eq ''
   && $TTL{ $LK->(15, 'Rico') } == $API->LIBMBID_MISS_TTL, '7: no album found at all: kept for LIBMBID_MISS_TTL');
});

# ---------------------------------------------------------------------------
# 8. WHO ASKS, AND WHEN NOT.
# ---------------------------------------------------------------------------
section('8', sub {
cold();
contrib(16, 'Jack', $JJ, $WJ);    # tagged
$TITLES{16} = [ 'Pioneer Soundtracks' ];
my ($m, $fromTag) = resolve(artist_id => 16, artist => 'Jack');
ok($m eq $WJ && $fromTag == 1 && nrg() == 0, '8: a tag wins: no album asked');
cold();
contrib(17, 'Jack', $JJ);
$TITLES{17} = [ 'Pioneer Soundtracks' ];
$RG{ url('Pioneer Soundtracks', 'Jack') } = rgs([ 'Pioneer Soundtracks', [ [ $WJ, 'Jack' ] ] ]);
($m) = resolve(artist_id => 17, artist => 'Jack', speculative => 1);
ok($m eq $JJ && nrg() == 0, '8: a speculative call (the search row check) asks no album');
($m) = resolve(artist_id => 17, artist => 'Jack');
@QUERIES = ();
delete $CACHE{ Plugins::Discography::API::_mbidKey('Jack') };   # a kept answer needs no name either
($m) = resolve(artist_id => 17, artist => 'Jack');
ok($m eq $WJ && @QUERIES == 0, '8: a kept answer is served without any request');
cold();
contrib(18, 'Fever', id(70));
$TITLES{18} = [ 'Fever' ];
$CACHE{ $LK->(18, 'Fever') } = '';
($m) = resolve(artist_id => 18, artist => 'Fever');
ok($m eq id(70) && nrg() == 0, '8: a kept "nothing decided": the name, no album asked');
cold();
contrib(19, 'Jack', $JJ);
($m) = resolve(artist_id => 19, artist => 'Jack');
ok($m eq $JJ && nrg() == 0 && !exists $CACHE{ $LK->(19, 'Jack') },
   '8: no album of its own: the name, nothing asked, nothing kept');
cold();
contrib(20, 'Jack', $JJ);
$CACHE{ $LK->(20, 'Jill') } = $WJ;    # the id reused for another contributor
$TITLES{20} = [];
($m) = resolve(artist_id => 20, artist => 'Jack');
ok($m eq $JJ, '8: an answer kept for the id under ANOTHER name is not this contributor\'s');
cold();
$CONTRIB{21} = undef;   # outside LMS: no name from the library -> the page's name
$CACHE{ Plugins::Discography::API::_mbidKey('Jack') } = $JJ;
$TITLES{21} = [ 'Pioneer Soundtracks' ];
$RG{ url('Pioneer Soundtracks', 'Jack') } = rgs([ 'Pioneer Soundtracks', [ [ $WJ, 'Jack' ] ] ]);
($m) = resolve(artist_id => 21, artist => 'Jack');
ok($m eq $WJ && exists $CACHE{ $LK->(21, 'Jack') }, '8: no library name: the page\'s name keys it');
cold();
contrib(22, 'Jack', $JJ);
$TITLES{22} = [ 'Pioneer Soundtracks' ];
($m) = resolve(artist => 'Jack');
ok($m eq $JJ && nrg() == 0, '8: control - a page by name only (no id) is exactly as before');
});

# ---------------------------------------------------------------------------
# 9. AT MOST LIBMBID_TITLES TITLES, DISTINCTIVE FIRST.
# ---------------------------------------------------------------------------
section('9', sub {
cold();
contrib(23, 'Pacific', id(80));
$TITLES{23} = [ 'Pacific', 'Greatest Hits', 'Inference', 'Narrow Sleep', 'Shoals', 'Bluest' ];
$RG{ url($_, 'Pacific') } = rgs() for @{ $TITLES{23} };
my ($m) = resolve(artist_id => 23, artist => 'Pacific');
my @asked = map { my ($t) = /releasegroup%3A%22(.*?)%22/; $t } grep { /release-group/ } @QUERIES;
ok(scalar(@asked) == 3, '9: three titles asked at most (every one missed here)');
ok(join('|', @asked) eq 'Inference|Narrow%20Sleep|Shoals',
   '9: the distinctive ones, in library order, before the self-titled and the generic');
});

# ---------------------------------------------------------------------------
# 10. PEEK, AND REFRESH.
# ---------------------------------------------------------------------------
section('10', sub {
cold();
contrib(24, 'Jack', $JJ);
$CACHE{ $LK->(24, 'Jack') } = $WJ;
ok(($API->peekLibraryMbid(24, 'Whatever') // '') eq $WJ, '10: peekLibraryMbid by id, under the library\'s own name');
$CACHE{ $LK->(24, 'Jack') } = '';
ok(!defined $API->peekLibraryMbid(24, 'Jack'), '10: a kept "nothing decided" peeks as undef');
ok(!defined $API->peekLibraryMbid(undef, 'Jack'), '10: no id, no answer');
$CACHE{ $LK->(24, 'Jack') } = $WJ;
my $rgk = Plugins::Discography::API::_rgKey($WJ);
$CACHE{$rgk} = [ { mbid => id(99) } ];
my $bk = Plugins::Discography::API::_bioMbidKey($WJ);
$CACHE{$bk} = 'a biography kept under the mbid';
ok(scalar(Plugins::Discography::API::_bioMbidKey('ABC-Def') eq 'dsc:biomb:1:abc-def'),
   '10: the shared-name biography key is the mbid, lower-cased (t_exactbio.pl stands in with this spelling)');
my ($cleared, $used) = $API->clearArtistCache(name => 'Jack', artist_id => 24);
ok(scalar(!exists $CACHE{$bk} && grep { $_ eq 'bio-mbid' } @$cleared),
   '10: Refresh forgets the biography kept under the act\'s mbid (0.56.22)');
ok(!exists $CACHE{ $LK->(24, 'Jack') }, '10: Refresh forgets the albums\' answer');
ok(($used // '') eq $WJ && !exists $CACHE{$rgk}, '10: and clears the act it named (its release groups)');
ok(scalar(grep { $_ eq 'library-albums' } @$cleared), '10: reported as cleared');
cold();
contrib(25, 'Jack', $JJ, $WJ);    # tagged: no libmbid key is touched or recovered
$CACHE{ $LK->(25, 'Jack') } = id(98);
($cleared, $used) = $API->clearArtistCache(name => 'Jack', artist_id => 25);
ok(($used // '') eq $WJ && exists $CACHE{ $LK->(25, 'Jack') }, '10: control - a tagged artist clears by its tag');
});

# ---------------------------------------------------------------------------
# 11. Sources::ownAlbumTitles AND _titleWeight.
# ---------------------------------------------------------------------------
section('11', sub {
cold();
$ALBUMS_LOOP = [
    { album => 'The Jazz Age',          year => 1998, artist_id => 153744, compilation => 0 },
    { album => 'Pioneer Soundtracks',   year => 1996, artist_id => 153744, compilation => 0 },
    { album => 'Pioneer Soundtracks (Remastered)', year => 2016, artist_id => 153744, compilation => 0 },
    { album => 'Now That\'s Indie',     year => 1997, artist_id => 151537, compilation => 1 },
    { album => 'Jack: The Mixtapes',    year => 1990, artist_id => 153744, compilation => 1 },
    { album => 'Split 7"',              year => 1995, artist_id => 160000, compilation => 0 },
    { album => 'Undated',               artist_id => 153744, compilation => 0 },
];
my $t = $realOwn->($SRC, 153744);
ok(join('|', @$t) eq 'Pioneer Soundtracks|The Jazz Age|Undated',
   '11: own albums only (no compilation - even one filed under its name - no other album artist), one per spelling, oldest first, undated last');
my ($ask) = @ALBUM_ASKS;
ok(scalar(grep { $_ eq 'role_id:ALBUMARTIST' } @$ask) && scalar(grep { /^tags:.*w/ } @$ask),
   '11: asked as ALBUMARTIST, with the compilation flag (tag w)');
ok(!@{ $realOwn->($SRC, undef) }, '11: no id, no titles');
ok(Plugins::Discography::Sources::_titleWeight('Muzz', 'Muzz') == 0.5
   && Plugins::Discography::Sources::_titleWeight('The Greatest Hits', 'X') == 0.5
   && Plugins::Discography::Sources::_titleWeight('Pioneer Soundtracks', 'Jack') == 1.0,
   '11: _titleWeight: self-titled 0.5, generic 0.5, distinctive 1.0');
});

# ---------------------------------------------------------------------------
# 12. THE QUERY.
# ---------------------------------------------------------------------------
section('12', sub {
my $u = Plugins::Discography::API::_rgQueryUrl('Sign "O" the Times (Live)', 'AC/DC');
(my $q) = $u =~ /query=([^&]+)/;
$q =~ s/%([0-9A-F]{2})/chr hex $1/ge;
ok($q eq 'releasegroup:"Sign \"O\" the Times \(Live\)" AND artist:"AC\/DC"',
   '12: quotes, brackets and the slash escaped inside the quoted values');
ok($u =~ /&limit=12$/ && index($u, $MB_BASE . 'release-group?query=') == 0, '12: on the configured base, limit 12');
ok(Plugins::Discography::API::_editionless('Abbey Road (Super Deluxe Edition)') eq 'Abbey Road',
   '12: _editionless drops a bracketed edition');
ok(Plugins::Discography::API::_editionless('Disintegration [Remastered 2010]') eq 'Disintegration',
   '12: and a square-bracketed remaster');
ok(Plugins::Discography::API::_editionless('Sign O\' the Times - Remastered') eq 'Sign O\' the Times',
   '12: and a dashed one');
ok(Plugins::Discography::API::_editionless('(I Can\'t Get No) Satisfaction') eq '(I Can\'t Get No) Satisfaction',
   '12: a bracket that is part of the title stays');
ok(Plugins::Discography::API::_editionless('(Deluxe Edition)') eq '(Deluxe Edition)', '12: nothing left: the title');
});

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
