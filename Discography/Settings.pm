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

sub name { 'PLUGIN_DISCOGRAPHY' }

sub page { 'plugins/Discography/settings.html' }

sub prefs {
    return ($prefs, qw(
        svc_priority_local svc_priority_qobuz svc_priority_tidal svc_priority_deezer
        sort_order show_types hide_unmatched show_bio show_library_extras
        show_all_versions material_action debug_log
    ));
}

sub handler {
    my ($class, $client, $params) = @_;

    if ($params->{saveSettings}) {
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
