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
use Slim::Utils::Timers;
use Slim::Control::Request;

my $log   = Slim::Utils::Log->logger('plugin.discography');
my $prefs = preferences('plugin.discography');
my $cache = Slim::Utils::Cache->new();

# Matching diagnostics: debug_log pref ON mirrors to server.log at ERROR level
# (visible without touching Settings->Logging — remotely settable via
#   ["pref","plugin.discography:debug_log","1"]
# ); OFF logs at INFO (hidden at the default WARN).
sub _dbg {
    my ($msg) = @_;
    if ($prefs->get('debug_log')) { $log->error("dsc[dbg]: $msg") }
    else                          { $log->info("dsc: $msg") }
}

use constant CAND_FOUND_TTL => 3 * 86400;   # service discography is stable-ish
use constant CAND_EMPTY_TTL => 1 * 86400;   # artist not on the service
use constant CAND_ERR_TTL   => 3600;        # couldn't query -> retry soon
use constant SVC_TIMEOUT    => 8;           # per-service search watchdog (s)
use constant MAX_PER_SVC    => 4;           # editions shown per service
use constant CAND_CACHE_V   => '1';         # bump on shape/matcher changes

# ---------------------------------------------------------------------------
# Adapters (ported from PFR; Qobuz/Tidal/Deezer only — no Bandcamp by scope)
# ---------------------------------------------------------------------------

sub _pluginIcon {
    my ($class) = @_;
    return eval { $class->_pluginDataFor('icon') } || undef;
}

