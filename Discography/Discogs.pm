package Plugins::Discography::Discogs;

# DISCOGS FIRST, FOR A TILE WITH NO COVER OF ITS OWN (2026-10-09). A tile whose
# release no source holds (not owned, not on a streaming service) took its cover
# from the Cover Art Archive only, 2-4 s a cover, and with no streaming service
# EVERY unowned tile does: the held requests filled the browser's connections and
# the alpha tester's taps and Play waited behind them (CLAUDE.md dev log
# `REPRODUCED with no streaming service`). Simon: Discogs first, then the archive
# ("it needs to use discogs first not after CAA"), the small thumbnails are fine
# ("speed and performance are more important for these", "they work in material
# so we use them"), and only for releases with no cover of their own (owned and
# streaming copies keep theirs).
#
# WHAT IT READS: the artist's own entries on Discogs (`artists/<id>/releases`,
# role Main, 100 a page), each with its 150 px `thumb` (a signed i.discogs.com
# url, about 3 KB, 0.1 s through the proxy against the archive's 2-4 s).
# NEWEST FIRST, PAGES TOGETHER, EACH USED AS IT LANDS (2026-10-09; Simon: "I
# said dicogs first CAA nex", after a big artist's first visit got archive
# covers): Discogs takes 4-5 s for ANY page of a big artist (Miles Davis, 13
# pages of his own: 56 s one after another, and the old 10-page limit stopped at
# 2011), but six pages asked at once come back together. So page 1 (newest
# first, the page's own order: `sort=year&sort_order=desc` keeps his own entries
# first, measured), then PARALLEL pages at a time until a page holds anything
# not his own, at most MAX_PAGES; one at a time when Discogs says fewer than
# RESERVE calls are left in its minute (60 a minute from one server, shared with
# MAI's own). Every page's entries count the moment it lands (thumbFor), and the
# page build waits for page 1 (Browse, DG_PAGE_WAIT). Through MAI's own Discogs
# request (`Plugins::MusicArtistInfo::Discogs::_call`): Discogs sends no `thumb`
# without a key (0 of 100, measured), and MAI's carries its key, its rate limit
# (60 a minute, shared with MAI's own calls) and a 60-day cache of each reply.
# Guarded with can(): without MAI, or if MAI renames it, nothing is read and
# every tile goes to the archive as before. MAI is required anyway (A2 `MAI OFF
# IS NOT A SUPPORTED STATE`); MAI's own Discography menu reads page 1 only.
#
# THE ARTIST BY ID, NEVER BY NAME: the Discogs artist is the one MusicBrainz
# links (`discogs.com/artist/<id>`, API::warmServiceLinks, the artist read the
# page already makes). No link, no Discogs covers. MAI finds its Discogs artist
# by name; a shared name would bring another act's albums.
#
# A RELEASE BY ID FIRST (A3 `MAI'S COVERS ARE FOUND BY NAME`: 3 of 3 live and
# session releases got the studio album's cover by name). A group MusicBrainz
# links to a Discogs master (API::_discogsOf, the browse's url-rels; 61 of Bill
# Evans's first 100) takes that master's thumbnail, or none. A group with no
# link takes one only when exactly one of the artist's own Discogs entries has
# the same full title (brackets kept; case, curly quotes and dashes aside) AND
# the same year, no other group on the list has that title and year, and no
# linked group already owns that entry (Simon chose this guard, 2026-10-09).
# Masters are preferred to plain releases of the same title.
#
# Browse asks for the list as an artist page starts and waits for its first
# page (bounded); a tile shows the thumbnail when its entry is here (thumbFor);
# Covers' route asks Discogs before the archive for the rest, and asks the
# archive only once the list is complete without it.
#
# REVIEW 2026-10-09 (everything since 0.56.66), four rules:
#   - a read that kept nothing (page 1 not read, MAI's request dying, the
#     watchdog) is noted: the artist is not asked again for FAIL_TTL, so a
#     failing Discogs is neither waited for nor asked on every view (Browse's
#     page waits only on a fresh entry, at most DG_PAGE_WAIT from readSince);
#     MusicBrainz's links not read is not Discogs failing, and is not noted;
#   - a list kept after a page failed (PARTIAL_TTL) matches titles only in the
#     years the pages in a row from page 1 hold whole (_floor): entries come
#     newest first, so a year can straddle the missing page, and the guard
#     (exactly one entry of that title and year) must not be judged on half of
#     it. WHILE the list is read the title rule runs on the pages in so far, as
#     before: holding back the lowest year of page 1 would cost a big artist's
#     first draw 1-4 Discogs covers (measured 2026-10-09, Miles Davis 1, Frank
#     Zappa 1, Herbie Hancock 2, Chick Corea 4), and none of those four has a
#     same-title, same-year pair across pages 1-2 (one across 2-3, Miles Davis
#     2011, no MusicBrainz group of it); the map is rebuilt as each page
#     lands, so a pair found later stops the match from then on;
#   - Discogs's minute is one for every read (LOW_HOLD): a reply saying fewer
#     than RESERVE calls are left, a refusal's included, sends every read one
#     page at a time for the rest of the minute;
#   - a page failing mid-read keeps what came an hour (PARTIAL_TTL), with the
#     year its titles are whole above, not a day.

