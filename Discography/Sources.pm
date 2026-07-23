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
# Dedicated, version-scoped cache namespace -- see the note in API.pm.
# MUST match API.pm exactly (asserted by tools/syntax_check.sh).
use constant CACHE_NS      => 'discography';
use constant CACHE_VERSION => '0.50.5';
my $cache = Slim::Utils::Cache->new(CACHE_NS, CACHE_VERSION);

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
use constant PUNCT_PROBE_MAX     => 2;      # term probes on a Local miss
use constant PUNCT_PROBE_MIN_LEN => 4;      # skip "the"/"of" as probe terms
use constant SEARCH_MERGED_MAX => 30;       # merged result rows shown
use constant LOCAL_TRACKS_MAX  => 2000;     # owned tracks scanned for track-linking

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
# Encode BEFORE folding, so a key cannot depend on which shape the name arrived
# in (a CLI param and a decoded JSON string differ). Mirrors API::_nameKey.
#
# DEFENSIVE, NOT A FIX -- and worth stating, because I first believed otherwise:
# I expected raw _norm to disagree across encodings (the 0.43.3 trap) and wrote
# a test control asserting it. The control DISPROVED it -- 0.44.26's %FOLD
# extension already handles both shapes (tools/t_local.pl). The real defect was
# only ever the missing ASCII-folded QUERY below.
sub _normKey {
    my ($s) = @_;
    $s = defined $s ? $s : '';
    utf8::encode($s) if utf8::is_utf8($s);
    return _norm($s);
}

