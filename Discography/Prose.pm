package Plugins::Discography::Prose;

# THE BIOGRAPHY AND REVIEW LADDER'S SERVICE CLIENTS (2026-10-08; Simon: "If a
# user has Qobuz then first look to get these from Qobuz, if it has none then
# ... the Deezer API ... as its free to use, if this has none fall back to how we
# currently pull them"). The ladder itself, and the identity check that keeps a
# namesake's text off the page, are Browse.pm's (_bioStart, _serviceArtistOk);
# this module only asks.
#
#   * Deezer, ANONYMOUS, no Deezer plugin needed (Simon: "We dont need deezer
#     plugin you can query this without it"):
#       - the biography: the undocumented gw-light `deezer.pageArtist`, on a
#         session `deezer.getUserData` hands out with no account (checkForm +
#         SESSION_ID). Measured 2026-10-08: 50 of 52 linked artists have one,
#         mostly "Music Story". Deezer has NO album reviews (pageAlbum's
#         COMMENTS are users' comments), so it is not in the review ladder.
#       - finding the artist when MusicBrainz links no Deezer page: the public
#         API's artist search and album lists (deezerFindArtist).
#   * Qobuz, through the Qobuz plugin's own handler: an artist's biography
#     (getArtist, the reply the pool already reads) and an album's description
#     (getAlbum).
#   * isMixedArtistPage: a Last.fm page about SEVERAL acts of one name.
#
# Every client answers its callback exactly once: a hashref with `text` (found),
# a hashref with `none` (asked, nothing there), or undef (could not tell: no
# handler, a failure, a timeout, a backoff). The ladder keeps a pick for a day
# instead of a month when a source above it could not tell.
#
# THE COOKIE JAR. LMS keeps one jar for all its HTTP (Slim::Networking::Async::
# HTTP, cookies.dat) and sends whatever it holds for the host. A user signed in
# to the Deezer plugin may have their arl there, and our anonymous session must
# never carry it; so, as the Deezer plugin does before each of its own requests,
# the jar's deezer.com cookies are cleared before each of ours and the session
# cookie is sent explicitly. The Deezer plugin sets its own cookies explicitly
# too and never reads them back from the jar, so clearing costs it nothing.

use strict;
use warnings;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Timers;
use JSON::PP ();
use Time::HiRes ();

my $log = logger('plugin.discography');

sub _dbg { Plugins::Discography::Plugin::dbg(@_) }

use constant DZ_GW_URL       => 'https://www.deezer.com/ajax/gw-light.php';
use constant DZ_API_URL      => 'https://api.deezer.com/';
use constant DZ_TIMEOUT      => 10;
use constant DZ_SESSION_TTL  => 3600;   # an anonymous session, kept about an hour
use constant DZ_BACKOFF      => 3600;   # a refusal (403, a challenge page) holds Deezer off
use constant DZ_BIO_IDS_MAX  => 3;      # linked Deezer ids asked, lowest first
use constant DZ_FIND_MAX     => 4;      # same-name search hits whose albums are read
use constant DZ_SEARCH_LIMIT => 25;
use constant DZ_ALBUMS_LIMIT => 200;
use constant QOBUZ_IDS_MAX   => 3;
use constant QOBUZ_TIMEOUT   => 12;

my $json = JSON::PP->new->utf8->canonical;

# ---------------------------------------------------------------------------
# A LAST.FM PAGE ABOUT SEVERAL ACTS. MAI's biography falls back to Last.fm by
# NAME, and Last.fm keeps one page per name: measured 2026-10-08 on the live
# server, Hope ("There are many artists going by the name of"), Echo ("There are
# at least twelve artists"), Pencil, Dark Star ("There are at least five
# bands"), Roswell ("There have been at least two bands called") and Kingfisher
# ("1. Kingfisher is ... 2. ...") open that way; Madness, Jack, Bush, Genesis,
# Radiohead, Lambchop, Kraftwerk, Cocteau Twins and Nirvana do not. Such a page
# is no biography for the act on the page (the 0.44.5 rule: another act's life
# story is worse than none).
# ---------------------------------------------------------------------------
my $MANY = qr/(?:many|multiple|several|various|numerous|a\s+number\s+of|more\s+than\s+(?:one|\w+)|\d+|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)/i;
my $ACTS = qr/(?:artists?|bands?|acts?|groups?|musicians?|singers?|rappers?|djs?|producers?|projects?|performers?|people|entities)/i;