use strict;
use warnings;

use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Timers;

my $log = logger('plugin.discography');

use constant LIST_TTL  => 30 * 86400;   # an artist's Discogs entries
use constant NONE_TTL  => 86400;        # no Discogs link, or nothing usable: asked again tomorrow
use constant PER_PAGE  => 100;
use constant MAX_PAGES => 20;           # own entries come first: Bill Evans 4 pages, Miles Davis 13
use constant PARALLEL  => 6;            # pages asked at once after page 1
use constant RESERVE   => 10;           # Discogs's calls left this minute below which pages go one at a time
use constant WATCHDOG  => 120;          # one artist's whole read, at most
use constant INDEX_TTL => 60;           # a built group -> thumbnail map is reused this long
use constant FAIL_TTL    => 120;        # a read that kept nothing: not asked again this long
use constant PARTIAL_TTL => 3600;       # a page failed mid-read: what came, kept this long
use constant LOW_HOLD    => 60;         # Discogs's minute: every read gentle this long after a low reply
use constant NO_YEAR     => 9999;       # page 1 not in yet: no year whole

my %waiting;   # artist mbid => [callbacks], while its list is being read
my %firstWait; # artist mbid => [callbacks waiting for page 1 only]
my %first;     # artist mbid => 1 once page 1 is in, while the rest is read
my %partial;   # artist mbid => [entries read so far], while its list is being read
my %index;     # artist mbid => { at, map => { group mbid => thumbnail url } }
my @listeners; # told (with the artist) after every page that lands (listen)
my %started;   # artist mbid => time() its read in flight started (readSince)
my %failedAt;  # artist mbid => time() a read last kept nothing (FAIL_TTL)
my %pageIn;    # artist mbid => { page => [ its lowest year, all his own? ] }, while read
my %pagesOf;   # artist mbid => the list's page count, while read
my $lowUntil = 0;   # Discogs said its minute runs low: every read one page at a time until then
my $store;

sub _store { $store ||= eval { Plugins::Discography::DB->store() } }

# For the suite: forget everything held in memory.
sub _resetForSuite {
    %waiting = (); %firstWait = (); %first = (); %partial = (); %index = ();
    %started = (); %failedAt = (); %pageIn = (); %pagesOf = (); $lowUntil = 0;
    @listeners = (); undef $store;
    return;
}
sub _key   { 'dsc:dg:v2:' . $_[0] }
sub _dbg   { Plugins::Discography::Plugin::dbg(@_) if Plugins::Discography::Plugin->can('dbg') }