sub adapters {
    my @adapters;

    push @adapters, {
        name => 'Qobuz', icon => _pluginIcon('Plugins::Qobuz::Plugin'),
        run  => \&_searchQobuz,
    } if Plugins::Qobuz::Plugin->can('getAPIHandler')
      && Plugins::Qobuz::Plugin->can('_albumItem')
      && Plugins::Qobuz::Plugin->can('QobuzGetTracks');

    push @adapters, {
        name => 'Tidal', icon => _pluginIcon('Plugins::TIDAL::Plugin'),
        run  => \&_searchTidal,
    } if Plugins::TIDAL::Plugin->can('getAPIHandler')
      && Plugins::TIDAL::Plugin->can('getAlbum')
      && Plugins::TIDAL::Plugin->can('_renderAlbum');

    push @adapters, {
        name => 'Deezer', icon => _pluginIcon('Plugins::Deezer::Plugin'),
        run  => \&_searchDeezer,
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

    my $req = eval {
        Slim::Control::Request::executeRequest(undef, ['albums', 0, 500, "artist_id:$artistId", 'tags:ljya']);
    };
    return [] unless $req;

    my @out;
    for my $e (@{ $req->getResult('albums_loop') || [] }) {
        my $id    = $e->{id}    or next;
        my $title = $e->{album} // next;
        my $img   = $e->{artwork_track_id} ? "/music/$e->{artwork_track_id}/cover" : undef;
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
            _candTitle  => $title,
            _candArtist => $e->{artist} // $artist,
        };
    }
    _dbg("local albums for artist_id=$artistId: " . scalar @out);
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

# Detection + priority for every known service — for the settings page (step 5).
sub serviceStatus {
    my @known = ( [ 'qobuz', 'Qobuz' ], [ 'tidal', 'Tidal' ], [ 'deezer', 'Deezer' ] );
    my %installed = map { lc($_->{name}) => 1 } adapters();
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

sub _candKey {
    my ($svc, $artist) = @_;
    my $key = 'dsc:cand:' . CAND_CACHE_V . ':' . lc($svc) . ':' . _norm($artist);
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
    my ($key, $items, $ttl) = @_;
    my @store = map { my %x = %$_; delete $x{url}; \%x } @{ $items || [] };
    eval { $cache->set($key, { items => \@store }, $ttl); 1 }
        or $log->warn("candidate cache set failed: $@");
}

# getCandidates($client, $artist, $force, $cb) -> $cb->({ <svc> => [items] })
# One artist-level search per enabled service, in parallel, each behind its own
# watchdog. Cache hits skip the search entirely. $cb fires exactly once, after
# every service settles (a hung one settles as an error at SVC_TIMEOUT).
sub getCandidates {
    my ($class, $client, $artist, $force, $cb) = @_;

    my @adapters = orderedAdapters();
    unless (@adapters && defined $artist && length $artist) { $cb->({}); return }

    # Raw artist to the service search (normalisation mangles stylised names —
    # "P!nk" -> "p nk"); octet-encode for the URI layer.
    my $queryEnc = $artist;
    utf8::encode($queryEnc) if utf8::is_utf8($queryEnc);

    my %out;
    my $pending = scalar @adapters;

    for my $a (@adapters) {
        my $svc = $a->{name};
        my $key = _candKey($svc, $artist);

        if (!$force && (my $c = $cache->get($key))) {
            $out{$svc} = _reattach($svc, $c->{items});
            $cb->(\%out) unless --$pending;
            next;
        }

        my $settled = 0;
        my $timer;
        my $settle = sub {
            my ($items) = @_;
            return if $settled;
            $settled = 1;
            Slim::Utils::Timers::killSpecific($timer) if $timer;
            if (!defined $items) {
                # Couldn't query (no handler / timeout / renderer died): cache
                # empty briefly so the next open retries soon, not in 3 days.
                _cacheCands($key, [], CAND_ERR_TTL);
                $out{$svc} = [];
            }
            else {
                _cacheCands($key, $items, @$items ? CAND_FOUND_TTL : CAND_EMPTY_TTL);
                $out{$svc} = $items;
            }
            _dbg("candidates $svc/'$artist': "
                . (defined $items ? scalar(@{$items}) : 'error (handler/timeout/renderer)'));
            $cb->(\%out) unless --$pending;
        };

        $timer = Slim::Utils::Timers::setTimer(undef, time() + SVC_TIMEOUT, sub {
            return if $settled;
            $log->warn("candidates $svc timed out");
            $settle->(undef);
        });

        eval { $a->{run}->($client, $queryEnc, $svc, $settle); 1 } or do {
            $log->warn("candidates $svc failed: $@");
            $settle->(undef);
        };
    }
}

# Drop an artist's candidate caches (the detail page's "Refresh matches" row).
sub clearCandidates {
    my ($class, $artist) = @_;
    return unless defined $artist && length $artist;
    $cache->remove(_candKey($_->{name}, $artist)) for adapters();
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
    my ($class, $bySvc, $artist, $albumTitle, $local) = @_;

    my $artistNorm = _norm($artist);
    my $albumNorm  = _norm($albumTitle);

    my %all = %{ $bySvc || {} };
    $all{Local} = $local if $local && @$local;

    my @sections;
    for my $a (orderedSources()) {
        my $svc   = $a->{name};
        my $cands = $all{$svc} or next;

        my (%seen, @matched);
        for my $it (@$cands) {
            next unless _albumMatches($artistNorm, $albumNorm, $it->{_candArtist}, $it->{_candTitle});
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
    my ($class, $rgs, $artist, $local) = @_;
    my %claimed;
    return \%claimed unless $local && @$local;
    my $artistNorm = _norm($artist);
    for my $rg (@{ $rgs || [] }) {
        my $albumNorm = _norm($rg->{title});
        for my $it (@$local) {
            next if $claimed{ $it->{_albumid} };
            $claimed{ $it->{_albumid} } = 1
                if _albumMatches($artistNorm, $albumNorm, $it->{_candArtist}, $it->{_candTitle});
        }
    }
    return \%claimed;
}

# Cache-only variant for sync paths (list-tile badges): never searches, never
# needs a client. Returns { sections => [...], resolved => 0|1 } where
# `resolved` means STREAMING candidates were cached (a resolved no-match may
# hide the release). Local matches ride along but deliberately do NOT set
# `resolved` — owning some of an artist's albums must not hide the unowned
# ones before streaming has actually been checked.
sub peekMatches {
    my ($class, $artist, $albumTitle, $local) = @_;
    return { sections => [], resolved => 0 }
        unless defined $artist && length $artist;

    my (%bySvc, $resolved);
    for my $a (orderedAdapters()) {
        my $c = $cache->get(_candKey($a->{name}, $artist)) or next;
        $resolved = 1;
        $bySvc{ $a->{name} } = _reattach($a->{name}, $c->{items});
    }
    return {
        sections => $class->matchesFor(\%bySvc, $artist, $albumTitle, $local),
        resolved => $resolved ? 1 : 0,
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
# Per-service artist searches. Unlike PFR these do NOT filter by album — the
# full candidate list is cached and filtered per release group later. Each
# candidate carries: the native rendered node (playable), _svc, _albumid,
# _cover (native art), _candTitle/_candArtist (raw, for the matcher).
# ---------------------------------------------------------------------------

sub _decorate {
    my ($item, $svc, $album, $candArtist) = @_;
    $item->{_svc}        = $svc;
    $item->{_albumid}    = $album->{id};
    $item->{_cover}      = $item->{image} if defined $item->{image} && !ref $item->{image};
    $item->{_candTitle}  = $album->{title};
    $item->{_candArtist} = $candArtist;
    # Qobuz search albums sometimes carry an editorial description — kept as a
    # review fallback for the detail page (MAI wins when it has one).
    $item->{_desc}       = $album->{description}
        if defined $album->{description} && !ref $album->{description} && length $album->{description};
}

sub _searchQobuz {
    my ($client, $query, $svc, $collect) = @_;

    my $api = Plugins::Qobuz::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return }

    $api->search(sub {
        my $res = shift;
        return $collect->(undef) unless defined $res;
        my @out;
        my $rendererFailed = 0;
        for my $album (@{ ($res && $res->{albums} && $res->{albums}{items}) || [] }) {
            next unless ref $album eq 'HASH' && defined $album->{id};
            next if defined $album->{streamable} && !$album->{streamable};
            my $candArtist = ref $album->{artist} eq 'HASH' ? $album->{artist}{name} : '';
            # Guard the foreign renderer — a die here is inside an async callback.
            my $item = eval { Plugins::Qobuz::Plugin::_albumItem($client, $album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Qobuz _albumItem failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            _decorate($item, $svc, $album, $candArtist);
            push @out, $item;
        }
        return $collect->(undef) if !@out && $rendererFailed;
        $collect->(\@out);
    }, lc($query), 'albums');
}

sub _searchTidal {
    my ($client, $query, $svc, $collect) = @_;

    my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return }

    $api->search(sub {
        my $albums = shift;
        return $collect->(undef) unless defined $albums;
        my @out;
        my $rendererFailed = 0;
        for my $album (@{ $albums || [] }) {
            next unless ref $album eq 'HASH' && defined $album->{id};
            my $artistRef  = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            my $item = eval { Plugins::TIDAL::Plugin::_renderAlbum($album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Tidal _renderAlbum failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            _decorate($item, $svc, $album, $candArtist);
            push @out, $item;
        }
        return $collect->(undef) if !@out && $rendererFailed;
        $collect->(\@out);
    }, { type => 'albums', search => $query, limit => 50 });
}

sub _searchDeezer {
    my ($client, $query, $svc, $collect) = @_;

    my $api = Plugins::Deezer::Plugin::getAPIHandler($client);
    unless ($api) { $collect->(undef); return }

    $api->search(sub {
        my $albums = shift;
        return $collect->(undef) unless defined $albums;
        $albums = $albums->{data} || $albums->{albums} || [] if ref $albums eq 'HASH';
        return $collect->([]) unless ref $albums eq 'ARRAY';
        my @out;
        my $rendererFailed = 0;
        for my $album (@$albums) {
            next unless ref $album eq 'HASH' && defined $album->{id};
            my $artistRef  = $album->{artist} || ($album->{artists} && $album->{artists}[0]) || {};
            my $candArtist = ref $artistRef eq 'HASH' ? $artistRef->{name} : '';
            my $item = eval { Plugins::Deezer::Plugin::_renderAlbum($album) };
            if ($@ || ref $item ne 'HASH') {
                $log->warn("Deezer _renderAlbum failed: $@") if $@;
                $rendererFailed = 1;
                next;
            }
            _decorate($item, $svc, $album, $candArtist);
            push @out, $item;
        }
        return $collect->(undef) if !@out && $rendererFailed;
        $collect->(\@out);
    }, { search => $query, type => 'album', strict => 'off', limit => 50 });
}

# ===========================================================================
# Matching (verbatim from the Pitchfork/ListenBrainz plugins — keep in sync)
# ===========================================================================

sub _albumMatches {
    my ($artistNorm, $albumNorm, $candArtist, $candTitle) = @_;

    return 0 if length $albumNorm < 2;
    my $t = _norm($candTitle);
    return 0 if $t eq '';

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
    $s =~ s/\$/s/g;
    $s =~ s/\x{20ac}/e/g;   # euro sign
    $s =~ s/\x{a3}/l/g;     # pound sign
    $s =~ s/\x{a5}/y/g;     # yen sign
    $s =~ s/!/i/g;
    $s =~ s/\@/a/g;
    $s =~ s/[\(\[].*?[\)\]]//g;
    $s =~ s/[^\p{Alnum}]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}

1;
