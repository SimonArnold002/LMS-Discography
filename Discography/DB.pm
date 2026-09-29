package Plugins::Discography::DB;

# PLUGIN-OWNED STORAGE: one SQLite file, <cachedir>/discography.db, replacing
# Slim::Utils::Cache for everything Discography keeps.
#
# WHY. The fleet decision (LBF docs/caching-rework.md §2.1, "do not re-open"):
# "Everything moves out of Slim::Utils::Cache into a plugin-owned SQLite
# database, as PFR did." Pitchfork Reviews, ListenBrainz Fresh Releases, Listen
# to Later and Listening History all have one; this is Discography's. The LMS
# cache reads any lifetime over 30 days as an absolute date in 1970
# (DbCache::_canonicalize_expiration_time), is emptied whenever the version
# handed to it changes, and is disposable by design. Here `expires_at` is always
# an absolute epoch computed in Perl, 0 meaning never, so no duration can
# silently mean "already expired".
#
# THE FILE NAME IS REUSED ON PURPOSE (Simon, 2026-09-25). `discography.db` was
# the file LMS kept for this plugin's cache namespace (DbCache::_get_dbfile names
# it <cachedir>/<namespace>.db). Nothing in it needs keeping, and once no module
# calls Slim::Utils::Cache->new('discography') LMS never opens it again, so this
# module takes it over and migration 1 drops LMS's `cache` table and its index.
# The switch MUST be complete in one build: LMS's cache code deletes the whole
# file when it cannot open it (`unlink $dbfile`), so the two must never share it.
# (On Windows LMS hashed namespaces longer than 8 characters, so there the cache
# file was never called discography.db; nothing to take over.)
#
# TWO TABLES, BY HOW THEY ARE INVALIDATED:
#
#   kv    every cache family, exactly as before (same keys, same lifetimes).
#         Emptied when CACHE_VERSION changes, which is what
#         Slim::Utils::Cache->new(NS, CACHE_VERSION) did: every build still
#         clears these (Simon, 2026-07-22).
#   mbid  MusicBrainz ids the plugin resolved: artist name -> artist mbid
#         (`dsc:mbid:<v>:<name>`) and owned release -> release group
#         (`dsc:rel2rg:<v>:<release>`). NOT emptied by a build (Simon,
#         2026-09-25: "we need a new one for storing mbids"). Lifetimes are
#         unchanged (found 30d / miss 1h; releases 14d), so a stored id is still
#         re-asked on the same schedule; a change to how names resolve must bump
#         API::MBID_CACHE_V, which changes the key (the fleet rule: a resolve fix
#         needs a cache bump). Refresh and `clearcache` remove rows here exactly as
#         they removed the cache entries.
#   artist  what MusicBrainz says about an artist mbid, kept WITH the id: its
#         canonical name (`dsc:mbname:<v>:<mbid>`) and its aliases
#         (`dsc:alias:<v>:<mbid>`). LBF's `artist` table shape: one row per mbid,
#         one column + version + time + expiry PER ANSWER, so one answer never
#         re-ages another. NOT emptied by a build. WHY THEY CANNOT STAY IN kv: a
#         name lookup writes the id and the canonical name together, and a cache
#         HIT on the id returns without writing the name again. With the id kept
#         and the name wiped, the first page after every build searched the
#         services without MusicBrainz's name (British Sea Power lost Qobuz again,
#         the 0.45.0 case) until the band lookup refilled it.
#
# The call sites do not change: `store()` returns an object answering get / set
# / remove like Slim::Utils::Cache, and routes these families to their tables by
# key prefix (LBF's approach: its ~120 call sites were not touched). A key's
# version is stored with the answer and must match to be served, so bumping a
# family's key version still invalidates it here.
#
# DEGRADE, NEVER DIE. Without the file the plugin re-fetches, as it would with a
# cold cache.

use strict;
use warnings;

use DBI;
use Storable ();

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $log = logger('plugin.discography');

my $dbh;       # lazily-opened handle
my $broken;    # latched once the file cannot be opened: complain once, degrade
my $version;   # CACHE_VERSION, from the first store() call

my @ARTIST_COLS = qw(name aliases);   # the answers an `artist` row holds (see _artistRoute)
my %ARTIST_FAMILY = ('dsc:mbname:' => 'name', 'dsc:alias:' => 'aliases');

# family ('dsc:mbid:') => [ current version, current prefix ('dsc:mbid:2:') ]
my %current;