sub _ambid {
    my $m = lc($_[0] // '');
    return $m =~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/ ? $m : undef;
}

# MAI's Discogs request, or undef when MAI cannot make one.
sub _call {
    return undef unless eval { Slim::Utils::PluginManager->isEnabled('Plugins::MusicArtistInfo::Plugin') };
    return Plugins::MusicArtistInfo::Discogs->can('_call');
}

# Cache-only: the artist's Discogs entries ([] = read, none usable), or undef
# until read.
sub peekList {
    my ($class, $ambid) = @_;
    $ambid = _ambid($ambid) // return undef;
    my ($l) = _kept($ambid);
    return $l;
}

# The kept list, and the year its titles are whole above (undef: all of it).
# A whole list is kept as the list itself; one cut short (a page failed, or
# MAX_PAGES all his own) as { list, floor }.
sub _kept {
    my ($ambid) = @_;
    my $v = eval { _store()->get(_key($ambid)) };
    return ($v, undef) if ref $v eq 'ARRAY';
    return ($v->{list}, $v->{floor}) if ref $v eq 'HASH' && ref $v->{list} eq 'ARRAY';
    return;
}

# When the artist's read in flight started (time()), or undef: Browse's page
# waits at most DG_PAGE_WAIT from then, however often it is built.
sub readSince {
    my ($class, $ambid) = @_;
    $ambid = _ambid($ambid) // return undef;
    return $waiting{$ambid} ? $started{$ambid} : undef;
}

# The year the list read so far is whole above (_match's title rule, for a list
# kept after a page failed). Entries come newest first, so once pages 1..n are
# all in, every year above page n's lowest is whole; page n+1 may hold more of
# that lowest year. undef: whole (a page holding anything not his own is the
# last of his, or every page is in).
sub _floor {
    my ($ambid) = @_;
    my $in   = $pageIn{$ambid} || {};
    my $last = $pagesOf{$ambid} // 1;
    my $floor;
    for my $n (1 .. $last) {
        my $p = $in->{$n} or return $floor // NO_YEAR;
        return undef unless $p->[1];
        $floor = $p->[0];
    }
    return undef;
}

# A sub told, with the artist's mbid, after every page that lands and when the
# read ends (Covers wakes its queue: a cover waiting for Discogs may be answered
# now, or may go on to the archive). Each sub once.
sub listen {
    my ($class, $sub) = @_;
    push @listeners, $sub if ref $sub eq 'CODE' && !grep { $_ == $sub } @listeners;
    return;
}

sub _tell {
    my ($ambid) = @_;
    for my $l (@listeners) {
        eval { $l->($ambid); 1 } or $log->warn("dsc: Discogs listener failed: $@");
    }
    return;
}

# MusicBrainz's links for the artist's groups changed (API: its completed list
# landed, or was promoted): the map is rebuilt at the next look, and the queue
# told (a cover not started yet may match by id now).
sub linksChanged {
    my ($class, $ambid) = @_;
    $ambid = _ambid($ambid) // return;
    delete $index{$ambid};
    _tell($ambid);
    return;
}

# The artist's list is being read right now.
sub pending {
    my ($class, $ambid) = @_;
    $ambid = _ambid($ambid) // return 0;
    return $waiting{$ambid} ? 1 : 0;
}

# Cache-only: the Discogs thumbnail for one of the artist's groups, or undef.
sub thumbFor {
    my ($class, $ambid, $rg) = @_;
    $ambid = _ambid($ambid) // return undef;
    my $map = _map($ambid) or return undef;
    return $map->{ lc($rg // '') };
}

# Read the artist's Discogs entries once (one read per artist at a time; a
# caller arriving mid-read waits for it). $cb->() once, whatever happened: when
# the whole list is in, or with { first => 1 } as soon as page 1 is (Browse's
# page waits only for that). Nothing is kept when MusicBrainz or Discogs could
# not be read; MusicBrainz's links are asked again on the next look, Discogs
# itself after FAIL_TTL (the header's review rules).
sub warm {
    my ($class, $ambid, $cb, $opt) = @_;
    $cb ||= sub {};
    my $firstOnly = ref $opt eq 'HASH' && $opt->{first} ? 1 : 0;
    $ambid = _ambid($ambid) // return $cb->();
    return $cb->() if defined $class->peekList($ambid);
    if ($waiting{$ambid}) {
        return $cb->() if $firstOnly && $first{$ambid};
        push @{ $firstOnly ? $firstWait{$ambid} : $waiting{$ambid} }, $cb;
        return;
    }
    # A read that kept nothing a moment ago: not asked again yet (FAIL_TTL).
    return $cb->() if defined $failedAt{$ambid} && time() - $failedAt{$ambid} < FAIL_TTL;
    my $call = _call() or return $cb->();

    $waiting{$ambid}   = $firstOnly ? [] : [ $cb ];
    $firstWait{$ambid} = $firstOnly ? [ $cb ] : [];
    $partial{$ambid}   = [];
    $started{$ambid}   = time();
    $pageIn{$ambid}    = {};
    my ($settled, $watch) = (0);
    # $failed: Discogs's side kept nothing (noted for FAIL_TTL).
    my $settle = sub {
        my ($list, $ttl, $failed) = @_;
        return if $settled++;
        eval { Slim::Utils::Timers::killSpecific($watch); 1 } if $watch;
        if ($list) {
            eval { _store()->set(_key($ambid), $list, $ttl); 1 }
                or $log->warn("dsc: Discogs list for $ambid not kept: $@");
        }
        if ($failed) {
            my $now = time();
            delete @failedAt{ grep { $now - $failedAt{$_} >= FAIL_TTL } keys %failedAt };
            $failedAt{$ambid} = $now;
            _dbg("discogs $ambid: nothing read - not asked again for " . FAIL_TTL . ' s');
        }
        else { delete $failedAt{$ambid} }
        delete $index{$ambid};
        delete $partial{$ambid};
        delete $first{$ambid};
        delete $started{$ambid};
        delete $pageIn{$ambid};
        delete $pagesOf{$ambid};
        my @cbs = (@{ delete $firstWait{$ambid} || [] }, @{ delete $waiting{$ambid} || [] });
        for my $w (@cbs) {
            eval { $w->(); 1 } or $log->warn("dsc: Discogs list callback failed: $@");
        }
        _tell($ambid);
    };
    $watch = eval {
        Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + WATCHDOG,
            sub { _dbg("discogs $ambid: no answer in " . WATCHDOG . ' s'); $settle->(undef, undef, 1) });
    };

    Plugins::Discography::API->warmServiceLinks($ambid, sub {
        my ($links) = @_;
        return $settle->() unless ref $links eq 'HASH';    # not read: nothing kept
        my ($did) = @{ ref $links->{discogs} eq 'ARRAY' ? $links->{discogs} : [] };
        unless ($did) {
            _dbg("discogs $ambid: MusicBrainz links no Discogs artist");
            return $settle->([], NONE_TTL);
        }
        my $out = $partial{$ambid};
        my ($pages, $t0) = (1, Time::HiRes::time());

        # One page's reply: its own entries kept (usable at once, _map), its
        # lowest year noted (_floor), the queue told. Answers undef when
        # nothing was read, else whether every entry on the page was his own
        # (the next page may still be). Discogs's rate header first: a refusal
        # carries it too.
        my $take = sub {
            my ($d, $h, $n) = @_;
            $lowUntil = time() + LOW_HOLD if _low($h);
            my $rs = ref $d eq 'HASH' && ref $d->{releases} eq 'ARRAY' ? $d->{releases} : undef;
            return undef unless $rs;
            if ($n == 1) {
                $pages = ref $d->{pagination} eq 'HASH' ? ($d->{pagination}{pages} || 1) : 1;
                $pagesOf{$ambid} = $pages;
            }
            my ($own, $low) = (0);
            for my $r (@$rs) {
                next unless ref $r eq 'HASH';
                my $y = $r->{year} || 0;
                $low = $y if !defined $low || $y < $low;
                next unless lc($r->{role} // '') eq 'main';
                $own++;
                next unless _usable($r->{thumb}) && $r->{id};
                push @$out, { kind  => lc($r->{type} // ''), id => $r->{id},
                              title => $r->{title} // '', year => $y,
                              thumb => $r->{thumb} };
            }
            my $all = $own && $own == @$rs ? 1 : 0;
            $pageIn{$ambid}{$n} = [ $low // 0, $all ] if $pageIn{$ambid};
            delete $index{$ambid};
            _tell($ambid);
            return $all;
        };
        my $ask = sub {
            my ($n, $then) = @_;
            my $ok = eval {
                $call->("artists/$did/releases",
                        { per_page => PER_PAGE, page => $n, sort => 'year', sort_order => 'desc' }, $then);
                1;
            };
            $log->warn("dsc: MAI's Discogs request failed: $@") unless $ok;
            return $ok;
        };
        my $finish = sub {
            my ($n) = @_;
            _dbg(sprintf('discogs %s: artist %s, %d entries with a thumbnail, %d page(s) in %.1f s',
                         $ambid, $did, scalar(@$out), $n, Time::HiRes::time() - $t0));
            $settle->([ @$out ], @$out ? LIST_TTL : NONE_TTL);
        };
        # A page not read: what came, kept an hour (asked again then), with the
        # year its titles are whole above when a page before his last own one
        # is missing.
        my $keepPartial = sub {
            my $floor = _floor($ambid);
            _dbg("discogs $ambid: a page not read - " . scalar(@$out) . ' entries kept '
                 . PARTIAL_TTL . ' s' . (defined $floor ? ", titles above $floor" : ''));
            $settle->(defined $floor ? { list => [ @$out ], floor => $floor } : [ @$out ], PARTIAL_TTL);
        };

        # The pages after the first, PARALLEL at a time (one at a time while
        # Discogs's minute runs low, LOW_HOLD: every read's), until a page
        # holds anything not his own. Self-passing, not a captured lexical (the
        # 0.30.1 leak fix).
        my $wave = sub {
            my ($self, $from) = @_;
            my $last = $pages < MAX_PAGES ? $pages : MAX_PAGES;
            return $finish->($from - 1) if $from > $last;
            my $to = $from + (time() < $lowUntil ? 1 : PARALLEL) - 1;
            $to = $last if $to > $last;
            my ($left, $more, $failed) = ($to - $from + 1, 1, 0);
            my $landed = sub {
                return if $settled || --$left;
                return $keepPartial->() if $failed;
                return $finish->($to) unless $more && $to < $last;
                $self->($self, $to + 1);
            };
            for my $n ($from .. $to) {
                my $ok = $ask->($n, sub {
                    my ($d, $h) = @_;
                    return if $settled;
                    my $all = $take->($d, $h, $n);
                    if    (!defined $all) { _dbg("discogs $ambid: page $n not read"); $failed = 1 }
                    elsif (!$all)         { $more = 0 }
                    $landed->();
                });
                unless ($ok) { $failed = 1; $landed->() }
            }
        };

        my $ok = $ask->(1, sub {
            my ($d, $h) = @_;
            return if $settled;
            my $all = $take->($d, $h, 1);
            unless (defined $all) {
                _dbg("discogs $ambid: page 1 not read");
                return $settle->(undef, undef, 1);
            }
            _dbg(sprintf('discogs %s: page 1 of %d in %.1f s, %d entries with a thumbnail',
                         $ambid, $pages, Time::HiRes::time() - $t0, scalar(@$out)));
            $first{$ambid} = 1;
            my $fw = $firstWait{$ambid};
            $firstWait{$ambid} = [];
            for my $w (@{ $fw || [] }) {
                eval { $w->(); 1 } or $log->warn("dsc: Discogs list callback failed: $@");
            }
            return if $settled;
            return $finish->(1) unless $all && $pages > 1;
            $wave->($wave, 2);
        });
        $settle->(undef, undef, 1) unless $ok;
    });
    return;
}

# Discogs says fewer than RESERVE calls are left in its minute (its reply's
# header, through MAI: an HTTP::Headers, or a plain hash in the suite).
sub _low {
    my ($h) = @_;
    my $n = ref $h eq 'HASH' ? $h->{'x-discogs-ratelimit-remaining'}
          : eval { $h->header('X-Discogs-Ratelimit-Remaining') };
    return defined $n && $n =~ /^\d+$/ && $n < RESERVE ? 1 : 0;
}

# A thumbnail Discogs means: an http(s) url that is not its blank record.
sub _usable {
    my ($t) = @_;
    return defined $t && !ref $t && $t =~ m{^https?://}i
        && $t !~ m{spacer\.gif|record90\.png|/images/default-}i;
}

# The title as compared: case, curly quotes, dashes and spacing aside; brackets
# and everything in them kept ("Unholy (live version)" is not "Unholy").
sub _titleKey {
    my $t = lc($_[0] // '');
    $t =~ s/[\x{2018}\x{2019}\x{201B}\x{2032}]/'/g;
    $t =~ s/[\x{201C}\x{201D}\x{2033}]/"/g;
    $t =~ s/[\x{2010}-\x{2014}\x{2212}]/-/g;
    $t =~ s/\s+/ /g;
    $t =~ s/^ | $//g;
    return $t;
}

# The artist's groups (the cached list the page draws) mapped to thumbnails,
# rebuilt at most every INDEX_TTL, or when a page of the Discogs list lands or
# MusicBrainz's links change (linksChanged). While the list is read, the entries
# read so far count (the header says why the title rule runs on them as they
# are); a list kept after a page failed carries the year its titles are whole
# above. A group the page's list has no link for takes the one
# MusicBrainz's completed list holds, while that list waits for the next fresh
# entry (API::peekNextDiscogsLinks): the covers match by id the moment
# MusicBrainz has answered, the page's list unchanged.
sub _map {
    my ($ambid) = @_;
    my $now = time();
    my $ix  = $index{$ambid};
    return $ix->{map} if $ix && $now - $ix->{at} < INDEX_TTL;
    my ($list, $floor) = _kept($ambid);
    $list //= $partial{$ambid} or return undef;
    my $rgs  = eval { Plugins::Discography::API->peekReleaseGroups($ambid) } || [];
    if (my $links = eval { Plugins::Discography::API->peekNextDiscogsLinks($ambid) }) {
        $rgs = [ map {
            my $l = ref $_ eq 'HASH' && !$_->{discogs} ? $links->{ lc($_->{mbid} // '') } : undef;
            $l ? { %$_, discogs => $l } : $_;
        } @$rgs ] if ref $links eq 'HASH' && %$links;
    }
    my $map  = _match($list, $rgs, $floor);
    delete @index{ grep { $now - $index{$_}{at} >= INDEX_TTL } keys %index };
    $index{$ambid} = { at => $now, map => $map };
    return $map;
}

# { group mbid => thumbnail } for $rgs from the Discogs $list (the header's
# rules). $floor: titles matched only in years above it (a list kept after a
# page failed holds those whole; undef = no limit).
sub _match {
    my ($list, $rgs, $floor) = @_;
    my (%byId, %byKey);
    for my $e (@{ $list || [] }) {
        $byId{"$e->{kind}:$e->{id}"} //= $e->{thumb};
        push @{ $byKey{ _titleKey($e->{title}) } }, $e;
    }
    my %linked = map { ($_->{discogs} => 1) } grep { $_->{discogs} } @{ $rgs || [] };
    my (%mbSame, %map);
    for my $rg (grep { !$_->{discogs} } @{ $rgs || [] }) {
        my ($y) = ($rg->{date} // '') =~ /^(\d{4})/;
        $mbSame{ _titleKey($rg->{title}) . "|$y" }++ if $y;
    }
    for my $rg (@{ $rgs || [] }) {
        my $id = lc($rg->{mbid} // '') or next;
        my $t;
        if ($rg->{discogs}) {
            $t = $byId{ $rg->{discogs} };          # linked: that entry or nothing
        }
        else {
            my ($y) = ($rg->{date} // '') =~ /^(\d{4})/;
            next unless $y;
            next if defined $floor && $y <= $floor;
            my $k = _titleKey($rg->{title});
            next if ($mbSame{"$k|$y"} // 0) > 1;
            my @c = @{ $byKey{$k} || [] };
            my @m = grep { $_->{kind} eq 'master' } @c;
            @c = @m if @m;
            @c = grep { !$linked{"$_->{kind}:$_->{id}"} && ($_->{year} // 0) == $y } @c;
            $t = $c[0]{thumb} if @c == 1;
        }
        $map{$id} = $t if defined $t;
    }
    return \%map;
}

1;