sub isMixedArtistPage {
    my ($class, $text) = @_;
    return 0 unless defined $text && !ref $text && length $text;
    (my $plain = $text) =~ s/<[^>]+>/ /g;
    $plain =~ s/&nbsp;|&#160;/ /g;
    $plain =~ s/\s+/ /g;
    $plain =~ s/^ //;
    my $head = substr($plain, 0, 800);
    # The acts must follow the count (two words between at most: "many
    # different artists"), or "There are three members in the band" would read
    # as several bands.
    return 1 if $head =~ /^there\s+(?:are|is|were|was|have\s+been|has\s+been)\s+(?:at\s+least\s+|probably\s+|possibly\s+)?$MANY\s+(?:[\w'-]+\s+){0,2}?$ACTS\b/i;
    # "There is more than one artist with this name", and its kin.
    return 1 if $head =~ /^there\s+(?:is|are)\s+(?:more\s+than\s+one|several|multiple)\s+$ACTS\b/i;
    # A numbered list from the very first word: "1. X is ... 2. X is ...".
    return 1 if $head =~ /^1\s*[.)]\s+\S.{0,700}?\s2\s*[.)]\s+\S/;
    return 0;
}

# ---------------------------------------------------------------------------
# Deezer
# ---------------------------------------------------------------------------
my %dz = (sid => undef, csrf => undef, until => 0, held => 0);
my (@dzQueue, $dzBusy);

sub _now { Time::HiRes::time() }

sub _clearJar {
    my $jar = eval {
        Slim::Networking::Async::HTTP->can('cookie_jar') && Slim::Networking::Async::HTTP::cookie_jar();
    };
    return unless $jar && ref $jar;
    eval { $jar->clear($_); 1 } for qw(.deezer.com www.deezer.com api.deezer.com);
    return;
}

sub _dzHeld {
    return 0 unless $dz{held};
    return 1 if _now() < $dz{held};
    $dz{held} = 0;
    return 0;
}

sub _dzHold {
    my ($why) = @_;
    $dz{held} = _now() + DZ_BACKOFF;
    $log->warn("Deezer refused ($why) - not asked again for " . DZ_BACKOFF . 's');
}

# Deezer's language for the LMS one ('EN' -> 'en', 'ZH_CN' -> 'zh').
sub _dzLang {
    my $l = eval { lc(preferences('server')->get('language') || 'en') } || 'en';
    $l =~ s/[_-].*//;
    return $l =~ /^[a-z]{2}$/ ? $l : 'en';
}

# One gw-light call at a time (the session is shared and refreshed in place).
sub _gw {
    my ($method, $body, $cb) = @_;
    push @dzQueue, [ $method, $body, $cb ];
    _gwPump();
}

sub _gwPump {
    return if $dzBusy || !@dzQueue;
    my $job = shift @dzQueue;
    $dzBusy = 1;
    my $done = sub {
        my @r = @_;
        $dzBusy = 0;
        eval { $job->[2]->(@r); 1 } or $log->warn("Deezer callback died: $@");
        _gwPump();
    };
    return $done->(undef) if _dzHeld();
    _gwRun($job->[0], $job->[1], 0, $done);
}

