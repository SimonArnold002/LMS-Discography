package Plugins::Discography::Plugin;

# Discography — a Lyrion Music Server plugin.
#
# Browse an artist's FULL discography — not just what's in the library. The
# discography spine comes from MusicBrainz release-groups (original/first
# release dates, primary types), artwork from the Cover Art Archive, and each
# release resolves to playable sources: the local library and/or the user's
# streaming services (Qobuz / Tidal / Deezer). The streaming resolver is a
# trimmed port of the album-match engine from the ListenBrainz Fresh Releases
# plugin, same as the Pitchfork Reviews plugin's port.
#
# Entry point: a "Full Discography" custom action on the ARTIST context menu in
# Material Skin (an `lmsbrowse` action written into the shared
# prefs/material-skin/actions.json — read-merge-write, we only ever touch our
# own entries; the file is shared with Listen Later and user-defined actions).
# The plugin is also registered as an app so the feed is reachable/testable
# without Material.
#
# Pure Perl, async HTTP, no extra server software (cross-platform).

use strict;
use base qw(Slim::Plugin::OPMLBased);

use JSON::XS;
use File::Path ();
use File::Spec;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(string cstring);

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.discography',
    # WARN in production keeps server.log quiet. Raise to INFO via Settings ->
    # Logging when diagnosing (same convention as the sibling plugins).
    'defaultLevel' => 'WARN',
    'description'  => 'PLUGIN_DISCOGRAPHY',
});

my $prefs = preferences('plugin.discography');

# Canonical debug sink for the whole plugin — API/Browse/Sources all delegate
# here (fleet pattern; PFR and LBF do the same). The debug_log pref mirrors to
# server.log at ERROR level, visible without touching Settings -> Logging:
#   ["pref","plugin.discography:debug_log","1"]
# OFF logs at INFO, hidden at the default WARN. Resolution failures MUST go
# through this — "artist not found" at info level is undiagnosable in the field.
sub dbg {
    my ($msg) = @_;
    if ($prefs->get('debug_log')) { $log->error("dsc[dbg]: $msg") }
    else                          { $log->info("dsc: $msg") }
}

# Canonical JSON writer for the shared actions.json (stable output for diffs).
my $JSON = JSON::XS->new->utf8->canonical->pretty;

$prefs->init({
    # Write the "Full Discography" entry to Material's artist context menu.
    material_action => 1,

    # Default discography sort: 'newest' or 'oldest' first (by original release
    # date from MusicBrainz). An in-menu toggle overrides per visit.
    sort_order => 'newest',

    # Source priority (ascending; 0 = never use). Local = the library.
    # Same convention as the ListenBrainz / Pitchfork plugins.
    svc_priority_local  => 1,
    svc_priority_qobuz  => 2,
    svc_priority_tidal  => 3,
    svc_priority_deezer => 4,

    # Which release-type sections to show (CSV of Browse.pm group keys).
    show_types => 'ALBUMS,EPS,SINGLES,COMPILATIONS,LIVE,OTHER',

    # Hide releases with no source match. Only applies once the artist's
    # candidates are cached (an unresolved artist shows everything); the
    # visible set is SNAPSHOTTED per visit for walk-stability (Browse.pm).
    hide_unmatched => 1,

    # Detail page: 0 = just the preferred service's best version (one row);
    # 1 = every matching service's versions under per-service headers.
    show_all_versions => 0,

    # "Also in your library" safety-net section: library albums under the
    # artist that no MusicBrainz release group claimed.
    show_library_extras => 1,

    # Artist bio atop the list. NB: ANY text row disables Material's grid for
    # the whole view (hard rule in browse-resp.js, even window.textarea) — so
    # bio and grid-capable tiles are mutually exclusive; this picks which.
    show_bio => 1,

    # Opt-in extra logging.
    debug_log => 0,
});

sub initPlugin {
    my $class = shift;

    if (main::WEBUI) {
        require Plugins::Discography::Settings;
        Plugins::Discography::Settings->new();
    }

    require Plugins::Discography::API;
    require Plugins::Discography::Sources;
    require Plugins::Discography::Browse;

    $class->SUPER::initPlugin(
        tag    => 'discography',
        feed   => \&Plugins::Discography::Browse::topLevel,
        is_app => 1,
        menu   => 'radios',
        weight => 10,
    );

    return;
}

# Runs after all plugins have initialised, so Material Skin is available to
# check before touching its actions file.
sub postinitPlugin {
    my $class = shift;

    if ( Slim::Utils::PluginManager->isEnabled('Plugins::MaterialSkin::Plugin') ) {
        if ( $prefs->get('material_action') ) {
            eval { _writeMaterialActions(); 1 }
                or $log->error("dsc: failed to write Material custom action: $@");
        }
        else {
            # Pref is OFF but a previous run may have written our entry — strip it
            # so the toggle actually removes the menu item.
            eval { _clearMaterialActions(); 1 }
                or $log->error("dsc: failed to clear Material custom action: $@");
        }
    }

    return;
}

