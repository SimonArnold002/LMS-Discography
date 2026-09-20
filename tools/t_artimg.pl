#!/usr/bin/env perl
#
# REGRESSION TEST — artist artwork is keyed by CONTRIBUTOR ID when the library
# knows the artist, the way LMS itself keys it.
#
# FIELD (Simon, 2026-07-22): *"when I play these albums or browse the artists I
# get the correct artwork ... from MAI"* — while the plugin's own row showed
# the silhouette. LMS's artist browse emits `contributor/<hash>/image`, the
# SAME image for every spelling; the plugin was asking the MAI proxy by NAME,
# which cannot resolve a name carrying typographic punctuation. 56 of his 4,288
# library artists have some. Measured live against the running server:
#
#     name 'The La’s'    ->   5,071 bytes (the silhouette)  id 57545 -> 418,519
#     name 'The Go‐Go’s' ->   5,071 bytes                   id       -> 411,927
#     name 'The dB’s'    ->   5,071 bytes                   id       ->  41,154
#     name 'Radiohead'   -> 214,785 bytes                   id       -> 214,785
#     name 'Nonexistent Band Xyzzy' -> 5,071 bytes  <- identical placeholder
#
# An earlier plan to TRANSLITERATE the punctuation was dropped: it treated the
# symptom while leaving the plugin keyed differently from the rest of LMS, and
# Simon's observation is what revealed the id route existed at all.
#
# Standalone -- no LMS install needed:  perl tools/t_artimg.pl
#
use strict;
use warnings;
use FindBin;