# $done->($results) with the reply's `results`, or undef on any failure.
sub _gwRun {
    my ($method, $body, $retried, $done) = @_;
    return _gwSession(sub {
        my $ok = shift;
        return $done->(undef) unless $ok;
        _gwRun($method, $body, $retried, $done);
    }) unless $dz{sid} && _now() < $dz{until};

    _gwPost($method, $dz{csrf}, $dz{sid}, $body, sub {
        my ($d, $code) = @_;
        return $done->(undef) unless ref $d eq 'HASH';
        my $err = $d->{error};
        if ((ref $err eq 'HASH' && %$err) || (ref $err eq 'ARRAY' && @$err)) {
            my $what = ref $err eq 'HASH' ? join(',', keys %$err) : 'error';
            # A stale token or session: one fresh session, then give up.
            if (!$retried && $what =~ /TOKEN|SESSION|AUTH/i) {
                _dbg("Deezer $method: $what - new session");
                @dz{qw(sid csrf until)} = (undef, undef, 0);
                return _gwRun($method, $body, 1, $done);
            }
            _dbg("Deezer $method: error $what");
            return $done->(undef);
        }
        $done->(ref $d->{results} eq 'HASH' ? $d->{results} : {});
    });
}

sub _gwSession {
    my ($cb) = @_;
    _gwPost('deezer.getUserData', '', undef, {}, sub {
        my ($d) = @_;
        my $r = ref $d eq 'HASH' && ref $d->{results} eq 'HASH' ? $d->{results} : {};
        if ($r->{checkForm} && $r->{SESSION_ID}) {
            @dz{qw(csrf sid until)} = ($r->{checkForm}, $r->{SESSION_ID}, _now() + DZ_SESSION_TTL);
            _dbg('Deezer: new anonymous session');
            return $cb->(1);
        }
        _dbg('Deezer: no anonymous session in the reply');
        $cb->(0);
    });
}

