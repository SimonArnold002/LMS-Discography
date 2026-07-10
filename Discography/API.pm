package Plugins::Discography::API;

# Async MusicBrainz access for the Discography plugin.
#
# Two jobs:
#   1. Resolve an artist to a MusicBrainz artist MBID — library tag first
#      (contributor.musicbrainz_id, exact identity for free), MB name search as
#      fallback (port of the ListenBrainz Fresh Releases plugin's
#      getArtistMbidByName).
#   2. Fetch the artist's full RELEASE-GROUP list — the discography spine:
#      one entry per release (not per edition), with first-release-date and
#      primary/secondary types. Paginated serially at MusicBrainz's 1 req/s
#      etiquette; artwork comes from the Cover Art Archive by release-group
#      MBID (plain URL, no API call).

use strict;
use warnings;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Slim::Utils::PluginManager;
use Slim::Utils::Timers;
use JSON::XS::VersionOneAndTwo;

my $log   = logger('plugin.discography');
my $prefs = preferences('plugin.discography');
my $cache = Slim::Utils::Cache->new();

# MB resolution failures MUST go through this — "artist not found" with only
# info-level logging is undiagnosable in the field (Better Oblivion, 2026-07-09).
sub _dbg { Plugins::Discography::Plugin::dbg(@_) }

use constant MB_BASE_URL     => 'https://musicbrainz.org/ws/2/';
use constant CAA_RG_BASE_URL => 'https://coverartarchive.org/release-group/';

# Artist-MBID lookups: hits are stable for weeks; misses retried daily.
use constant MBID_FOUND_TTL => 30 * 86400;
use constant MBID_EMPTY_TTL =>  1 * 86400;

# Release-group lists change rarely (a new release every few months at most).
# The browse view's Refresh action bypasses this.
use constant RG_TTL => 14 * 86400;

# MB pagination: 100/page max; pages fetched serially with a courtesy gap
# (MB asks for <=1 req/s). 6 pages = 600 release groups — beyond any artist
# this UI can usefully show; truncation is logged.
use constant RG_PAGE_SIZE => 100;
use constant RG_MAX_PAGES => 6;
use constant RG_PAGE_GAP  => 1.1;   # seconds between pages

# Bump when the cached release-group shape or filtering changes — versioned key
# invalidates every stale entry at once (the fleet's bump-every-layer rule).
use constant RG_CACHE_V => 'v1';

# UA per MB etiquette: identify the app + a contact URL. Version read from the
# plugin manifest so it can't drift.
my $_userAgent;
sub USER_AGENT {
    return $_userAgent if defined $_userAgent;
    my $ver = eval {
        Slim::Utils::PluginManager->dataForPlugin('Plugins::Discography::Plugin')->{version};
    };
    $ver = 'dev' unless defined $ver && length $ver;
    return $_userAgent =
        "LMS-Discography/$ver ( https://github.com/SimonArnold002/LMS-Discography )";
}

sub _rgKey { 'dsc:rg:' . RG_CACHE_V . ':' . $_[0] }

# ---------------------------------------------------------------------------
# Artist -> MBID
# ---------------------------------------------------------------------------

my $UUID_RE = qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

# getArtistMbid(artist_id => N, artist => 'Name', onDone => sub($mbid_or_undef))
# Library tag wins (exact identity); MB name search otherwise. onDone always
# fires exactly once.
sub getArtistMbid {
    my ($class, %a) = @_;
    my $onDone = $a{onDone} || sub {};

    if ($a{artist_id}) {
        my $mbid = eval {
            require Slim::Schema;
            my $c = Slim::Schema->find('Contributor', $a{artist_id});
            $c ? $c->musicbrainz_id : undef;
        };
        if ($mbid && $mbid =~ $UUID_RE) {
            _dbg("artist mbid from library tag: $mbid");
            $onDone->(lc $mbid);
            return;
        }
    }

    $class->_artistMbidByName($a{artist}, $onDone);
}

