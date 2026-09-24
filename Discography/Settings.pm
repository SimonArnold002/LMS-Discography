package Plugins::Discography::Settings;

# Settings page: source priorities (Local + streaming, with detection),
# discography-view options, release-page mode, integration toggles.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.discography');

# The release-type section keys, in display order (mirror Browse.pm's
# @GROUP_ORDER — keep in sync).
my @TYPE_KEYS = qw(ALBUMS EPS SINGLES COMPILATIONS LIVE OTHER);

# Every checkbox pref on the page (LBF's @CHECKBOX_PREFS, same reason). An
# unticked checkbox posts NOTHING, and Slim::Web::Settings::handler then stores
# undef for it; Prefs::Base::init re-seeds an undef pref with its DEFAULT at the
# next load, so a default-on box (material_action, hide_unmatched, show_bio,
# show_library_extras) came back ticked after every restart and could never be
# turned off. handler() coerces each to an explicit 0/1.
#
# KEEP IN SYNC with the pref_* checkboxes in settings.html. The release-type
# boxes are NOT here — they are dsc_type_* fields folded into show_types below.
our @CHECKBOX_PREFS = qw(
    hide_unmatched show_bio show_library_extras show_streaming_extras
    show_all_versions material_action debug_log
);

sub name { 'PLUGIN_DISCOGRAPHY' }

sub page { 'plugins/Discography/settings.html' }

sub prefs {
    return ($prefs, qw(
        svc_priority_local svc_priority_qobuz svc_priority_tidal svc_priority_deezer
        sort_order layout_albums layout_singles show_types hide_unmatched show_bio show_library_extras
        show_streaming_extras
        show_all_versions material_action mb_base_url debug_log
    ));
}

sub handler {
    my ($class, $client, $params) = @_;

    if ($params->{saveSettings}) {
        # Checkboxes -> explicit 0/1, but only for the REAL form: an unticked box
        # and a box absent from a partial/non-form POST look the same, and a
        # blind coercion would zero every toggle on a partial save. The hidden
        # dsc_types_form field is always posted by the page, so it is the
        # sentinel (it also gates the release-type boxes below).
        if (defined $params->{dsc_types_form}) {
            $params->{"pref_$_"} = $params->{"pref_$_"} ? 1 : 0 for @CHECKBOX_PREFS;
        }

        # Normalise priorities to integers 0-9 (0 = never use). An absent field
        # (partial/non-form POST) keeps the CURRENT value rather than forcing 0,
        # which would silently disable that source (fleet convention).
        for my $src (qw(local qobuz tidal deezer)) {
            my $p = $params->{"pref_svc_priority_$src"};
            if (defined $p && $p =~ /^\d+$/) {
                $p = 9 if $p > 9;
                $params->{"pref_svc_priority_$src"} = $p + 0;
            }
            else {
                $params->{"pref_svc_priority_$src"} = $prefs->get("svc_priority_$src") // 0;
            }
        }

        # Fixed enum — keep the current value on any unexpected POST.
        my $so = $params->{pref_sort_order};
        unless (defined $so && ($so eq 'newest' || $so eq 'oldest')) {
            $params->{pref_sort_order} = $prefs->get('sort_order') // 'newest';
        }

        # Section layouts, same rule as sort_order.
        for my $lp (qw(layout_albums layout_singles)) {
            my $v = $params->{"pref_$lp"};
            unless (defined $v && ($v eq 'tiles' || $v eq 'list')) {
                $params->{"pref_$lp"} = $prefs->get($lp) // ($lp eq 'layout_singles' ? 'list' : 'tiles');
            }
        }

        # MusicBrainz base URL: trim; a blank field STAYS blank so _mbBase can
        # auto-detect a same-host mirror (and fall back to the public API when
        # none is found). Storing the public URL on blank would defeat that — the
        # settings.html placeholder communicates the default in the empty box.
        # _mbBase normalises the trailing slash at read time.
        # Guard: a scheme-less entry (e.g. a bare mirror host "your-server:5000/ws/2")
        # is unfetchable and would fail EVERY MB lookup silently. Prepend http://
        # (the usual local-mirror scheme; type https:// yourself for a TLS mirror)
        # so a bare host still works.
        if (exists $params->{pref_mb_base_url}) {
            (my $u = $params->{pref_mb_base_url}) =~ s/^\s+|\s+$//g;
            $u = "http://$u" if length $u && $u !~ m{^https?://}i;
            $params->{pref_mb_base_url} = $u;
        }

        # Release-type checkboxes -> the show_types CSV. Unchecked boxes don't
        # POST, so presence of the marker field distinguishes "form submitted
        # with none ticked" (allowed — empty view is the user's choice) from a
        # partial POST (keep current).
        if (defined $params->{dsc_types_form}) {
            $params->{pref_show_types} =
                join(',', grep { $params->{"dsc_type_$_"} } @TYPE_KEYS);
        }
        else {
            $params->{pref_show_types} = $prefs->get('show_types') // '';
        }
    }

    return $class->SUPER::handler($client, $params);
}

# Slim::Web::Settings::handler persists the POST, refreshes its own `prefs`
# template var from the store, and THEN calls this — the last hook before the
# template renders.
#
# ANY template variable derived from a pref MUST be built here, not in handler().
# Built in handler() it is read BEFORE the save, so a save re-renders the page
# with the OLD values (looks like the save was lost) while the base class's
# `prefs.*` rows on the same page show the new ones.
sub beforeRender {
    my ($class, $params, $client) = @_;

    # Detected streaming services (installed + priority) for the sources table;
    # Local is rendered as its own always-present row.
    require Plugins::Discography::Sources;
    $params->{dsc_services} = Plugins::Discography::Sources::serviceStatus();

    # Checked-state map for the type checkboxes.
    my %on = map { $_ => 1 } split /\s*,\s*/, ($prefs->get('show_types') // '');
    $params->{dsc_types} = [ map { { key => $_, on => $on{$_} ? 1 : 0 } } @TYPE_KEYS ];
}

1;
