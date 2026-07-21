package Plugins::Discography::Sources;

# Streaming-source resolution — a port of the Pitchfork Reviews plugin's
# trimmed ListenBrainz engine, restructured for discography scale:
#
#   * PFR resolves ONE album per search (artist query, first-priority winner).
#     Here ONE artist-level search per service is cached and serves EVERY
#     release group of that artist — resolving a 50-release discography costs
#     the same 3 searches as resolving one album.
#   * ALL matching services are kept (the detail page lists every service's
#     version); priority only orders the sections (and later, tile play).
#
# The matcher (_norm/_albumMatches/_artistMatch and helpers) is verbatim from
# the Pitchfork/ListenBrainz plugins — keep in sync if those change.
#
# Candidate cache: dsc:cand:<v>:<svc>:<norm-artist> holds the service's raw
# artist-search results (rendered native album nodes, url coderef stripped —
# Storable can't serialise it — and reattached on read). Per-release matching
# is then a local filter: no API call, safe in sync paths (tile badges).

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Utils::PluginManager;
use Slim::Utils::Timers;
use Slim::Control::Request;

my $log   = Slim::Utils::Log->logger('plugin.discography');
my $prefs = preferences('plugin.discography');
my $cache = Slim::Utils::Cache->new();

sub _dbg { Plugins::Discography::Plugin::dbg(@_) }

use constant CAND_FOUND_TTL => 3 * 86400;   # service discography is stable-ish
use constant CAND_EMPTY_TTL => 1 * 86400;   # artist not on the service
use constant CAND_ERR_TTL   => 3600;        # couldn't query -> retry soon
use constant SVC_TIMEOUT    => 20;          # per-service fetch watchdog (s).
                                            # Sized for the artist-first chain:
                                            # an artist search THEN the artist's
                                            # album list (Tidal: 3 paginated
                                            # bucket pulls). The old 8s was
                                            # sized for a single 50-item search.
use constant MAX_PER_SVC    => 4;           # editions shown per service
use constant POOL_LOG_MAX   => 25;          # log a pool this small IN FULL

# PERFORMANCE roles — the artist must PERFORM (solo, primary, band member or
# guest), not merely have WRITTEN a song that appears. 0.19.0 added this to the
# library album query after Bob Dylan's page filled with albums he only wrote a
# track on (Richard Hawley, George Harrison, Ladysmith Black Mambazo).
#
# ONE constant, used by BOTH the library album query AND the artist SEARCH's
# Local leg, because the two disagreeing is itself a bug: 0.19.0 filtered the
# PAGE and left the SEARCH unfiltered, so a writer-only contributor was offered
# as a "Local" search row and then opened a page that found nothing under them
# (field, Simon: "several artists that claim are local but show no entries" —
# John Bush / Steven Bush / David Bush, composer credits in his library).
# Library rows are also EXEMPT from the dead-end filter, so nothing downstream
# could catch it either. Spelling the policy once is what stops it drifting
# apart again — widen this if composer support is ever built, and both call
# sites widen together.
use constant PERFORMANCE_ROLES => 'ARTIST,ALBUMARTIST,BAND,TRACKARTIST';
use constant CAND_CACHE_V   => '4';         # bump on shape/matcher changes
                                            # v2: flush octet-query poisoned pools
                                            # v3: artist-first pools (search-cap
                                            #     lottery dropped e.g. Valtari)
                                            # v4: candidates carry _year (needed
                                            #     by the same-title rival rule)
use constant SEARCH_TIMEOUT => 10;          # artist-search watchdog (s) — one
                                            # request per service, not the full
                                            # artist-first candidate chain
use constant SEARCH_MAX     => 15;          # artist hits kept per source
use constant SEARCH_MERGED_MAX => 30;       # merged result rows shown

# ---------------------------------------------------------------------------
# Adapters (ported from PFR; Qobuz/Tidal/Deezer only — no Bandcamp by scope)
# ---------------------------------------------------------------------------

sub _pluginIcon {
    my ($class) = @_;
    return eval { $class->_pluginDataFor('icon') } || undef;
}

sub adapters {
    my @adapters;

    # query_enc: what the service plugin's OWN URL layer expects for the search
    # string (verified in each plugin's source, 2026-07-10). Qobuz escapes
    # query params with uri_escape_utf8 and Tidal transliterates them with
    # Text::Unidecode — both need CHARACTER strings (feeding UTF-8 octets
    # double-encodes: "Sigur Rós" searched as "Sigur RÃ³s" -> junk/empty
    # pools). Deezer's complex_to_query percent-encodes bytes -> OCTETS.
    push @adapters, {
        name => 'Qobuz', icon => _pluginIcon('Plugins::Qobuz::Plugin'),
        run  => \&_searchQobuz, artists => \&_artistsQobuz, query_enc => 'chars',
    } if Plugins::Qobuz::Plugin->can('getAPIHandler')
      && Plugins::Qobuz::Plugin->can('_albumItem')
      && Plugins::Qobuz::Plugin->can('QobuzGetTracks');

    push @adapters, {
        name => 'Tidal', icon => _pluginIcon('Plugins::TIDAL::Plugin'),
        run  => \&_searchTidal, artists => \&_artistsTidal, query_enc => 'chars',
    } if Plugins::TIDAL::Plugin->can('getAPIHandler')
      && Plugins::TIDAL::Plugin->can('getAlbum')
      && Plugins::TIDAL::Plugin->can('_renderAlbum');

    push @adapters, {
        name => 'Deezer', icon => _pluginIcon('Plugins::Deezer::Plugin'),
        run  => \&_searchDeezer, artists => \&_artistsDeezer, query_enc => 'bytes',
    } if Plugins::Deezer::Plugin->can('getAPIHandler')
      && Plugins::Deezer::Plugin->can('_renderAlbum')
      && Plugins::Deezer::Plugin->can('getAlbum');

    return @adapters;
}

# Enabled adapters in ascending svc_priority_<name> order, dropping 0 (= off).
sub orderedAdapters {
    my @out;
    for my $a (adapters()) {
        my $prio = $prefs->get('svc_priority_' . lc $a->{name});
        $prio = 1 unless defined $prio;
        next unless $prio > 0;
        push @out, { %$a, priority => $prio };
    }
    return sort { $a->{priority} <=> $b->{priority} } @out;
}

# All sources (Local + streaming) in priority order — the ordering matchesFor
# uses. Local is a pseudo-source: its candidates come from the library DB
# (localAlbums), not a search adapter; svc_priority_local 0 disables it.
sub orderedSources {
    my @out;
    my $lp = $prefs->get('svc_priority_local');
    $lp = 1 unless defined $lp;
    push @out, { name => 'Local', icon => undef, priority => $lp, local => 1 } if $lp > 0;
    push @out, orderedAdapters();
    return sort { $a->{priority} <=> $b->{priority} } @out;
}