# $cb->($decoded, $httpCode): $decoded undef when the reply is not JSON.
sub _gwPost {
    my ($method, $token, $sid, $body, $cb) = @_;
    require URI::Escape;
    my $url = DZ_GW_URL . '?method=' . URI::Escape::uri_escape($method)
            . '&input=3&api_version=1.0&api_token=' . URI::Escape::uri_escape($token // '');
    my %headers = ('Content-Type' => 'application/json');
    $headers{Cookie} = "sid=$sid" if $sid;
    _clearJar();
    my $content = $json->encode($body || {});
    _http('post', $url, \%headers, $content, $cb);
}

sub _dzGet {
    my ($path, $cb) = @_;
    return $cb->(undef) if _dzHeld();
    _clearJar();
    _http('get', DZ_API_URL . $path, {}, undef, $cb);
}

# One HTTP call, answered once. A 403 or 429, or an HTML page where JSON was
# expected (a bot-manager challenge), holds Deezer off for DZ_BACKOFF.
sub _http {
    my ($verb, $url, $headers, $content, $cb) = @_;
    my $answered = 0;
    my $answer = sub { return if $answered++; $cb->(@_) };
    my $http = eval { Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $res = shift;
            my $raw = eval { $res->content } // '';
            my $d = eval { $json->decode($raw) };
            unless (ref $d) {
                _dzHold('not JSON') if $raw =~ /^\s*</;
                return $answer->(undef, 200);
            }
            # The public API reports its own errors in the body (code 4: quota).
            if (ref $d eq 'HASH' && ref $d->{error} eq 'HASH' && defined $d->{error}{code}) {
                _dbg("Deezer API error $d->{error}{code}: " . ($d->{error}{message} // ''));
                return $answer->(undef, 200);
            }
            $answer->($d, 200);
        },
        sub {
            my ($h, $error, $res) = @_;
            my $code = eval { $res->code } // 0;
            _dzHold("HTTP $code") if $code == 403 || $code == 429;
            _dbg("Deezer request failed: " . ($error // 'error') . " ($url)");
            $answer->(undef, $code);
        },
        { timeout => DZ_TIMEOUT },
    ) };
    eval {
        die "no HTTP client\n" unless $http;
        $verb eq 'post' ? $http->post($url, %$headers, $content)
                        : $http->get($url, %$headers);
        1;
    } or do { $log->warn("Deezer request could not be sent: $@"); $answer->(undef, 0) };
}

# The biography of ONE Deezer artist: { text, source } | { none => 1 } | undef.
# Asked in the LMS language, and once more in English when that has none.
sub deezerBio {
    my ($class, $artId, $cb) = @_;
    return $cb->(undef) unless defined $artId && $artId =~ /^\d+$/;
    # Self-passing, never a captured lexical: the 0.30.1 reference-cycle leak.
    my $ask = sub {
        my ($self, $l, $last) = @_;
        _gw('deezer.pageArtist', { art_id => "$artId", lang => $l }, sub {
            my $r = shift;
            return $cb->(undef) unless ref $r eq 'HASH';
            my $bio = ref $r->{BIO} eq 'HASH' ? $r->{BIO} : {};
            my $t = $bio->{BIO};
            if (defined $t && !ref $t && $t =~ /\S/) {
                return $cb->({ text => $t, source => $bio->{SOURCE} // '', id => $artId, lang => $l });
            }
            return $self->($self, 'en', 1) if !$last && $l ne 'en';
            $cb->({ none => 1 });
        });
    };
    $ask->($ask, _dzLang(), 0);
    return;
}

# The first of several Deezer ids (lowest first) that has a biography.
sub deezerBioFor {
    my ($class, $ids, $cb) = @_;
    my @ids = grep { defined && /^\d+$/ } @{ $ids || [] };
    splice(@ids, DZ_BIO_IDS_MAX) if @ids > DZ_BIO_IDS_MAX;
    return $cb->({ none => 1 }) unless @ids;
    my $unknown = 0;
    my $next = sub {
        my ($self) = @_;
        my $id = shift @ids;
        return $cb->($unknown ? undef : { none => 1 }) unless defined $id;
        $class->deezerBio($id, sub {
            my $r = shift;
            return $cb->($r) if $r && $r->{text};
            $unknown++ unless $r;
            $self->($self);
        });
    };
    $next->($next);
    return;
}

# THE DEEZER ARTIST WHEN MUSICBRAINZ LINKS NONE, with no Deezer plugin: the
# public API's artist search under $query, the hits whose name is one of
# MusicBrainz's names for the artist ($names: normalised), and for at most
# DZ_FIND_MAX of them their album lists, scored against the page's releases
# ($spine, Sources::_spineScore). A hit passes only as the pools' resolver lets
# one pass (score >= min(SPINE_STRONG, spine), at least 1).
#
# ORDERED BY FANS, and that is load-bearing. Measured 2026-10-08: Deezer's search
# does not put the famous act first among same-name hits (ABBA 180 is 5th behind
# four "Abba" with under 400 fans; Madness 1825 and Sam Smith 1097709 are 7th),
# so the first four in search order miss them. Ordered by nb_fan, 52 of 52
# linked artists agreed with MusicBrainz's link and none was wrong; 3 of 8
# unlinked ones were found (Holly Golightly, Roswell Road, Rico Rodriguez); the
# garage Bees and the horrorcore Madness correctly found none.
#
# $cb->({ id, name, score, spine }) | { none => 1 } | undef (could not tell).
sub deezerFindArtist {
    my ($class, $names, $spine, $query, $cb) = @_;
    my %want = map { $_ => 1 } grep { defined && length } @{ $names || [] };
    my $n = ref $spine eq 'HASH' ? scalar(keys %$spine) : 0;
    return $cb->(undef) unless %want && $n && defined $query && length $query;
    my $need = $n >= _strong() ? _strong() : 1;
    require URI::Escape;
    _dzGet('search/artist?q=' . URI::Escape::uri_escape_utf8($query) . '&limit=' . DZ_SEARCH_LIMIT, sub {
        my $d = shift;
        return $cb->(undef) unless ref $d eq 'HASH' && ref $d->{data} eq 'ARRAY';
        my @same = sort { ($b->{nb_fan} // 0) <=> ($a->{nb_fan} // 0) }
                   grep { ref $_ eq 'HASH' && $_->{id} && $want{ Plugins::Discography::Sources::_norm($_->{name} // '') } }
                   @{ $d->{data} };
        splice(@same, DZ_FIND_MAX) if @same > DZ_FIND_MAX;
        unless (@same) {
            _dbg("Deezer search '$query': no artist of that name");
            return $cb->({ none => 1 });
        }
        my ($left, $failed, @scored) = (scalar(@same), 0);
        for my $h (@same) {
            _dzGet("artist/$h->{id}/albums?limit=" . DZ_ALBUMS_LIMIT, sub {
                # NEVER `my $a` / `my $b` in a scope holding a sort block: a
                # lexical masks sort's own and the comparator reads it instead
                # (0.44.18's silent corruptor; this file had it, caught by a
                # warning in t_deezerbio.pl).
                my $reply = shift;
                if (ref $reply eq 'HASH' && ref $reply->{data} eq 'ARRAY') {
                    push @scored, { id => $h->{id}, name => $h->{name}, spine => $n,
                                    score => Plugins::Discography::Sources::_spineScore($reply->{data}, $spine) };
                }
                else { $failed++ }
                return if --$left;
                @scored = sort { $b->{score} <=> $a->{score} || $a->{id} <=> $b->{id} } @scored;
                _dbg("Deezer search '$query': " . join(', ', map { "$_->{id}=$_->{score}" } @scored)
                     . ($failed ? " ($failed album list(s) failed)" : '') . " - need $need of $n");
                return $cb->($scored[0]) if @scored && $scored[0]{score} >= $need;
                $cb->($failed ? undef : { none => 1 });
            });
        }
    });
    return;
}

sub _strong {
    my $s = eval { Plugins::Discography::Sources::SPINE_STRONG() };
    return $s || 2;
}

# ---------------------------------------------------------------------------
# Qobuz, through the plugin's own handler (its token, app id, 30-day cache)
# ---------------------------------------------------------------------------
sub _qobuzApi {
    my ($client) = @_;
    my $on = eval { Slim::Utils::PluginManager->isEnabled('Plugins::Qobuz::Plugin') };
    return undef unless $on;
    my $fn = eval { Plugins::Qobuz::Plugin->can('getAPIHandler') } or return undef;
    return eval { $fn->($client) };
}

# Ask each id in turn, until $pick finds text in a reply.
sub _qobuzEach {
    my ($client, $ids, $call, $pick, $what, $cb) = @_;
    my @ids = grep { defined && length } @{ $ids || [] };
    splice(@ids, QOBUZ_IDS_MAX) if @ids > QOBUZ_IDS_MAX;
    return $cb->({ none => 1 }) unless @ids;
    my $api = _qobuzApi($client) or return $cb->(undef);
    my $unknown = 0;
    my $next = sub {
        my ($self) = @_;
        my $id = shift @ids;
        return $cb->($unknown ? undef : { none => 1 }) unless defined $id;
        my $settled = 0;
        my $timer;
        my $land = sub {
            my ($r) = @_;
            return if $settled++;
            Slim::Utils::Timers::killSpecific($timer) if $timer;
            if (!defined $r) { $unknown++; return $self->($self) }
            my $t = $pick->($r);
            return $cb->({ text => $t, id => $id }) if defined $t && !ref $t && $t =~ /\S/;
            $self->($self);
        };
        $timer = Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + QOBUZ_TIMEOUT, sub {
            _dbg("Qobuz $what $id: no answer in " . QOBUZ_TIMEOUT . 's');
            $land->(undef);
        });
        eval { $call->($api, $id, sub { $land->(ref $_[0] eq 'HASH' ? $_[0] : undef) }); 1 }
            or do { $log->warn("Qobuz $what $id threw: $@"); $land->(undef) };
    };
    $next->($next);
    return;
}

# The biography of the first Qobuz artist (of $ids) that has one.
sub qobuzArtistBio {
    my ($class, $client, $ids, $cb) = @_;
    _qobuzEach($client, $ids,
        sub { my ($api, $id, $land) = @_; $api->getArtist($land, $id) },
        sub { my $r = shift; ref $r->{biography} eq 'HASH' ? $r->{biography}{content} : undef },
        'artist bio', $cb);
}

# The description of the first Qobuz album (of $ids) that has one.
sub qobuzAlbumDescription {
    my ($class, $client, $ids, $cb) = @_;
    _qobuzEach($client, $ids,
        sub { my ($api, $id, $land) = @_; $api->getAlbum($land, $id) },
        sub { $_[0]{description} },
        'album description', $cb);
}

1;
