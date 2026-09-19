#!/usr/bin/env perl
#
# REGRESSION TEST — a name shown under "Also a member of" must NOT be repeated
# under "Similar artists".
#
# THIS IS NOT COSMETIC. Field (Simon, screenshot, 2026-07-29): Frank Zappa's
# "Also a member of" listed Ned and Nelda / Ruben and the Jets / The Midnighters
# and *dropped* The Mothers of Invention — while the same name rendered fine
# under Similar artists. The FEED was correct: the live SlimBrowse response
# (`menu:1`) carried all four band rows. The row is lost in MATERIAL, on the
# My Apps entry path only:
#
#   browse-resp.js sets isApps from the parent's section (inherited by every
#   descendant view), and the Apps id ladder is
#       params.item_id -> presetParams.favorites_url
#                      -> actions.go.params.item_id
#                      -> parent.id + "." + i.title      <- our rows land here
#   because XMLBrowser emits params.item_id / a favurl only for PLAYABLE items,
#   and our self-identifying `go` sends artist/mbid instead of an item_id.
#   The list is keyed :key="item.id", so two rows with the same TITLE share a
#   Vue key and only one is rendered — the later section wins.
#
# Album tiles are immune (playable -> a real params.item_id), so only these two
# navigation sections can collide. Material is not ours to patch, the drill is
# identical either way, and MB membership outranks a Last.fm suggestion — so
# the similar-artists copy is the one that goes.
#
# Standalone -- no LMS install needed:  perl tools/t_dupes.pl
#
use strict;
use warnings;
use FindBin;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  Plugins::Discography::Plugin Plugins::Discography::API)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Strings::cstring'}     = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;      # loads the REAL Sources::_norm
my $drop = \&Plugins::Discography::Browse::_dropBandDupes;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# The field case, with the REAL spellings from MusicBrainz and Last.fm.
my $ZAPPA_BANDS = [
    { mbid => 'c14dc975', name => 'Ned and Nelda' },
    { mbid => '32fbbfeb', name => 'Ruben and the Jets' },
    { mbid => 'b54b7869', name => 'The Midnighters' },
    { mbid => 'fe98e268', name => 'The Mothers of Invention' },
];
my $ZAPPA_SIMILAR = [ 'The Mothers of Invention', 'Frank Zappa & Captain Beefheart',
                      'King Crimson', 'Captain Beefheart & His Magic Band', 'Gentle Giant' ];

my $out = $drop->($ZAPPA_SIMILAR, $ZAPPA_BANDS);
ok(scalar(@$out) == 4, 'the field case: one name dropped from Similar artists');
ok(scalar(!grep { $_ eq 'The Mothers of Invention' } @$out),
   '... and it is the band, so its "Also a member of" row can render');
ok(scalar($out->[0] eq 'Frank Zappa & Captain Beefheart' && $out->[-1] eq 'Gentle Giant'),
   '... with the rest kept in Last.fm relevance order');

# WHAT THE GATE MUST CATCH is exactly what Material would key alike, i.e. the
# same displayed TITLE. `_norm` is a superset of that (it folds case and
# punctuation), which is why it is used here rather than `eq`.
ok(scalar(@{ $drop->(['THE MOTHERS OF INVENTION'], $ZAPPA_BANDS) }) == 0,
   'case-only differences are folded (a superset of the exact-title collision)');
ok(scalar(@{ $drop->(['The Mothers of Invention!'], $ZAPPA_BANDS) }) == 0,
   '... and punctuation-only ones');
# A leading article is NOT folded (`_norm` is not `_stripArtistPrefix`) and must
# not be: it is a DIFFERENT title, so Material keys it differently and both rows
# render. Dropping it would silently delete a row for no benefit.
ok(scalar(@{ $drop->(['Mothers of Invention'], $ZAPPA_BANDS) }) == 1,
   'a leading-article variant is KEPT - a different title cannot collide');
ok(scalar(@{ $drop->(['The Mothers'], $ZAPPA_BANDS) }) == 1,
   'and a genuinely different act with a similar name is never dropped');

# Nothing to do -> the list is returned untouched, never rebuilt or reordered.
ok(scalar(@{ $drop->($ZAPPA_SIMILAR, []) }) == 5, 'no bands -> the list is unchanged');
ok(scalar(@{ $drop->($ZAPPA_SIMILAR, undef) }) == 5, 'undef bands -> unchanged');
ok(scalar(!defined $drop->(undef, $ZAPPA_BANDS)), 'undef similar stays undef (no section)');
ok(scalar(@{ $drop->([], $ZAPPA_BANDS) }) == 0, 'an empty list stays empty');

# Junk on either side must not take a real row down with it: a band whose name
# normalises to nothing ("( )") would otherwise key an empty bucket that every
# unnamed similar entry then matched.
ok(scalar(@{ $drop->(['King Crimson'], [{ name => '( )' }, { name => '' }]) }) == 1,
   'a band name that normalises to nothing drops nobody');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
