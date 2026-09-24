#!/usr/bin/env perl
#
# REGRESSION TEST — THE MATERIAL MENU ENTRY IS REGISTERED, NOT WRITTEN (0.52.0).
#
# Material 6.4.6 added `registerCustomAction($section, $action)`. Discography now
# hands Material its one "Discography" action that way instead of writing it into
# the shared prefs/material-skin/actions.json, and startup STRIPS the entry older
# builds left in that file. Listen to Later made the same move first; its
# tools/t_material_actions.pl is the model, cut down to one positive action.
#
# Two contracts carry the weight, and each fails silently in the field:
#
#   * REGISTER ONCE. registerCustomAction pushes — no de-dupe, no unregister — so
#     a second call puts the entry in the menu twice (Material does drop a
#     repeated TITLE, but only by luck of the title matching).
#   * STRIP THE OLD FILE ENTRY. Material reads the file list BEFORE the registered
#     list and skips a repeated title, so a leftover file entry silently HIDES the
#     registered one — and keeps the menu item alive with the pref off. The strip
#     must touch nothing else: Material, Listen to Later, Album Booklet and the
#     user's own actions share that file.
#
# Drives the REAL subs out of the shipped Plugin.pm against a fake Material and a
# temporary prefs directory. Nothing is sent anywhere.
#
# Standalone -- no LMS install needed:  perl tools/t_material_actions.pl
#
use strict;
use warnings;
use FindBin;
use File::Temp ();
use JSON::XS ();

our $PREFS_DIR = File::Temp::tempdir(CLEANUP => 1);
our %PREF   = (material_action => 1);
our %ENABLED;          # plugin class => 1
our @LOG;              # [level, message]

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::PluginManager
                  Slim::Utils::Strings Slim::Control::Request Slim::Plugin::OPMLBased
                  Plugins::Discography::API)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::addLogCategory'}      = sub { bless {}, 'T::Log' };
    *{'Slim::Utils::Prefs::preferences'}       = sub { bless {}, 'T::Prefs' };
    *{'Slim::Utils::Prefs::dir'}               = sub { $main::PREFS_DIR };
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { $main::ENABLED{$_[1]} ? 1 : 0 };
    *{'Slim::Utils::Strings::string'}          = sub { $_[0] };
    *{'Slim::Utils::Strings::cstring'}         = sub { $_[1] };
    *{'Plugins::Discography::API::autodetectMirror'} = sub { 1 };
    *{'Slim::Plugin::OPMLBased::initPlugin'}   = sub { 1 };   # base class must be non-empty
    for my $p (qw(Slim::Utils::Prefs Slim::Utils::Strings)) { push @{"${p}::ISA"}, 'Exporter' }
    @{'Slim::Utils::Prefs::EXPORT'}      = ('preferences');
    @{'Slim::Utils::Strings::EXPORT_OK'} = qw(string cstring);
}

package T::Log;
sub warn  { push @main::LOG, ['warn',  $_[1]] }
sub error { push @main::LOG, ['error', $_[1]] }
sub info  { push @main::LOG, ['info',  $_[1]] }
our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs;
sub init { }
sub get  { $main::PREF{$_[1]} }
our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package main;

use constant WEBUI => 0;
require "$FindBin::Bin/../Discography/Plugin.pm";

my ($pass, $fail) = (0, 0);
# Dies without a name: a bare match in an argument list returns the EMPTY LIST on
# failure, shifting the name into the condition slot so a failing assertion prints
# as a pass (0.47.3, fleet-wide).
sub ok {
    my ($cond, $name) = @_;
    die "ok() called without a test name - list-context trap?\n" unless defined $name;
    if ($cond) { $pass++; print "ok   $name\n" } else { $fail++; print "FAIL $name\n" }
}
sub section { print "\n== $_[0]\n" }

# --- the fake Material -------------------------------------------------------------
# ->can() is what the plugin tests, so presence is controlled by installing or
# deleting the symbol, exactly as a real Material with or without the API looks.
our @REGISTERED_CALLS;
our $REGISTER_DIES = 0;
sub material_api_on {
    no strict 'refs'; no warnings 'redefine';
    *{'Plugins::MaterialSkin::Plugin::registerCustomAction'} = sub {
        die "refused\n" if $main::REGISTER_DIES;
        push @main::REGISTERED_CALLS, [@_];
    };
}
sub material_api_off {
    no strict 'refs';
    delete ${'Plugins::MaterialSkin::Plugin::'}{registerCustomAction};
}
sub reset_state {
    $Plugins::Discography::Plugin::REGISTERED = 0;
    @REGISTERED_CALLS = ();
    $REGISTER_DIES = 0;
    @LOG = ();
    %PREF = (material_action => 1);
    %ENABLED = ('Plugins::MaterialSkin::Plugin' => 1);
    unlink actions_file();
    material_api_on();
}
sub logged { my ($lvl, $re) = @_; scalar grep { $_->[0] eq $lvl && $_->[1] =~ $re } @LOG }

