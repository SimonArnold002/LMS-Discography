#!/usr/bin/perl
# t_db.pl - Discography's own SQLite store (DB.pm), run for REAL against a temp
# cache folder: no stubbed storage.
#
#   1. an old LMS-cache discography.db is taken over (LMS's `cache` table dropped)
#   2. every cache family the modules write round-trips, in the right table
#   3. lifetimes: expiry, and a lifetime OVER 30 days is kept (the LMS-cache trap)
#   4. a CACHE_VERSION change empties kv and keeps the mbid table
#   5. key identity matches what LMS's cache gave (Latin-1 chars == their bytes)
#   6. degrade, never die, when the file cannot be opened
#   7. the REAL API module writes its artist-mbid family into the mbid table and
#      clearArtistMbid removes it (same key on both sides)
use strict;
use warnings;
use FindBin;
use File::Temp ();
use DBI;

my $DIR;      # the cachedir the stub prefs hand out
my @TIMERS;   # callbacks scheduled through Slim::Utils::Timers::setTimer

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Timers
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Strings
                  Slim::Utils::PluginManager Slim::Control::Request
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Timers::setTimer'}   = sub { push @TIMERS, $_[2]; 1 };
    *{'Slim::Utils::Timers::killTimers'} = sub { @TIMERS = (); 1 };
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { {} };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs;
sub get { return $_[1] eq 'cachedir' ? $DIR : undef }
sub set { 1 } sub init { 1 } sub setChange { 1 }

package main;

my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::DB;
my $DB = 'Plugins::Discography::DB';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $name) = @_;
    die "ok() called without a test name - list-context trap\n" unless defined $name;
    if ($c) { $pass++; print "ok - $name\n" } else { $fail++; print "not ok - $name\n" }
}
sub deep { require Data::Dumper; local $Data::Dumper::Sortkeys = 1; local $Data::Dumper::Indent = 0;
           return Data::Dumper::Dumper($_[0]) }
sub raw  { DBI->connect("dbi:SQLite:dbname=$DIR/discography.db", '', '', { RaiseError => 1 }) }
my $fresh = 0;
sub fresh {
    $DB->_reset;
    $DIR = "$tmp/f" . ++$fresh;
    mkdir $DIR or die "mkdir $DIR: $!";
}

# ---------------------------------------------------------------------------
# 1. Take over an old LMS-cache file.
{
    $DB->_reset;
    $DIR = "$tmp/c1"; mkdir $DIR;
    my $h = raw();
    # exactly what DbCache::_init_db creates
    $h->do('CREATE TABLE cache (k INTEGER PRIMARY KEY, v BLOB, t INTEGER)');
    $h->do('CREATE INDEX expiry ON cache (t)');
    $h->do('INSERT INTO cache VALUES (1, ?, 0)', undef, 'old');
    $h->disconnect;

    my $s = $DB->store('1.0');
    ok($s->set('dsc:bio:2:x', 'hello', 3600), '1: a write succeeds on the old file');
    my $h2 = raw();
    my %t = map { $_->[0] => 1 }
            @{ $h2->selectall_arrayref("SELECT name FROM sqlite_master WHERE type IN ('table','index')") };
    ok(!$t{cache},  "1: LMS's cache table is dropped");
    ok(!$t{expiry}, "1: LMS's expiry index is dropped");
    ok($t{kv} && $t{mbid} && $t{meta}, '1: kv, mbid and meta tables exist');
    ok(($h2->selectrow_array('PRAGMA user_version'))[0] == 1, '1: schema version 1 recorded');
    $h2->disconnect;
}

