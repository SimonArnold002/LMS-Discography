#!/usr/bin/env perl
#
# REGRESSION TEST — a search row that becomes LOCAL must be ranked as local
# (review 2026-09-19).
#
# "Local always trumps" (Simon, 0.48.4) is applied twice already, because two
# separate passes can make a row owned after the merge has ranked it:
# `attachLibraryArtists` (0.48.1, "The La's") and then the MusicBrainz-tag
# attach inside `filterRowsWithContent` (0.51.3, the braille/Yi artist whose
# name no index can hold). The first is followed by a re-rank; the second was
# NOT — it runs inside the filter callback, after `rankArtistHits` — so a row
# that gained an artist_id and a Local source there kept the position it had as
# a streaming-only row, below unowned same-name rows.
#
# Drives the REAL `_withMbCandidates` with the filter stubbed to attach Local
# exactly as the tag attach does, and asserts the ORDER of the rows it emits.
#
# Standalone -- no LMS install needed:  perl tools/t_searchrank.pl
#
use strict;
use warnings;
use FindBin;

our @EMITTED;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  Plugins::Discography::Plugin Plugins::Discography::API)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');

    my $A = 'Plugins::Discography::API';
    # THE TAG ATTACH, as filterRowsWithContent performs it: a kept row with no
    # artist_id is claimed by its resolved MusicBrainz id, gaining the id and a
    # leading Local source. Nothing is dropped here.
    *{"${A}::filterRowsWithContent"} = sub {
        my ($class, $rows, $cb) = @_;
        for my $r (@$rows) {
            next unless ($r->{name} // '') eq 'Owned By Tag';
            $r->{artist_id} = 88810;
            unshift @{ $r->{sources} ||= [] }, 'Local';
        }
        return $cb->($rows);
    };
    *{"${A}::getArtistCandidates"} = sub { $_[-1]->([]) };   # no same-name section
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';
{
    no warnings 'redefine'; no strict 'refs';
    # Capture the rows in the order the view builds them.
    *{"${B}::_searchResultItems"} = sub {
        my ($client, $rows) = @_;
        @main::EMITTED = map { $_->{name} } @$rows;
        return [ map { { name => $_->{name} } } @$rows ];
    };
    # The library-side passes are not what this test is about.
    *{'Plugins::Discography::Sources::attachLibraryArtists'} = sub { $_[1] };
    *{'Plugins::Discography::Sources::splitOwnedByIdentity'} = sub { $_[1] };
}

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# Three merged rows in the order the merge ranked them: two unowned streaming
# rows first (breadth), and the row that only becomes Local inside the filter.
sub rows {
    return [
        { name => 'Unowned Wide', sources => [ 'Qobuz', 'Tidal', 'Deezer' ], _seq => 0 },
        { name => 'Unowned Two',  sources => [ 'Qobuz', 'Tidal' ],           _seq => 1 },
        { name => 'Owned By Tag', sources => [ 'Qobuz' ],                    _seq => 2 },
    ];
}

@EMITTED = ();
$B->can('_withMbCandidates')->(undef, sub { }, '', 'q', rows());
ok(scalar(@EMITTED == 3), 'every row still reaches the view');
ok(scalar(($EMITTED[0] // '') eq 'Owned By Tag'),
   'the row the MusicBrainz tag made Local is ranked first');
ok(scalar(($EMITTED[1] // '') eq 'Unowned Wide'),
   '... and the unowned rows keep their own order below it');

# CONTROL: with nothing attached, the order is exactly as the merge left it —
# the re-rank must not reshuffle a list it has no new information about.
{
    no warnings 'redefine'; no strict 'refs';
    my $prev = \&Plugins::Discography::API::filterRowsWithContent;
    *{'Plugins::Discography::API::filterRowsWithContent'} = sub { $_[-1]->($_[1]) };
    @EMITTED = ();
    $B->can('_withMbCandidates')->(undef, sub { }, '', 'q', rows());
    ok(scalar(join(',', @EMITTED) eq 'Unowned Wide,Unowned Two,Owned By Tag'),
       'control: nothing attached -> the merge order is untouched');
    *{'Plugins::Discography::API::filterRowsWithContent'} = $prev;
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