# Port of the ListenBrainz plugin's getArtistMbidByName: quoted artist query,
# top hit only, score gate >= 90 so a wrong same-name artist is rejected rather
# than adopted. '' is the cached "not found" sentinel.
sub _artistMbidByName {
    my ($class, $name, $onDone) = @_;

    $name = defined $name ? $name : '';
    $name =~ s/^\s+|\s+$//g;
    unless (length $name) { $onDone->(undef); return; }

    my $cacheKey = 'dsc:mbid:' . lc $name;
    utf8::encode($cacheKey) if utf8::is_utf8($cacheKey);
    if (defined(my $c = $cache->get($cacheKey))) {
        _dbg("artist mbid cache hit '$name': " . ($c || 'NOT-FOUND sentinel (retried daily)'));
        $onDone->($c || undef);
        return;
    }

    my $q = 'artist:"' . $name . '"';
    utf8::encode($q) if utf8::is_utf8($q);
    (my $safe = $q) =~ s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge;
    my $url = MB_BASE_URL . 'artist?query=' . $safe . '&fmt=json&limit=1';

    $log->info("resolving artist name to MBID: $name");

    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            my $mbid = '';
            my $why  = 'no results';
            if (!$@ && ref $data eq 'HASH' && ref $data->{artists} eq 'ARRAY' && @{ $data->{artists} }) {
                my $a = $data->{artists}[0];
                if ($a->{id} && ($a->{score} // 0) >= 90) {
                    $mbid = lc $a->{id};
                }
                else {
                    $why = "top hit '" . ($a->{name} // '?') . "' score " . ($a->{score} // '?') . ' < 90';
                }
            }
            elsif ($@) { $why = 'unparseable MB response' }
            eval { $cache->set($cacheKey, $mbid, $mbid ? MBID_FOUND_TTL : MBID_EMPTY_TTL); 1 }
                or $log->warn("artist-mbid cache set failed: $@");
            _dbg("MB artist search '$name' => " . ($mbid || "NO MATCH ($why; cached 1d)"));
            $onDone->($mbid || undef);
        },
        sub {
            my $err = shift->error // '?';
            $log->error("MB artist search failed: $err");
            _dbg("MB artist search '$name' => HTTP error ($err; not cached, retry works)");
            $onDone->(undef);
        },
        { timeout => 12 }
    )->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
}

# ---------------------------------------------------------------------------
# MBID -> release groups
# ---------------------------------------------------------------------------

# getReleaseGroups(mbid => $m, force => 0|1, onDone => sub(\@rgs), onError => sub($msg))
# Each entry: { mbid, title, date ('YYYY[-MM[-DD]]' or ''), type (primary,
# may be ''), secondary => [..] }. Cached whole; force bypasses the read (the
# write still happens, so Refresh renews the entry).
sub getReleaseGroups {
    my ($class, %a) = @_;
    my $mbid    = $a{mbid} or do { ($a{onError} || sub {})->('no mbid'); return };
    my $onDone  = $a{onDone}  || sub {};
    my $onError = $a{onError} || sub { $onDone->([]) };

    my $key = _rgKey($mbid);
    if (!$a{force} && (my $c = $cache->get($key))) {
        $log->info("release-group cache hit: $key (" . scalar(@$c) . " entries)");
        $onDone->($c);
        return;
    }

    my @all;
    my $page = 0;

    my $fetchPage; $fetchPage = sub {
        my ($offset) = @_;
        my $url = MB_BASE_URL . 'release-group?artist=' . $mbid
                . '&limit=' . RG_PAGE_SIZE . '&offset=' . $offset . '&fmt=json';

        $log->info("fetching release groups: $url");

        Slim::Networking::SimpleAsyncHTTP->new(
            sub {
                my $resp = shift;
                my $data = eval { from_json($resp->content) };
                if ($@ || ref $data ne 'HASH' || ref $data->{'release-groups'} ne 'ARRAY') {
                    _dbg("MB release-group page unparseable for $mbid (offset $offset)");
                    $onError->('bad MB response'); return;
                }

                for my $rg (@{ $data->{'release-groups'} }) {
                    next unless $rg->{id} && defined $rg->{title};
                    push @all, {
                        mbid      => lc $rg->{id},
                        title     => $rg->{title},
                        date      => $rg->{'first-release-date'} // '',
                        type      => $rg->{'primary-type'}       // '',
                        secondary => ref $rg->{'secondary-types'} eq 'ARRAY'
                                       ? $rg->{'secondary-types'} : [],
                    };
                }

                my $total = $data->{'release-group-count'} // scalar @all;
                $page++;
                if ($offset + RG_PAGE_SIZE < $total && $page < RG_MAX_PAGES) {
                    # Serial + spaced: MB etiquette is <=1 req/s per client.
                    Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + RG_PAGE_GAP,
                        sub { $fetchPage->($offset + RG_PAGE_SIZE) });
                    return;
                }

                $log->warn("release-group list truncated at " . scalar(@all) . " of $total for $mbid")
                    if $offset + RG_PAGE_SIZE < $total;

                eval { $cache->set($key, \@all, RG_TTL); 1 }
                    or $log->warn("release-group cache set failed: $@");
                $log->info("release groups for $mbid: " . scalar(@all) . " of $total");
                $onDone->(\@all);
            },
            sub {
                my $err = shift->error // 'HTTP error';
                $log->error("MB release-group fetch failed: $err");
                $onError->($err);
            },
            { timeout => 20 }
        )->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
    };

    $fetchPage->(0);
}