# ---------------------------------------------------------------------------
# Material custom action (prefs/material-skin/actions.json)
#
# The file is SHARED — Material itself, Listen Later and hand-written user
# actions all live in it. Discipline (same as Listen Later): read the whole
# file, strip only OUR entries (matched by _isOurAction), append the current
# one, write back atomically. We never reset a category we don't own.
# ---------------------------------------------------------------------------

sub _materialActionsFile {
    my $dir = File::Spec->catdir(Slim::Utils::Prefs::dir(), 'material-skin');
    return File::Spec->catfile($dir, 'actions.json');
}

# Read the shared actions.json into a hashref (empty on missing/corrupt).
sub _readMaterialActions {
    my ($file) = @_;
    my $data = {};
    if (-e $file) {
        local $/;
        if (open my $fh, '<:raw', $file) {
            my $raw = <$fh>;
            close $fh;
            $data = eval { JSON::XS->new->utf8->decode($raw) } || {};
            $data = {} unless ref $data eq 'HASH';
        }
    }
    return $data;
}

# Write atomically: a truncated write (crash mid-write) would corrupt every
# plugin's actions, not just ours. Temp file then rename() over the original.
sub _writeMaterialActionsFile {
    my ($file, $data) = @_;
    my $tmp = "$file.tmp.$$";
    open my $fh, '>:raw', $tmp or die "open $tmp: $!";
    print $fh $JSON->encode($data) or do { close $fh; unlink $tmp; die "write $tmp: $!" };
    close $fh                      or do {            unlink $tmp; die "close $tmp: $!" };
    rename($tmp, $file)            or do {            unlink $tmp; die "rename $tmp -> $file: $!" };
    return;
}

# Ours = an lmsbrowse action whose command targets our 'discography' tag.
sub _isOurAction {
    my ($entry) = @_;
    return 0 unless ref $entry eq 'HASH';
    my $lb = $entry->{lmsbrowse};
    return 1 if ref $lb eq 'HASH'
             && ref $lb->{command} eq 'ARRAY'
             && ($lb->{command}[0] // '') eq 'discography';
    return 0;
}

sub _writeMaterialActions {
    my $file = _materialActionsFile();
    my $dir  = File::Spec->catdir(Slim::Utils::Prefs::dir(), 'material-skin');
    File::Path::make_path($dir) unless -d $dir;

    my $data = _readMaterialActions($file);

    # Strip our entries from every category (covers a category rename between
    # versions), then append the current entry to 'artist'.
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        $data->{$cat} = [ grep { !_isOurAction($_) } @{ $data->{$cat} } ];
    }

    # `lmsbrowse` navigates Material INTO our browse feed with the item's $VARS
    # substituted. On an artist item $ARTISTID comes from the "artist_id:N" item
    # id and is the reliable key (we resolve the display name from the library
    # DB). $TITLE is the row's title — the artist name on artist rows — kept as
    # a fallback for surfaces without an artist_id. Unpopulated $VARS arrive as
    # the literal token ("$TITLE"); the feed guards against those.
    #
    # menu:discography is ESSENTIAL: without a menu param XMLBrowser answers in
    # the legacy loop_loop format whose items carry NO click actions — Material
    # renders the list but every click builds an empty command (blank page).
    # With it the response is SlimBrowse item_loop with per-item go actions
    # (verified live both ways, 0.2.2).
    # features:hi — Material appends this itself on every DRILL command
    # (browseBuildCommand), but the custom-action entry fetch bypasses that
    # path, so advertise it here or the top view renders headers as plain text
    # while drill rebuilds render real ones.
    # "Discography", not "Full Discography" — streaming-gated matching means
    # we can't promise completeness (hide_unmatched drops what we can't play).
    push @{ $data->{artist} ||= [] }, {
        title => 'Discography',
        icon  => 'album',
        lmsbrowse => {
            command => [ 'discography', 'items' ],
            params  => [ 'artist_id:$ARTISTID', 'artist:$TITLE', 'menu:discography', 'features:hi' ],
        },
    };

    _writeMaterialActionsFile($file, $data);
    $log->info("dsc: wrote Material artist custom action to $file");

    # NB: Material reads customactions.json ONCE at app start and browser-caches
    # it — an already-open Material tab needs a hard refresh to see this entry.
    return;
}

sub _clearMaterialActions {
    my $file = _materialActionsFile();
    return unless -e $file;

    my $data    = _readMaterialActions($file);
    my $changed = 0;
    for my $cat (keys %$data) {
        next unless ref $data->{$cat} eq 'ARRAY';
        my @kept = grep { !_isOurAction($_) } @{ $data->{$cat} };
        if (@kept != @{ $data->{$cat} }) {
            $data->{$cat} = \@kept;
            $changed = 1;
        }
        # Drop the 'artist' key only if WE emptied it; an empty category is not
        # neutral in Material (it suppresses), so never leave one behind.
        delete $data->{$cat} if $changed && $cat eq 'artist' && !@kept;
    }
    _writeMaterialActionsFile($file, $data) if $changed;
    $log->info("dsc: cleared Material artist custom action") if $changed;
    return;
}

1;