# ---------------------------------------------------------------------------
# 2. Every family the modules write, with a value in the shape they write.
my %FAMILY = (
    'dsc:mbsearchok:v1:http://m/ws/2/'  => 1,
    'dsc:mbmirror:v1'                   => 'http://localhost:5000/ws/2/',
    'dsc:mbid:2:radiohead'              => 'a74b1b7f-71a5-4011-9441-d0b5e4122711',
    'dsc:mbid:2:nobody'                 => '',
    'dsc:rgcount:1:abc'                 => 0,
    'dsc:mbname:1:abc'                  => "The B\xe2\x80\x9052s",
    'dsc:empty:1:abc'                   => 1,
    'dsc:alias:2:abc'                   => [ 'Tony Madness', "Cafe\xcc\x81" ],
    'dsc:acand:7:madness'               => [ { mbid => 'x', name => 'Madness', score => 100 } ],
    'dsc:rg:abc:v2'                     => [ { mbid => 'r', title => 'OK', aliases => ['a'] } ],
    'dsc:rel2rg:v1:rel-1'               => 'rg-1',
    'dsc:rel2rg:v1:rel-404'             => '',
    'dsc:collabs:v1:abc'                => [],
    'dsc:bands:v2:abc'                  => [ { mbid => 'b', name => 'Soft Cell' } ],
    'dsc:collabcand:v1:abc'             => [ { mbid => 'c' } ],
    'dsc:rgo:v4:abc'                    => { o => { g => 1 }, r => { rel => 'g' }, t => { g => ['T'] } },
    'dsc:urls:1:abc'                    => [ { type => 'discogs', url => 'u' } ],
    'dsc:cand:4:0.55.1:qobuz:mb:abc'    => { items => [ { _candTitle => 'X' } ], unresolved => 1 },
    'dsc:svcartimg:v1:madness'          => '',
    'dsc:bio:2:abc'                     => "bio text",
    'dsc:rev:2:abc'                     => '',
    'dsc:artimg:v1:madness'             => 'http://img',
    'dsc:similar:v1:abc'                => [ 'The Specials' ],
    'dsc:asearch:11:madness'            => [ { name => 'Madness', sources => ['Qobuz'] } ],
);
{
    fresh();
    my $s = $DB->store('1.0');
    $s->set($_, $FAMILY{$_}, 3600) for sort keys %FAMILY;
    for my $k (sort keys %FAMILY) {
        my $got = $s->get($k);
        ok(defined $got && deep($got) eq deep($FAMILY{$k}), "2: $k round-trips");
    }
    my $h = raw();
    my %inMbid = map { $_->[0] => 1 } @{ $h->selectall_arrayref('SELECT k FROM mbid') };
    my %inKv   = map { $_->[0] => 1 } @{ $h->selectall_arrayref('SELECT k FROM kv') };
    # artist rows hold a column per answer; rebuild the key each column came from
    my %inArtist;
    for my $r (@{ $h->selectall_arrayref('SELECT mbid, name_v, name IS NOT NULL, aliases_v, aliases IS NOT NULL FROM artist') }) {
        $inArtist{"dsc:mbname:$r->[1]:$r->[0]"} = 1 if $r->[2];
        $inArtist{"dsc:alias:$r->[3]:$r->[0]"}  = 1 if $r->[4];
    }
    for my $k (sort keys %FAMILY) {
        my $want = $k =~ /^dsc:(?:mbid|rel2rg):/   ? 'mbid'
                 : $k =~ /^dsc:(?:mbname|alias):/  ? 'artist' : 'kv';
        my @in   = grep { $_->[1] } [mbid => $inMbid{$k}], [artist => $inArtist{$k}], [kv => $inKv{$k}];
        my $in   = @in == 1 ? $in[0][0] : @in ? 'several' : 'none';
        ok($in eq $want, "2: $k is stored in $want (got $in)");
    }
    my $row = $h->selectrow_hashref("SELECT * FROM mbid WHERE k = 'dsc:mbid:2:radiohead'");
    ok($row->{kind} eq 'artist' && $row->{lookup} eq 'radiohead', '2: artist row carries kind + lookup');
    $row = $h->selectrow_hashref("SELECT * FROM mbid WHERE k = 'dsc:rel2rg:v1:rel-1'");
    ok($row->{kind} eq 'release' && $row->{lookup} eq 'rel-1' && $row->{mbid} eq 'rg-1',
       '2: release row carries kind + lookup + mbid');
    my $n = $DB->counts;
    ok($n->{mbid} == 4 && $n->{artist} == 1 && $n->{kv} == keys(%FAMILY) - 6,
       '2: counts() = 4 mbid rows, 1 artist row (name + aliases), the rest kv');
    $h->disconnect;

    ok(!defined $s->get('dsc:never:set'), '2: an absent key reads undef');
    ok($s->remove('dsc:mbid:2:radiohead') && !defined $s->get('dsc:mbid:2:radiohead'),
       '2: remove works on the mbid table');
    ok($s->remove('dsc:bio:2:abc') && !defined $s->get('dsc:bio:2:abc'), '2: remove works on kv');

    # A reference stored under an mbid key (no caller does this) must not be lost.
    $s->set('dsc:mbid:2:odd', [1, 2], 3600);
    ok(deep($s->get('dsc:mbid:2:odd')) eq deep([1, 2]), '2: a ref under an mbid key round-trips (kv)');
    $s->set('dsc:mbid:2:odd', 'm', 3600);
    my $h3 = raw();
    my ($inkv) = $h3->selectrow_array("SELECT COUNT(*) FROM kv WHERE k = 'dsc:mbid:2:odd'");
    ok($s->get('dsc:mbid:2:odd') eq 'm' && $inkv == 0, '2: a later scalar replaces it in the mbid table');
    $h3->disconnect;
}