sub clearReleaseGroups {
    my ($class, $mbid) = @_;
    $cache->remove(_rgKey($mbid)) if $mbid;
}

# CAA cover by release-group MBID — a plain URL; CAA redirects to the front
# image of the group's representative release. A CAA miss 404s and the UI shows
# its default art, which is the honest state.
sub caaImage {
    my ($class, $rgMbid, $size) = @_;
    return CAA_RG_BASE_URL . $rgMbid . '/front-' . ($size || 250);
}

# ---------------------------------------------------------------------------
# Release-group external links (AllMusic, Discogs, Wikipedia, reviews, ...)
# via MB url-relationships. One extra MB call per detail open, heavily cached.
# ---------------------------------------------------------------------------

use constant URLS_FOUND_TTL => 30 * 86400;
use constant URLS_EMPTY_TTL =>  7 * 86400;

# Relation types worth a row, in display order. MB types not listed (streaming,
# purchase, lyrics, wikidata, ...) are skipped — link rows should be curated,
# not a dump.
my @URL_REL_TYPES = (
    [ 'allmusic'          => 'AllMusic'      ],
    [ 'discogs'           => 'Discogs'       ],
    [ 'wikipedia'         => 'Wikipedia'     ],
    [ 'review'            => 'Review'        ],
    [ 'official homepage' => 'Official site' ],
);

# getReleaseGroupUrls(mbid => $m, onDone => sub(\@links)) — each link is
# { label => 'AllMusic', url => 'https://...' }. Errors resolve to [] (the
# detail page must never stall on link decoration).
sub getReleaseGroupUrls {
    my ($class, %a) = @_;
    my $mbid   = $a{mbid} or do { ($a{onDone} || sub {})->([]); return };
    my $onDone = $a{onDone} || sub {};

    my $key = 'dsc:urls:1:' . $mbid;
    if (my $c = $cache->get($key)) {
        $onDone->($c);
        return;
    }

    my $url = MB_BASE_URL . 'release-group/' . $mbid . '?inc=url-rels&fmt=json';
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $resp = shift;
            my $data = eval { from_json($resp->content) };
            my @links;
            if (!$@ && ref $data eq 'HASH' && ref $data->{relations} eq 'ARRAY') {
                for my $want (@URL_REL_TYPES) {
                    my ($type, $label) = @$want;
                    for my $rel (@{ $data->{relations} }) {
                        next unless ($rel->{type} // '') eq $type
                                 && ref $rel->{url} eq 'HASH'
                                 && $rel->{url}{resource};
                        push @links, { label => $label, url => $rel->{url}{resource} };
                        last;   # one row per type
                    }
                }
            }
            eval { $cache->set($key, \@links, @links ? URLS_FOUND_TTL : URLS_EMPTY_TTL); 1 }
                or $log->warn("url-rels cache set failed: $@");
            $log->info("url-rels for $mbid: " . scalar(@links));
            $onDone->(\@links);
        },
        sub {
            $log->warn("MB url-rels fetch failed: " . (shift->error // '?'));
            $onDone->([]);
        },
        { timeout => 15 }
    )->get($url, 'Accept' => 'application/json', 'User-Agent' => USER_AGENT);
}

1;