# ---------------------------------------------------------------------------
# ONE LOCAL ARTIST LOOKUP FOR BOTH ENTRY PATHS.
#
# Simon, 2026-07-22: "we need to ensure all fixes we do for matching are done
# across matching from the rows in Artists and via our search." The &/and retry
# (0.44.23) and the punctuation probe (0.44.26) were built into searchArtists'
# Local leg ONLY; localAlbums' name fallback never got them, so the same "you
# do not own this artist" bug was still live whenever an artist was reached BY
# NAME -- a search drill-in, a similar-artist link or a band link.
#
# Measured before writing this (browse by name, 0.45.1):
#   Björk 0 local · Röyksopp 0 · The B‐52's 0 · Sigur Rós 5
# against browse by artist_id, which is correct for all four. LMS itself finds
# every one of them, so the library was never the problem.
#
# The ladder, cheapest first, each step only on a total miss:
#   1. the text as typed
#   2. the &/and variant          (LMS does not fold "&" against "and")
#   3. the ASCII-FOLDED spelling  (LMS's index DOES fold accents -- verified
#      live: `search:Bjork` returns Björk -- and this is the step that recovers
#      a SINGLE-WORD accented name, which the term probe below cannot)
#   4. the most selective terms   (recovers apostrophes/hyphens: `search:Jane`
#      finds "Jane's Addiction")
# Rows from the recovery steps are norm-verified by the CALLER, so widening the
# net here cannot adopt a wrong artist.
# ---------------------------------------------------------------------------
# $opt->{no_probe} skips the TERM PROBES only (the spelling ladder still runs).
# The probes are the widest net and exist to rescue a MANGLED USER-TYPED string
# ("b52s"); when the caller already holds a canonical artist name — as
# attachLibraryArtists does, straight off a service row — they cost two extra
# CLI queries per lookup and cannot add a hit the spelling ladder would miss.
# Measured 2026-07-22: they were 20 of the 30 queries a 10-row search made.
# DEFAULT IS UNCHANGED, so localAlbums and the search Local leg keep the net.
sub _localArtistRows {
    my ($text, $opt) = @_;
    $opt ||= {};
    return [] unless defined $text && length $text;

    my $enc = $text;
    utf8::encode($enc) if utf8::is_utf8($enc);

    my @tries = ($enc);
    my $alt   = $enc;
    if    ($alt =~ s/\s*&\s*/ and /g)  { push @tries, $alt }
    elsif ($alt =~ s/\s+and\s+/ & /gi) { push @tries, $alt }

    # ASCII fold: strip combining marks, then drop anything still non-ASCII.
    my $dec = $text;
    utf8::decode($dec) unless utf8::is_utf8($dec);
    my $fold = $dec;
    if (eval { require Unicode::Normalize; 1 }) {
        $fold = Unicode::Normalize::NFD($fold);
        $fold =~ s/\p{NonspacingMark}//g;
    }
    # TYPOGRAPHIC PUNCTUATION MUST BE TRANSLITERATED, NOT STRIPPED. It is not a
    # combining mark, so NFD leaves it intact, and deleting it JOINS the words:
    # "Yo‐Yo Ma" (U+2010 HYPHEN) became "YoYo Ma", which LMS cannot match --
    # measured, this is why The B‐52's and Yo‐Yo Ma still failed after the fold
    # recovered Björk/Röyksopp/ROSALÍA. Map to the ASCII the library actually
    # holds, THEN drop anything still non-ASCII.
    $fold =~ tr/\x{2010}\x{2011}\x{2012}\x{2013}\x{2014}\x{2015}\x{2212}/\-\-\-\-\-\-\-/;
    $fold =~ tr/\x{2018}\x{2019}\x{201A}\x{201B}\x{2032}/'''''/;
    $fold =~ tr/\x{201C}\x{201D}\x{201E}\x{201F}\x{2033}/"""""/;
    $fold =~ s/\x{2026}/.../g;
    $fold =~ s/[^\x00-\x7F]//g;
    $fold =~ s/\s+/ /g;
    $fold =~ s/^\s+|\s+$//g;
    push @tries, $fold if length $fold && $fold ne $enc;

    my $run = sub {
        my ($q) = @_;
        my $req = eval { Slim::Control::Request::executeRequest(undef,
            ['artists', 0, SEARCH_MAX, "search:$q", 'role_id:' . PERFORMANCE_ROLES]) };
        return () unless $req;
        return grep { defined $_->{name} && length $_->{name} }
               map  { { name => $_->{artist}, artist_id => $_->{id} } }
               @{ $req->getResult('artists_loop') || [] };
    };

    for my $try (@tries) {
        my @hits = $run->($try);
        if (@hits) {
            _dbg("Local lookup '$text': matched " . scalar(@hits)
                 . ($try eq $enc ? '' : " via variant '$try'"));
            return \@hits;
        }
    }

    # Term probes last -- widest net, so it runs only when everything else missed.
    if ($opt->{no_probe}) {
        _dbg("Local lookup '$text': no library artist found (tried "
             . scalar(@tries) . ' spelling(s), term probes skipped)');
        return [];
    }
    # The length floor drops a probable ASCII STOPWORD ("the"/"of") -- but only
    # when the token is ASCII. A short NON-ASCII token is a whole word in a dense
    # script (CJK/Yi/Georgian/Tamil...), never a stopword, and is often the ONLY
    # handle LMS indexes for a name it cannot match whole. Field 2026-07-23: an
    # artist whose name is symbols + combining marks whose sole searchable token
    # is "\x{a27a}\x{10da}" (2 chars) -- the exact spelling AND the ASCII fold
    # both return nothing, so this probe is the only route to the owned album,
    # which otherwise resolves to a streaming service instead of Local.
    my @terms = sort { length($b) <=> length($a) || $a cmp $b }
                grep { length($_) >= PUNCT_PROBE_MIN_LEN || /[^\x00-\x7f]/ }
                split /[^\p{Alnum}]+/, $dec;
    for my $term (grep { defined } @terms[0 .. PUNCT_PROBE_MAX - 1]) {
        my $tEnc = $term;
        utf8::encode($tEnc) if utf8::is_utf8($tEnc);
        my @hits = $run->($tEnc);
        if (@hits) {
            _dbg("Local lookup '$text': matched " . scalar(@hits) . " via term probe '$term'");
            return \@hits;
        }
    }
    _dbg("Local lookup '$text': no library artist found (tried "
         . scalar(@tries) . ' spelling(s) + term probes)');
    return [];
}

# THE PARTS OF A JOINT CREDIT (0.48.6) — canonical for the whole plugin.
# API::_creditHead delegates here, so "what counts as a joint credit" has ONE
# definition and the MB side and the library side cannot drift apart.
#
# Separators need spaces around them, so an ampersand INSIDE a name survives
# ("AC/DC", "Hall & Oates").
#
# NO LENGTH RULE HERE, deliberately — and the first cut had one, which broke
# `_creditHead`'s "Stan Getz / A / B" case (it only ever checked the HEAD). Each
# caller already applies a test far stronger than a character count: the
# resolver requires its head to be >= 3 and to resolve on MusicBrainz, and the
# library lookup requires EVERY part to resolve to a real contributor by exact
# normalised name. "A" is refused because no contributor is called "A", not
# because it is one letter.
our $CREDIT_SPLIT = qr{\s+(?:/|&|\+|feat\.?|featuring|with|and|vs\.?|versus)\s+}i;

sub _creditParts {
    my ($name) = @_;
    return () unless defined $name && $name =~ $CREDIT_SPLIT;
    my @p = split $CREDIT_SPLIT, $name;
    for my $x (@p) { $x =~ s/^\s+|\s+$//g }
    @p = grep { length } @p;
    return () unless @p >= 2;
    return @p;
}

# TWO INDEPENDENT INCONSISTENCIES, so a joint credit needs matching from BOTH
# ends (Simon, 2026-07-22: *"some users might tag it as Robert Plant & Alison
# Krauss, same as they might for Panda Bear and Sonic Boom ... MB isn't itself
# consistent with doing this, some are new artists entirely"*).
#
#                     | library: separate contributors | library: one joint
#   ------------------+--------------------------------+--------------------
#   MB HAS a joint    | the duo's page finds NOTHING   | works (name matches)
#   artist (Plant &   | <- Simon's Raising Sand        |
#   Krauss, 38eb4af8) |                                |
#   ------------------+--------------------------------+--------------------
#   MB has NO joint   | works (0.47.0 splits to the    | album INVISIBLE: the
#   artist (Cave &    | head act, who IS a contributor)| head act has no
#   Ellis, PB & SB)   |                                | contributor at all
#
# Only the diagonal worked. Measured on Simon's library, both contributors hold
# the record — LMS honours a `;`-separated ALBUMARTIST correctly, and it is the
# `albums` query's single DISPLAY string that collapses, not the join:
#     artist_id 56743 Robert Plant  -> 19127 Raising Sand
#     artist_id 56744 Alison Krauss -> 19127 Raising Sand
# while MusicBrainz models a THIRD artist his library has no contributor for.
#
# ONE symmetric rule fixes both corners, treating a joint name as the SET of
# its parts whichever side it appears on:
#   * browsed name is joint, the library has the parts -> INTERSECT their album
#     sets. The intersection IS the duo's catalogue by construction, so no
#     amount of solo work can leak in and "Also in your library" stays honest.
#   * browsed name is single, a library contributor is joint AND NAMES IT as
#     one of its parts -> that contributor counts too.
sub _localArtistIds {
    my ($artist) = @_;
    my $an = _normKey($artist);
    my @rows = @{ _localArtistRows($artist) };
    my ($exact) = grep { _normKey($_->{name}) eq $an } @rows;

    # (B) Joint contributors naming this artist as a part. Deliberately NOT
    # gated on a miss, unlike (A): a user owning BOTH a plain "Nick Cave"
    # contributor and a "Nick Cave & Warren Ellis" one must get both, or the
    # collaboration silently disappears from the page it belongs on. The test
    # is part EQUALITY, never substring, so "Nick Cave" cannot pick up
    # "Nick Cavendish & Friends".
    my @joint = grep {
        my @p = _creditParts($_->{name} // '');
        @p >= 2 && grep { _normKey($_) eq $an } @p;
    } @rows;

    if ($exact || @joint) {
        my @ids = map { $_->{artist_id} }
                  grep { $_ && $_->{artist_id} } ($exact ? ($exact) : ()), @joint;
        my (%seen, @uniq);
        push @uniq, $_ for grep { !$seen{$_}++ } @ids;
        return (\@uniq, 0) if @uniq;
    }

    # (A) The browsed name is itself a joint credit and the library files it as
    # its members. EVERY part must resolve to a contributor, or there is no
    # intersection to take and a half-match could speak for the wrong act.
    my @parts = _creditParts($artist);
    return ([], 0) unless @parts >= 2;
    my @pid;
    for my $p (@parts) {
        my $pn = _normKey($p);
        my ($hit) = grep { _normKey($_->{name}) eq $pn }
                    @{ _localArtistRows($p, { no_probe => 1 }) };
        return ([], 0) unless $hit && $hit->{artist_id};
        push @pid, $hit->{artist_id};
    }
    return (\@pid, 1);
}

sub localAlbums {
    my ($class, $artistId, $artist) = @_;
    return [] unless ($prefs->get('svc_priority_local') // 1) > 0;

    my @ids      = $artistId ? ($artistId) : ();
    my $intersect = 0;

    # No artist_id (non-library entry surface): resolve by name, norm-verified
    # so a fuzzy `artists search:` can't adopt the wrong artist.
    if (!$artistId && defined $artist && length $artist) {
        my ($found, $needAll) = _localArtistIds($artist);
        @ids       = @$found;
        $intersect = $needAll;
        _dbg("localAlbums: name '$artist' -> "
             . (@ids ? 'artist_id ' . join('+', @ids)
                       . ($intersect ? ' (joint credit, intersected)' : '')
                     : 'NO library artist'));
        return [] unless @ids;
    }
    return [] unless @ids;
    $artistId = $ids[0];

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
    #
    # ONE query per contributor (normally exactly one). With $intersect the
    # album must appear under EVERY part of the joint credit — that is what
    # makes the result the duo's catalogue rather than the union of two solo
    # discographies. Without it the sets are merged, deduped by album id.
    my (@rows, %seenAlbum, %hits);
    for my $id (@ids) {
        my $r = eval {
            Slim::Control::Request::executeRequest(undef,
                ['albums', 0, 500, "artist_id:$id",
                 'role_id:' . PERFORMANCE_ROLES, 'tags:ljya']);
        };
        next unless $r;
        for my $e (@{ $r->getResult('albums_loop') || [] }) {
            next unless $e->{id};
            $hits{ $e->{id} }++;
            push @rows, $e unless $seenAlbum{ $e->{id} }++;
        }
    }
    @rows = grep { $hits{ $_->{id} } == scalar @ids } @rows if $intersect;
    return [] unless @rows;

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
    for my $e (@rows) {
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
    _dbg("local albums for artist_id=" . join("+", @ids) . ": " . scalar @out
        . (@out ? ' | ' . join('; ', map {
              ($_->{_candTitle} // '?') . ' mbid=' . ($_->{_mbid} // 'NONE')
          } @out) : ''));
    return \@out;
}

# Owned TRACKS for the artist — the track-level twin of localAlbums, for a
# release the user owns only as a COMPILATION TRACK (Simon: an act's single that
# he owns only via a Nuggets/Pushin'-Too-Hard comp). Same PERFORMANCE-role gate
# and same id-vs-name resolution as localAlbums. Each track carries a direct
# `db:track.id` play string and the comp it lives on (for the row hint). Fetched
# LAZILY by the caller (only when a release goes otherwise-unmatched), so an
# artist owned as albums never pays for it.
sub localTracks {
    my ($class, $artistId, $artist) = @_;
    return [] unless ($prefs->get('svc_priority_local') // 1) > 0;

    my @ids = $artistId ? ($artistId) : ();
    if (!$artistId && defined $artist && length $artist) {
        my ($found) = _localArtistIds($artist);
        @ids = @$found;
        return [] unless @ids;
    }
    return [] unless @ids;

    my (@out, %seen);
    for my $id (@ids) {
        my $r = eval {
            Slim::Control::Request::executeRequest(undef,
                ['titles', 0, LOCAL_TRACKS_MAX, "artist_id:$id",
                 'role_id:' . PERFORMANCE_ROLES, 'sort:album', 'tags:ulJ']);
        };
        next unless $r;
        for my $e (@{ $r->getResult('titles_loop') || [] }) {
            next unless $e->{id} && defined $e->{title} && length $e->{title};
            next if $seen{ $e->{id} }++;
            my $img = $e->{artwork_track_id} ? "/music/$e->{artwork_track_id}/cover" : undef;
            push @out, {
                name        => $e->{title},
                type        => 'audio',
                ($e->{url} ? (url => $e->{url}) : ()),
                play        => 'db:track.id=' . $e->{id},
                _svc        => 'Local',
                _track      => 1,
                _trackid    => $e->{id},
                _candTitle  => $e->{title},
                _candArtist => $artist,
                ($img ? (_cover => $img) : ()),
                _fromAlbum  => $e->{album},
            };
        }
    }
    _dbg("local tracks for artist_id=" . join('+', @ids) . ": " . scalar @out);
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
            # An UNRESOLVED artist settles undef exactly like a handler error or
            # a timeout does (see the spine branch in _qobuz/_tidal/_deezer), so
            # this line must not claim a cause it cannot know. It read
            # "error (handler/timeout/renderer)" and sent a field diagnosis
            # after a Qobuz timeout that was really "this artist could not be
            # identified under that name".
            _dbg("candidates $svc/'$artist': "
                . (defined $n ? $n . $sample
                              : 'no pool (artist unresolved, or handler/timeout/renderer error)'));
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
        # SHARED with localAlbums' name fallback -- one ladder, so the &/and
        # retry, the ASCII fold and the term probes can never again exist on
        # one entry path and not the other (Simon, 2026-07-22).
        my @hits = @{ _localArtistRows($query) };

        # Recovery steps widen the net, so anything they returned is
        # norm-verified against what the user typed before it is offered as a
        # Local row. An exact-spelling match needs no gate.
        if (@hits) {
            my $qn = _normKey($query);
            my @exact = grep { _normKey($_->{name}) eq $qn } @hits;
            @hits = @exact if @exact;
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

# ONE LAST CHANCE to attach a merged search row to the user's OWN library,
# using the row's own name.
#
# FIELD (Simon, 2026-07-22): searching "The Las" renders "The La's" with only
# Tidal/Deezer, although he owns it. Three independent safety nets exist and
# this is the one name that slips past ALL of them:
#
#   1. the Local leg: `artists search:The Las` returns The Last / The Last Word
#      / The Last Dinner Party -- real bands, WRONG ones. `_localArtistRows`
#      returns at the first non-empty step, so a wrong answer actively BLOCKS
#      the fallbacks. ("Las" is a prefix of "Last"; "OJays" is a prefix of
#      nothing, which is why The O'Jays never hits this.)
#   2. the term probes: skipped, because every word is under
#      PUNCT_PROBE_MIN_LEN -- "The" (3) and "Las" (3). Rag'n'Bone Man survives
#      only because "Bone" happens to be 4 letters.
#   3. API::filterRowsWithContent's MB canonical/alias attach: runs ONLY for
#      DUPLICATED mbid groups, and every service spells this one identically,
#      so it is a lone row. (The O'Jays is rescued there purely because the
#      services disagreed -- straight vs curly apostrophe. Luck, not design.)
#
# So it is not really an apostrophe problem: it is a SHORT-NAME problem, where
# the plain spelling collides with other real artists and the services agree.
#
# The row is already labelled with a service spelling the library CAN match
# ("The La's" -> library "The La’s"), so one more lookup settles it. Costs NO
# MusicBrainz request -- which is the cost API.pm:1066 was avoiding -- and runs
# on public installs too, where filterRowsWithContent bails out entirely.
#
# NORM-VERIFIED, the same gate the other attach paths use: an exact `_normKey`
# match, so "The Last" can never adopt "The La's".
use constant LIB_PROBE_MAX => 10;   # rows probed per search (each a local DB hit)

# TYPOGRAPHIC PUNCTUATION ONLY — curly quotes, the non-ASCII dashes, prime and
# ellipsis. NOT diacritics: "Björk" and "Sigur Rós" are correct spellings that
# every name-keyed lookup resolves, and must never be penalised here.
#
# WHY THIS EXISTS (regression I shipped in 0.48.1, caught by Simon the same
# day: "it doesn't have artwork"). 0.46.5 established that the LIBRARY's
# spelling outranks MusicBrainz's, measured on the live image proxy:
#     "The B-52s" (library, ASCII) -> 1,966,381 bytes, a photo
#     "The B‐52s" (MB, U+2010)     ->     5,071 bytes, the silhouette
# But that rule assumed the library holds the CLEANER spelling. Simon's library
# holds "The La’s" with a CURLY apostrophe, so adopting it blindly produced
# exactly the same failure in reverse — measured the same way:
#     "The La's" (ASCII)  -> 2,317,943 bytes, a photo
#     "The La’s" (curly)  ->     5,071 bytes, the SAME placeholder byte-for-byte
# So the rule is not "the library's spelling wins", it is "the spelling that
# RESOLVES wins" — which in 0.46.5's case happened to be the library's.
sub _typoMarks {
    my ($s) = @_;
    return 0 unless defined $s && length $s;
    my $d = $s;
    utf8::decode($d) unless utf8::is_utf8($d);
    my $n = () = $d =~ /[\x{2010}-\x{2015}\x{2018}-\x{201F}\x{2032}\x{2033}\x{2212}\x{2026}]/g;
    return $n;
}

# How many albums a contributor actually holds. Duplicate contributors are a
# real tagging artefact (Simon's library carries BOTH "The La's" and "The La’s"
# as separate artists), and only one of them has the music: 58667 has NO
# albums, 57545 has five. Attaching the empty one would open a blank page.
sub _albumCountFor {
    my ($id) = @_;
    return 0 unless $id;
    my $req = eval { Slim::Control::Request::executeRequest(undef,
        ['albums', 0, 1, "artist_id:$id", 'role_id:' . PERFORMANCE_ROLES]) };
    return 0 unless $req;
    my $n = $req->getResult('count');
    return (defined $n && $n =~ /^\d+$/) ? $n : 0;
}

# LMS's OWN per-artist icon URL, keyed by artist_id — the ARTIST art it shows in
# its artist menu (folder artist-art MAI ingests on rescan), NOT an album cover.
# Returns { artist_id => 'contributor/<hash>/image' | '' } for every same-name
# artist LMS lists: a URL when it holds artist art, '' when it knows the artist
# but has none (so the caller shows a neutral icon rather than MAI's online
# guess). Used to give same-name owned acts their OWN correct thumbnails —
# MAI's `imageproxy/mai/artist/<id>` route serves this SAME art when it exists
# (verified byte-identical), but INVENTS an online photo of the prominent act
# when it does not, which is exactly the "bootleg shows the UK band" case
# (Simon, 2026-07-23). Empty client, like every other CLI query here.
sub _artistMenuIcons {
    my ($name) = @_;
    return {} unless defined $name && length $name;
    my $enc = $name;
    utf8::encode($enc) if utf8::is_utf8($enc);
    my $r = eval { Slim::Control::Request::executeRequest(undef,
        ['browselibrary', 'items', 0, 50, 'mode:artists', "search:$enc", 'menu:1']) };
    return {} unless $r;
    my %icon;
    for my $it (@{ $r->getResult('item_loop') || [] }) {
        my $aid = ($it->{commonParams} && $it->{commonParams}{artist_id})
               // ($it->{params}       && $it->{params}{artist_id});
        next unless $aid;
        $icon{$aid} = (defined $it->{icon} && length $it->{icon}) ? $it->{icon} : '';
    }
    return \%icon;
}

sub attachLibraryArtists {
    my ($class, $rows) = @_;
    return $rows unless $rows && @$rows;
    return $rows unless ($prefs->get('svc_priority_local') // 1) > 0;

    my ($probes, $found) = (0, 0);
    my @out;
    for my $r (@$rows) {
        my $name = $r->{name};
        if ($r->{artist_id} || !defined $name || !length $name
            || $probes >= LIB_PROBE_MAX) {
            push @out, $r;
            next;
        }
        $probes++;
        my $want = _normKey($name);
        my @hits = grep { _normKey($_->{name}) eq $want }
                   @{ _localArtistRows($name, { no_probe => 1 }) };
        if (!@hits) {
            # A COLLABORATION the user OWNS via its members (0.48.8). Field
            # (Simon, screenshot): the "Robert Plant & Alison Krauss" search row
            # read just "Qobuz", with no Local, though he owns Raising Sand —
            # which is tagged under both member contributors, not under a
            # contributor of the duo's name. So the exact probe above finds
            # nothing, but localAlbums' joint-credit intersection (0.48.6) does.
            # Add the Local SOURCE, but NO artist_id: there is no single
            # contributor to navigate to, and the row already drills to the duo
            # correctly by name/mbid. Only for a name that IS a joint credit, so
            # ordinary rows pay nothing.
            if (_creditParts($name) && @{ $class->localAlbums(undef, $name) }) {
                my %row  = %$r;
                my %have = map { $_ => 1 } @{ $row{sources} || [] };
                $row{sources} = [ @{ $row{sources} || [] } ];
                unshift @{ $row{sources} }, 'Local' unless $have{Local};
                $found++;
                _dbg("search rows: '$name' is an OWNED collaboration "
                     . '(intersection of member contributors) - added Local');
                push @out, \%row;
                next;
            }
            push @out, $r;
            next;
        }
        # Duplicate contributors differing only by apostrophe style are a real
        # tagging artefact, and only one of them holds the albums — take that
        # one, or the row opens a blank page. One extra query, and only when
        # the library genuinely has more than one match.
        my $hit = $hits[0];
        if (@hits > 1) {
            my ($best) = sort { $b->{_n} <=> $a->{_n} }
                         map  { { %$_, _n => _albumCountFor($_->{artist_id}) } } @hits;
            $hit = $best;
            _dbg("search rows: '$name' matched " . scalar(@hits)
                 . " library artists; kept '$hit->{name}' ($hit->{_n} album(s))");
        }
        # COPY before decorating: these rows come straight out of the 10-minute
        # search cache on a hit, and the fleet rule is never to decorate a
        # shared cache entry in place.
        my %row  = %$r;
        my %have = map { $_ => 1 } @{ $row{sources} || [] };
        $row{sources}   = [ @{ $row{sources} || [] } ];
        unshift @{ $row{sources} }, 'Local' unless $have{Local};
        $row{artist_id} = $hit->{artist_id};
        # THE SPELLING THAT RESOLVES WINS — not simply the library's.
        #
        # 0.46.5 made the library's spelling outrank MusicBrainz's because the
        # library held the cleaner one. Adopting it BLINDLY shipped the same bug
        # in reverse (0.48.1): Simon's library spells it "The La’s" with a curly
        # apostrophe, and the artist-artwork proxy returned the 5,071-byte
        # silhouette for that name while the ASCII "The La's" the row already
        # carried returned a 2,317,943-byte photo. The artist_id is still the
        # library's — that is where the albums are — only the LABEL is kept.
        $row{name} = $hit->{name} if _typoMarks($hit->{name}) <= _typoMarks($name);
        $found++;
        _dbg("search rows: attached library artist '$hit->{name}' (artist_id "
             . "$hit->{artist_id}) to row '$name'"
             . ($row{name} eq $name && $hit->{name} ne $name
                ? " - KEPT the row's spelling (fewer typographic marks)" : ''));
        push @out, \%row;
    }
    _dbg("search rows: library probe attached $found of $probes row(s)") if $probes;
    return \@out;
}

# A contributor's MusicBrainz artist tag (the SAME read getArtistMbid trusts
# first, API.pm:285), lowercased, or undef when untagged / not a UUID. Cheap: a
# local DB lookup, no network.
sub _contribMbid {
    my ($id) = @_;
    return undef unless $id;
    my $mbid = eval {
        require Slim::Schema;
        my $c = Slim::Schema->find('Contributor', $id);
        $c ? $c->musicbrainz_id : undef;
    };
    return (defined $mbid && $mbid =~ /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i)
        ? lc $mbid : undef;
}

# SPLIT AN OWNED SEARCH ROW INTO ONE ROW PER OWNED IDENTITY.
#
# Field (Simon): he owns THREE distinct acts called "The Bees" — the UK band,
# a US garage band and a third with a bootleg-only spine — as three separate
# library contributors, each carrying its own MusicBrainz tag. LMS's own library
# search shows all three; ours showed one, because `mergeArtistHits` buckets by
# `_norm(name)` and keeps only the FIRST contributor id (Sources.pm:1348) — so
# two of the three acts were unreachable, and the surviving row drilled into
# whichever contributor happened to be first (the garage band).
#
# Simon's rule, verbatim: "it should fold them if the same artist but if
# legitimate different acts it should not." The discriminator is MUSICBRAINZ
# IDENTITY, not the name string: contributors sharing a tag mbid are the same
# act (fold into one row); contributors with different tags are different acts
# (a row each). The three Bees carry three different tags, so three rows.
#
# WHY THIS IS A SEPARATE PASS, not part of the merge: `mergeArtistHits` is a
# PURE function (no DB), which is what lets t_fold/t_fuzzy/t_rank run headless
# and what its 10-minute cache stores. Identity needs the library, so it lives
# here, in the DB-aware layer, run by Browse::_withMbCandidates AFTER the merge
# — where the discarded contributor ids are re-derived from `_localArtistRows`.
#
# STREAMING SOURCES ARE DELIBERATELY NOT ATTRIBUTED. A service "The Bees" entity
# carries no MBID, so knowing which owned act it belongs to would mean the
# per-row spine scoring the search path refuses to pay (0.44.7 / 0.46.6). Each
# split row therefore shows only "Local"; the CORRECT streaming catalogue is
# recovered on drill-in, where `_resolveArtist` scores it against that identity's
# spine. The planned library identity index is what makes attributing them cheap
# and safe later — until then, honest "Local" beats a guessed service label.
#
# `_ident_mbid` is stamped on EVERY owned row (single-identity too), for the
# disambiguation section to exclude owned acts by mbid rather than by the older
# name-match heuristic. It is in-memory only — never rendered, never cached (the
# cache holds the pre-split merged list, same shape as before).
sub splitOwnedByIdentity {
    my ($class, $rows) = @_;
    return $rows unless $rows && @$rows;
    return $rows unless ($prefs->get('svc_priority_local') // 1) > 0;

    my $probes = 0;
    my @out;
    for my $r (@$rows) {
        my $name = $r->{name};
        # Only OWNED rows (an artist_id, from the Local leg or attachLibraryArtists)
        # can be split, and the probe is bounded like attachLibraryArtists'.
        if (!$r->{artist_id} || !defined $name || !length $name
            || $probes >= LIB_PROBE_MAX) {
            push @out, $r;
            next;
        }
        $probes++;

        # All same-name contributors, deduped by id, in LMS's stable order.
        my $want = _normKey($name);
        my (%seenId, @contribs);
        for my $c (grep { _normKey($_->{name}) eq $want }
                   @{ _localArtistRows($name, { no_probe => 1 }) }) {
            next unless $c->{artist_id} && !$seenId{ $c->{artist_id} }++;
            push @contribs, $c;
        }
        # The row's own contributor may not spell-match its label (0.48.1 keeps
        # the row's spelling); make sure it is represented.
        push @contribs, { name => $name, artist_id => $r->{artist_id} }
            unless $seenId{ $r->{artist_id} }++;

        # Group by MusicBrainz identity. An untagged contributor is its own
        # identity, keyed by id, so two untagged same-name contributors are NOT
        # blindly folded (we cannot prove they are one act) — but neither do
        # they masquerade as each other.
        my (%grp, @order);
        for my $c (@contribs) {
            my $key = _contribMbid($c->{artist_id}) // "id:$c->{artist_id}";
            push @order, $key unless $grp{$key};
            push @{ $grp{$key} }, $c;
        }

        # ONE identity -> the row is a single act. Stamp its mbid and keep it.
        if (@order < 2) {
            my %row = %$r;
            $row{_ident_mbid} = _contribMbid($r->{artist_id});
            push @out, \%row;
            next;
        }

        # SEVERAL identities -> one Local row per act. Emit in a deterministic
        # order (by representative contributor id) so the item_id walk is stable.
        _dbg("search rows: '$name' is " . scalar(@order)
             . ' distinct owned acts (by MB identity) - splitting into rows');
        # LMS's own per-act artist icons (one browselibrary query), so same-name
        # acts get their OWN artist art instead of MAI's online photo of the
        # prominent one.
        my $icons = _artistMenuIcons($name);
        my @reps;
        for my $key (@order) {
            # Within one identity, the contributor holding the most albums is
            # the one that drills to content (apostrophe-variant duplicates).
            my ($rep) = sort { _albumCountFor($b->{artist_id})
                                   <=> _albumCountFor($a->{artist_id}) }
                        @{ $grp{$key} };
            push @reps, [ $rep, ($key =~ /^id:/ ? undef : $key) ];
        }
        for my $pair (sort { $a->[0]{artist_id} <=> $b->[0]{artist_id} } @reps) {
            my ($rep, $identMbid) = @$pair;
            # LMS's ARTIST icon for this act: a URL when it has artist art (use
            # it), '' when LMS knows the act but has none (show a neutral icon,
            # NOT MAI's online guess of the prominent act), undef/absent when the
            # act is not in the menu (fall back to MAI as usual).
            my $ic = $icons->{ $rep->{artist_id} };
            push @out, {
                name       => $rep->{name},
                artist_id  => $rep->{artist_id},
                sources    => ['Local'],
                _ident_mbid => $identMbid,
                (defined $ic && length $ic ? (_img   => $ic)
                 : defined $ic             ? (_noart => 1)
                 :                           ()),
                _exact     => $r->{_exact},
                # keep the split rows clustered where the original row sat;
                # rankArtistHits' stable sort preserves the emission order above
                # for equal _seq.
                _seq       => $r->{_seq},
            };
        }
    }
    return \@out;
}

# RANKING — ONE comparator, deliberately applied TWICE.
#
# Simon, 2026-07-22: *"when searching, a Local artist will show ahead of any
# matches that there is no local artist ... local should always be trumps."*
# Ownership was not a rank key at all; the order was exactness, then how many
# services carried the row, then first-seen. Measured live before changing it:
#
#   typed 'bush'     0 Bush        Q·T·D   <- NOT owned, wins on exact name
#                    1 Kate Bush   Local·Q·D
#                    2 Bush Tetras Local·Q·D
#   typed 'The Las'  6 The Last      Local  <- owned, sunk under six streaming
#                    7 The Last Word Local     rows purely on breadth
#
# WHY OWNERSHIP OUTRANKS EXACTNESS, and this was Simon's call after seeing both
# orderings side by side: "exact" is not only what the user typed — 0.46.4 also
# accepts MusicBrainz's canonical name for whatever the query RESOLVED to, so a
# wrong resolution confers exactness on an unrelated artist. Measured: MB
# resolves the query "La's" to *Yo La Tengo*. Ranking ownership below that key
# means the one thing a user can verify (they own the record) loses to an MB
# inference. Owning it is the strongest signal of intent there is.
#
# ACCEPTED COST, stated plainly: typing a name that exactly matches an artist
# you do NOT own now puts owned near-misses above it — 'bush' returns Kate Bush
# and Bush Tetras before Bush. That is the deliberate trade, not an oversight.
#
# artist_id IS the ownership test and cannot be anything else: `_artistHits`
# builds every streaming hit as `{ name => ... }` with no id whatsoever, so an
# artist_id on a merged row can only have come from the Local leg or from
# `attachLibraryArtists`.
#
# APPLIED TWICE because the two facts arrive at different times. The merge
# knows what the LOCAL LEG found; `attachLibraryArtists` (0.48.1) rescues rows
# the Local leg could not spell-match — "The La's" is the whole reason that sub
# exists — and it runs AFTER the merge, in Browse::_withMbCandidates. Ranking
# only inside the merge would therefore miss exactly the rows 0.48.1 was
# written for. Ranking only after it would let SEARCH_MERGED_MAX truncate an
# owned row before it could be promoted. Both calls, one comparator.
#
# `_seq` is preserved rather than recomputed, so the second pass re-ranks
# WITHOUT re-basing the first-seen tiebreak — the order stays deterministic for
# a given library state, which is what the item_id walk depends on.
sub rankArtistHits {
    my ($class, $rows) = @_;
    return $rows unless $rows && @$rows;
    # OWNERSHIP is artist_id OR a Local source. Normally a Local row carries the
    # contributor id, but an OWNED COLLABORATION (0.48.8) is Local with NO id —
    # there is no single contributor for a duo — and it must still trump.
    my $owned = sub {
        return 1 if $_[0]->{artist_id};
        return scalar grep { $_ eq 'Local' } @{ $_[0]->{sources} || [] };
    };
    my $i = 0;
    for my $r (@$rows) {
        $r->{_seq}   = $i unless defined $r->{_seq};
        $r->{_exact} = 0  unless defined $r->{_exact};
        $i++;
    }
    return [ sort {
        ($owned->($b) ? 1 : 0) <=> ($owned->($a) ? 1 : 0)
            || $b->{_exact} <=> $a->{_exact}
            || @{ $b->{sources} || [] } <=> @{ $a->{sources} || [] }
            || $a->{_seq} <=> $b->{_seq}
    } @$rows ];
}

sub mergeArtistHits {
    my ($class, $query, $bySvc, $order, $also) = @_;
    my @order = $order ? @$order
              : ('Local', map { $_->{name} } orderedAdapters());
    my $key = sub {
        my $k = _norm($_[0] // '');
        $k = _punctNorm($_[0] // '') if $k eq '';
        return $k;
    };

    # ACCEPTED QUERIES: what was typed, PLUS any name the caller ALSO searched
    # the services under (0.45.2's canonical-name pass).
    #
    # Field (Simon, 2026-07-22): searching "b52s" produced a row without Deezer
    # while "b-52s" had all three. Deezer was not missing -- it returned two
    # artists and both were thrown away here, because a hit fetched under MB's
    # canonical name was judged against the string the USER typed:
    #   _norm("The B-52's") = 'the b 52s'   vs typed 'b52s'
    #   substring no · token-subset no · fuzzy no (4-char query, floor is 8)
    # Qobuz and Tidal survived only because their result lists happened to also
    # contain "B52's", which folds exactly onto the typed query -- a spelling
    # lottery, not a Deezer difference.
    #
    # A hit returned for the canonical name must be judged against THAT name.
    # This cannot admit an unrelated artist: the extra query is MusicBrainz's
    # own name for the artist the typed query already resolved to, and every
    # admitted row still faces the dead-end filter downstream.
    my @qk = grep { $_ ne '' } map { $key->($_) }  ($query, @{ $also || [] });
    my @qn = grep { $_ ne '' } map { _norm($_ // '') } ($query, @{ $also || [] });
    my $isExact = sub { my $k = shift; scalar grep { $_ eq $k } @qk };

    my (%bucket, @seq);
    for my $svc (@order) {
        for my $h (@{ $bySvc->{$svc} || [] }) {
            next unless ref $h eq 'HASH';
            my $k = $key->($h->{name});
            next if $k eq '';
            # The relevance gate. No usable query norm (a punct-only query)
            # leaves exact key equality as the only way in.
            unless ($isExact->($k)) {
                my $hn = _norm($h->{name} // '');
                next unless $hn ne '' && grep {
                    index($hn, $_) >= 0 || _artistMatch($_, $hn)
                        || _closeEnough($_, $hn)
                } @qn;
            }
            my $b = $bucket{$k};
            unless ($b) {
                $b = $bucket{$k} = {
                    name => $h->{name}, sources => [],
                    _seq => scalar @seq, _exact => $isExact->($k) ? 1 : 0,
                };
                push @seq, $b;
            }
            push @{ $b->{sources} }, $svc
                unless grep { $_ eq $svc } @{ $b->{sources} };
            $b->{artist_id} //= $h->{artist_id} if $h->{artist_id};
        }
    }
    # Rank BEFORE the cap, or an owned row sitting past SEARCH_MERGED_MAX would
    # be truncated away before Browse's post-attach pass could promote it.
    # `_seq`/`_exact` are deliberately NOT stripped: they are what lets that
    # second pass re-rank consistently, including on the cached path (the rows
    # go into `dsc:asearch` carrying them).
    my $merged = $class->rankArtistHits(\@seq);
    splice @$merged, SEARCH_MERGED_MAX if @$merged > SEARCH_MERGED_MAX;
    return $merged;
}

# ---------------------------------------------------------------------------
# Per-release matching (local filter over the candidate lists)
# ---------------------------------------------------------------------------

# The normalised sides of an "A / B" title — a 45rpm single is titled with both
# sides ("Voices Green and Purple / Trip to New Orleans") while the compilation
# holds only one ("Voices Green and Purple"). Split on a spaced slash so a title
# with an inline "/" ("AC/DC", "9/11") is left whole.
sub _titleSides {
    my ($title) = @_;
    return [] unless defined $title && length $title;
    return [ grep { length } map { _norm($_) } split m{\s+/\s+}, $title ];
}

# Does an owned TRACK correspond to this release group? Title-based and A/B-side
# aware, in BOTH directions (the release may name both sides while the track
# names one, or vice versa). The >= 4-char guard keeps a trivial/generic title
# from linking; the real safety is that the caller only ever passes THIS
# artist's own tracks (id-keyed), so a match is this artist's song either way.
sub _trackLinksRelease {
    my ($rgNorm, $rgTitle, $track) = @_;
    my $tn = _norm($track->{_candTitle} // '');
    return 0 unless length $tn >= 4 && length $rgNorm >= 4;
    return 1 if $tn eq $rgNorm;
    return 1 if grep { $_ eq $tn }     @{ _titleSides($rgTitle) };
    return 1 if grep { $_ eq $rgNorm } @{ _titleSides($track->{_candTitle}) };
    return 0;
}

# matchesFor($bySvc, $artist, $albumTitle, $local) ->
#   [ { svc => 'Local'|'Qobuz'|..., icon, items => [nodes] }, ... ]
# in orderedSources priority order, only sources with matches; per-source
# dedupe + cap; streaming items get the ListenLater favurl handshake (Local
# ones don't — there's no service scheme to hand over).
# $opt->{localTracks} (an arrayref OR a lazy coderef) links a release the user
# owns ONLY as a compilation track — see the track-link pass below.
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
    # MB release-group ALIASES (v2 spine): MusicBrainz titles a group in its
    # original language and files other spellings as aliases, which no title
    # normalisation can reach. Tried only AFTER the canonical title, so an
    # alias can rescue a miss but never change a match that already works.
    my @alts;
    for my $al (@{ $opt->{aliases} || [] }) {
        next unless defined $al && length $al;
        my $an = _norm($al);
        next if $an eq '' || $an eq $albumNorm;
        push @alts, [ $an, $al ];
    }

    my $index = $opt->{index};
    my @lkeys = ($index && length $albumNorm >= 2) ? _titleKeys($albumNorm, $artistNorm) : ();
    # An alias routinely starts with a DIFFERENT word than the canonical title
    # ("Computerwelt" vs "Computer World"), and the index buckets by first
    # token — so without folding the aliases' keys in here, the narrowed subset
    # could not contain the very candidate the alias exists to reach.
    if ($index && @lkeys && @alts) {
        my %seenK = map { $_ => 1 } @lkeys;
        for my $a (@alts) {
            next unless length $a->[0] >= 2;
            push @lkeys, grep { !$seenK{$_}++ } _titleKeys($a->[0], $artistNorm);
        }
    }

    # Canonical title first, then each alias. Returns 1 on the first hit.
    my $titleHit = sub {
        my ($gateArtist, $candTitle) = @_;
        return 1 if _albumMatches($artistNorm, $albumNorm, $gateArtist, $candTitle, $albumTitle);
        for my $a (@alts) {
            return 1 if _aliasMatches($artistNorm, $a->[0], $a->[1], $gateArtist, $candTitle);
        }
        return 0;
    };

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
                next unless $titleHit->($gateArtist, $it->{_candTitle});
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

    # TRACK LINKING — a release the user owns ONLY as a compilation track.
    # Runs ONLY when nothing else matched (an orphaned, otherwise-unplayable
    # spine release): if an owned track links to this release's title, add a
    # Local section that plays that track directly (db:track.id). The comp album
    # itself stays under "Appearances" — this only makes the spine tile playable.
    # localTracks is a lazy coderef so an artist owned as ALBUMS never fetches
    # it; resolved here only because we reached an unmatched release.
    if (!@sections && $opt->{localTracks}) {
        my $lt = ref $opt->{localTracks} eq 'CODE'
               ? $opt->{localTracks}->() : $opt->{localTracks};
        if ($lt && @$lt) {
            my ($localSrc) = grep { $_->{local} } @$sources;
            my (%seen, @tmatch);
            for my $t (@$lt) {
                next unless _trackLinksRelease($albumNorm, $albumTitle, $t);
                next if $seen{ $t->{_trackid} // $t->{_candTitle} }++;
                push @tmatch, { %$t };   # per-release copy, never the shared entry
                last if @tmatch >= MAX_PER_SVC;
            }
            if (@tmatch) {
                unshift @sections, { svc => 'Local',
                    icon => ($localSrc ? $localSrc->{icon} : undef), items => \@tmatch };
                _dbg("track-link '" . ($albumTitle // '') . "' [" . ($artist // '')
                     . "]: " . scalar(@tmatch) . ' owned comp track(s)');
            }
        }
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
        # Same alias pass as matchesFor — an owned copy filed under the English
        # title must be claimed by the German-titled release group, or it leaks
        # into "Also in your library" while its own tile sits right above it.
        my @alts;
        for my $al (@{ $rg->{aliases} || [] }) {
            next unless defined $al && length $al;
            my $an = _norm($al);
            next if $an eq '' || $an eq $albumNorm;
            push @alts, [ $an, $al ];
        }
        for my $it (@$local) {
            next if $claimed{ $it->{_albumid} };
            # $local candidates are ALL Local (join-proven for the browsed
            # artist), so gate on $artist not the collapsed _candArtist — same
            # co-credit reasoning as matchesFor. Keeps a co-credited owned album
            # from leaking into "Also in your library" when its tile matched.
            next unless _mbidMatch($it, $rg->{mbid}, $relMap)
                     || _albumMatches($artistNorm, $albumNorm, $artist, $it->{_candTitle}, $rg->{title})
                     || grep { _aliasMatches($artistNorm, $_->[0], $_->[1], $artist,
                                             $it->{_candTitle}) } @alts;
            $claimed{ $it->{_albumid} } = 1;
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

# HOW MUCH CORROBORATION IS ENOUGH TO STOP LOOKING (0.47.2).
#
# FIELD: browsing "Rossini" adopted a modern rapper on both Tidal and Deezer —
#     Tidal: 'Rossini' is ambiguous - 3637384=1, 51024775=0, 58712447=0, ...
# One title hit against a spine of several HUNDRED release groups is noise, but
# it beat zero and settled the matter. Measured proof a better answer existed,
# same mbid: under MB's canonical name "Gioachino Rossini" the RIGHT Tidal
# artist scores 3, and the page goes from Albums (3) to Albums (19).
#
# So a score below this bar is an answer to be HELD, not one to stop on: the
# resolver buys one more name and keeps whichever corroborates more. Below the
# bar and nothing better turns up, the held pick is returned unchanged — which
# is what keeps an artist whose service titles simply differ from MusicBrainz's
# spellings working exactly as it does today (the very case the verify path was
# deliberately not made the default for).
use constant SPINE_STRONG => 2;

# A weak pick is ALREADY an answer, so it buys exactly ONE more name to compare
# against — Browse puts MB's canonical name at the front of the alias list, and
# that is the rung with the evidence behind it. A total MISS still walks the
# full ALIAS_MAX list, as it always has: there, extra names are the only hope.
use constant WEAK_RETRY_MAX => 1;

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

    # The strongest attempt so far. A WEAKLY corroborated pick is held here
    # rather than returned, so a better-corroborated name can displace it — and
    # is returned unchanged when none does. That fallback is the whole safety
    # argument: every artist that resolves today still resolves, to the same
    # service entity, unless something demonstrably corroborates better.
    my $best;
    my $keep = sub {
        my ($artist, $albums, $score) = @_;
        return unless $artist;
        $best = { artist => $artist, albums => $albums, score => $score }
            if !$best || ($score // 0) > ($best->{score} // 0);
    };
    my $settle = sub {
        return $cb->(undef, undef) unless $best;
        _dbg("$svc: settling on '" . ($best->{artist}{name} // '?')
            . "' (" . ($best->{artist}{id} // '?') . ') with '
            . ($best->{score} // 0) . ' spine title(s) - nothing corroborated better');
        $cb->($best->{artist}, $best->{albums});
    };

    _resolveOne($svc, $query, $artists, $spine, $fetch, sub {
        my ($artist, $albums, $score) = @_;
        # Nothing to judge by (no spine), or a genuinely corroborated artist:
        # done, at exactly today's cost — no extra search, no extra fetch.
        return $cb->($artist, $albums)
            if $artist && (!defined $score || $score >= SPINE_STRONG);
        if ($artist) {
            _dbg("$svc: '" . ($artist->{name} // '?') . "' corroborates only "
                . ($score // 0) . ' spine title(s) - holding it and looking further');
        }
        $keep->($artist, $albums, $score);

        my @names = @{ $aliases || [] };
        # A HELD pick is already an answer, so it buys ONE more name. A total
        # miss still walks the full list.
        my $cap = $best ? WEAK_RETRY_MAX : ALIAS_MAX;
        splice @names, $cap if @names > $cap;
        return $settle->() unless @names && $search;

        # Self-passing closure, not a captured lexical — avoids the reference
        # cycle Perl never reclaims (the 0.30.1 leak fix).
        my $i = 0;
        my $step = sub {
            my ($self) = @_;
            my $alias = $names[$i++];
            return $settle->() unless defined $alias;
            _dbg("$svc: " . ($best ? "only weak corroboration under '$query'"
                                   : "nothing under '$query'")
                . " - retrying MB alias '$alias'");
            $search->($alias, sub {
                _resolveOne($svc, $alias, shift, $spine, $fetch, sub {
                    my ($a, $al, $sc) = @_;
                    return $cb->($a, $al) if $a && (!defined $sc || $sc >= SPINE_STRONG);
                    $keep->($a, $al, $sc);
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
        # SCORE THE PICK — free, because its albums are fetched either way, and
        # it is the only thing standing between a caller and an UNVERIFIED
        # name match. `_pickArtist` falls back to `_artistMatch`, a token
        # SUBSET test, so browsing "Shostakovich" adopts "Maxim Shostakovich"
        # (his son) or "Shostakovich Quartet" with nothing checked at all —
        # measured on Qobuz and Deezer, 2026-07-22. undef = no spine, i.e. no
        # opinion; the caller must not read that as a zero.
        return $fetch->($a->{id}, sub {
            my ($albums) = @_;
            $cb->($a, $albums,
                  ($spine && %$spine) ? _spineScore($albums, $spine) : undef);
        });
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
            $cb->($scored[0]{artist}, $scored[0]{albums}, $scored[0]{score});
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

# An MB release-group ALIAS is a weaker claim than the group's own title, so it
# does NOT get the full rule set — the same discipline 0.11.1 applied to
# self-titled releases, and for the same reason. The prefix rule reads
# "<album> <extra>" as an edition suffix, which is right for "(Deluxe)" and
# WRONG for a different record that merely starts with the same words: via the
# alias "The Man·Machine", Kraftwerk's "Die Mensch·Maschine" claimed the remix
# tribute album "The Man-Machine Recreated" (caught by t_alias.pl, 2026-07-22).
#
# So an alias must be the WHOLE title, with one deliberate exception: a "/" or
# ":" immediately after it marks an ALTERNATE TITLE rather than an edition, and
# that is still the same record — Big Star's release group `3rd` (alias
# "Third") against the owned copy "Third/Sister Lovers".
#
# The artist gate is unchanged: shape is decided here, identity by _albumMatches.
# DSC-ONLY call-site logic — aliases are not part of the shared matcher, so this
# does NOT trip tools/matcher_sync_check.py.
sub _aliasMatches {
    my ($artistNorm, $aliasNorm, $aliasRaw, $candArtist, $candTitle) = @_;
    return 0 unless defined $candTitle && length $candTitle;
    my $cn = _norm($candTitle);
    unless ($cn eq $aliasNorm) {
        return 0 unless $candTitle =~ m{^\s*\Q$aliasRaw\E\s*[/:]}i;
    }
    return _albumMatches($artistNorm, $aliasNorm, $candArtist, $candTitle, $aliasRaw);
}

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
# LETTERS NFD CANNOT DECOMPOSE.
#
# The NFD pass above strips COMBINING MARKS, which is why every true accent
# already folds: "Sigur Rós", "Björk", "Dvořák", "Beyoncé" all reduce to ASCII
# without a single table entry. What NFD cannot touch is a letter whose mark is
# part of the glyph itself — a STROKE (ø đ ł ŧ ƀ), a HOOK (ɓ ɗ ƙ), or a
# LIGATURE/DIGRAPH (æ œ ĳ ǉ) — because those are atomic codepoints with no
# canonical decomposition. Left alone they survive into the key as non-ASCII,
# so the name is unfindable typed the plain way.
#
# Applied AFTER lc(), so only lowercase forms are needed — but note that several
# uppercase Latin Extended-B letters lowercase to a DIFFERENT block (Ⱥ U+023A ->
# ⱥ U+2C65, Ʉ U+0244 -> ʉ U+0289), which is why those targets appear here.
#
# Swept 2026-07-21 across U+00C0-U+024F: 130 letters reached the key non-ASCII
# before this table, 26 after. The 26 left are click consonants (ǀ ǁ ǂ ǃ),
# glottal stops (ɂ) and tone/phonetic letters with no sensible ASCII base —
# deliberately unmapped, because guessing a base is worse than not folding.
my %FOLD = (
    # ligatures and digraphs
    "\x{e6}"  => 'ae', "\x{153}" => 'oe', "\x{df}"  => 'ss', "\x{fe}" => 'th',
    "\x{133}" => 'ij', "\x{1c6}" => 'dz', "\x{1f3}" => 'dz', "\x{1c9}" => 'lj',
    "\x{1cc}" => 'nj', "\x{223}" => 'ou', "\x{195}" => 'hv', "\x{1a3}" => 'oi',
    # stroked / barred letters
    "\x{f8}"  => 'o', "\x{111}" => 'd', "\x{142}" => 'l', "\x{127}" => 'h',
    "\x{167}" => 't', "\x{180}" => 'b', "\x{19a}" => 'l', "\x{1e5}" => 'g',
    "\x{23c}" => 'c', "\x{23f}" => 's', "\x{240}" => 'z', "\x{247}" => 'e',
    "\x{249}" => 'j', "\x{24b}" => 'q', "\x{24d}" => 'r', "\x{24f}" => 'y',
    "\x{1b6}" => 'z', "\x{2c65}" => 'a', "\x{2c66}" => 't', "\x{289}" => 'u',
    "\x{268}" => 'i', "\x{275}" => 'o',
    # hooked letters
    "\x{253}" => 'b', "\x{188}" => 'c', "\x{256}" => 'd', "\x{257}" => 'd',
    "\x{192}" => 'f', "\x{260}" => 'g', "\x{199}" => 'k', "\x{1ad}" => 't',
    "\x{1a5}" => 'p', "\x{272}" => 'n', "\x{19e}" => 'n', "\x{288}" => 't',
    "\x{28b}" => 'v', "\x{1b4}" => 'y', "\x{271}" => 'm',
    # dotless, long-s, turned and archaic forms
    "\x{131}" => 'i', "\x{17f}" => 's', "\x{140}" => 'l', "\x{138}" => 'k',
    "\x{149}" => 'n', "\x{14b}" => 'n', "\x{1dd}" => 'e', "\x{259}" => 'e',
    "\x{254}" => 'o', "\x{25b}" => 'e', "\x{25c}" => 'e', "\x{292}" => 'z',
    "\x{250}" => 'a', "\x{26f}" => 'm', "\x{28a}" => 'u', "\x{26a}" => 'i',
    "\x{283}" => 'sh', "\x{263}" => 'g', "\x{28c}" => 'v', "\x{280}" => 'r',
    "\x{21d}" => 'g', "\x{1bf}" => 'w', "\x{1a8}" => 's', "\x{225}" => 'z',
    "\x{221}" => 'd', "\x{234}" => 'l', "\x{235}" => 'n', "\x{236}" => 't',
    "\x{237}" => 'j', "\x{f0}"  => 'd',
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

    # APOSTROPHES ELIDE — they do NOT become a space. Every other mark handled
    # by the [^\p{Alnum}] rule below SEPARATES words; an apostrophe sits INSIDE
    # one, marking a contraction or a possessive, and both spellings of the same
    # name are common in the wild.
    #
    # WHY (field, 2026-07-21): spacing it keyed "Jane's Addiction" as
    # 'jane s addiction' against 'janes addiction'. `_artistMatch` is an
    # exact-token SUBSET test, so the token 'janes' matched nothing on the other
    # side and the act failed to match against EVERY source — not just the
    # library. Same for O'Connor/OConnor, D'Angelo/DAngelo, The B-52's/B-52s.
    # This is the "!" fold's mandatory-artist-gate failure in another costume.
    #
    # LMS's own index agrees with eliding: it TOKENISES on the apostrophe
    # (verified live — `artists search:Connor` returns "Sinead O'Connor", and
    # `search:s Addiction` returns "Jane's Addiction"), so folding the mark away
    # is the one choice that puts both spellings on a single key.
    #
    # GUARD — "'n'" contracting "and" is the exception, because there the mark
    # joins two WORDS rather than sitting inside one. All three spellings agree
    # TODAY ("Rock'n'Roll", "Rock 'n' Roll" and "Rock N Roll" all key
    # 'rock n roll'); eliding blindly would key the first as 'rocknroll' and
    # break a set that currently works. Space that one form first and the
    # three-way agreement survives untouched.
    my $apos = qr/['\x{2019}\x{2018}\x{02bc}\x{00b4}\x{2032}`]/;
    $s =~ s/(?<=\w)${apos}n${apos}(?=\w)/ n /g;
    $s =~ s/$apos//g;

    $s =~ s/[^\p{Alnum}]+/ /g;
    $s =~ s/^\s+//; $s =~ s/\s+$//;
    $s =~ s/\s+/ /g;
    return $s;
}

1;