# ---------------------------------------------------------------------------
# 3. Lifetimes.
{
    fresh();
    my $s = $DB->store('1.0');
    $s->set('dsc:bio:2:long', 'kept', 90 * 86400);
    ok(($s->get('dsc:bio:2:long') // '') eq 'kept', '3: a 90-day lifetime is kept (no 1970 trap)');
    $s->set('dsc:bio:2:old', 'x', 3600);
    $s->set('dsc:mbid:2:old', 'y', 3600);
    my $h = raw();
    $h->do('UPDATE kv   SET expires_at = ? WHERE k = ?', undef, time() - 5, 'dsc:bio:2:old');
    $h->do('UPDATE mbid SET expires_at = ? WHERE k = ?', undef, time() - 5, 'dsc:mbid:2:old');
    ok(!defined $s->get('dsc:bio:2:old'),  '3: an expired kv entry reads undef');
    ok(!defined $s->get('dsc:mbid:2:old'), '3: an expired mbid entry reads undef');
    my ($left) = $h->selectrow_array(
        "SELECT (SELECT COUNT(*) FROM kv WHERE k='dsc:bio:2:old') + (SELECT COUNT(*) FROM mbid WHERE k='dsc:mbid:2:old')");
    ok($left == 0, '3: expired rows are deleted on read');
    $h->disconnect;

    # the sweep on open
    $s->set('dsc:bio:2:sweep', 'x', 3600);
    my $h2 = raw();
    $h2->do('UPDATE kv SET expires_at = ? WHERE k = ?', undef, time() - 5, 'dsc:bio:2:sweep');
    $h2->disconnect;
    $DB->_reset; $DB->store('1.0'); $DB->dbh;
    my $h4 = raw();
    my ($sw) = $h4->selectrow_array("SELECT COUNT(*) FROM kv WHERE k = 'dsc:bio:2:sweep'");
    ok($sw == 0, '3: an expired row is swept when the file is opened');
    $h4->disconnect;
}

# ---------------------------------------------------------------------------
# 4. CACHE_VERSION change: kv emptied, mbid kept; same version: nothing emptied.
{
    fresh();
    my $s = $DB->store('1.0');
    $s->set('dsc:bio:2:v', 'kv row', 3600);
    $s->set('dsc:mbid:2:v', 'mbid row', 3600);

    $DB->_reset;
    $s = $DB->store('1.0');
    ok(($s->get('dsc:bio:2:v') // '') eq 'kv row', '4: same version reopened: kv kept');

    $DB->_reset;
    $s = $DB->store('2.0');
    ok(!defined $s->get('dsc:bio:2:v'), '4: new version: kv emptied');
    ok(($s->get('dsc:mbid:2:v') // '') eq 'mbid row', '4: new version: mbid table kept');

    $DB->_reset;
    $s = $DB->store('2.0');
    $DB->store('3.0');   # a later caller with another version is ignored
    $s->set('dsc:bio:2:w', 'y', 3600);
    $DB->_reset; $s = $DB->store('2.0');
    ok(($s->get('dsc:bio:2:w') // '') eq 'y', '4: the first store() version wins');
}

# ---------------------------------------------------------------------------
# 4b. The artist record: kept with the id across a build, one stamp per answer.
{
    fresh();
    my $s = $DB->store('1.0');
    $s->set('dsc:mbid:2:british sea power', 'm-bsp', 3600);
    $s->set('dsc:mbname:1:m-bsp', 'Sea Power', 3600);
    $s->set('dsc:alias:2:m-bsp', ['British Sea Power'], 3600);

    $DB->_reset;
    $s = $DB->store('2.0');   # a new build
    ok(($s->get('dsc:mbid:2:british sea power') // '') eq 'm-bsp', '4b: new build: the artist id is kept');
    ok(($s->get('dsc:mbname:1:m-bsp') // '') eq 'Sea Power',
       '4b: new build: its canonical name is kept WITH it (the 0.45.0 case)');
    ok(deep($s->get('dsc:alias:2:m-bsp')) eq deep(['British Sea Power']), '4b: new build: its aliases are kept');

    ok(!defined $s->get('dsc:mbname:9:m-bsp'), '4b: a bumped key version is not served the old answer');
    ok(!defined $s->get('dsc:alias:1:m-bsp'),  '4b: ...for aliases too');

    my $h = raw();
    $h->do("UPDATE artist SET name_exp = ? WHERE mbid = 'm-bsp'", undef, time() - 5);
    ok(!defined $s->get('dsc:mbname:1:m-bsp'), '4b: the name expires on its own stamp');
    ok(deep($s->get('dsc:alias:2:m-bsp')) eq deep(['British Sea Power']),
       '4b: ...without taking the aliases with it');

    $s->remove('dsc:alias:2:m-bsp');
    my ($rows) = $h->selectrow_array("SELECT COUNT(*) FROM artist WHERE mbid = 'm-bsp'");
    ok(!defined $s->get('dsc:alias:2:m-bsp') && $rows == 0,
       '4b: removing the last answer removes the row');

    $s->set('dsc:mbname:1:m-x', 'X', 3600);
    $s->set('dsc:alias:2:m-x', ['Y'], 3600);
    $h->do("UPDATE artist SET aliases_exp = ? WHERE mbid = 'm-x'", undef, time() - 5);
    $h->disconnect;
    $DB->_reset; $s = $DB->store('2.0'); $DB->dbh;
    my $h2 = raw();
    my $r = $h2->selectrow_hashref("SELECT name IS NOT NULL AS n, aliases IS NOT NULL AS a FROM artist WHERE mbid = 'm-x'");
    ok($r && $r->{n} && !$r->{a}, '4b: the sweep clears an expired answer and keeps the other');
    $h2->disconnect;
}

# ---------------------------------------------------------------------------
# 5. Key identity, as LMS's cache gave it.
{
    fresh();
    my $s = $DB->store('1.0');
    # "\x{e9}" alone is NOT a character string in Perl (below 256 it stays a
    # byte), so upgrade it explicitly, as a from_json name arrives.
    my $chars = "dsc:bio:2:caf\x{e9}"; utf8::upgrade($chars);
    my $bytes = "dsc:bio:2:caf\xe9";   utf8::downgrade($bytes);
    ok(utf8::is_utf8($chars) && !utf8::is_utf8($bytes), '5: fixture: one key flagged, one not');
    $s->set($chars, 'v', 3600);
    ok(($s->get($bytes) // '') eq 'v', '5: a Latin-1 character key and its bytes are one key');
    my $wide = "dsc:bio:2:\x{41a}\x{438}\x{43d}\x{43e}";   # Кино
    ok($s->set($wide, "\x{41a}\x{438}\x{43d}\x{43e} bio", 3600), '5: a wide-character key is written');
    ok(($s->get($wide) // '') eq "\x{41a}\x{438}\x{43d}\x{43e} bio", '5: ...and a wide-character value reads back');
    my $enc = $wide; utf8::encode($enc);
    ok(($s->get($enc) // '') eq "\x{41a}\x{438}\x{43d}\x{43e} bio", '5: its UTF-8 bytes are the same key');
}

# ---------------------------------------------------------------------------
# 6. Degrade, never die.
{
    $DB->_reset;
    $DIR = "$tmp/no/such/dir";
    my $s = $DB->store('1.0');
    my $r = eval { [ $s->get('dsc:bio:2:x'), $s->set('dsc:bio:2:x', 'v', 60), $s->remove('dsc:bio:2:x') ] };
    ok($r && !defined $r->[0] && $r->[1] == 0 && $r->[2] == 0,
       '6: an unopenable file reads undef and writes fail quietly');
    ok(ref $DB->counts eq 'HASH', '6: counts() does not die either');
}

# ---------------------------------------------------------------------------
# 7. The real API module, on the real store.
{
    fresh();
    require Plugins::Discography::API;
    my $key = Plugins::Discography::API::_mbidKey('Radiohead');
    ok($key =~ /^dsc:mbid:/, '7: API builds a dsc:mbid: key');
    Plugins::Discography::DB::set($key, 'a74b1b7f', 3600);
    my $h = raw();
    my ($n) = $h->selectrow_array('SELECT COUNT(*) FROM mbid WHERE k = ?', undef, $key);
    ok($n == 1, "7: API's artist-mbid key lands in the mbid table");
    Plugins::Discography::API->clearArtistMbid('Radiohead');
    ($n) = $h->selectrow_array('SELECT COUNT(*) FROM mbid WHERE k = ?', undef, $key);
    ok($n == 0, '7: API->clearArtistMbid removes it');
    Plugins::Discography::API->markArtistEmpty('abc');
    ok(Plugins::Discography::API->peekArtistEmpty('abc'), '7: API markArtistEmpty/peekArtistEmpty round-trip via kv');

    # The API's own name and alias keys land in the artist table and survive a build.
    Plugins::Discography::API::_setMbName('m-bsp', "Sea Power");
    my $nk = Plugins::Discography::API::_mbNameKey('m-bsp');
    my $ak = Plugins::Discography::API::_aliasKey('m-bsp');
    Plugins::Discography::DB::set($ak, ['British Sea Power'], 3600);
    my ($n2) = $h->selectrow_array(
        "SELECT COUNT(*) FROM artist WHERE mbid = 'm-bsp' AND name IS NOT NULL AND aliases IS NOT NULL");
    ok($n2 == 1, "7: API's canonical-name and alias keys land in the artist table");
    $h->disconnect;
    $DB->_reset; $DB->store('9.9');   # a new build
    ok((Plugins::Discography::DB::get($nk) // '') eq 'Sea Power', "7: API's canonical name survives a build");
}

# ---------------------------------------------------------------------------
# 8. Expired rows are collected on a timer, not only when the file is opened.
{
    fresh();
    @TIMERS = ();
    my $s = $DB->store('1.0');
    $DB->dbh;
    ok(@TIMERS == 1, '8: opening the store arms one sweep timer');
    $s->set('dsc:asearch:11:gone', ['x'], 600);
    $s->set('dsc:mbid:2:gone', 'm', 3600);
    my $h = raw();
    $h->do('UPDATE kv   SET expires_at = ? WHERE k = ?', undef, time() - 5, 'dsc:asearch:11:gone');
    $h->do('UPDATE mbid SET expires_at = ? WHERE k = ?', undef, time() - 5, 'dsc:mbid:2:gone');
    # Take the callback OUT of the list before firing it: left in, "one timer
    # armed" would still hold if the tick never re-armed.
    my $tick = shift @TIMERS;
    $tick->() if $tick;
    my ($left) = $h->selectrow_array(
        "SELECT (SELECT COUNT(*) FROM kv WHERE k='dsc:asearch:11:gone') + (SELECT COUNT(*) FROM mbid WHERE k='dsc:mbid:2:gone')");
    ok($tick && $left == 0, '8: the timer sweep removes expired rows nothing has read');
    ok(@TIMERS == 1, '8: ...and re-arms itself');
    $h->disconnect;
}

# ---------------------------------------------------------------------------
# 9. Rows from an old key version are retired.
{
    fresh();
    my $s = $DB->store('1.0');
    $s->set('dsc:mbid:1:old',   'a', 3600);
    $s->set('dsc:mbid:2:cur',   'b', 3600);
    $s->set('dsc:rel2rg:v0:r',  'x', 3600);
    $s->set('dsc:rel2rg:v1:r',  'y', 3600);
    $s->set('dsc:mbname:0:m',   'Old', 3600);
    $s->set('dsc:mbname:1:m2',  'Cur', 3600);
    $s->set('dsc:alias:1:m2',   ['old alias'], 3600);
    $DB->keepCurrent('dsc:mbid:2:', 'dsc:rel2rg:v1:', 'dsc:mbname:1:', 'dsc:alias:2:');
    my $h = raw();
    my %mb = map { $_->[0] => 1 } @{ $h->selectall_arrayref('SELECT k FROM mbid') };
    ok(!$mb{'dsc:mbid:1:old'} && !$mb{'dsc:rel2rg:v0:r'}, '9: old-version id rows are deleted');
    ok($mb{'dsc:mbid:2:cur'} && $mb{'dsc:rel2rg:v1:r'}, '9: current-version id rows are kept');
    my ($oldName) = $h->selectrow_array("SELECT COUNT(*) FROM artist WHERE mbid = 'm'");
    my $r = $h->selectrow_hashref("SELECT name IS NOT NULL AS n, aliases IS NOT NULL AS a FROM artist WHERE mbid = 'm2'");
    ok($oldName == 0, '9: an artist row holding only an old-version answer is deleted');
    ok($r && $r->{n} && !$r->{a}, '9: an old-version answer is cleared, the current one beside it kept');
    $h->disconnect;
}

# ---------------------------------------------------------------------------
# 10. The REAL API registers its current prefixes: an old row goes at open.
{
    fresh();
    $DB->store('1.0'); $DB->dbh;
    my $h = raw();
    $h->do("INSERT INTO mbid (k, kind, lookup, mbid, fetched_at, expires_at)
            VALUES ('dsc:mbid:1:zz', 'artist', 'zz', 'old', ?, 0)", undef, time());
    my $cur = Plugins::Discography::API::_mbidKey('zz');
    $h->do("INSERT INTO mbid (k, kind, lookup, mbid, fetched_at, expires_at)
            VALUES (?, 'artist', 'zz', 'cur', ?, 0)", undef, $cur, time());
    $h->disconnect;
    $DB->_reset;
    {   # re-run API's load-time registration, as a server start would
        no warnings 'redefine';
        delete $INC{'Plugins/Discography/API.pm'};
        local $SIG{__WARN__} = sub {};
        require Plugins::Discography::API;
    }
    $DB->store('1.0'); $DB->dbh;
    my $h2 = raw();
    my %mb = map { $_->[0] => 1 } @{ $h2->selectall_arrayref('SELECT k FROM mbid') };
    ok(!$mb{'dsc:mbid:1:zz'} && $mb{$cur}, "10: API's own key version decides what is retired");
    $h2->disconnect;
}

# ---------------------------------------------------------------------------
# 11. Refresh (clearArtistCache) clears what the store now keeps across builds.
{
    fresh();
    my $API = 'Plugins::Discography::API';
    my @localArgs;
    my $JSON;
    {
        no warnings 'redefine'; no strict 'refs';
        *{'Plugins::Discography::Sources::localAlbums'} = sub {
            @localArgs = @_[1 .. 4];
            return [ { _mbid => 'rel-mine' } ];
        };
        *{'Plugins::Discography::API::from_json'} = sub { $JSON };
        *{'Plugins::Discography::API::_netGet'}   = sub { $_[1]->(bless {}, 'T::Resp') };
    }
    $JSON = { name => 'Old Name', aliases => [ { name => 'Alt Name' } ] };
    $API->warmArtistAliases('m-r', sub {});
    ok(($API->peekArtistName('m-r') // '') eq 'Old Name', '11: fixture: name held (store + memo)');
    ok(@{ $API->peekArtistAliases('m-r') || [] } == 1, '11: fixture: aliases held');
    Plugins::Discography::DB::set(Plugins::Discography::API::_rel2rgKey('rel-mine'),  'rg-a', 3600);
    Plugins::Discography::DB::set(Plugins::Discography::API::_rel2rgKey('rel-other'), 'rg-b', 3600);

    $API->clearArtistCache(name => 'Some Artist', mbid => 'm-r', artist_id => 7);
    ok(!defined $API->peekArtistName('m-r'), "11: Refresh clears MusicBrainz's name (store AND memo)");
    ok(!defined $API->peekArtistAliases('m-r'), '11: Refresh clears the aliases');
    ok(!defined Plugins::Discography::DB::get(Plugins::Discography::API::_rel2rgKey('rel-mine')),
       "11: Refresh clears an owned release's group");
    ok((Plugins::Discography::DB::get(Plugins::Discography::API::_rel2rgKey('rel-other')) // '') eq 'rg-b',
       "11: ...and leaves another artist's release alone");
    ok(($localArgs[0] // '') eq '7' && ($localArgs[1] // '') eq 'Some Artist' && ($localArgs[2] // '') eq 'm-r',
       '11: the owned albums are asked for with artist_id, name and mbid (as the page asks)');
    # The page passes its id fallback (Browse::_idFallback); without it an id that
    # performs on no album (The B-52's composer credit) found nothing to clear.
    ok(ref $localArgs[3] eq 'HASH' && ($localArgs[3]{fallback} // '') eq 'name',
       "11: ... with the id fallback in 'name' mode (a superset of the page's albums)");

    $JSON = { name => 'New Name', aliases => [] };
    $API->warmArtistAliases('m-r', sub {});
    ok(($API->peekArtistName('m-r') // '') eq 'New Name', '11: the next lookup re-pulls the new name');
}

# 11b. An artist_id that performs on NO album (The B-52's composer credit): the
#      page finds its albums only through the id fallback, so Refresh must too,
#      or those albums' groups outlive every Refresh (a stale `reid:` answer
#      then stays for REL2RG_TTL). The stub answers as localAlbums does for such
#      an id: nothing, unless a fallback is asked for.
{
    fresh();
    my $API = 'Plugins::Discography::API';
    {
        no warnings 'redefine'; no strict 'refs';
        *{'Plugins::Discography::Sources::localAlbums'} = sub {
            my $opt = $_[4] || {};
            return $opt->{fallback} ? [ { _mbid => 'rel-fb' } ] : [];
        };
    }
    Plugins::Discography::DB::set(Plugins::Discography::API::_rel2rgKey('rel-fb'), 'rg-old', 3600);
    $API->clearArtistCache(name => "The B-52's", mbid => 'm-52', artist_id => 137553);
    ok(!defined Plugins::Discography::DB::get(Plugins::Discography::API::_rel2rgKey('rel-fb')),
       '11b: Refresh on a composer-only id clears the groups of the albums its page shows');
}

package T::Resp; sub content { '{}' } sub error { '' }
package main;

# 11c. Clearing by LIBRARY ID finds the mbid the page uses: the library tag
#      first, as getArtistMbid resolves (0.56.15). Field: `clearcache
#      artist_id:154055` (Radiohead, tagged) found nothing under the name,
#      cleared only name-keyed pools, and the next open read the MB-keyed one.
{
    fresh();
    my $API = 'Plugins::Discography::API';
    my $TAG = 'a74b1b7f-71a5-4011-9441-d0b5e4122711';
    my $NAM = '11111111-2222-3333-4444-555555555555';
    my %TAGS = (154055 => $TAG);
    {
        no warnings 'redefine'; no strict 'refs';
        $INC{'Slim/Schema.pm'} = 1;
        *{'Slim::Schema::find'} = sub { my ($c, $t, $id) = @_; bless { m => $TAGS{$id} }, 'T::TagC' };
        *{'T::TagC::musicbrainz_id'} = sub { $_[0]{m} };
        *{'Plugins::Discography::Sources::localAlbums'} = sub { [] };
    }
    Plugins::Discography::DB::set(Plugins::Discography::API::_rgKey($TAG), [ 'x' ], 3600);
    my ($cl, $used) = $API->clearArtistCache(name => 'Radiohead', artist_id => 154055);
    ok(($used // '') eq $TAG, '11c: an artist_id with a library tag clears under the TAG mbid');
    ok(!defined Plugins::Discography::DB::get(Plugins::Discography::API::_rgKey($TAG)),
       "11c: ... and that mbid's release groups are gone");

    Plugins::Discography::DB::set(Plugins::Discography::API::_mbidKey('Radiohead'), $NAM, 3600);
    ($cl, $used) = $API->clearArtistCache(name => 'Radiohead', artist_id => 154055);
    ok(($used // '') eq $TAG, "11c: the tag wins over the name's cached mbid, as the page resolves");
    ($cl, $used) = $API->clearArtistCache(name => 'Radiohead', artist_id => 154055, mbid => $NAM);
    ok(($used // '') eq $NAM, '11c: control: an mbid passed in is still used as given');
    Plugins::Discography::DB::set(Plugins::Discography::API::_mbidKey('Radiohead'), $NAM, 3600);
    ($cl, $used) = $API->clearArtistCache(name => 'Radiohead', artist_id => 999);
    ok(($used // '') eq $NAM, "11c: control: an untagged artist_id falls back to the name's mbid, as before");
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
