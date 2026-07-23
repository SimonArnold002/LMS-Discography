#!/usr/bin/env perl
#
# REGRESSION TEST — artist artwork is keyed by CONTRIBUTOR ID when the library
# knows the artist, the way LMS itself keys it.
#
# FIELD (Simon, 2026-07-22): *"when I play these albums or browse the artists I
# get the correct artwork ... from MAI"* — while the plugin's own row showed
# the silhouette. LMS's artist browse emits `contributor/<hash>/image`, the
# SAME image for every spelling; the plugin was asking the MAI proxy by NAME,
# which cannot resolve a name carrying typographic punctuation. 56 of his 4,288
# library artists have some. Measured live against the running server:
#
#     name 'The La’s'    ->   5,071 bytes (the silhouette)  id 57545 -> 418,519
#     name 'The Go‐Go’s' ->   5,071 bytes                   id       -> 411,927
#     name 'The dB’s'    ->   5,071 bytes                   id       ->  41,154
#     name 'Radiohead'   -> 214,785 bytes                   id       -> 214,785
#     name 'Nonexistent Band Xyzzy' -> 5,071 bytes  <- identical placeholder
#
# An earlier plan to TRANSLITERATE the punctuation was dropped: it treated the
# symptom while leaving the plugin keyed differently from the rest of LMS, and
# Simon's observation is what revealed the id route existed at all.
#
# Standalone -- no LMS install needed:  perl tools/t_artimg.pl
#
use strict;
use warnings;
use FindBin;

our $MAI_ON = 1;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Utils::Misc Slim::Menu::GlobalSearch
                  Slim::Plugin::OPMLBased
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g;
        $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Slim::Utils::Strings::cstring'} = sub { $_[1] };
    *{'Slim::Utils::Strings::string'}  = sub { $_[0] };
    push @{'Slim::Utils::Strings::ISA'}, 'Exporter';
    @{'Slim::Utils::Strings::EXPORT'} = qw(cstring string);
    *{'JSON::XS::VersionOneAndTwo::to_json'}   = sub { '' };
    *{'JSON::XS::VersionOneAndTwo::from_json'} = sub { {} };
    # MAI presence is the gate _artistImg checks first.
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { return $main::MAI_ON };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs JSON::XS::VersionOneAndTwo)) {
        push @{"${p}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
    @{'JSON::XS::VersionOneAndTwo::EXPORT'} = qw(to_json string);
}

package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $img = \&Plugins::Discography::Browse::_artistImg;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

# ---------------------------------------------------------------------------
# 1. AN ID WINS, and it is what makes a typographic name resolve at all.
# ---------------------------------------------------------------------------
ok(scalar($img->("The La\x{2019}s", 57545) eq 'imageproxy/mai/artist/57545/image.png'),
   'a curly-apostrophe artist with an id is keyed by ID');
ok(scalar($img->('Radiohead', 1234) eq 'imageproxy/mai/artist/1234/image.png'),
   '... and so is a plain name (one rule, no special cases)');
ok(scalar($img->("The La\x{2019}s", 57545) !~ /\x{2019}|%E2%80%99/),
   '... so no typographic punctuation reaches the proxy URL');

# ---------------------------------------------------------------------------
# 2. NO ID -> the NAME route is unchanged. Streaming-only rows, similar
#    artists and MB candidates all still land here.
# ---------------------------------------------------------------------------
ok(scalar($img->('Radiohead') eq 'imageproxy/mai/artist/Radiohead/image.png'),
   'no id: the name route is unchanged');
ok(scalar($img->('Sigur R\x{f3}s') =~ m{^imageproxy/mai/artist/.+/image\.png$}),
   '... and an accented name is still escaped into the URL');
ok(scalar($img->('AC/DC') !~ m{artist/AC/DC/}),
   '... with a slash in the name escaped, not left to split the path');

# ---------------------------------------------------------------------------
# 3. GARBAGE IDS MUST NOT BUILD A URL. Anything non-numeric falls back to the
#    name rather than producing imageproxy/mai/artist//image.png.
# ---------------------------------------------------------------------------
for my $bad ('', 'abc', '12x', undef) {
    my $got = $img->('Radiohead', $bad);
    ok(scalar($got eq 'imageproxy/mai/artist/Radiohead/image.png'),
       'a non-numeric id (' . (defined $bad ? "'$bad'" : 'undef')
       . ') falls back to the name');
}

# ---------------------------------------------------------------------------
# 4. THE MAI GATE still comes first, and an id alone is enough to ask.
# ---------------------------------------------------------------------------
{
    local $main::MAI_ON = 0;
    ok(scalar($img->('Radiohead', 57545) =~ /person\.png$/),
       'MAI disabled -> the person icon, id or not');
}
ok(scalar($img->(undef, 57545) eq 'imageproxy/mai/artist/57545/image.png'),
   'an id with NO name is still enough to build a URL');
ok(scalar($img->(undef, undef) =~ /person\.png$/),
   'neither name nor id -> the person icon');
ok(scalar($img->('') =~ /person\.png$/), 'an empty name -> the person icon');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