# ---------------------------------------------------------------------------
# Local library albums for an artist — SYNC (LMS DB access is synchronous, the
# fleet's accepted pattern) and NOT cached (the library is live; a rescan must
# show immediately). One `albums` CLI query per call; candidates are decorated
# exactly like streaming ones so the matcher treats them identically.
# ---------------------------------------------------------------------------
sub localAlbums {
    my ($class, $artistId, $artist) = @_;
    return [] unless ($prefs->get('svc_priority_local') // 1) > 0;

    # No artist_id (non-library entry surface): resolve by name, norm-verified
    # so a fuzzy `artists search:` can't adopt the wrong artist.
    if (!$artistId && defined $artist && length $artist) {
        my $an  = _norm($artist);
        my $enc = $artist;
        utf8::encode($enc) if utf8::is_utf8($enc);
        my $req = eval { Slim::Control::Request::executeRequest(undef, ['artists', 0, 10, "search:$enc"]) };
        if ($req) {
            for my $e (@{ $req->getResult('artists_loop') || [] }) {
                next unless defined $e->{artist};
                if (_norm($e->{artist}) eq $an) { $artistId = $e->{id}; last }
            }
        }
        return [] unless $artistId;
    }
    return [] unless $artistId;

    # PERFORMANCE roles only — the artist must PLAY on the album, not merely
    # have written a song that appears on it. The default `albums artist_id:`
    # query spans ALL contributor roles (LMS Queries.pm: contributorRoles()),
    # so a covers/compilation album drags in every writer: under Bob Dylan it
    # surfaced Richard Hawley, George Harrison, Ladysmith Black Mambazo — albums
    # Dylan only WROTE a track on (Simon, 2026-07-10). role_id restricts the
    # contributor_album join to these roles (LMS adds ARTIST automatically for
    # ALBUMARTIST when the artists list isn't unified).
    #   ARTIST / ALBUMARTIST -> solo + primary credits
    #   BAND / TRACKARTIST   -> band membership + guest performances (kept:
    #                           "appears on" is fine per the user)
    # KNOWN LIMIT: a band album whose member is tagged ONLY as COMPOSER (no
    # performer credit) drops too — e.g. Marc Almond is COMPOSER-only on Soft
    # Cell's "Non-Stop Erotic Cabaret" in Simon's library, indistinguishable
    # from a write-only cover credit. Separating those needs a MusicBrainz
    # "member of band" lookup (future); no library signal exists (track-fraction
    # fails: that album tags Almond on just 2/18 tracks).
    my $req = eval {
        Slim::Control::Request::executeRequest(undef,
            ['albums', 0, 500, "artist_id:$artistId",
             'role_id:' . PERFORMANCE_ROLES, 'tags:ljya']);
    };
    return [] unless $req;

    # MUSICBRAINZ_ALBUMID off the tags, read straight from the schema: the
    # `albums` CLI query exposes no MusicBrainz tag (verified against LMS 9.0
    # Queries.pm), but Slim::Schema::Album carries musicbrainz_id. It holds a
    # RELEASE mbid, which API::peekReleaseMap turns into a release-GROUP mbid —
    # an exact identity match, no title matching. Guarded: an untagged library
    # or a schema change just falls through to the matcher.
    my $mbidOf = sub {
        my $albumId = shift;
        return eval { require Slim::Schema; Slim::Schema->find('Album', $albumId)->musicbrainz_id } || undef;
    };

    my @out;
    for my $e (@{ $req->getResult('albums_loop') || [] }) {
        my $id    = $e->{id}    or next;
        my $title = $e->{album} // next;
        my $img   = $e->{artwork_track_id} ? "/music/$e->{artwork_track_id}/cover" : undef;
        my $mbid  = $mbidOf->($id);
        push @out, {
            name        => $title,
            type        => 'playlist',
            ($img ? (image => $img) : ()),
            # Playable two ways: `play` is a core db: URL (Commands.pm
            # _parseDbItem resolves album.id -> the album's tracks — the exact
            # path album Favorites replay through), and the row's url feed is
            # the tracklist (drill = track view). The play string is ALSO what
            # makes local-first TILE play work: XMLBrowser's play collects the
            # detail feed's play-string rows (verified in 9.0 source).
            play        => 'db:album.id=' . $id,
            url         => \&_localAlbumTracks,
            passthrough => [{ album_id => $id }],
            _svc        => 'Local',
            _albumid    => $id,
            _cover      => $img,
            _year       => $e->{year},
            _mbid       => ($mbid ? lc $mbid : undef),
            _candTitle  => $title,
            _candArtist => $e->{artist} // $artist,
        };
    }
    _dbg("local albums for artist_id=$artistId: " . scalar @out
        . (@out ? ' | ' . join('; ', map {
              ($_->{_candTitle} // '?') . ' mbid=' . ($_->{_mbid} // 'NONE')
          } @out) : ''));
    return \@out;
}

# Resolve a MusicBrainz band to a library Contributor id: MB id (exact) first,
# then a normalised name match (same discipline as localAlbums' name path — a
# fuzzy `artists search:` must not adopt the wrong contributor).
sub _bandContributorId {
    my ($mbid, $name) = @_;
    if ($mbid) {
        my $c = eval {
            require Slim::Schema;
            Slim::Schema->rs('Contributor')->search({ musicbrainz_id => $mbid })->first;
        };
        return $c->id if $c;
    }
    return undef unless defined $name && length $name;
    my $an  = _norm($name);
    my $enc = $name;
    utf8::encode($enc) if utf8::is_utf8($enc);
    my $req = eval { Slim::Control::Request::executeRequest(undef, ['artists', 0, 20, "search:$enc"]) };
    if ($req) {
        for my $e (@{ $req->getResult('artists_loop') || [] }) {
            next unless defined $e->{artist};
            return $e->{id} if _norm($e->{artist}) eq $an;
        }
    }
    return undef;
}

# Library albums by the BANDS an artist is a member of (API::peekBands feeds the
# list). Each band's OWN album-artist records via localAlbums — so a member
# tagged COMPOSER-only on their band's album (the case the role filter drops)
# comes back through the band, WITHOUT the write-only chaff (the band IS the
# album artist). $exclude {album_id=>1} skips albums already shown for the
# browsed artist; it is updated as we go so two bands can't double-list a split.
sub bandAlbums {
    my ($class, $bands, $exclude) = @_;
    return [] unless $bands && @$bands;
    $exclude ||= {};
    my @out;
    for my $b (@$bands) {
        my $id = _bandContributorId($b->{mbid}, $b->{name});
        next unless $id;
        for my $a (@{ $class->localAlbums($id, $b->{name}) }) {
            next if $exclude->{ $a->{_albumid} }++;
            $a->{_band} = $b->{name};
            push @out, $a;
        }
    }
    _dbg("band albums: " . scalar(@out) . " from " . scalar(@$bands) . " band(s)");
    return \@out;
}

sub _localAlbumTracks {
    my ($client, $cb, $args, $pass) = @_;
    my $req = eval {
        Slim::Control::Request::executeRequest(undef,
            ['titles', 0, 999, 'album_id:' . $pass->{album_id}, 'sort:tracknum', 'tags:u']);
    };
    my @items;
    for my $e (@{ ($req && $req->getResult('titles_loop')) || [] }) {
        next unless $e->{url};
        push @items, { name => $e->{title} // '', type => 'audio', url => $e->{url}, play => $e->{url} };
    }
    $cb->({ items => \@items });
}

# Detection + priority for every known service — for the settings page (step 5)
# and the app-root "Works best with" list. $adapters is an OPTIONAL pre-built
# adapters() list: a caller that already needs the adapters (the root view
# reads their icons) passes its own copy so the capability probe runs once per
# render instead of once per consumer. Omitted = probe here, as before.
sub serviceStatus {
    my ($adapters) = @_;
    my @known = ( [ 'qobuz', 'Qobuz' ], [ 'tidal', 'Tidal' ], [ 'deezer', 'Deezer' ] );
    my %installed = map { lc($_->{name}) => 1 }
        (ref $adapters eq 'ARRAY' ? @$adapters : adapters());
    return [ map {
        {   key       => $_->[0],
            name      => $_->[1],
            installed => $installed{ $_->[0] } ? 1 : 0,
            priority  => $prefs->get('svc_priority_' . $_->[0]) // 0,
        }
    } @known ];
}

# ---------------------------------------------------------------------------
# Candidate fetch + cache
# ---------------------------------------------------------------------------

# $mbid scopes the key to ONE MusicBrainz artist. Only same-name-ambiguous
# lookups pass it, so every ordinary artist keeps its existing name-keyed entry
# (no mass cache invalidation) while two acts called Madness get their own.
# The candidate pool is the ONE cache whose contents depend on resolver LOGIC
# rather than on remote data: which service artist we picked, what the foreign-
# artist filter dropped, whether the alias retry ran. So every change to that
# logic can leave a pool that is stale in a way no TTL describes — and it
# persists for CAND_FOUND_TTL (3 days), which during development repeatedly made
# a WORKING fix look broken (Sonic Boom, 2026-07-19: the page only came right
# after a manual clearcache).
#
# Including the plugin VERSION in the key makes every install self-invalidating:
# a new build simply cannot read an old build's pools. Costs one refetch per
# artist actually visited after an update, on demand — not a mass rebuild — and
# removes a whole class of "is this the fix or the cache?" diagnosis. Old keys
# are never read again and expire on their own.
my $_pluginVer;
sub _pluginVersion {
    return $_pluginVer if defined $_pluginVer;
    $_pluginVer = eval {
        Slim::Utils::PluginManager->dataForPlugin('Plugins::Discography::Plugin')->{version};
    };
    $_pluginVer = 'dev' unless defined $_pluginVer && length $_pluginVer;
    return $_pluginVer;
}

sub _candKey {
    my ($svc, $artist, $mbid) = @_;
    my $key = 'dsc:cand:' . CAND_CACHE_V . ':' . _pluginVersion() . ':' . lc($svc) . ':'
            . ($mbid ? "mb:$mbid" : _norm($artist));
    utf8::encode($key) if utf8::is_utf8($key);   # octet key — non-Latin can't crash md5
    return $key;
}

# Native play/browse coderefs can't live in the cache — stripped on write,
# reattached per service on read. A service that's since been disabled or
# uninstalled yields no coderef and the item is dropped.
my %REATTACH = (
    Qobuz  => sub { Plugins::Qobuz::Plugin->can('QobuzGetTracks') && \&Plugins::Qobuz::Plugin::QobuzGetTracks },
    Tidal  => sub { Plugins::TIDAL::Plugin->can('getAlbum')       && \&Plugins::TIDAL::Plugin::getAlbum },
    Deezer => sub { Plugins::Deezer::Plugin->can('getAlbum')      && \&Plugins::Deezer::Plugin::getAlbum },
);

sub _reattach {
    my ($svc, $cached) = @_;
    my $getter = $REATTACH{$svc} or return [];
    my $code   = $getter->()     or return [];
    return [ map { my %x = %$_; $x{url} = $code; \%x } @{ $cached || [] } ];
}

sub _cacheCands {
    my ($key, $items, $ttl, $unresolved) = @_;
    my @store = map { my %x = %$_; delete $x{url}; \%x } @{ $items || [] };
    eval { $cache->set($key, { items => \@store,
                               ($unresolved ? (unresolved => 1) : ()) }, $ttl); 1 }
        or $log->warn("candidate cache set failed: $@");
}

# getCandidates($client, $artist, $force, $cb) -> $cb->({ <svc> => [items] })
# One artist-level search per enabled service, in parallel, each behind its own
# watchdog. Cache hits skip the search entirely. $cb fires exactly once, after
# every service settles (a hung one settles as an error at SVC_TIMEOUT).
sub getCandidates {
    my ($class, $client, $artist, $force, $cb, $opt) = @_;
    $opt ||= {};

    # %opt (all optional): spine => { normalised MB title => 1 }, mbid => '...'
    # The spine is what an ambiguous name's candidates are scored against (see
    # _resolveArtist) and may legitimately be EMPTY. The mbid scopes the cache
    # so two acts sharing a name cannot share a pool, and is independent of the
    # spine — see the write-key note below.
    my $spine   = $opt->{spine};
    my $aliases = $opt->{aliases};
    # The NAME is shared by several MB artists: a lone same-name hit on a
    # service proves nothing and must be checked against the spine too.
    my $strict  = $opt->{ambiguous} ? 1 : 0;
    # THE WRITE KEY, and it must be derived exactly as the READ keys are.
    #
    # This used to be `($spine && %$spine) ? $opt->{mbid} : undef` — vestigial
    # from 0.43.1, when only ambiguous lookups were mbid-scoped. Both readers
    # (peekPool via _buildList and the cold check) pass the mbid
    # UNCONDITIONALLY, so an EMPTY spine wrote a name-keyed pool that nothing
    # ever read back. Two ways that bit:
    #   - an artist with no MB release groups: _spineTitles is {}, so the pool
    #     was written name-keyed and read mb-keyed — a permanent miss, and with
    #     hide_unmatched on the cold-pool await re-resolved every service on
    #     EVERY visit, never warming.
    #   - _releaseDetail builds its spine from peekReleaseGroups, a cache-ONLY
    #     peek; on a miss the spine is empty, so the detail page resolved
    #     against the name-keyed pool — the prominent same-name act's catalogue
    #     — and disagreed with the tile that opened it.
    # Same class as the 0.43.1/0.43.2 split key: a scope on a cache key must be
    # derived the same way on both sides, or it fails silently.
    my $mbid    = $opt->{mbid};

    my @adapters = orderedAdapters();
    unless (@adapters && defined $artist && length $artist) { $cb->({}); return }

    # Raw artist to the service search (normalisation mangles stylised names —
    # "P!nk" -> "p nk"), in BOTH spellings: character string for adapters whose
    # URL layer escapes/transliterates itself (Qobuz, Tidal), octets for
    # byte-level escapers (Deezer). See the query_enc notes in adapters().
    my $qChars = $artist;
    utf8::decode($qChars) unless utf8::is_utf8($qChars);   # no-op if not valid UTF-8
    my $qBytes = $artist;
    utf8::encode($qBytes) if utf8::is_utf8($qBytes);

    my %out;
    my $pending = scalar @adapters;

    for my $a (@adapters) {
        my $svc = $a->{name};
        my $key = _candKey($svc, $artist, $mbid);

        if (!$force && (my $c = $cache->get($key))) {
            $out{$svc} = _reattach($svc, $c->{items});
            $cb->(\%out) unless --$pending;
            next;
        }

        my $settled = 0;
        my $timer;
        my $settle = sub {
            my ($items) = @_;
            if ($settled) {
                # The watchdog already gave up on this service, but the fetch
                # landed anyway. Keep the result: pinning the error TTL over a
                # pool we actually hold would repeat the same slow fetch on
                # every open. Only the $cb is spoken for — it already fired.
                _cacheCands($key, $items, CAND_FOUND_TTL)
                    if defined $items && @$items;
                return;
            }
            $settled = 1;
            Slim::Utils::Timers::killSpecific($timer) if $timer;
            if (!defined $items) {
                # Couldn't query (no handler / timeout / renderer died): cache
                # empty briefly so the next open retries soon, not in 3 days.
                # UNRESOLVED, not "this service has nothing". An empty pool
                # that peekPool counts as `resolved` lets hide_unmatched hide
                # the release — which is precisely what 0.43.1 set out to
                # prevent and did not, because the marker was never stored
                # (field, 2026-07-19: an unresolvable artist's page still read
                # "No releases found").
                _cacheCands($key, [], CAND_ERR_TTL, 1);
                $out{$svc} = [];
            }
            else {
                _cacheCands($key, $items, @$items ? CAND_FOUND_TTL : CAND_EMPTY_TTL);
                $out{$svc} = $items;
            }
            # Sample the pool head in the log: a healthy count full of the
            # WRONG artist (mangled query, wrong-artist adoption) is otherwise
            # indistinguishable from a good pool the matcher rejected.
            #
            # A SMALL pool is listed IN FULL (POOL_LOG_MAX), because for a
            # missing release the whole question is "is it in the pool and
            # failing the title match, or was it never fetched?" — and three
            # examples can never answer that. Big pools stay sampled: a single
            # render already writes ~100 match lines and log.txt tails.
            my $n = defined $items ? scalar(@$items) : undef;
            my $show = ($n && $n <= POOL_LOG_MAX) ? $n : 3;
            my $sample = ($n && $n > 0)
                ? (($n <= POOL_LOG_MAX ? ' ALL: ' : ' e.g. ')
                   . join('; ', map { ($_->{_candArtist} // '?') . ' - ' . ($_->{_candTitle} // '?') }
                     @{$items}[0 .. ($n > $show ? $show - 1 : $n - 1)]))
                : '';
            _dbg("candidates $svc/'$artist': "
                . (defined $n ? $n . $sample : 'error (handler/timeout/renderer)'));
            $cb->(\%out) unless --$pending;
        };

        $timer = Slim::Utils::Timers::setTimer(undef, time() + SVC_TIMEOUT, sub {
            return if $settled;
            $log->warn("candidates $svc timed out");
            $settle->(undef);
        });

        my $query = ($a->{query_enc} || 'bytes') eq 'chars' ? $qChars : $qBytes;
        eval { $a->{run}->($client, $query, $svc, $settle, $spine, $aliases, $strict); 1 } or do {
            $log->warn("candidates $svc failed: $@");
            $settle->(undef);
        };
    }
}

# Drop an artist's candidate caches (the detail page's "Refresh matches" row).
# Clears BOTH scopes: the mbid-keyed pool (what an identified artist actually
# uses) and the legacy/name-keyed one. Refresh must not leave a stale pool
# behind just because the caller didn't know the mbid.
sub clearCandidates {
    my ($class, $artist, $mbid) = @_;
    return unless defined $artist && length $artist;

    # LOGS THE KEYS, and whether each actually held anything. clearcache
    # reported success for a long time while the pool survived (2026-07-19),
    # which silently invalidated every "cold cache" test run against this
    # plugin — including ones that concluded a real bug was unreproducible.
    # A clear that cannot be observed is a clear that cannot be trusted.
    my @report;
    for my $a (adapters()) {
        for my $key (_candKey($a->{name}, $artist),
                     ($mbid ? _candKey($a->{name}, $artist, $mbid) : ())) {
            my $had = defined $cache->get($key) ? 'HIT' : 'miss';
            $cache->remove($key);
            my $now = defined $cache->get($key) ? 'STILL-PRESENT' : 'gone';
            push @report, "$key [$had->$now]";
        }
    }
    _dbg('clearCandidates: ' . (@report ? join(' | ', @report)
                                        : 'NO ADAPTERS - nothing cleared'));
    return \@report;
}

# ---------------------------------------------------------------------------
# Global artist search (the plugin-view "Search for an artist" feature) —
# one artist-TYPE search per enabled service plus the library, results merged
# and deduped by mergeArtistHits. Deliberately NOT cached here (user-initiated,
# one request per service); Browse caches the MERGED list briefly for item_id
# walk determinism.
# ---------------------------------------------------------------------------

# searchArtists($client, $query, $cb) -> cb(\%bySvc, \%failed) where %bySvc is
#   { Local => [{name, artist_id}], Qobuz => [{name}], ... } — every source key
# present once settled — and %failed is { <svc> => 1 } for each service that
# ERRORED or TIMED OUT.
#
# The second arg matters (0.42.2): a failed service settles as an EMPTY list,
# which is indistinguishable from "this service genuinely has no such artist"
# unless the failure is reported separately. Browse caches the merged list for
# SEARCH_TTL, so without this signal one slow/erroring service pinned a
# silently-degraded result set for the full TTL — every retry inside the window
# served the same short list from cache instead of re-searching. Callers must
# treat a non-empty %failed as "these results are incomplete, do not persist".
#
# Same parallel settle-once/watchdog pattern as getCandidates, sized for the
# single request each artist search costs.
sub searchArtists {
    my ($class, $client, $query, $cb) = @_;

    my (%out, %failed);
    return $cb->(\%out, \%failed) unless defined $query && length $query;

    # Local leg — sync CLI query (LMS DB access is synchronous, the fleet's
    # accepted pattern), the same `artists search:` call localAlbums' name
    # fallback uses. Hits keep their contributor id so a drill-in resolves
    # via the reliable library-tag path.
    #
    # role_id MUST match what localAlbums asks for (PERFORMANCE_ROLES). Left
    # unfiltered, `artists` falls back to activeContributorRoles /
    # defaultContributorRoles (verified in LMS 9.0 Queries.pm:1047-1063), which
    # include COMPOSER — so a writer-only contributor was returned here as a
    # Local row while the page it opened filtered them out and showed nothing.
    if (($prefs->get('svc_priority_local') // 1) > 0) {
        my $enc = $query;
        utf8::encode($enc) if utf8::is_utf8($enc);
        # LMS's OWN search does not fold "&" against "and" — verified live
        # 2026-07-21: `artists search:Simon and Garfunkel` returns 0 while
        # `search:Simon & Garfunkel` returns 1. `_norm` folds them, but this leg
        # queries the LMS database DIRECTLY with the raw text, so the fold never
        # reaches it and a user typing the other spelling was told they do not
        # own an artist they demonstrably do (the streaming rows still appeared,
        # so the row simply lost its Local source).
        #
        # Try the other spelling only when the first finds nothing: one extra
        # sync DB query, on a miss, on a query the user typed.
        my @tries = ($enc);
        my $alt   = $enc;
        if    ($alt =~ s/\s*&\s*/ and /g)  { push @tries, $alt }
        elsif ($alt =~ s/\s+and\s+/ & /gi) { push @tries, $alt }

        my @hits;
        for my $try (@tries) {
            my $req = eval { Slim::Control::Request::executeRequest(undef,
                ['artists', 0, SEARCH_MAX, "search:$try",
                 'role_id:' . PERFORMANCE_ROLES]) };
            if ($req) {
                for my $e (@{ $req->getResult('artists_loop') || [] }) {
                    next unless defined $e->{artist} && length $e->{artist};
                    push @hits, { name => $e->{artist}, artist_id => $e->{id} };
                }
            }
            if (@hits) {
                _dbg("Local: '$try' matched " . scalar(@hits)
                    . ($try eq $enc ? '' : " (via &/and variant of '$enc')"));
                last;
            }
        }
        $out{Local} = \@hits;
    }

    my @adapters = orderedAdapters();
    return $cb->(\%out, \%failed) unless @adapters;

    # Both query spellings, per the query_enc discipline (see adapters()).
    my $qChars = $query;
    utf8::decode($qChars) unless utf8::is_utf8($qChars);
    my $qBytes = $query;
    utf8::encode($qBytes) if utf8::is_utf8($qBytes);

    my $pending = scalar @adapters;
    for my $a (@adapters) {
        my $svc = $a->{name};
        my $settled = 0;
        my $timer;
        my $settle = sub {
            my ($hits) = @_;
            return if $settled;
            $settled = 1;
            Slim::Utils::Timers::killSpecific($timer) if $timer;
            my $ok = ref $hits eq 'ARRAY';
            $out{$svc}    = $ok ? $hits : [];
            $failed{$svc} = 1 unless $ok;
            # NAMES, not just a count. A count cannot answer "was this artist
            # ever returned?" - and that is the only question that matters when
            # a row the user expected is missing (field: "The Iron Maidens"
            # absent from an Iron Maiden search, present in Tidal's own
            # results). It distinguishes a service/limit gap from the merge
            # relevance gate dropping it downstream.
            _dbg("artist-search $svc/'$query': " . scalar(@{ $out{$svc} })
                . ($ok ? '' : ' (error/timeout)')
                . (@{ $out{$svc} } ? ' | ' . join('; ',
                    map { $_->{name} // '?' } @{ $out{$svc} }) : ''));
            $cb->(\%out, \%failed) unless --$pending;
        };
        $timer = Slim::Utils::Timers::setTimer(undef, time() + SEARCH_TIMEOUT, sub {
            return if $settled;
            $log->warn("artist-search $svc timed out");
            $settle->(undef);
        });
        my $q = ($a->{query_enc} || 'bytes') eq 'chars' ? $qChars : $qBytes;
        eval { $a->{artists}->($client, $q, $svc, $settle); 1 } or do {
            $log->warn("artist-search $svc failed: $@");
            $settle->(undef);
        };
    }
}

# N random library album-cover URLs for the app-root banner — one `albums`
# CLI query using the server's own sort:random (verified live 2026-07-17;
# fresh order every call, no Perl-side shuffling needed). Only albums that
# actually HAVE artwork are kept (tags:j artwork_track_id), so the banner can
# never show a blank tile; the pool is 3x the ask to survive artless albums.
# Empty library / failed query -> [] (the caller skips the banner).
sub randomAlbumCovers {
    my ($class, $n) = @_;
    $n ||= 4;
    my $req = eval { Slim::Control::Request::executeRequest(undef,
        ['albums', 0, $n * 3, 'sort:random', 'tags:j']) };
    return [] unless $req;
    my @ids = grep { defined $_ && length $_ }
        map { $_->{artwork_track_id} } @{ $req->getResult('albums_loop') || [] };
    splice @ids, $n if @ids > $n;
    return [ map { "/music/$_/cover_300x300_f.jpg" } @ids ];
}

# Normalise a service's artist list to [{name}], capped. All three services
# carry the display name in {name} (the same field _pickArtist reads).
sub _artistHits {
    my ($list) = @_;
    return undef unless ref $list eq 'ARRAY';
    my @out;
    for my $a (@$list) {
        next unless ref $a eq 'HASH'
            && defined $a->{name} && !ref $a->{name} && length $a->{name};
        push @out, { name => $a->{name} };
        last if @out >= SEARCH_MAX;
    }
    return \@out;
}

# The artist-search leg of each adapter, standalone — the same call the
# artist-first candidate fetch opens with (signatures verified against the
# plugin sources, see the Service Plugin APIs table in CLAUDE.md).
sub _artistsQobuz {
    my ($client, $query, $svc, $collect) = @_;
    my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return }
    $api->search(sub {
        my $res = shift;
        $collect->(_artistHits(
            ref $res eq 'HASH' && ref $res->{artists} eq 'HASH'
                ? $res->{artists}{items} : undef));
    }, lc($query), 'artists');
}

sub _artistsTidal {
    my ($client, $query, $svc, $collect) = @_;
    my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return }
    $api->search(sub {
        $collect->(_artistHits(shift));
    }, { type => 'artists', search => $query, limit => SEARCH_MAX });
}

sub _artistsDeezer {
    my ($client, $query, $svc, $collect) = @_;
    my $api = Plugins::Deezer::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return }
    $api->search(sub {
        $collect->(_artistHits(shift));
    }, { search => $query, type => 'artist', strict => 'off', limit => SEARCH_MAX });
}

# Merge per-source artist hits into ONE deduped, deterministically ordered
# list: [ { name, sources => ['Local','Qobuz',...], artist_id? } ].
#
# RELEVANCE GATE (0.37.1 — the Beatles-junk fix, verified live): the services'
# artist searches return their whole RELEVANCE tail, and Tidal's even returns
# RELATED artists — "The Beatles" came back with Led Zeppelin, Pink Floyd,
# The Monkees, Paul McCartney. A hit survives only if it is TEXTUALLY related
# to what was typed:
#   * exact key match (also the only way in for punct-only names), or
#   * the normalised query is a SUBSTRING of the normalised name (covers
#     partial typing: "beatl" -> The Beatles), or
#   * _artistMatch token-subset either way ("Beatles" <-> "The Beatles";
#     "the beatles" <-> "Yesterday - A Tribute To The Beatles").
# So acts CONTAINING the typed text stay (that IS what was asked for — exact
# ranks first anyway), and the services' free-association neighbours drop.
#
# Dedupe key = the matcher's _norm of the name (falling back to _punctNorm for
# names _norm empties, e.g. "( )") — so the same act spelled slightly
# differently across services collapses to one row, while genuinely distinct
# names ("Laetitia Sadier" vs "Laetitia Sadier Source Ensemble") stay apart.
# The display name comes from the FIRST source to introduce the bucket
# (sources iterate in priority order, Local first — the library's spelling
# wins). Ordering: exact-normalised match on the query first, then breadth
# (found on more sources = more likely the act the user meant), then the
# first-seen relevance sequence; capped at SEARCH_MERGED_MAX. Pure function —
# no prefs, no network — the caller passes the source order (defaulting to
# Local + adapter priority).
#
# DELIBERATELY NO ENTITY FOLDING (decided 2026-07-17): services carry
# duplicate artist entities (Qobuz has BOTH "Beatles" and "The Beatles";
# "Chocolate Watchband" / "The Chocolate Watch Band" / a TYPO'd "The
# Chocoloate Watch Band") and an article/spacing/edit-distance fold was
# built, then REVERTED on Simon's call: we should not paper over streaming-
# service catalogue errors, and string similarity alone cannot prove two
# entities are one act ("Beatles"/"Beatless" and "Iron Maiden"/"The Iron
# Maidens" are one edit apart and genuinely distinct). If folding ever
# returns, it must be DISCOGRAPHY-VERIFIED — corroborate that the entities'
# release lists actually overlap (the 0.28.x library-disambiguation
# philosophy) — never inferred from the name.
# ---------------------------------------------------------------------------
# TYPO TOLERANCE FOR THE RELEVANCE GATE
#
# THE BUG (field, 2026-07-21). Simon typed "Layo & Bushwaka" — one letter out —
# and got NOTHING. The services had already done the hard part: Qobuz, Tidal
# and Deezer ALL returned "Layo & Bushwacka!" for that misspelling. Our gate
# then threw all 17 hits away and kept only a vague "Layo" (0 release groups),
# which the dead-end filter correctly dropped. So the search was strictly WORSE
# than the services it queries, and Simon was right that "from a user
# perspective this is broken".
#
# THIS IS NOT THE ENTITY FOLDING DECLINED ON 2026-07-17, and the distinction is
# the whole point. That decision rejected MERGING two service entities into one
# row on string similarity ("Beatles" + "The Beatles"), because a name cannot
# prove two entities are one act. Nothing here merges anything: bucketing is
# still EXACT `_norm` equality. This only decides whether a hit the service
# returned is relevant to what the USER TYPED — a query/result question, not an
# identity claim — and every admitted row still faces the dead-end filter.
#
# PURELY ADDITIVE: it runs only after the three existing tests have all failed,
# so it can never reject something that passes today. The 0.37.1 junk it must
# keep out (Tidal answering "The Beatles" with Led Zeppelin, Pink Floyd, The
# Monkees) is nowhere near the threshold.
#
# THRESHOLDS, measured against the REAL logged service hits (not invented):
#   lowest wanted-KEEP  0.944  (layo and bushwaka -> layo and bushwacka)
#   highest wanted-DROP 0.545  (the beatles -> beatless / the monkees)
# 0.85 sits far above the junk with margin on both sides.
#
# THE LENGTH FLOOR IS NOT DECORATION — it is doing real work. On short names a
# single edit is a DIFFERENT WORD: "eagles"/"beagles" scores 0.857 and
# "slayer"/"player" 0.833, both ABOVE the ratio threshold, and only the floor
# excludes them. Cost of the floor is a genuine miss on short typos
# ("nirvna"), accepted deliberately: no result beats a confidently wrong one.
use constant FUZZY_MIN_SIM => 0.85;
use constant FUZZY_MIN_LEN => 8;

# Levenshtein. NB the parameters are NOT $a/$b: a lexical $a/$b in scope
# silently breaks any sort/min written in terms of them — the 0.44.18 bug, and
# I reproduced it in this very function's first test harness.
sub _editDistance {
    my ($s1, $s2) = @_;
    return length($s2) unless length $s1;
    return length($s1) unless length $s2;
    my @prev = (0 .. length($s2));
    for my $i (1 .. length($s1)) {
        my @cur = ($i);
        for my $j (1 .. length($s2)) {
            my $del = $prev[$j] + 1;
            my $ins = $cur[$j - 1] + 1;
            my $sub = $prev[$j - 1]
                    + (substr($s1, $i - 1, 1) ne substr($s2, $j - 1, 1) ? 1 : 0);
            my $min = $del;
            $min = $ins if $ins < $min;
            $min = $sub if $sub < $min;
            push @cur, $min;
        }
        @prev = @cur;
    }
    return $prev[-1];
}

sub _closeEnough {
    my ($qn, $hn) = @_;
    return 0 unless length($qn) >= FUZZY_MIN_LEN && length $hn;
    my $max = length($qn) > length($hn) ? length($qn) : length($hn);
    # Cheap reject before the O(n*m) matrix: a length gap alone can already put
    # the pair out of reach, and most candidates fail here.
    return 0 if (abs(length($qn) - length($hn)) / $max) > (1 - FUZZY_MIN_SIM);
    return ((1 - _editDistance($qn, $hn) / $max) >= FUZZY_MIN_SIM) ? 1 : 0;
}

sub mergeArtistHits {
    my ($class, $query, $bySvc, $order) = @_;
    my @order = $order ? @$order
              : ('Local', map { $_->{name} } orderedAdapters());
    my $key = sub {
        my $k = _norm($_[0] // '');
        $k = _punctNorm($_[0] // '') if $k eq '';
        return $k;
    };
    my $qk = $key->($query);
    my $qn = _norm($query // '');
    my (%bucket, @seq);
    for my $svc (@order) {
        for my $h (@{ $bySvc->{$svc} || [] }) {
            next unless ref $h eq 'HASH';
            my $k = $key->($h->{name});
            next if $k eq '';
            # The relevance gate. $qn eq '' (punct-only query) leaves exact
            # key equality as the only way in.
            unless ($k eq $qk) {
                my $hn = _norm($h->{name} // '');
                next unless $qn ne '' && $hn ne ''
                    && (index($hn, $qn) >= 0 || _artistMatch($qn, $hn)
                        || _closeEnough($qn, $hn));
            }
            my $b = $bucket{$k};
            unless ($b) {
                $b = $bucket{$k} = {
                    name => $h->{name}, sources => [],
                    _seq => scalar @seq, _exact => ($qk ne '' && $k eq $qk) ? 1 : 0,
                };
                push @seq, $b;
            }
            push @{ $b->{sources} }, $svc
                unless grep { $_ eq $svc } @{ $b->{sources} };
            $b->{artist_id} //= $h->{artist_id} if $h->{artist_id};
        }
    }
    my @merged = sort {
        $b->{_exact} <=> $a->{_exact}
            || @{ $b->{sources} } <=> @{ $a->{sources} }
            || $a->{_seq} <=> $b->{_seq}
    } @seq;
    splice @merged, SEARCH_MERGED_MAX if @merged > SEARCH_MERGED_MAX;
    delete @$_{qw(_seq _exact)} for @merged;
    return \@merged;
}

# ---------------------------------------------------------------------------
# Per-release matching (local filter over the candidate lists)
# ---------------------------------------------------------------------------

# matchesFor($bySvc, $artist, $albumTitle, $local) ->
#   [ { svc => 'Local'|'Qobuz'|..., icon, items => [nodes] }, ... ]
# in orderedSources priority order, only sources with matches; per-source
# dedupe + cap; streaming items get the ListenLater favurl handshake (Local
# ones don't — there's no service scheme to hand over).
sub matchesFor {
    my ($class, $bySvc, $artist, $albumTitle, $local, $rgMbid, $relMap, $rivals, $opt) = @_;
    $opt ||= {};

    # Whole-list builds thread precomputed invariants in via $opt: the artist
    # norm and the source order are IDENTICAL for every release group, yet
    # orderedSources() reads prefs + builds + sorts an array on EACH call and
    # _norm folds Unicode — recomputing both per-RG was pure waste (a big artist
    # calls matchesFor once per release group). The album norm is just the RG
    # title's, which the caller already normed for the rivals lookup. Each falls
    # back to computing here for standalone callers (detail page, unit tests).
    my $artistNorm = defined $opt->{artistNorm} ? $opt->{artistNorm} : _norm($artist);
    my $albumNorm  = defined $opt->{albumNorm}  ? $opt->{albumNorm}  : _norm($albumTitle);
    my $sources    = $opt->{sources} || [ orderedSources() ];

    # Candidate index (peekPool builds it): STREAMING pools only test the subset
    # sharing a first token with this release group, not the whole pool. Local
    # pools are small AND match by release MBID (not just title), so they always
    # full-scan. A short (<2 char) album norm matches via the raw-punctuation
    # branch (no first token) -> full-scan too. Empty @lkeys => full scan.
    my $index = $opt->{index};
    my @lkeys = ($index && length $albumNorm >= 2) ? _titleKeys($albumNorm, $artistNorm) : ();

    my %all = %{ $bySvc || {} };
    $all{Local} = $local if $local && @$local;

    my @sections;
    for my $a (@$sources) {
        my $svc   = $a->{name};
        my $cands = $all{$svc} or next;

        # Narrow to the index subset for a streaming service when we can.
        my $iter = $cands;
        if (!$a->{local} && @lkeys && (my $idx = $index->{$svc})) {
            my (%seenIt, @sub);
            for my $key (@lkeys) {
                push @sub, grep { !$seenIt{$_}++ } @{ $idx->{$key} || [] };
            }
            $iter = \@sub;
        }

        my (%seen, @matched);
        for my $it (@$iter) {
            # Identity (tier 0) is never second-guessed by the rival rule: an
            # MBID says which group this IS.
            unless (_mbidMatch($it, $rgMbid, $relMap)) {
                # A LOCAL candidate was fetched by artist_id + performance role,
                # so the DB join ALREADY proves the browsed artist performs on
                # this album. The `albums` query then collapses a multi-artist
                # ALBUMARTIST to ONE display string (Robert Plant + Alison Krauss
                # -> "Robert Plant"), which would wrongly fail _albumMatches' MANDATORY
                # artist gate for a co-credited / band-fronted owned album. Trust
                # the join: gate Local on the BROWSED artist (title must still
                # match). _candArtist is left untouched so Browse's "Appearances"
                # split still sees the true album-artist. (Simon: Raising Sand,
                # 2026-07-11.)
                my $gateArtist = $a->{local} ? $artist : $it->{_candArtist};
                next unless _albumMatches($artistNorm, $albumNorm, $gateArtist, $it->{_candTitle}, $albumTitle);
                # Several same-title groups matched it; only its owner keeps it.
                next if $rivals && @$rivals > 1 && $rgMbid
                     && _rivalOwner($it->{_year}, $rivals) ne $rgMbid;
            }
            my $k = join('|', $it->{name} // '', $it->{line2} // '');
            next if $seen{$k}++;
            my %item = %$it;   # per-release copy — never decorate the shared cache entry
            _attachFavUrl(\%item, $svc, $item{_cover}, $artist) unless $a->{local};
            push @matched, \%item;
            last if @matched >= MAX_PER_SVC;
        }
        push @sections, { svc => $svc, icon => $a->{icon}, items => \@matched } if @matched;
    }

    # The matching-diagnosis line: which services hit, and how big each
    # candidate pool was — a miss with a healthy pool means the matcher
    # rejected everything (title/artist normalisation gap, worth a look with
    # the LBF match_check tooling); an empty pool means the service search
    # itself returned nothing for this artist.
    _dbg("match '" . ($albumTitle // '') . "' [" . ($artist // '') . "]: "
        . (@sections ? join(', ', map { $_->{svc} . '=' . scalar @{ $_->{items} } } @sections) : 'NO MATCH')
        . ' | pool: '
        . (join(', ', map { $_ . '=' . scalar @{ $all{$_} || [] } } sort keys %all) || 'none'));

    return \@sections;
}

# Which local album ids are claimed by ANY release group of this artist —
# pure-CPU matcher pass (no cache reads), used to find the LEFTOVER library
# albums for the "Also in your library" safety-net section. Claims run across
# every RG the caller passes (including type-filtered ones) so a hidden
# section can't resurface its matches as "unmatched".
sub claimedLocalIds {
    my ($class, $rgs, $artist, $local, $relMap) = @_;
    my %claimed;
    return \%claimed unless $local && @$local;
    my $artistNorm = _norm($artist);
    for my $rg (@{ $rgs || [] }) {
        my $albumNorm = _norm($rg->{title});
        for my $it (@$local) {
            next if $claimed{ $it->{_albumid} };
            # $local candidates are ALL Local (join-proven for the browsed
            # artist), so gate on $artist not the collapsed _candArtist — same
            # co-credit reasoning as matchesFor. Keeps a co-credited owned album
            # from leaking into "Also in your library" when its tile matched.
            $claimed{ $it->{_albumid} } = 1
                if _mbidMatch($it, $rg->{mbid}, $relMap)
                || _albumMatches($artistNorm, $albumNorm, $artist, $it->{_candTitle}, $rg->{title});
        }
    }
    return \%claimed;
}

# Read + reattach every service's cached candidate pool ONCE per build. The
# artist-first fetch made these pools big (thousands of items), and _reattach
# shallow-copies every item — doing it per release group meant tens of
# thousands of hash copies on the single-threaded event loop for one list
# render. Callers building a whole list hoist this out of their loop and hand
# the result to peekMatches.
# $mbid MUST be passed wherever getCandidates was given one, or the render
# reads a DIFFERENT cache entry than the warm wrote (field, 0.43.1: the warm
# fetched into `mb:<mbid>` while this read the name-keyed pool, so the fix could
# not take effect and the page still matched against the prominent act's
# catalogue). Read key and write key are the same function for exactly this
# reason — keep them that way.
sub peekPool {
    my ($class, $artist, $mbid) = @_;
    return { bySvc => {}, resolved => 0, index => {} }
        unless defined $artist && length $artist;

    my $artistNorm = _norm($artist);
    my (%bySvc, %index, $resolved);
    # COLD = not one service has a cached entry, i.e. streaming was never
    # fetched for this artist. Distinct from "fetched and nothing found"
    # ($resolved==0 with entries present), and the two must not be conflated:
    # the render EXEMPTS unmatched releases from hide_unmatched when streaming
    # is unresolved, which is right for "we asked and the services don't have
    # this artist" but wrong for "we haven't asked yet" — that just renders a
    # page the next visit contradicts (field, 2026-07-19: 85 unmatched releases
    # on the first view of Madness after an update, 0 on the second).
    my $seen = 0;
    for my $a (orderedAdapters()) {
        # An mbid-scoped pool is authoritative for THIS act; fall back to the
        # name-keyed one only when there is no mbid scope in play (ordinary
        # artists), never as a second chance for an ambiguous one — that is the
        # wrong act's catalogue by definition.
        my $rkey = _candKey($a->{name}, $artist, $mbid);
        my $c = $cache->get($rkey);
        # Logged so the READ key can be diffed against the keys clearCandidates
        # reports removing — the pair is the whole diagnosis when a clear does
        # not take effect.
        _dbg("peekPool read $rkey: " . ($c ? 'HIT' : 'miss'));
        $c or next;
        $seen++;
        # An entry cached as UNRESOLVED (no artist could be identified on this
        # service) must NOT count as "streaming was checked" — otherwise an
        # empty pool hides every release behind hide_unmatched.
        $resolved = 1 unless $c->{unresolved};
        my $items = _reattach($a->{name}, $c->{items});
        $bySvc{ $a->{name} } = $items;

        # First-token title index for this service's pool, built ONCE per render
        # (matchesFor runs per release group; without this it re-scanned the whole
        # pool each time). A candidate lands under every key its title yields.
        my %idx;
        for my $it (@$items) {
            push @{ $idx{$_} }, $it
                for _titleKeys(_norm($it->{_candTitle}), $artistNorm);
        }
        $index{ $a->{name} } = \%idx;
    }
    return { bySvc => \%bySvc, resolved => $resolved ? 1 : 0, index => \%index,
             cold => $seen ? 0 : 1 };
}

# Cache-only variant for sync paths (list-tile badges): never searches, never
# needs a client. Returns { sections => [...], resolved => 0|1 } where
# `resolved` means STREAMING candidates were cached (a resolved no-match may
# hide the release). Local matches ride along but deliberately do NOT set
# `resolved` — owning some of an artist's albums must not hide the unowned
# ones before streaming has actually been checked.
#
# $pool is an optional peekPool() result: pass it when peeking many releases
# for one artist. matchesFor copies matched items before decorating them, so
# sharing the pool arrays across releases is safe.
sub peekMatches {
    my ($class, $artist, $albumTitle, $local, $pool, $rgMbid, $relMap, $rivals, $opt) = @_;
    return { sections => [], resolved => 0 }
        unless defined $artist && length $artist;

    $pool ||= $class->peekPool($artist, $opt->{mbid});
    return {
        sections => $class->matchesFor($pool->{bySvc}, $artist, $albumTitle, $local, $rgMbid, $relMap, $rivals, $opt),
        resolved => $pool->{resolved},
    };
}

# ---------------------------------------------------------------------------
# ListenLater favurl handshake (ported from PFR/LBF):
#   <scheme>://album:<nativeId>[?cover=<escaped art>][&a=<escaped artist>]
# XMLBrowser copies favorites_url into presetParams (Material's $FAVURL);
# without it the coderef url leaks as the favurl and ListenLater can't tell
# the service or replay the album.
# ---------------------------------------------------------------------------
sub _attachFavUrl {
    my ($it, $svc, $art, $artist) = @_;
    my $id = $it->{_albumid};
    return unless defined $id && length $id;

    my $fav = lc($svc) . '://album:' . $id;
    my @params;
    if (defined $art && !ref $art && length $art) {
        require URI::Escape;
        push @params, 'cover=' . URI::Escape::uri_escape_utf8($art);
    }
    if (defined $artist && !ref $artist && length $artist) {
        require URI::Escape;
        push @params, 'a=' . URI::Escape::uri_escape_utf8($artist);
    }
    $fav .= '?' . join('&', @params) if @params;
    $it->{favorites_url} = $fav;
}

# ---------------------------------------------------------------------------
# Per-service candidate fetch. Unlike PFR these do NOT filter by album — the
# full candidate list is cached and filtered per release group later. Each
# candidate carries: the native rendered node (playable), _svc, _albumid,
# _cover (native art), _candTitle/_candArtist (raw, for the matcher).
#
# ARTIST-FIRST (2026-07-10): album-search-by-artist-name is a relevance
# lottery — Qobuz caps catalog/search at 200 and 'sigur rós' left Valtari
# outside the top 200 while 193 fuzzy strangers made it in (Tidal/Deezer
# searches were capped at 50, same exposure). Each adapter now resolves the
# ARTIST on the service and pulls that artist's own album list — complete by
# construction. The old album search remains as the fallback when no artist
# resolves (stylised names, artists absent from the service).
# ---------------------------------------------------------------------------

# Best service artist for the query: normalised exact name wins, else the
# first (services rank by relevance) token-subset _artistMatch hit.
# ---------------------------------------------------------------------------
# SAME-NAME ARTIST RESOLUTION AGAINST THE MUSICBRAINZ SPINE
#
# THE BUG THIS EXISTS FOR (field, 0.43.0): browsing a SECONDARY same-name act
# showed an empty page. Diagnosed live — the MB spine was right and everything
# else was wrong:
#
#   topLevel: artist=Madness mbid=5d500d2e-...        (the horrorcore rapper)
#   match 'Open Corpse': NO MATCH | pool: Qobuz=158, Tidal=131, Local=7
#
# The release group is the rapper's; the candidate pool is the SKA BAND's,
# because getCandidates is keyed by artist NAME and _pickArtist picks the first
# exact-name hit — a coin toss when eight artists share the name. Nothing
# matched, hide_unmatched hid it, and the page read "No releases found". The
# matcher was never at fault: it was handed the wrong pool.
#
# THE FIX: when a name is ambiguous, pick the service artist whose CATALOGUE
# corroborates the release groups MusicBrainz already gave us. MB is an
# authoritative title list for THIS mbid, so overlap is a real test of identity
# rather than another name comparison.
#
# Bounded: only engages with a spine AND >1 same-name candidate, probes at most
# SPINE_ARTISTS per service, and the result is cached under the mbid. Ordinary
# artists never reach it and their cache entries are untouched.
#
# NO CORROBORATION = UNRESOLVED, NOT "no match". Settling as undef caches the
# short error TTL and leaves peekMatches' `resolved` false, so hide_unmatched
# does NOT hide the release: the user sees the real discography unplayable
# rather than an empty page. Falling back to the name-keyed album search would
# be worse than nothing — it returns the prominent act's records under the
# wrong artist's page.
# ---------------------------------------------------------------------------
use constant SPINE_ARTISTS => 4;

sub _sameName {
    my ($query, $artists) = @_;
    my $qn = _norm($query);
    return () if $qn eq '';
    return grep { ref $_ eq 'HASH' && defined $_->{id}
                  && _norm($_->{name} // '') eq $qn } @{ $artists || [] };
}

sub _spineScore {
    my ($albums, $spine) = @_;
    my $hit = 0;
    my %seen;
    for my $al (@{ $albums || [] }) {
        next unless ref $al eq 'HASH';
        my $t = _norm($al->{title} // $al->{name} // '');
        next if $t eq '' || $seen{$t}++;
        $hit++ if $spine->{$t};
    }
    return $hit;
}

# An album whose OWN artist id differs from the one we asked for. Measured on
# the live Qobuz API (2026-07-18): getArtist(85999) returns 139 albums by 85999
# plus about twenty by eighteen OTHER artist ids - appears-on/related entries
# that Qobuz's own app does not show on the artist page. Left in, they pollute
# the candidate pool and (once unclaimed candidates are surfaced) would fill the
# streaming-extras section with other artists' records.
#
# SELF-GUARDING, and it must be: TIDAL's album payloads use a DIFFERENT id space
# from its artist ids - we ask for artist 9130 and not one album reports 9130 -
# so a naive "must equal the requested id" filter would delete TIDAL's entire
# discography. It therefore only engages once the requested id actually appears
# in the response, which proves the two are comparable. Albums carrying no
# artist id are always kept (Deezer sends none, and its endpoint is server-side
# scoped to the artist anyway).
sub _albumArtistId {
    my ($al) = @_;
    return undef unless ref $al eq 'HASH';
    my $a = $al->{artist} || ($al->{artists} && $al->{artists}[0]) || {};
    return (ref $a eq 'HASH' && defined $a->{id}) ? $a->{id} : undef;
}

sub _albumArtistName {
    my ($al) = @_;
    return '' unless ref $al eq 'HASH';
    my $a = $al->{artist} || ($al->{artists} && $al->{artists}[0]) || {};
    return (ref $a eq 'HASH' && defined $a->{name}) ? $a->{name}
         : (!ref $a && defined $a) ? $a : '';
}

sub _filterForeignArtist {
    my ($albums, $svc, $wantId, $wantName) = @_;
    return $albums unless defined $wantId && ref $albums eq 'ARRAY';

    my $mine = grep { my $a = _albumArtistId($_);
                      defined $a && $a eq $wantId } @$albums;
    return $albums unless $mine;          # id spaces differ - do not touch

    # A COLLABORATION is credited to a different entity and is still genuinely
    # this artist's record — "Panda Bear & Sonic Boom" carries the collab's
    # artist id, not Sonic Boom's, and dropping it would lose an album the MB
    # spine DOES list. So a differing id is forgiven when the credit still
    # names the artist; only credits that do not (his other band's records)
    # are dropped.
    # The forgiveness must be NARROW. An EXACTLY equal credit under a different
    # id is a DIFFERENT ACT WITH THE SAME NAME — the Madness problem again, and
    # 0.44.1's softening let those straight back in (field: Sonic Boom's page
    # listed "Bajo Tu Voz" and "El Mssiah" by another Sonic Boom). A genuine
    # collaboration reads as the artist PLUS someone else ("Panda Bear & Sonic
    # Boom"), i.e. strictly MORE tokens than the name alone. So: forgive a
    # differing id only when the credit CONTAINS the artist and is not merely
    # equal to it.
    my $wn = defined $wantName ? _norm($wantName) : '';
    # Partitioned in ONE pass so the dropped set is the exact complement of the
    # kept set by construction — recomputing it, or matching on ref addresses,
    # is how a diagnostic drifts from the decision it claims to explain.
    my (@keep, @lost);
    for my $al (@$albums) {
        my $a  = _albumArtistId($al);
        my $cn = _norm(_albumArtistName($al));
        if (!defined $a || $a eq $wantId
            || ($wn ne '' && $cn ne '' && $cn ne $wn && _artistMatch($wn, $cn))) {
            push @keep, $al;
        }
        else { push @lost, $al }
    }
    my $n = scalar @lost;
    if ($n) {
        # NAMES THE DROPPED RECORDS, not just a count. A count cannot answer
        # "was this album ever returned by the service?" - and that is the only
        # question that matters when a release the user knows exists is missing
        # from the page (field, 2026-07-21: Layo & Bushwacka's Low Life / All
        # Night Long / Feels Closer / The Raw Road absent while Tidal dropped 8
        # albums here). It also distinguishes the two failure modes that look
        # identical on screen: a genuine foreign record (correctly dropped) vs
        # the SAME act filed by the service under a second artist id, whose
        # credit is exactly equal and is therefore dropped by the same-name
        # rule that exists to keep a DIFFERENT act out. Same lesson as the
        # 0.44.17 artist-search name list.
        _dbg("$svc/$wantId: dropped $n album(s) credited to other artist ids | "
            . join('; ', map {
                  ($_->{title} // $_->{name} // '?') . ' [credit '
                  . (_albumArtistName($_) || '?') . ' id '
                  . (defined _albumArtistId($_) ? _albumArtistId($_) : '-') . ']'
              } @lost[0 .. ($#lost > 7 ? 7 : $#lost)]));
    }
    return \@keep;
}

# How many MB aliases to retry under. Aliases are ordered as MB returns them;
# an artist with a long alias list is usually one whose primary name works.
use constant ALIAS_MAX => 3;

# $fetch->($artistId, sub { \@rawAlbums })
# $search->($name, sub { \@artists })   — re-runs the service's ARTIST search
# $cb->($artist, \@rawAlbums)  — $artist undef means "could not resolve".
#
# Wrapper: try the searched name, then MB's ALIASES. A rapper whose records are
# all sold as "Tony Madness" is not absent from the service — we were asking
# under the wrong name (field, 2026-07-19). Alias retries cost one extra artist
# search each and happen ONLY on the failure path.
sub _resolveArtist {
    my ($svc, $query, $artists, $spine, $fetch, $cb, $aliases, $search, $strict) = @_;

    _resolveOne($svc, $query, $artists, $spine, $fetch, sub {
        my ($artist, $albums) = @_;
        return $cb->($artist, $albums) if $artist;

        my @names = @{ $aliases || [] };
        splice @names, ALIAS_MAX if @names > ALIAS_MAX;
        return $cb->(undef, undef) unless @names && $search;

        # Self-passing closure, not a captured lexical — avoids the reference
        # cycle Perl never reclaims (the 0.30.1 leak fix).
        my $i = 0;
        my $step = sub {
            my ($self) = @_;
            my $alias = $names[$i++];
            return $cb->(undef, undef) unless defined $alias;
            _dbg("$svc: nothing under '$query' - retrying MB alias '$alias'");
            $search->($alias, sub {
                _resolveOne($svc, $alias, shift, $spine, $fetch, sub {
                    my ($a, $al) = @_;
                    return $cb->($a, $al) if $a;
                    $self->($self);
                }, $strict);
            });
        };
        $step->($step);
    }, $strict);
}

sub _resolveOne {
    my ($svc, $query, $artists, $spine, $fetch, $cb, $strict) = @_;

    my @same = _sameName($query, $artists);

    # $strict: the NAME is known to be shared by several MB artists, so a
    # single same-name hit on this service proves nothing - it is most likely
    # the PROMINENT act. Score it against the spine like any other candidate,
    # and if it does not corroborate, report unresolved so the caller can retry
    # under MB's aliases.
    #
    # THE BUG THIS EXISTS FOR (field, 2026-07-19): Qobuz returns exactly ONE
    # artist called "Madness", so the US rapper's page took the shortcut below,
    # adopted the ska band, reported SUCCESS - and the alias retry that would
    # have found "Tony Madness" never ran.
    #
    # Deliberately NOT the default: for an unambiguous artist a single name
    # match is the right answer, and demanding catalogue corroboration would
    # reject legitimate artists whose service titles are spelled differently
    # from MusicBrainz's.
    my $verify = $spine && %$spine && (@same > 1 || ($strict && @same));

    unless ($verify) {
        my $a = _pickArtist($query, $artists);
        return $cb->(undef, undef) unless $a;
        return $fetch->($a->{id}, sub { $cb->($a, shift) });
    }

    splice @same, SPINE_ARTISTS if @same > SPINE_ARTISTS;
    my $left = scalar @same;
    my @scored;
    # NB the loop variable is NOT $a: a lexical $a in scope MASKS sort's own
    # $a, so `sort { $b->{score} <=> $a->{score} }` would read `score` off the
    # service-artist hashref (always undef) instead of the element being
    # compared. That is not a sorted list - the top-scoring candidate need not
    # end up first, so the wrong service artist gets adopted, and when the
    # misordered head scores 0 the whole thing reports UNRESOLVED even though a
    # candidate corroborated. Silent: `perl -c` cannot see it and this file has
    # no `use warnings`, so the "uninitialized value" warning never fires.
    for my $cand (@same) {
        $fetch->($cand->{id}, sub {
            my ($albums) = @_;
            push @scored, { artist => $cand, albums => $albums,
                            score => _spineScore($albums, $spine) };
            return if --$left;

            @scored = sort { $b->{score} <=> $a->{score} } @scored;
            _dbg("$svc: '$query' is ambiguous - "
                . join(', ', map { $_->{artist}{id} . '=' . $_->{score} } @scored)
                . ' spine titles');

            unless ($scored[0]{score}) {
                _dbg("$svc: no candidate corroborates this artist's releases"
                    . ' - UNRESOLVED (releases stay visible, unmatched)');
                return $cb->(undef, undef);
            }
            $cb->($scored[0]{artist}, $scored[0]{albums});
        });
    }
}

sub _pickArtist {
    my ($query, $artists) = @_;
    my $qn = _norm($query);
    return undef if $qn eq '';
    my $fuzzy;
    for my $a (@{ $artists || [] }) {
        next unless ref $a eq 'HASH' && defined $a->{id};
        my $n = _norm($a->{name} // '');
        next if $n eq '';
        return $a if $n eq $qn;
        $fuzzy ||= $a if _artistMatch($qn, $n);
    }
    return $fuzzy;
}

# Candidate release year, off the RAW service album (the plugins' rendered items
# drop it). Field names verified in each plugin's source, ORIGINAL release date
# first — a remaster's stream date would point at the wrong release-group:
#   Qobuz  release_date_original -> release_date_stream -> year
#   TIDAL  releaseDate
#   Deezer release_date
# Any 4-digit leading year wins; nothing sane -> undef (caller must cope).
sub _candYear {
    my ($album) = @_;
    for my $f (qw(release_date_original releaseDate release_date release_date_stream year date)) {
        my $v = $album->{$f};
        next unless defined $v && !ref $v;
        return $1 if $v =~ /^(\d{4})/;
    }
    return undef;
}

sub _decorate {
    my ($item, $svc, $album, $candArtist) = @_;
    $item->{_svc}        = $svc;
    $item->{_albumid}    = $album->{id};
    $item->{_cover}      = $item->{image} if defined $item->{image} && !ref $item->{image};
    $item->{_candTitle}  = $album->{title};
    $item->{_candArtist} = $candArtist;
    $item->{_year}       = _candYear($album);
    # Qobuz search albums sometimes carry an editorial description — kept as a
    # review fallback for the detail page (MAI wins when it has one).
    $item->{_desc}       = $album->{description}
        if defined $album->{description} && !ref $album->{description} && length $album->{description};
}

# Normalise a fetch result to an arrayref of albums, or undef.
#
# VERIFIED against the plugin sources (2026-07-10): all three unwrap their own
# JSON envelope and hand us a plain ARRAY — Deezer Async.pm `artistAlbums`/
# `search` both do `shift->{data}` then `$cb->($albums || [])`; TIDAL Async.pm
# `artistAlbums` does `$cb->($albums || [])`. The exception is Qobuz, whose
# callback carries the whole result hash, so we reach into `{albums}{items}`
# ourselves. This helper keeps that reach in ONE place and tolerates an
# envelope if a plugin ever stops unwrapping (the old Deezer search leg carried
# a `{data}` unwrap that could no longer fire).
#
# undef means "not a list at all" — the callers treat that as a failed fetch
# (short retry TTL), never as a genuinely empty discography.
sub _albumArray {
    my ($x) = @_;
    return $x if ref $x eq 'ARRAY';
    if (ref $x eq 'HASH') {
        for my $k (qw(data items albums)) {
            return $x->{$k} if ref $x->{$k} eq 'ARRAY';
        }
    }
    return undef;
}

# ONE render loop for every adapter. $render is the service plugin's own node
# renderer (guarded — a die here is inside an async callback); $skip optionally
# drops entries before rendering.
#
# _candArtist feeds the matcher's MANDATORY artist gate, so it must never come
# out undef: an artist-album payload may carry {artist} with a name, only an
# {artists} list, or no artist at all (Deezer's /artist/N/albums), and Deezer's
# own renderer autovivifies an empty {artist} as a side effect. Hence the
# ladder ending in $artistName (the name the artist-first fetch resolved) and
# then ''. Computed BEFORE $render runs, so a renderer's autovivification can't
# poison it.
#
# Returns undef — meaning ERROR, cache briefly and retry — only when the
# renderer failed for EVERY album. An empty arrayref means the list really was
# empty, which the callers distinguish.
sub _renderAlbums {
    my ($albums, $svc, $artistName, $render, $skip) = @_;
    my @out;
    my $rendererFailed = 0;
    for my $album (@{ $albums || [] }) {
        next unless ref $album eq 'HASH' && defined $album->{id};
        next if $skip && $skip->($album);
        my $ref = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
        my $candArtist = (ref $ref eq 'HASH' && $ref->{name}) || $artistName || '';
        my $item = eval { $render->($album) };
        if ($@ || ref $item ne 'HASH') {
            $log->warn("$svc renderer failed: $@") if $@;
            $rendererFailed = 1;
            next;
        }
        _decorate($item, $svc, $album, $candArtist);
        push @out, $item;
    }
    return undef if !@out && $rendererFailed;
    return \@out;
}

sub _searchQobuz {
    my ($client, $query, $svc, $collect, $spine, $aliases, $strict) = @_;

    my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return }

    my $fetch = sub {
        my ($id, $done) = @_;
        $api->getArtist(sub {
            my $r = shift;
            # Filtered BEFORE scoring as well as rendering: a foreign album must
            # not contribute to a candidate's spine score either.
            $done->(_filterForeignArtist(
                _albumArray(ref $r eq 'HASH' ? $r->{albums} : undef),
                'Qobuz', $id, $query));
        }, $id);
    };

    my $search = sub {
        my ($name, $done) = @_;
        $api->search(sub {
            my $r = shift;
            $done->($r && $r->{artists} && $r->{artists}{items});
        }, lc($name), 'artists');
    };

    $api->search(sub {
        my $res = shift;
        _resolveArtist('Qobuz', $query,
            $res && $res->{artists} && $res->{artists}{items}, $spine, $fetch,
            sub {
                my ($artist, $albums) = @_;
                unless ($artist) {
                    # With a spine, an unresolved artist is DELIBERATE (nothing
                    # corroborated) and the album-search fallback would pull the
                    # prominent same-named act — settle unresolved instead.
                    if ($spine && %$spine) { return $collect->(undef) }
                    _dbg("Qobuz: no artist hit for '$query' - album-search fallback");
                    return _qobuzAlbumSearch($api, $client, $query, $svc, $collect);
                }
                # A resolved artist with a raw-empty album list is a failed fetch
                # far more often than a zero-album artist — settle as error (short
                # retry), never a 1-day empty pin.
                return $collect->(undef) unless $albums && @$albums;
                $collect->(_renderQobuzAlbums($client, $albums, $svc, $artist->{name}));
            }, $aliases, $search, $strict);
    }, lc($query), 'artists');
}

sub _qobuzAlbumSearch {
    my ($api, $client, $query, $svc, $collect) = @_;
    $api->search(sub {
        my $res = shift;
        return $collect->(undef) unless defined $res;
        $collect->(_renderQobuzAlbums(
            $client, _albumArray(ref $res eq 'HASH' ? $res->{albums} : undef) || [], $svc, undef));
    }, lc($query), 'albums');
}

sub _renderQobuzAlbums {
    my ($client, $albums, $svc, $artistName) = @_;
    return _renderAlbums($albums, $svc, $artistName,
        sub { Plugins::Qobuz::Plugin::_albumItem($client, $_[0]) },
        sub { defined $_[0]->{streamable} && !$_[0]->{streamable} });
}

sub _searchTidal {
    my ($client, $query, $svc, $collect, $spine, $aliases, $strict) = @_;

    my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return }

    # TIDAL splits a discography across filter buckets — fetch all three in
    # parallel and merge (id-deduped; the buckets shouldn't overlap).
    my $fetch = sub {
        my ($id, $done) = @_;
        my @filters = qw(ALBUMS EPSANDSINGLES COMPILATIONS);
        my (@albums, %seen);
        my $left = scalar @filters;
        for my $f (@filters) {
            $api->artistAlbums(sub {
                my $a = _albumArray(shift);
                push @albums, grep { ref $_ eq 'HASH' && defined $_->{id} && !$seen{$_->{id}}++ }
                    @{ $a || [] };
                $done->(_filterForeignArtist(\@albums, 'Tidal', $id, $query)) unless --$left;
            }, $id, $f);
        }
    };

    my $search = sub {
        my ($name, $done) = @_;
        $api->search(sub { $done->(ref $_[0] eq 'ARRAY' ? $_[0] : []) },
            { type => 'artists', search => $name, limit => 25 });
    };

    $api->search(sub {
        my $artists = shift;
        _resolveArtist('Tidal', $query, ref $artists eq 'ARRAY' ? $artists : [],
            $spine, $fetch,
            sub {
                my ($artist, $albums) = @_;
                unless ($artist) {
                    if ($spine && %$spine) { return $collect->(undef) }
                    _dbg("Tidal: no artist hit for '$query' - album-search fallback");
                    return _tidalAlbumSearch($api, $query, $svc, $collect);
                }
                return $collect->(undef) unless $albums && @$albums;   # all-empty = failed fetch
                $collect->(_renderTidalAlbums($albums, $svc, $artist->{name}));
            }, $aliases, $search, $strict);
    }, { type => 'artists', search => $query, limit => 25 });
}

sub _tidalAlbumSearch {
    my ($api, $query, $svc, $collect) = @_;
    $api->search(sub {
        my $albums = shift;
        return $collect->(undef) unless defined $albums;
        $collect->(_renderTidalAlbums(_albumArray($albums) || [], $svc, undef));
    }, { type => 'albums', search => $query, limit => 50 });
}

sub _renderTidalAlbums {
    my ($albums, $svc, $artistName) = @_;
    return _renderAlbums($albums, $svc, $artistName,
        sub { Plugins::TIDAL::Plugin::_renderAlbum($_[0]) });
}

sub _searchDeezer {
    my ($client, $query, $svc, $collect, $spine, $aliases, $strict) = @_;

    my $api = Plugins::Deezer::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return }

    my $fetch = sub {
        my ($id, $done) = @_;
        $api->artistAlbums(sub { $done->(_albumArray(shift)) }, $id);
    };

    my $search = sub {
        my ($name, $done) = @_;
        $api->search(sub { $done->(ref $_[0] eq 'ARRAY' ? $_[0] : []) },
            { search => $name, type => 'artist', strict => 'off', limit => 25 });
    };

    $api->search(sub {
        my $artists = shift;
        _resolveArtist('Deezer', $query, ref $artists eq 'ARRAY' ? $artists : [],
            $spine, $fetch,
            sub {
                my ($artist, $albums) = @_;
                unless ($artist) {
                    if ($spine && %$spine) { return $collect->(undef) }
                    _dbg("Deezer: no artist hit for '$query' - album-search fallback");
                    return _deezerAlbumSearch($api, $query, $svc, $collect);
                }
                return $collect->(undef) unless $albums && @$albums;
                # /artist/N/albums items carry NO artist object — Deezer's own
                # _renderAlbum reads $item->{artist}{name} and would leave it undef,
                # which is exactly why it takes the artist name as a 3rd arg. Pass
                # the resolved name (verified: sub _renderAlbum($item,$addArtistToTitle,$artist)).
                $collect->(_renderDeezerAlbums($albums, $svc, $artist->{name}));
            }, $aliases, $search, $strict);
    }, { search => $query, type => 'artist', strict => 'off', limit => 25 });
}

sub _deezerAlbumSearch {
    my ($api, $query, $svc, $collect) = @_;
    $api->search(sub {
        my $albums = shift;
        return $collect->(undef) unless defined $albums;
        $collect->(_renderDeezerAlbums(_albumArray($albums) || [], $svc, undef));
    }, { search => $query, type => 'album', strict => 'off', limit => 50 });
}

sub _renderDeezerAlbums {
    my ($albums, $svc, $artistName) = @_;
    # 3rd arg backfills favorites_title when the payload has no artist object
    # (the artist-albums endpoint) — mirrors the plugin's own use.
    return _renderAlbums($albums, $svc, $artistName,
        sub { Plugins::Deezer::Plugin::_renderAlbum($_[0], 0, $artistName) });
}

# Same-title release-groups ("rivals") compete for one candidate.
#
# The Beatles have FOUR official release-groups whose titles normalise to the
# artist name — the 1968 album plus compilations from 1967/1983/1988 — so the
# streaming album titled "The Beatles" title-matches all four and the White
# Album's artwork appeared four times (Simon, 2026-07-10). A candidate belongs
# to exactly ONE release group; this decides which.
#
# DELIBERATELY NOT nearest-year. Streaming catalogues date a remaster by its
# REISSUE year, so a 2009 White Album remaster is nearer 1988 than 1968 and
# nearest-year would hand it to the compilation — worse than the bug. The rule
# is therefore conservative:
#   * candidate year EXACTLY equals a rival's first-release year -> that rival
#     (a service listing the 1988 compilation as 1988 gets it right);
#   * otherwise the EARLIEST rival wins. A self-titled album is the original;
#     the later same-named records are compilations of it.
# An undated or reissue-dated candidate therefore lands on the real album, and
# the compilations show nothing rather than a wrong thing.
#
# $rivals must be pre-sorted deterministically (see Browse::_rivalsByTitle):
# dated ascending, undated last, mbid as the final tiebreak — the whole feed's
# item_id walk depends on this being stable across rebuilds.
sub _rivalOwner {
    my ($candYear, $rivals) = @_;
    if ($candYear) {
        for my $r (@$rivals) {
            return $r->{mbid} if $r->{year} && $r->{year} == $candYear;
        }
    }
    return $rivals->[0]{mbid};
}

# Tier 0 — EXACT IDENTITY, ahead of every title rule and immune to all of them.
# A library album tagged MUSICBRAINZ_ALBUMID carries a RELEASE mbid; MB models
# reissues, box sets and bonus-disc editions as releases under ONE release
# group, so the release->group map (API::peekReleaseMap, free from the bootleg
# browse) answers "is this album this tile?" with no string comparison at all.
# This is what makes "The Beatles and Esher Demos" resolve to the White Album:
# the titles share nothing the matcher can use, but they are the same group.
# Some taggers write the GROUP mbid instead, so accept a direct hit too.
# Streaming candidates carry no MBID -> they always fall through to the matcher.
sub _mbidMatch {
    my ($it, $rgMbid, $relMap) = @_;
    my $mb = $it->{_mbid} or return 0;
    return 0 unless $rgMbid;
    return 1 if $mb eq $rgMbid;
    return 1 if $relMap && defined $relMap->{$mb} && $relMap->{$mb} eq $rgMbid;
    return 0;
}

# ===========================================================================
# Matching (verbatim from the Pitchfork/ListenBrainz plugins — keep in sync)
# ===========================================================================

sub _albumMatches {
    my ($artistNorm, $albumNorm, $candArtist, $candTitle, $albumRaw) = @_;

    # All-punctuation / single-char titles ("( )", "X") normalise to (near)
    # nothing, so the standard path can't see them. Compare a punctuation-
    # PRESERVING form instead — lowercase, whitespace stripped: "( )" == "()"
    # but != "( ) (live)". Exact equality only (a prefix rule here would let
    # "x" swallow "xx") and the artist gate is mandatory — a match this thin
    # can't stand on the title alone. (Sigur Rós "( )", 2026-07-10.)
    if (length $albumNorm < 2) {
        my $ap = _punctNorm($albumRaw);
        return 0 unless length $ap;
        return 0 unless _punctNorm($candTitle) eq $ap;
        return 0 if $artistNorm eq '';
        return _artistMatch($artistNorm, _norm($candArtist));
    }
    my $t = _norm($candTitle);
    return 0 if $t eq '';

    # SELF-TITLED releases ("The Beatles", "Weezer") match on the EXACT title
    # only. Every rule below reads "<album> <extra>" as the same album carrying
    # an edition suffix — true for "(Deluxe)", catastrophic when the album
    # title IS the artist name, where it swallows the whole discography: the
    # "The Beatles" release-group matched "The Beatles 1962-1966" (the Red
    # album), "The Beatles 1967-1970" (Blue) and "The Beatles Anthology 1".
    # Via claimedLocalIds it also swallowed the user's own copies of those
    # albums, hiding them from the library-extras section. Bracketed decoration
    # is already stripped by _norm, so the White Album still matches its
    # "The Beatles (White Album)" / "(Remastered)" listings.
    # Residual, NOT fixable on title alone: MusicBrainz has four release-groups
    # titled "The Beatles", so one candidate legitimately matches them all.
    # (Simon's library, 2026-07-10.)
    if (length($artistNorm) && $albumNorm eq $artistNorm) {
        return 0 unless $t eq $albumNorm;
        return _artistMatch($artistNorm, _norm($candArtist));
    }

    my $ok = ($t eq $albumNorm || index($t, "$albumNorm ") == 0);

    # Trailing format descriptor ("… EP"/"… LP") present on one side only.
    if (!$ok) {
        my $ab = _stripFmt($albumNorm);
        my $tb = _stripFmt($t);
        $ok = 1 if length($ab) >= 3 && length($tb) >= 3
                && ($tb eq $ab || index($tb, "$ab ") == 0);
    }

    # Decorative non-ASCII glyphs spelled differently between sources.
    if (!$ok) {
        my $aa = _asciiNorm($albumNorm);
        my $ta = _asciiNorm($t);
        $ok = 1 if length($aa) >= 2 && length($ta) >= 2
                && ($ta eq $aa || index($ta, "$aa ") == 0);
    }

    # Titles carrying the ARTIST NAME as a prefix on ONE side only — e.g. the
    # release "Belle and Sebastian Write About Love" vs the MB release-group
    # "Write About Love" (found via Simon's library 2026-07-09; also fixes the
    # same album's streaming match). Strip a leading "<artist> " from both
    # sides and re-compare; gated on a >=3 char remainder, and the artist
    # check below still applies. DELIBERATE DIVERGENCE from the LBF/PFR
    # matcher — candidate to port back upstream.
    if (!$ok && length $artistNorm) {
        my $ab = _stripArtistPrefix($albumNorm, $artistNorm);
        my $tb = _stripArtistPrefix($t, $artistNorm);
        if (($ab ne $albumNorm || $tb ne $t) && length($ab) >= 3 && length($tb) >= 3) {
            $ok = 1 if $tb eq $ab || index($tb, "$ab ") == 0;
        }
    }
    return 0 unless $ok;

    return ($t eq $albumNorm) ? 1 : 0 if $artistNorm eq '';
    return _artistMatch($artistNorm, _norm($candArtist));
}

sub _stripFmt {
    my $s = shift // '';
    $s =~ s/\s+(?:ep|lp)$//;
    return $s;
}

# Lowercased, whitespace-stripped, punctuation KEPT — only for titles _norm
# erases (see the short-title branch in _albumMatches).
sub _punctNorm {
    my $s = shift // '';
    if (!utf8::is_utf8($s) && $s =~ /[^\x00-\x7f]/) {
        my $d = $s;
        $s = $d if utf8::decode($d);
    }
    $s = lc($s);
    $s =~ s/\s+//g;
    return $s;
}

sub _stripArtistPrefix {
    my ($t, $a) = @_;
    return substr($t, length($a) + 1) if index($t, "$a ") == 0;
    return $t;
}

sub _asciiNorm {
    my $s = shift // '';
    $s =~ s/[^\x00-\x7f]+/ /g;
    $s =~ s/[^a-z0-9]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}

# First-token index keys for an already-NORMALISED title — a SUPERSET pre-filter
# so a release group only tests candidates that COULD match it. Testing every
# streaming candidate (pools run to hundreds) against every release group was the
# render's R x C matcher cost. NOT part of the shared matcher — it only decides
# which candidates reach the unchanged _albumMatches, so it can never change a
# result as long as it's a proper superset. Every _albumMatches positive path
# leaves the two normalised titles sharing a first token in AT LEAST ONE form:
#   - the norm itself       (exact / trailing-extra prefix / _stripFmt: _stripFmt
#                            only trims a trailing "ep"/"lp", so the front is kept)
#   - _asciiNorm(norm)      (an accented FIRST token spelled differently per side)
#   - artist-prefix stripped ("<artist> <album>" present on one side only)
# so indexing candidates under all three and looking a release group up under all
# three cannot miss a real match. Short (<2 char) normalised titles match via the
# raw-punctuation branch instead and are full-scanned at the call site.
sub _titleKeys {
    my ($norm, $artistNorm) = @_;
    return () unless defined $norm && length $norm;
    my %k;
    $k{$1} = 1 if $norm =~ /^(\S+)/;
    my $a = _asciiNorm($norm);
    $k{$1} = 1 if length $a && $a =~ /^(\S+)/;
    if (defined $artistNorm && length $artistNorm) {
        my $p = _stripArtistPrefix($norm, $artistNorm);
        $k{$1} = 1 if $p ne $norm && length $p && $p =~ /^(\S+)/;
    }
    delete $k{''};
    return keys %k;
}

sub _artistMatch {
    my ($a, $b) = @_;
    return 0 if $a eq '' || $b eq '';

    my %at = map { ($_ => 1) } split ' ', $a;
    my %bt = map { ($_ => 1) } split ' ', $b;
    my ($small, $big) = (scalar keys %at <= scalar keys %bt) ? (\%at, \%bt) : (\%bt, \%at);

    for my $tok (keys %$small) {
        return 0 unless $big->{$tok};
    }
    return 1;
}

my $HAVE_NFD = eval { require Unicode::Normalize; 1 } ? 1 : 0;
my %FOLD = (
    "\x{131}" => 'i', "\x{142}" => 'l', "\x{f8}" => 'o', "\x{f0}" => 'd',
    "\x{111}" => 'd', "\x{fe}" => 'th', "\x{df}" => 'ss', "\x{e6}" => 'ae',
    "\x{153}" => 'oe', "\x{127}" => 'h',
);

sub _norm {
    my $s = shift // '';
    if (!utf8::is_utf8($s) && $s =~ /[^\x00-\x7f]/) {
        my $d = $s;
        $s = $d if utf8::decode($d);
    }
    $s = lc($s);
    if ($HAVE_NFD && utf8::is_utf8($s)) {
        $s = Unicode::Normalize::NFC(
             Unicode::Normalize::NFD($s) =~ s/[\x{0300}-\x{036F}]+//gr );
        $s =~ s/([^\x00-\x7f])/exists $FOLD{$1} ? $FOLD{$1} : $1/ge;
    }
    # LEETSPEAK SUBSTITUTIONS — a punctuation mark standing in for a LETTER.
    #
    # Applied ONLY when a word character FOLLOWS the mark. That is precisely
    # what separates a letter from decoration: "P!nk" -> pink and "Ke$ha" ->
    # kesha (the mark sits INSIDE the word), while a trailing or free-standing
    # mark is punctuation and falls through to the [^\p{Alnum}] rule below.
    #
    # WHY, and it is not cosmetic (field, 2026-07-21): the old unconditional
    # fold made a name spelled WITH the mark disagree with the same name
    # spelled WITHOUT it — "Layo & Bushwacka!" -> 'layo bushwackai' against
    # 'layo bushwacka'. `_albumMatches`' artist gate is MANDATORY, so EVERY
    # streaming candidate was rejected and the page read "No releases found"
    # for an artist with five MB albums and a correctly resolved MBID. The same
    # fold also made "Panic At The Disco" unsearchable without the "!", and let
    # the same-name row fold pick a different survivor from one query to the
    # next (whichever spelling won decided whether the page then worked).
    #
    # A name made ENTIRELY of these marks ("!!!", a real band) keeps the old
    # unconditional fold: stripping would leave '', and `_artistMatch` rejects
    # an empty side outright — i.e. this very bug in a new costume.
    # "$" and "@" are UNCONDITIONAL: in a stylised name they are effectively
    # always a letter, including at the END - "$uicideboy$" is Suicideboy(s),
    # so the trailing "$" is an s, not decoration. Scoping the boundary rule
    # below to them broke exactly that (caught by the cross-repo behaviour
    # harness, which PFR documents as a supported case).
    $s =~ s/\$/s/g;
    $s =~ s/\@/a/g;
    # "!" IS different, and it is the one that motivated this: it has a real
    # decorative use that the others do not - "Wham!", "Panic! At The Disco",
    # "Godspeed You! Black Emperor", "Layo & Bushwacka!" - where the mark is
    # punctuation and the name is spelled both ways in the wild. So "!" folds
    # to a letter ONLY when a word character FOLLOWS it (inside a word, as in
    # "P!nk"); otherwise it falls through to the [^\p{Alnum}] pass below.
    #
    # A name of nothing BUT marks ("!!!", a real band) keeps the unconditional
    # fold: stripping would leave '', and `_artistMatch` rejects an empty side
    # outright - this very bug in a new costume.
    if ($s =~ /[\p{Alnum}]/) { $s =~ s/(?<=\w)!(?=\w)/i/g }
    else                      { $s =~ s/!/i/g }
    $s =~ s/\x{20ac}/e/g;   # euro sign
    $s =~ s/\x{a3}/l/g;     # pound sign
    $s =~ s/\x{a5}/y/g;     # yen sign

    # "&" and "+" are SPOKEN "and", and this is the same rule as every
    # substitution above it — a symbol folded to the word it stands for, like
    # $ -> s and ! -> i. Without it the two spellings key differently ("simon
    # garfunkel" vs "simon and garfunkel", because & alone becomes a space
    # below), so the SAME act arrives from two services as two search rows and
    # only merges if MusicBrainz happens to record the variant as an alias.
    # Field 2026-07-21: Deezer says "Layo and bushwacka!" where Tidal says
    # "Layo & Bushwacka" — one act, two rows.
    #
    # "+" is included because services use it the same way; MB's own alias list
    # for that duo literally carries "Layo + Bushwacka!".
    $s =~ s/[&+]/ and /g;
    $s =~ s/[\(\[].*?[\)\]]//g;
    $s =~ s/[^\p{Alnum}]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}

1;