our $MAI_ON = 1;

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
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Strings::cstring'} = sub { $_[1] };
    *{'Slim::Utils::Strings::string'}  = sub { $_[0] };
    push @{'Slim::Utils::Strings::ISA'}, 'Exporter';
    @{'Slim::Utils::Strings::EXPORT'} = qw(cstring string);
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { {} };
    # MAI presence is the gate _artistImg checks first.
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { return $main::MAI_ON };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json string);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }
# Records every write, so §10 can assert that a failed walk caches NOTHING.
package T::RecCache;
sub get { return undef }
sub set { my (undef, $k, $v, $ttl) = @_; push @main::SET, [ $k, $v, $ttl ]; return 1 }
sub remove { 1 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $img = \&Plugins::Discography::Browse::_artistImg;

# Streaming adapters are a runtime fact (are the plugins installed?), so the
# gate is stubbed here — AFTER the real Sources.pm has loaded, or its own
# definition would win. Stub adapters(), NOT orderedAdapters(): the real
# orderedAdapters must run, because it ends in `return sort ...` and sort in
# SCALAR context is undefined behaviour that returns nothing. A stub returning
# a plain list hid exactly that, and _artistImg's gate read false forever.
our $SVC_ON = 0;
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::Sources::adapters'}
        = sub { $main::SVC_ON ? ({ name => 'Deezer' }) : () };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# ---------------------------------------------------------------------------
# 1. AN ID WINS, and it is what makes a typographic name resolve at all.
# ---------------------------------------------------------------------------
ok(scalar($img->("The La\x{2019}s", 57545) eq 'imageproxy/mai/artist/57545/image.png'),
   'a curly-apostrophe artist with an id is keyed by ID');
ok(scalar($img->('Radiohead', 1234) eq 'imageproxy/mai/artist/1234/image.png'),
   '... and so is a plain name (one rule, no special cases)');
ok(scalar($img->("The La\x{2019}s", 57545) !~ /\x{2019}|%E2%80%99/),
   '... so no typographic punctuation reaches the proxy URL');

# ---------------------------------------------------------------------------
# 2. NO ID -> OUR OWN name route (0.51.0). Streaming-only rows, similar artists
#    and MB candidates land on `imageproxy/dsc/artist/<name>`, where the
#    resolver can tell a placeholder from a photograph — MAI's route ends at
#    one snapshot of Deezer and serves its placeholder when that goes stale
#    (The Mothers of Invention / Pink Floyd / B52's, all measured 2026-07-29).
# ---------------------------------------------------------------------------
ok(scalar($img->('Radiohead') eq 'imageproxy/dsc/artist/Radiohead/image.png'),
   'no id: the name route is OURS');
ok(scalar($img->('Sigur R\x{f3}s') =~ m{^imageproxy/dsc/artist/.+/image\.png$}),
   '... and an accented name is still escaped into the URL');
ok(scalar($img->('AC/DC') !~ m{artist/AC/DC/}),
   '... with a slash in the name escaped, not left to split the path');

# ---------------------------------------------------------------------------
# 3. GARBAGE IDS MUST NOT BUILD A URL. Anything non-numeric falls back to the
#    name rather than producing imageproxy/mai/artist//image.png.
# ---------------------------------------------------------------------------
for my $bad ('', 'abc', '12x', undef) {
    my $got = $img->('Radiohead', $bad);
    ok(scalar($got eq 'imageproxy/dsc/artist/Radiohead/image.png'),
       'a non-numeric id (' . (defined $bad ? "'$bad'" : 'undef')
       . ') falls back to the name');
}

# ---------------------------------------------------------------------------
# 4. THE MAI GATE guards the ID route only. Without MAI there is no contributor
#    photo to serve, but a NAME can still be resolved from the services — the
#    whole point of owning the route — so MAI-off must not mean icon-only.
# ---------------------------------------------------------------------------
{
    local $main::MAI_ON = 0;
    local $main::SVC_ON = 0;
    ok(scalar($img->('Radiohead', 57545) =~ /person\.png$/),
       'no MAI and no services -> the person icon, id or not');
    local $main::SVC_ON = 1;
    ok(scalar($img->('Radiohead', 57545) eq 'imageproxy/dsc/artist/Radiohead/image.png'),
       'no MAI but a service enabled -> our name route still resolves it');
}
ok(scalar($img->(undef, 57545) eq 'imageproxy/mai/artist/57545/image.png'),
   'an id with NO name is still enough to build a URL');
ok(scalar($img->(undef, undef) =~ /person\.png$/),
   'neither name nor id -> the person icon');
ok(scalar($img->('') =~ /person\.png$/), 'an empty name -> the person icon');

# ---------------------------------------------------------------------------
# 5. PLACEHOLDER DETECTION — the signal the whole 0.51.0 fix turns on.
#    A picture-less Deezer entity answers with (or 302s to) the md5 of the
#    EMPTY STRING. Nothing else about the URL distinguishes it from a photo,
#    which is why 0.46.5 could only diagnose this and not fix it.
# ---------------------------------------------------------------------------
my $ph = \&Plugins::Discography::Sources::isPlaceholderImage;
ok(scalar($ph->('https://cdn-images.dzcdn.net/images/artist/'
    . 'd41d8cd98f00b204e9800998ecf8427e/1000x1000-000000-80-0-0.jpg')),
   'the empty-md5 Deezer entity is recognised as a placeholder');
ok(scalar($ph->('/images/artist/d41d8cd98f00b204e9800998ecf8427e/1000x1000.jpg')),
   '... including as a bare 302 Location header');
ok(scalar(!$ph->('https://cdn-images.dzcdn.net/images/artist/'
    . '32cfa44648e2605d89c843b5371fbb53/1000x1000-000000-80-0-0.jpg')),
   'The Mothers of Invention\'s LIVE Deezer picture is not a placeholder');
ok(scalar(!$ph->(undef)) && scalar(!$ph->('')),
   'undef/empty are not placeholders (nothing to serve is not a false photo)');
# The OTHER no-picture form: an EMPTY hash segment. Deezer's own search hands
# it back for a picture-less entity (live 2026-09-19, "Teddybears feat. CeeLo &
# B52's", id 14102297), and the CDN serves the identical 16,802-byte
# placeholder as the md5 form. It carries no md5, so the sentinel missed it.
ok(scalar($ph->('https://cdn-images.dzcdn.net/images/artist//1000x1000-000000-80-0-0.jpg')),
   'the EMPTY-hash Deezer picture (/images/artist//) is a placeholder too');
ok(scalar($ph->('/images/artist//500x500-000000-80-0-0.jpg')),
   '... including as a bare path');
ok(scalar(!$ph->('https://static.qobuz.com/images/artists/covers//large/abc.jpg')),
   '... but a double slash elsewhere in another service\'s path is not (control)');

# ---------------------------------------------------------------------------
# 6. SERVICE ARTIST PHOTOS come from each plugin's OWN url builder, and a
#    placeholder handed back by a service is dropped like any other.
# ---------------------------------------------------------------------------
my $svcImg = \&Plugins::Discography::Sources::_svcArtistImage;
{
    no strict 'refs';
    $INC{'Plugins/Deezer/API.pm'} = 1;
    $INC{'Plugins/TIDAL/API.pm'}  = 1;
    $INC{'Plugins/Qobuz/API/Common.pm'} = 1;
    # Both service builders read the hash and write {cover} back into it.
    *{'Plugins::Deezer::API::getImageUrl'} = sub { $_[1]->{picture_xl} };
    *{'Plugins::TIDAL::API::getImageUrl'}  = sub {
        my $c = $_[1]->{picture} or return undef;
        $c =~ s/-/\//g;
        return "http://resources.tidal.com/images/$c/750x750.jpg";
    };
    *{'Plugins::Qobuz::API::Common::getImageFromImagesHash'} = sub {
        my $i = $_[1]; ref $i ? ($i->{mega} || $i->{large}) : $i };
}
my $live = 'https://cdn-images.dzcdn.net/images/artist/'
         . '32cfa44648e2605d89c843b5371fbb53/500x500-000000-80-0-0.jpg';
ok(scalar(($svcImg->('Deezer', { name => 'The Mothers of Invention',
                                 picture_xl => $live }) // '') eq $live),
   'Deezer: the live picture is taken through the plugin\'s own builder');
ok(scalar(!defined $svcImg->('Deezer', { name => 'Nobody', picture_xl =>
    'https://cdn-images.dzcdn.net/images/artist/'
    . 'd41d8cd98f00b204e9800998ecf8427e/500x500-000000-80-0-0.jpg' })),
   '... and its placeholder is dropped, not shown');
ok(scalar(!defined $svcImg->('Deezer', { name => 'Nobody', picture_xl =>
    'https://cdn-images.dzcdn.net/images/artist//1000x1000-000000-80-0-0.jpg' })),
   '... and so is its empty-hash form, so an exact hit carrying it counts as NO photo');
ok(scalar(($svcImg->('Tidal', { name => 'X', picture => 'aa-bb-cc' }) // '')
    eq 'http://resources.tidal.com/images/aa/bb/cc/750x750.jpg'),
   'TIDAL: the picture uuid is expanded by the plugin, not by us');
ok(scalar(($svcImg->('Qobuz', { name => 'X',
        image => { large => 'https://static.qobuz.com/a.jpg' } }) // '')
    eq 'https://static.qobuz.com/a.jpg'),
   'Qobuz: the size hash resolves through API::Common');
ok(scalar(!defined $svcImg->('Qobuz', { name => 'X', picture => 'html/images/artists.png' })),
   '... and a relative plugin asset is not a photo (only http(s) counts)');
ok(scalar(!defined $svcImg->('Nope', { name => 'X', picture => 'http://x/y.jpg' })),
   'an unknown service yields nothing rather than a guessed URL');

# ---------------------------------------------------------------------------
# 7. THE PROXY HANDLER: parses its own escaped name back out, honours the async
#    contract (returns undef, answers via $cb), and falls THROUGH a dead MAI
#    answer to the services.
# ---------------------------------------------------------------------------
{
    no strict 'refs';
    my $asked;
    *{'Plugins::Discography::Sources::artistImage'} = sub {
        (undef, undef, my $name, my $cb) = @_;
        $asked = $name;
        $cb->('https://svc.example/photo.jpg');
    };
    local $main::MAI_ON = 0;            # no MAI -> tiers 1 and 2 are empty
    my $got;
    my $ret = Plugins::Discography::Browse::artistImageProxy(
        'dsc/artist/Sigur%20R%C3%B3s', '_96x96_o', sub { $got = shift });
    ok(scalar(!defined $ret), 'the handler returns undef (it answered via $cb)');
    ok(scalar($got && $got eq 'https://svc.example/photo.jpg'),
       'a service photo is what the proxy serves when MAI has nothing');
    ok(scalar(defined $asked && $asked eq "Sigur R\x{f3}s"),
       '... and the escaped name came back as CHARACTERS, not octets (a byte '
       . 'string would be re-encoded by MAI into "Sigur RÃ³s")');
    my $bad = Plugins::Discography::Browse::artistImageProxy('dsc/artist/', '', sub {});
    ok(scalar(!$bad || $bad !~ /^https?:/),
       'a nameless proxy URL never turns into a remote fetch');
    # ... and it must still ANSWER. undef is ImageProxy's "I already called
    # $cb" signal (ImageProxy.pm), so returning it without calling $cb leaves
    # the image request hanging forever. The icon file is normally there, so
    # the bare path only bites a broken install — but the other two exits guard
    # with `|| ''` and this one did not (review 2026-09-19).
    {
        no warnings 'redefine'; no strict 'refs';
        my $prev = \&Plugins::Discography::Browse::_personIconFile;
        *{'Plugins::Discography::Browse::_personIconFile'} = sub { undef };  # icon missing
        my $called = 0;
        my $r = Plugins::Discography::Browse::artistImageProxy('dsc/artist/', '', sub { $called++ });
        ok(scalar(defined $r || $called),
           'a nameless URL is answered even when the bundled icon is missing (never a hung request)');
        *{'Plugins::Discography::Browse::_personIconFile'} = $prev;
    }
}

# ---------------------------------------------------------------------------
# 8. THE NAME GATE IN artistImage. The exact-name test must see EVERY hit, not
#    only the ones carrying a photo. An exact entity with no picture (or only a
#    placeholder, which _svcArtistImage drops) is exactly the artist that
#    reaches this tier, and filtering it out first handed the row to a
#    token-subset NEIGHBOUR's face — "Genesis P-Orridge" for Genesis — cached
#    for 30 days.
# ---------------------------------------------------------------------------
{
    no strict 'refs'; no warnings 'redefine';
    *{'Slim::Utils::Timers::setTimer'}     = sub { 1 };
    *{'Slim::Utils::Timers::killSpecific'} = sub { 1 };
    # Section 7 stubbed artistImage itself; reload the module for the real one.
    delete $INC{'Plugins/Discography/Sources.pm'};
    local $SIG{__WARN__} = sub {};
    require Plugins::Discography::Sources;
}
our @HITS;
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::Sources::adapters'} = sub {
        ({ name => 'Deezer', query_enc => 'bytes',
           artists => sub { $_[3]->([ @main::HITS ]) } })
    };
}
sub artImg {
    my ($name) = @_;
    my $got = 'NOT CALLED';
    Plugins::Discography::Sources->artistImage(undef, $name, sub { $got = shift });
    return $got;
}
@HITS = ({ name => 'Genesis' },
         { name => 'Genesis P-Orridge', img => 'https://x/gpo.jpg' });
ok(scalar(!defined artImg('Genesis')),
   'an exact entity with NO photo -> nothing, not a neighbour\'s face');
@HITS = ({ name => 'Genesis P-Orridge', img => 'https://x/gpo.jpg' },
         { name => 'Genesis', img => 'https://x/genesis.jpg' });
ok(scalar((artImg('Genesis') // '') eq 'https://x/genesis.jpg'),
   '... an exact entity WITH a photo wins from any position (control)');
@HITS = ({ name => 'Mothers of Invention and Friends', img => 'https://x/moi.jpg' });
ok(scalar((artImg('Mothers of Invention') // '') eq 'https://x/moi.jpg'),
   '... and with NO exact entity the token-subset match still answers (control)');

# ---------------------------------------------------------------------------
# 9. EXACT BEATS LOOSE ACROSS SERVICES, not only within one. A higher-priority
#    service answering with only a NEIGHBOUR must not pre-empt the exact entity
#    a lower-priority service holds. Services are still asked one at a time,
#    and an exact photo still ends the walk at once; a loose photo is only
#    remembered, and used only if NO service knows the exact name.
# ---------------------------------------------------------------------------
our (%SVCHITS, @ASKED);
{
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::Discography::Sources::adapters'} = sub {
        map { my $svc = $_;
              { name => $svc, query_enc => 'bytes',
                artists => sub { push @main::ASKED, $svc;
                                 $_[3]->([ @{ $main::SVCHITS{$svc} || [] } ]) } } }
            qw(Qobuz Deezer);
    };
}
sub artImg2 { my ($n, %h) = @_; %SVCHITS = %h; @ASKED = (); return artImg($n) }

ok(scalar((artImg2('Genesis',
        Qobuz  => [{ name => 'Genesis P-Orridge', img => 'https://x/gpo.jpg' }],
        Deezer => [{ name => 'Genesis', img => 'https://x/genesis.jpg' }]) // '')
    eq 'https://x/genesis.jpg'),
   'a loose hit on the FIRST service does not beat an exact hit on the second');
ok(scalar(!defined artImg2('Genesis',
        Qobuz  => [{ name => 'Genesis P-Orridge', img => 'https://x/gpo.jpg' }],
        Deezer => [{ name => 'Genesis' }])),
   '... and an exact entity with no photo ANYWHERE vetoes every loose photo');
ok(scalar((artImg2('Mothers of Invention',
        Qobuz  => [{ name => 'Mothers of Invention and Friends', img => 'https://x/q.jpg' }],
        Deezer => [{ name => 'Mothers of Invention Tribute', img => 'https://x/d.jpg' }]) // '')
    eq 'https://x/q.jpg'),
   'no exact entity anywhere -> the loose photo, in PRIORITY order (control)');
artImg2('Genesis',
        Qobuz  => [{ name => 'Genesis', img => 'https://x/genesis.jpg' }],
        Deezer => [{ name => 'Genesis', img => 'https://x/other.jpg' }]);
ok(scalar("@ASKED" eq 'Qobuz'),
   'an exact photo still ends the walk: the next service is never asked');

# ---------------------------------------------------------------------------
# 10. A SERVICE THAT NEVER ANSWERED IS NOT A SERVICE WITH NO PHOTO
#     (review 2026-09-20). Every leg of the walk ended in `$settle->(undef)` —
#     the watchdog firing, the adapter throwing, the plugin having no API
#     handler AND a search that legitimately returned nothing all arrived the
#     same way. The end of the walk then cached '' for a day, so one flaky
#     minute pinned the person icon on an artist until the next day.
#
#     The adapters already carry the distinction the fleet's streaming-adapter
#     spec names: `undef` is INCONCLUSIVE, `[]` is a real miss (`_artistHits`
#     returns undef for a response it could not read, an arrayref otherwise).
#     So the verdict is cached only when at least one service actually
#     answered — the same rule `_vetCollabs` applies to its `$ok`.
#
#     A recording cache is needed to see the write, and `$cache` is captured
#     at load, so Sources is reloaded against it (as §8 reloads it).
# ---------------------------------------------------------------------------
our @SET;
{
    no strict 'refs'; no warnings 'redefine';
    *{'Slim::Utils::Cache::new'} = sub { bless {}, 'T::RecCache' };
    delete $INC{'Plugins/Discography/Sources.pm'};
    local $SIG{__WARN__} = sub {};
    require Plugins::Discography::Sources;
    *{'Plugins::Discography::Sources::adapters'} = sub {
        map { my $svc = $_;
              { name => $svc, query_enc => 'bytes',
                artists => sub { $_[3]->($main::SVCHITS{$svc}) } } }
            qw(Qobuz Deezer);
    };
}
sub artImg3 {
    my ($n, %h) = @_;
    %SVCHITS = %h; @SET = ();
    my $got = 'NOT CALLED';
    Plugins::Discography::Sources->artistImage(undef, $n, sub { $got = shift });
    return $got;
}

ok(scalar(!defined artImg3('Ghost Artist', Qobuz => undef, Deezer => undef)),
   'no service answered -> still no photo for this render');
ok(scalar(@SET == 0),
   '... and NOTHING is cached, so the next visit asks again');

ok(scalar(!defined artImg3('Ghost Artist', Qobuz => [], Deezer => [])),
   'control: both services answered with nothing -> no photo');
ok(scalar(@SET == 1 && $SET[0][1] eq ''),
   '... and THAT verdict is cached, because it is a real answer');

ok(scalar((artImg3('Genesis',
        Qobuz  => undef,
        Deezer => [{ name => 'Genesis', img => 'https://x/genesis.jpg' }]) // '')
    eq 'https://x/genesis.jpg'),
   'control: one service failing does not stop a later one answering');
ok(scalar(@SET == 1 && $SET[0][1] eq 'https://x/genesis.jpg'),
   '... and a found photo is cached as before');

# The verdict has to survive the trip back up, or the proxy — which keeps its
# OWN 'dsc:artimg:v1' entry over the whole resolution — pins the same failure
# it was just told not to trust. MAI off, so tiers 1 and 2 stand aside.
{
    local $MAI_ON = 0;
    my @got;
    %SVCHITS = (Qobuz => undef, Deezer => undef);
    Plugins::Discography::Browse::_resolveArtistImage('Ghost Artist',
        sub { @got = @_ });
    ok(scalar(@got && !$got[0] && !$got[1]),
       'the "no service answered" verdict reaches _resolveArtistImage\'s caller');
    %SVCHITS = (Qobuz => [], Deezer => []);
    Plugins::Discography::Browse::_resolveArtistImage('Ghost Artist',
        sub { @got = @_ });
    ok(scalar(@got && !$got[0] && $got[1]),
       'control: a real "nobody has one" comes back conclusive');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
