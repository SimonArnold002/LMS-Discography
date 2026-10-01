#!/usr/bin/env perl
#
# EVERY MODULE LOGS UNDER plugin.discography (0.56.16).
#
# LMS's `logger` is a plain FUNCTION whose first argument is the category
# (slimserver 9.1 Slim/Utils/Log.pm: `sub logger { my $category = shift; ... }`).
# Browse.pm and Sources.pm called it as a METHOD from the first import on, so
# `shift` took the class name: their lines were filed under "Slim::Utils::Log"
# and everything below WARN was dropped, whatever Discography's log level. Found
# 2026-10-01 when SingleFlight (handed Sources' logger) logged "already in
# flight" at info and nothing appeared.
#
# Loads the REAL Browse (which loads API and Sources) with `logger` recording
# the category each module asks for, and scans every module's source.
#
# Standalone -- no LMS install needed:  perl tools/t_logger.pl
#
use strict;
use warnings;
use FindBin;

our (@CATS);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    # Records (calling package, category) and hands back a logger that knows
    # its category, so a test can ask any logger object which one it is.
    *{'Slim::Utils::Log::logger'}          = sub { push @main::CATS, [ scalar caller, $_[0] ];
                                                   bless { cat => $_[0] }, 'T::Log' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'}   = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Strings::cstring'}     = sub { $_[1] };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json from_json);
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { {} };
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Log;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# 1. Each module that makes a logger asks for plugin.discography.
for my $pkg (qw(API Sources Browse)) {
    my @mine = grep { $_->[0] eq "Plugins::Discography::$pkg" } @CATS;
    ok(scalar(@mine && !grep { ($_->[1] // '') ne 'plugin.discography' } @mine),
       "1: $pkg.pm logs under plugin.discography");
}
ok(scalar(!grep { ($_->[1] // '') eq 'Slim::Utils::Log' } @CATS),
   "1: no module's logger is filed under 'Slim::Utils::Log' (the method-call form)");

# 2. The candidate registry is handed a Discography logger, so its "already in
#    flight" line shows at Discography's own log level.
my $flight = Plugins::Discography::Sources->can('_candFlight')->();
ok(scalar(ref $flight && ref $flight->{log} && ($flight->{log}{cat} // '') eq 'plugin.discography'),
   "2: SingleFlight (pool fetches) logs under plugin.discography");

# 3. No module makes its logger the method way (Plugin.pm's addLogCategory IS a
#    method and is fine; DB.pm is not loaded above, so this covers it).
my @bad;
for my $f (glob "$FindBin::Bin/../Discography/*.pm") {
    open my $fh, '<', $f or die "$f: $!";
    while (my $l = <$fh>) {
        next if $l =~ /^\s*#/;
        push @bad, (split m{/}, $f)[-1] . ":$." if $l =~ /Slim::Utils::Log\s*->\s*logger\s*\(/;
    }
    close $fh;
}
ok(scalar(!@bad), '3: no module calls Slim::Utils::Log->logger(...)' . (@bad ? " (@bad)" : ''));

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