# --- the shared file ---------------------------------------------------------------
sub actions_file { "$PREFS_DIR/material-skin/actions.json" }
sub write_file {
    my ($raw) = @_;
    mkdir "$PREFS_DIR/material-skin";
    open my $fh, '>:raw', actions_file() or die $!; print $fh $raw; close $fh;
}
sub write_json { write_file(JSON::XS->new->utf8->canonical->encode($_[0])) }
sub read_raw {
    open my $fh, '<:raw', actions_file() or return undef;
    local $/; my $r = <$fh>; close $fh; $r;
}
sub read_json { my $r = read_raw(); defined $r ? JSON::XS->new->utf8->decode($r) : undef }

my $OURS = Plugins::Discography::Plugin::_materialAction();
my $OLD_OURS = {        # what 0.2.x-0.7.x wrote: a different title, fewer params
    title => 'Full Discography', icon => 'album',
    lmsbrowse => { command => ['discography','items'], params => ['artist_id:$ARTISTID','artist:$TITLE'] },
};
my $BOOKLET = { title => 'View Booklet', icon => 'picture_as_pdf',
                weblink => '/albumbooklet/booklet?player=$ID' };
my $USER_ARTIST = { title => 'Wikipedia', icon => 'public',
                    weblink => 'https://en.wikipedia.org/wiki/$TITLE' };
my $LL_ALBUM = { title => 'Add to Listen Later', icon => 'playlist_add',
                 lmscommand => ['listenlater','addctx','name:$ALBUMNAME'] };

# ===================================================================================
section('1. the action is the one the file used to carry');
ok($OURS->{title} eq 'Discography', '1: title is "Discography"');
ok($OURS->{icon} eq 'album', '1: icon is album');
ok(join(',', @{ $OURS->{lmsbrowse}{command} }) eq 'discography,items', '1: lmsbrowse command');
ok(join('|', @{ $OURS->{lmsbrowse}{params} })
       eq 'artist_id:$ARTISTID|artist:$TITLE|menu:discography|features:hi',
   '1: all four params, menu:discography and features:hi included');
ok(!exists $OURS->{lmscommand}, '1: an lmsbrowse action, not an lmscommand');
ok(Plugins::Discography::Plugin::_isOurAction($OURS), '1: the cleanup recognises our own action');

# ===================================================================================
section('2. registration: once, into artist, through ->can');
reset_state();
ok(Plugins::Discography::Plugin::_registerMaterialActions() == 1, '2: first call registers');
ok(Plugins::Discography::Plugin::_registerMaterialActions() == 0, '2: second call is a no-op');
ok(scalar(@REGISTERED_CALLS) == 1, '2: registerCustomAction called exactly once');
ok($REGISTERED_CALLS[0][0] eq 'artist', '2: into the artist section');
ok(scalar(@{ $REGISTERED_CALLS[0] }) == 2, '2: the two-argument form (never the empty-section call)');
ok(JSON::XS->new->canonical->encode($REGISTERED_CALLS[0][1])
       eq JSON::XS->new->canonical->encode($OURS), '2: registers exactly _materialAction');

# ===================================================================================
section('3. no registration API (Material < 6.4.6)');
reset_state();
material_api_off();
my $r = eval { Plugins::Discography::Plugin::_registerMaterialActions() };
ok(!$@, '3: does not die');
ok(defined $r && $r == 0, '3: reports nothing registered');
ok(!$Plugins::Discography::Plugin::REGISTERED, '3: latch NOT set, so a later Material could still take it');
ok(logged('warn', qr/needs 6\.4\.6/), '3: says why in the log');

# ===================================================================================
section('4. Material refuses the action');
reset_state();
$REGISTER_DIES = 1;
$r = eval { Plugins::Discography::Plugin::_registerMaterialActions() };
ok(!$@ && defined $r && $r == 0, '4: a dying registerCustomAction is caught and reported as 0');
ok($Plugins::Discography::Plugin::REGISTERED, '4: latched on the ATTEMPT');
ok(logged('error', qr/refused/), '4: the refusal is logged');

# ===================================================================================
section('5. postinitPlugin wiring');
reset_state();
Plugins::Discography::Plugin->postinitPlugin();
Plugins::Discography::Plugin->postinitPlugin();
ok(scalar(@REGISTERED_CALLS) == 1, '5: two postinit runs still register once');

