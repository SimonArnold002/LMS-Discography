#!/usr/bin/env perl
#
# REGRESSION TEST — SETTINGS CHECKBOXES STICK WHEN UNTICKED (0.52.1).
#
# An unticked HTML checkbox posts NOTHING. Slim::Web::Settings::handler then sets
# every pref in prefs() from $params->{pref_<name>} regardless (LL's Settings.pm
# cites the line), so the pref is stored as undef — and Prefs::Base::init
# re-seeds an undef pref with its DEFAULT at the next load. A default-on box
# therefore came back ticked after every restart: "Material Skin artist menu
# entry" could not be turned off (field, 2026-09-24). LBF fixed the same thing
# long ago with @CHECKBOX_PREFS; Discography never got it.
#
# This RUNS the real handler() against a base class that behaves like LMS's
# (unconditional set, then beforeRender), per the settings-page rule: a test of
# an extracted sub cannot see a handler that never reaches its end.
#
# Standalone -- no LMS install needed:  perl tools/t_settings.pl
#
use strict;
use warnings;
use FindBin;

our %STORE;
our $BASE_RAN = 0;

BEGIN {
    for my $m (qw(Slim::Utils::Prefs Slim::Web::Settings Plugins::Discography::Sources)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Prefs' };
    push @{'Slim::Utils::Prefs::ISA'}, 'Exporter';
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    *{'Plugins::Discography::Sources::serviceStatus'} = sub { [] };
    # The LMS base: for EVERY pref in prefs(), set it from pref_<name> — present
    # or not — then call beforeRender.
    *{'Slim::Web::Settings::handler'} = sub {
        my ($class, $client, $params) = @_;
        if ($params->{saveSettings}) {
            my ($prefs, @names) = $class->prefs;
            $main::STORE{$_} = $params->{"pref_$_"} for @names;
        }
        $class->beforeRender($params, $client);
        $main::BASE_RAN = 1;
        return 'rendered';
    };
    *{'Slim::Web::Settings::beforeRender'} = sub { };
}

package T::Prefs;
sub get { $main::STORE{$_[1]} }
sub set { $main::STORE{$_[1]} = $_[2] }
package main;

require "$FindBin::Bin/../Discography/Settings.pm";

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $name) = @_;
    die "ok() called without a test name - list-context trap?\n" unless defined $name;
    if ($cond) { $pass++; print "ok   $name\n" } else { $fail++; print "FAIL $name\n" }
}
sub section { print "\n== $_[0]\n" }

my @CB = @Plugins::Discography::Settings::CHECKBOX_PREFS;
my %DEFAULTS = (
    material_action => 1, hide_unmatched => 1, show_bio => 1, show_library_extras => 1,
    show_streaming_extras => 0, show_all_versions => 0, debug_log => 0,
    sort_order => 'newest', show_types => 'ALBUMS,EPS', mb_base_url => '',
    svc_priority_local => 1, svc_priority_qobuz => 2, svc_priority_tidal => 3, svc_priority_deezer => 4,
);
sub reset_store { %STORE = %DEFAULTS; $BASE_RAN = 0 }

# What the page posts: the always-present fields, plus whichever boxes are ticked.
sub form_post {
    my (%ticked) = @_;
    my %p = (
        saveSettings => 1, dsc_types_form => 1,
        pref_sort_order => 'newest', pref_mb_base_url => '',
        pref_svc_priority_local => 1, pref_svc_priority_qobuz => 2,
        pref_svc_priority_tidal => 3, pref_svc_priority_deezer => 4,
        dsc_type_ALBUMS => 1, dsc_type_EPS => 1,
    );
    $p{"pref_$_"} = 1 for keys %ticked;
    return \%p;
}

# ===================================================================================
section('1. the list matches the page');
open my $fh, '<', "$FindBin::Bin/../Discography/HTML/EN/plugins/Discography/settings.html" or die $!;
my $html = do { local $/; <$fh> };
my %inPage = map { $_ => 1 } ($html =~ /type="checkbox"\s+name="pref_([a-z_]+)"/g);
my %inList = map { $_ => 1 } @CB;
ok(join(',', sort keys %inPage) eq join(',', sort keys %inList),
   '1: @CHECKBOX_PREFS == every pref_* checkbox in settings.html');
my (undef, @prefNames) = Plugins::Discography::Settings->prefs;
my %inPrefs = map { $_ => 1 } @prefNames;
ok(!grep({ !$inPrefs{$_} } @CB), '1: every checkbox pref is in prefs() (so the base saves it)');

# ===================================================================================
section('2. unticking every box stores an explicit 0');
reset_store();
Plugins::Discography::Settings->handler(undef, form_post());
ok($BASE_RAN, '2: handler reached the base (it did not die part way)');
for my $cb (@CB) {
    ok(defined $STORE{$cb} && $STORE{$cb} eq '0', "2: $cb stored as 0, not undef");
}

# ===================================================================================
section('3. ticking every box stores 1');
reset_store();
$STORE{$_} = 0 for @CB;
Plugins::Discography::Settings->handler(undef, form_post(map { $_ => 1 } @CB));
for my $cb (@CB) {
    ok(defined $STORE{$cb} && $STORE{$cb} eq '1', "3: $cb stored as 1");
}

# ===================================================================================
section('4. the field case: material_action off, everything else untouched');
reset_store();
my %keepOn = map { $_ => 1 } grep { $DEFAULTS{$_} && $_ ne 'material_action' } @CB;
Plugins::Discography::Settings->handler(undef, form_post(%keepOn));
ok($STORE{material_action} eq '0', '4: material_action is 0');
ok($STORE{hide_unmatched} eq '1' && $STORE{show_bio} eq '1' && $STORE{show_library_extras} eq '1',
   '4: the other default-on boxes stay 1');

# ===================================================================================
section('5. a partial POST (no form sentinel) does not zero the toggles');
reset_store();
Plugins::Discography::Settings->handler(undef, { saveSettings => 1, pref_debug_log => 1 });
ok(!defined $STORE{material_action} || $STORE{material_action} ne '0',
   '5: an absent box is not coerced to 0 without the form sentinel');

# ===================================================================================
section('6. the rest of the form still saves');
reset_store();
my $p = form_post();
$p->{pref_sort_order} = 'oldest';
delete $p->{dsc_type_EPS};
Plugins::Discography::Settings->handler(undef, $p);
ok($STORE{sort_order} eq 'oldest', '6: sort_order radio saves');
ok($STORE{show_types} eq 'ALBUMS', '6: release-type boxes still fold into show_types');
ok($STORE{svc_priority_qobuz} == 2, '6: priorities unchanged');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