# Collect expired rows on a timer, not only when the file is opened. PFR learned
# this the hard way (its DB.pm, kvSweep): a sweep on open fires once per server
# start, the rows that need collecting are the ones nothing reads again, so on
# a server that stays up the tables grow with uptime. The LMS cache this store
# replaced purged on its own cycle, so without this Discography would regress.
use constant SWEEP_INTERVAL => 6 * 3600;

use constant SCHEMA_VERSION => 1;

sub _path {
    my $dir = preferences('server')->get('cachedir') || '/tmp';
    return "$dir/discography.db";
}

# The modules call Plugins::Discography::DB->store(CACHE_VERSION) at load. The
# three pass the same version (tools/syntax_check.sh asserts it); the first wins.
sub store {
    my (undef, $v) = @_;
    $version = $v if defined $v && !defined $version;
    return bless {}, 'Plugins::Discography::DB::Store';
}

sub dbh {
    return undef if $broken;
    return $dbh if $dbh;

    my $path = _path();
    $dbh = eval {
        my $h = DBI->connect("dbi:SQLite:dbname=$path", '', '', {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
        });
        $h->do('PRAGMA journal_mode=WAL');
        _migrate($h);
        _checkVersion($h);
        _sweep($h);
        _retire($h);
        $h;
    };

    unless ($dbh) {
        $broken = 1;
        $log->error("dsc: store unavailable at $path ($@) - re-fetching instead");
        return undef;
    }
    _armSweep();
    return $dbh;
}

sub _armSweep {
    eval {
        Slim::Utils::Timers::killTimers(undef, \&_sweepTick);
        Slim::Utils::Timers::setTimer(undef, time() + SWEEP_INTERVAL, \&_sweepTick);
        1;
    } or $log->warn("dsc: could not schedule the store sweep: $@");
    return;
}

sub _sweepTick {
    if (my $h = dbh()) {
        eval { _sweep($h); 1 } or $log->warn("dsc: store sweep failed: $@");
    }
    _armSweep();
    return;
}

# KEYS FROM AN OLD VERSION, retired at open (PFR's _retireOldStreamKeys, LBF's
# retirePrefixes). The kept tables (mbid, artist) are not emptied by a build, so
# after a key-version bump the old rows would otherwise sit there, never read,
# until they expired. API.pm registers the CURRENT prefix of each kept family by
# calling its own key builders with an empty argument (`_mbidKey('')` is
# 'dsc:mbid:2:'), so the version exists in exactly one place.
sub keepCurrent {
    my (undef, @prefixes) = @_;
    for my $p (@prefixes) {
        next unless defined $p && $p =~ /\A(dsc:[a-z0-9]+:)([^:]*):\z/;
        $current{$1} = [ $2, $p ];
    }
    eval { _retire($dbh); 1 } if $dbh;
    return;
}