reset_state();
$PREF{material_action} = 0;
Plugins::Discography::Plugin->postinitPlugin();
ok(scalar(@REGISTERED_CALLS) == 0, '5: pref off registers nothing');

reset_state();
%ENABLED = ();
write_json({ artist => [ $OURS ] });
my $before = read_raw();
Plugins::Discography::Plugin->postinitPlugin();
ok(scalar(@REGISTERED_CALLS) == 0, '5: Material disabled registers nothing');
ok(read_raw() eq $before, '5: Material disabled leaves the file alone');

reset_state();
write_json({ artist => [ $OURS ], track => [ $BOOKLET ] });
Plugins::Discography::Plugin->postinitPlugin();
ok(scalar(@REGISTERED_CALLS) == 1, '5: pref on registers');
ok(!exists read_json()->{artist}, '5: ...and strips the old file entry in the same run');

reset_state();
$PREF{material_action} = 0;
write_json({ artist => [ $OURS ], track => [ $BOOKLET ] });
Plugins::Discography::Plugin->postinitPlugin();
ok(!exists read_json()->{artist}, '5: pref OFF still strips the old file entry');

# ===================================================================================
section('6. the strip: ours out, everything else untouched');
reset_state();
write_json({ artist => [ $USER_ARTIST, $OURS ], track => [ $BOOKLET ], album => [ $LL_ALBUM ] });
Plugins::Discography::Plugin::_clearMaterialActions();
my $d = read_json();
ok(scalar(@{ $d->{artist} }) == 1 && $d->{artist}[0]{title} eq 'Wikipedia',
   '6: the user\'s own artist action survives, ours is gone');
ok($d->{track}[0]{title} eq 'View Booklet', '6: Album Booklet\'s entry survives');
ok($d->{album}[0]{title} eq 'Add to Listen Later', '6: Listen to Later\'s entry survives');
ok(!-e actions_file() . ".tmp.$$", '6: no temp file left behind');

reset_state();
write_json({ artist => [ $OLD_OURS ], track => [ $BOOKLET ] });
Plugins::Discography::Plugin::_clearMaterialActions();
ok(!exists read_json()->{artist}, '6: an OLD-shaped entry ("Full Discography") is ours too');
ok(logged('warn', qr/removed the old Discography entry/), '6: the strip says what it did');

# ===================================================================================
section('7. an empty category is deleted only when WE emptied it');
reset_state();
write_json({ artist => [ $OURS ], track => [ $BOOKLET ] });
Plugins::Discography::Plugin::_clearMaterialActions();
ok(!exists read_json()->{artist}, '7: artist emptied by us -> removed (an empty category suppresses)');

reset_state();
# Somebody else keeps an EMPTY artist section on purpose, and our entry sits in
# another category. The pre-0.52 flag was file-wide, so this deleted their section.
write_json({ artist => [], album => [ $OURS, $LL_ALBUM ] });
Plugins::Discography::Plugin::_clearMaterialActions();
$d = read_json();
ok(exists $d->{artist} && ref $d->{artist} eq 'ARRAY' && !@{ $d->{artist} },
   '7: a deliberately empty artist section someone else owns survives');
ok(scalar(@{ $d->{album} }) == 1, '7: ...while ours is still taken out of the other category');

# ===================================================================================
section('8. nothing of ours: the file is not rewritten');
reset_state();
write_json({ track => [ $BOOKLET ] });
my $raw = read_raw();
my $mtime = (stat actions_file())[9];
sleep 1;
Plugins::Discography::Plugin::_clearMaterialActions();
ok(read_raw() eq $raw, '8: bytes identical');
ok((stat actions_file())[9] == $mtime, '8: not even touched (mtime unchanged)');

reset_state();
Plugins::Discography::Plugin::_clearMaterialActions();
ok(!-e actions_file(), '8: an absent file is not created');

# ===================================================================================
section('9. a file we cannot read is left exactly as it is');
reset_state();
write_file('{"track":[{"title":"View Booklet"}], TRUNCATED');
$raw = read_raw();
Plugins::Discography::Plugin::_clearMaterialActions();
ok(read_raw() eq $raw, '9: unparseable file untouched');

reset_state();
write_file('["not","an","object"]');
$raw = read_raw();
Plugins::Discography::Plugin::_clearMaterialActions();
ok(read_raw() eq $raw, '9: a JSON array (not an object) untouched');

printf "\n%d passed, %d failed\n", $pass, $fail;
exit($fail ? 1 : 0);