sub _retire {
    my ($h) = @_;
    my $n = 0;
    for my $fam (sort keys %current) {
        my ($v, $p) = @{ $current{$fam} };
        if (my $c = $ARTIST_FAMILY{$fam}) {
            $n += $h->do("UPDATE artist SET $c = NULL, ${c}_v = '', ${c}_exp = 0
                          WHERE $c IS NOT NULL AND ${c}_v <> ?", undef, $v);
        }
        else {
            $n += $h->do('DELETE FROM mbid WHERE substr(k, 1, ?) = ? AND substr(k, 1, ?) <> ?',
                         undef, length($fam), $fam, length($p), $p);
        }
    }
    $h->do('DELETE FROM artist WHERE name IS NULL AND aliases IS NULL');
    $log->info("dsc: store retired $n answer(s) from an old key version") if $n > 0;
    return;
}

sub _migrate {
    my ($h) = @_;
    my ($have) = $h->selectrow_array('PRAGMA user_version');
    $have ||= 0;
    return if $have >= SCHEMA_VERSION;

    if ($have < 1) {
        $h->begin_work;
        # LMS's own cache table (DbCache::_init_db). Never a name used here.
        $h->do('DROP INDEX IF EXISTS expiry');
        $h->do('DROP TABLE IF EXISTS cache');
        $h->do('CREATE TABLE IF NOT EXISTS kv (
                    k          TEXT PRIMARY KEY,
                    v          BLOB,
                    expires_at INTEGER NOT NULL DEFAULT 0)');
        $h->do('CREATE INDEX IF NOT EXISTS kv_expiry ON kv (expires_at)');
        $h->do('CREATE TABLE IF NOT EXISTS mbid (
                    k          TEXT PRIMARY KEY,
                    kind       TEXT NOT NULL,
                    lookup     TEXT NOT NULL,
                    mbid       TEXT NOT NULL,
                    fetched_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL DEFAULT 0)');
        $h->do('CREATE INDEX IF NOT EXISTS mbid_expiry ON mbid (expires_at)');
        $h->do('CREATE TABLE IF NOT EXISTS artist (
                    mbid        TEXT PRIMARY KEY,
                    name        BLOB,
                    name_v      TEXT    NOT NULL DEFAULT \'\',
                    name_at     INTEGER NOT NULL DEFAULT 0,
                    name_exp    INTEGER NOT NULL DEFAULT 0,
                    aliases     BLOB,
                    aliases_v   TEXT    NOT NULL DEFAULT \'\',
                    aliases_at  INTEGER NOT NULL DEFAULT 0,
                    aliases_exp INTEGER NOT NULL DEFAULT 0)');
        $h->do('CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)');
        $h->commit;
        $h->do('PRAGMA user_version = 1');
    }
    return;
}

# The per-build clear Slim::Utils::Cache->new(NS, CACHE_VERSION) used to do.
# kv only; the mbid table is kept (see the header).
sub _checkVersion {
    my ($h) = @_;
    return unless defined $version;
    my ($have) = $h->selectrow_array("SELECT v FROM meta WHERE k = 'cache_version'");
    return if defined $have && $have eq $version;
    $h->do('DELETE FROM kv');
    $h->do("INSERT OR REPLACE INTO meta (k, v) VALUES ('cache_version', ?)", undef, $version);
    $log->info("dsc: store emptied for version $version (was " . ($have // 'none') . ')');
    return;
}

sub _sweep {
    my ($h) = @_;
    my $now = time();
    $h->do('DELETE FROM kv   WHERE expires_at > 0 AND expires_at < ?', undef, $now);
    $h->do('DELETE FROM mbid WHERE expires_at > 0 AND expires_at < ?', undef, $now);
    for my $c (@ARTIST_COLS) {
        $h->do("UPDATE artist SET $c = NULL, ${c}_v = '', ${c}_exp = 0
                WHERE ${c}_exp > 0 AND ${c}_exp < ?", undef, $now);
    }
    $h->do('DELETE FROM artist WHERE name IS NULL AND aliases IS NULL');
    return;
}

# One identity per key, the one LMS's cache gave it: DbCache hashed the key with
# Digest::MD5, which downgrades a character string to its Latin-1 bytes (and
# died on anything wider, which is why the callers encode). Same rule here, with
# an encode instead of a death for wide characters.
sub _key {
    my ($k) = @_;
    return undef unless defined $k && length $k;
    if (utf8::is_utf8($k)) { utf8::downgrade($k, 1) or utf8::encode($k) }
    return $k;
}

# The two MusicBrainz-id families -> (kind, lookup). Anything else is kv.
sub _mbidRoute {
    my ($k) = @_;
    return ('artist',  $1) if $k =~ /\Adsc:mbid:[^:]*:(.*)\z/s;
    return ('release', $1) if $k =~ /\Adsc:rel2rg:[^:]*:(.*)\z/s;
    return;
}

# The artist-record families -> (column, key version, artist mbid). The column is
# always one of @ARTIST_COLS, which is what makes interpolating it into SQL safe.
sub _artistRoute {
    my ($k) = @_;
    return ('name',    $1, $2) if $k =~ /\Adsc:mbname:([^:]*):(.+)\z/s;
    return ('aliases', $1, $2) if $k =~ /\Adsc:alias:([^:]*):(.+)\z/s;
    return;
}

sub _freeze { Storable::nfreeze({ v => $_[0] }) }

sub _thaw {
    my ($blob) = @_;
    return undef unless defined $blob;
    my $w = eval { Storable::thaw($blob) };
    return ref $w eq 'HASH' ? $w->{v} : undef;
}

sub get {
    my ($key) = @_;
    my $h = dbh()          or return undef;
    my $k = _key($key)     // return undef;

    if (_mbidRoute($k)) {
        my $row = eval { $h->selectrow_arrayref(
            'SELECT mbid, expires_at FROM mbid WHERE k = ?', undef, $k) };
        if ($row) {
            return $row->[0] unless $row->[1] && $row->[1] < time();
            eval { $h->do('DELETE FROM mbid WHERE k = ?', undef, $k) };
            return undef;
        }
        # fall through: a reference stored under an mbid key lives in kv
    }
    elsif (my ($col, $kv, $mbid) = _artistRoute($k)) {
        my $row = eval { $h->selectrow_arrayref(
            "SELECT $col, ${col}_v, ${col}_exp FROM artist WHERE mbid = ?", undef, $mbid) };
        return undef unless $row && defined $row->[0] && $row->[1] eq $kv;
        if ($row->[2] && $row->[2] < time()) {
            eval { $h->do("UPDATE artist SET $col = NULL, ${col}_v = '', ${col}_exp = 0
                           WHERE mbid = ?", undef, $mbid) };
            return undef;
        }
        return _thaw($row->[0]);
    }

    my $row = eval { $h->selectrow_arrayref(
        'SELECT v, expires_at FROM kv WHERE k = ?', undef, $k) } or return undef;
    if ($row->[1] && $row->[1] < time()) {
        eval { $h->do('DELETE FROM kv WHERE k = ?', undef, $k) };
        return undef;
    }
    return _thaw($row->[0]);
}

# $ttl is SECONDS FROM NOW (every caller passes a *_TTL constant); undef/0 = never.
sub set {
    my ($key, $value, $ttl) = @_;
    my $h = dbh()          or return 0;
    my $k = _key($key)     // return 0;
    my $now = time();
    my $exp = $ttl ? $now + $ttl : 0;

    my ($kind, $lookup) = _mbidRoute($k);
    my ($col, $kv, $mbid) = _artistRoute($k);
    my $ok = eval {
        if ($col) {
            $h->do('INSERT OR IGNORE INTO artist (mbid) VALUES (?)', undef, $mbid);
            my $sth = $h->prepare_cached(
                "UPDATE artist SET $col = ?, ${col}_v = ?, ${col}_at = ?, ${col}_exp = ? WHERE mbid = ?");
            $sth->bind_param(1, _freeze($value), DBI::SQL_BLOB);
            $sth->bind_param(2, $kv);
            $sth->bind_param(3, $now);
            $sth->bind_param(4, $exp);
            $sth->bind_param(5, $mbid);
            $sth->execute;
        }
        elsif ($kind && defined $value && !ref $value) {
            $h->do('DELETE FROM kv WHERE k = ?', undef, $k);
            $h->do('INSERT OR REPLACE INTO mbid (k, kind, lookup, mbid, fetched_at, expires_at)
                    VALUES (?, ?, ?, ?, ?, ?)', undef, $k, $kind, $lookup, $value, $now, $exp);
        }
        else {
            $h->do('DELETE FROM mbid WHERE k = ?', undef, $k) if $kind;
            my $sth = $h->prepare_cached('INSERT OR REPLACE INTO kv (k, v, expires_at) VALUES (?, ?, ?)');
            $sth->bind_param(1, $k);
            $sth->bind_param(2, _freeze($value), DBI::SQL_BLOB);
            $sth->bind_param(3, $exp);
            $sth->execute;
        }
        1;
    };
    $log->warn("dsc: store write failed for $k: $@") unless $ok;
    return $ok ? 1 : 0;
}

sub remove {
    my ($key) = @_;
    my $h = dbh()          or return 0;
    my $k = _key($key)     // return 0;
    eval {
        $h->do('DELETE FROM mbid WHERE k = ?', undef, $k) if _mbidRoute($k);
        if (my ($col, undef, $mbid) = _artistRoute($k)) {
            $h->do("UPDATE artist SET $col = NULL, ${col}_v = '', ${col}_exp = 0
                    WHERE mbid = ?", undef, $mbid);
            $h->do('DELETE FROM artist WHERE mbid = ? AND name IS NULL AND aliases IS NULL',
                   undef, $mbid);
        }
        $h->do('DELETE FROM kv WHERE k = ?', undef, $k);
        1;
    } or return 0;
    return 1;
}

# Row counts per table, for checks and diagnostics.
sub counts {
    my $h = dbh() or return {};
    my %n;
    for my $t (qw(kv mbid artist)) {
        ($n{$t}) = eval { $h->selectrow_array("SELECT COUNT(*) FROM $t") };
    }
    return \%n;
}

# For the suite: drop the handle so the next dbh() opens whatever cachedir is set.
sub _reset { $dbh->disconnect if $dbh; undef $dbh; undef $broken; undef $version; %current = (); return }

package Plugins::Discography::DB::Store;

sub get    { shift; return Plugins::Discography::DB::get(@_) }
sub set    { shift; return Plugins::Discography::DB::set(@_) }
sub remove { shift; return Plugins::Discography::DB::remove(@_) }

1;
