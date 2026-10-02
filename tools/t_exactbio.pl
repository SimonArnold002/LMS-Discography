#!/usr/bin/env perl
#
# REGRESSION TEST: the biography of an act that shares its name (0.56.22).
#
# Simon, 2026-10-02, on Muzz the NYC trio (893e0bd0): "it didnt find a bio for
# Muzz I am sure there is one". The page holds the name route back for an act
# that is not the best-known one of its name (MUZZ the producer tops "Muzz"),
# so it showed none. Browse::_fetchExactBio takes the one step of MAI's route
# that is exact: the community API asked with the act's mbid, accepted only when
# its reply names that mbid and a Wikidata page, then MAI's own Wikipedia reader.
# Kept under the mbid, never the name.
#
# The community API's reply is the one MEASURED 2026-10-02 for 893e0bd0 (and,
# for the wrong-act case, the one it gave for an mbid it did not know: MUZZ the
# producer, 6cfdec30). The Wikipedia extract is captured:
# tools/fixtures/wp_extract_64177014_muzz_band.json (pageid 64177014). MAI's
# reader is stood in for with its own shape (Wikipedia.pm getPage, read
# 2026-10-02): content = stylesheet link + extract + "(Source: Wikipedia)".
#
# Standalone, no LMS install needed:  perl tools/t_exactbio.pl
#
use strict;
use warnings;
use FindBin;
use JSON::PP ();

our (%CACHE, $MAI_ON, @IDCALLS, @PAGECALLS, $IDREPLY, $PAGEREPLY, $LANG, $IDDIES, $IDTWICE);

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::PluginManager Slim::Utils::Timers Slim::Utils::Strings
                  Slim::Control::Request Slim::Schema Slim::Web::HTTP
                  Slim::Networking::SimpleAsyncHTTP Slim::Utils::Misc
                  Plugins::Discography::Plugin Plugins::Discography::API
                  Plugins::Discography::Sources)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}        = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Prefs::preferences'} = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}         = sub { bless {}, 'T::Cache' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Cache' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Strings::cstring'}   = sub { $_[1] };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    *{'Plugins::Discography::Sources::_norm'} = sub {
        my $s = lc($_[-1] // ''); $s =~ s/[^a-z0-9]+/ /g; $s =~ s/^ +| +$//g; $s };
    # API.pm's own spelling (pinned against the real module in t_libmbid.pl).
    *{'Plugins::Discography::API::_bioMbidKey'} = sub { 'dsc:biomb:1:' . lc($_[0] // '') };
    *{'Slim::Utils::PluginManager::isEnabled'} = sub { $main::MAI_ON };

    # MAI, in the shapes its own source has (API.pm getArtistBioId, Wikipedia.pm
    # getPage, Common.pm validateLanguage).
    *{'Plugins::MusicArtistInfo::API::getArtistBioId'} = sub {
        my ($class, $cb, $args) = @_;
        push @main::IDCALLS, { %$args };
        die "MAI exploded\n" if $main::IDDIES;
        $cb->($main::IDREPLY);
        $cb->($main::IDREPLY) if $main::IDTWICE;
    };
    *{'Plugins::MusicArtistInfo::Wikipedia::getPage'} = sub {
        my ($class, $client, $cb, $args) = @_;
        push @main::PAGECALLS, { %$args };
        $cb->($main::PAGEREPLY);
    };
    *{'Plugins::MusicArtistInfo::Common::validateLanguage'} = sub { $_[1] || $main::LANG };

    for my $e (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Strings)) {
        push @{"${e}::ISA"}, 'Exporter';
    }
    @{'Slim::Utils::Log::EXPORT'}     = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'}   = ('preferences');
    @{'Slim::Utils::Strings::EXPORT'} = ('cstring');
}

package T::Null; our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY {}
package T::Cache;
sub get    { my $e = $main::CACHE{ $_[1] }; return $e ? $e->[0] : undef }
sub set    { $main::CACHE{ $_[1] } = [ $_[2], $_[3] ]; return 1 }
sub remove { delete $main::CACHE{ $_[1] }; return 1 }

package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Browse;
my $B = 'Plugins::Discography::Browse';

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n"
        unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" }
    else           { $fail++; print "FAIL - $n\n" }
}

my $MUZZ     = '893e0bd0-a55a-4f4a-a6ee-f26f3bbe1a13';   # Muzz, NYC indie rock trio
my $PRODUCER = '6cfdec30-4730-4513-bfb4-5db3ff566900';   # MUZZ, the producer
my $KEY      = "dsc:biomb:1:$MUZZ";
my $FOUND    = $B->BIO_FOUND_TTL;
my $EMPTY    = $B->BIO_EMPTY_TTL;

# The community API's replies, as measured 2026-10-02.
my $REPLY_MUZZ = { name => 'Muzz', mbid => $MUZZ,
    wikidata => { pageid => 64177014, title => 'Muzz (band)', lang => 'en' },
    url => 'https://en.wikipedia.org/wiki/Muzz%20(band)' };
my $REPLY_PRODUCER = { name => 'MUZZ', mbid => $PRODUCER,
    wikidata => { pageid => 55759087, title => 'Muzz (musician)', lang => 'en' } };

# MAI's reader, as it builds its answer from the captured extract.
my $extract = do {
    open my $fh, '<:raw', "$FindBin::Bin/fixtures/wp_extract_64177014_muzz_band.json" or die "fixture: $!";
    local $/; JSON::PP::decode_json(scalar <$fh>)->{query}{pages}[0]{extract};
};
my $PAGE_OK = { content => '<link rel="stylesheet" type="text/css" href="/plugins/MusicArtistInfo/html/mai.css" />'
                         . $extract . '<div>(Source: Wikipedia)</div>' };
my $PAGE_NF = { error => 'PLUGIN_MUSICARTISTINFO_NOT_FOUND' };

sub fresh {
    %CACHE = (); @IDCALLS = (); @PAGECALLS = ();
    $MAI_ON = 1; $LANG = 'en'; $IDDIES = 0; $IDTWICE = 0;
    $IDREPLY = $REPLY_MUZZ; $PAGEREPLY = $PAGE_OK;
}
sub fetch {
    my ($artist, $mbid) = @_;
    my @got;
    $B->can('_fetchExactBio')->(undef, $artist, $mbid, sub { push @got, [ @_ ] });
    return @got;
}

# 1. The field case: the band's own Wikipedia page, by its mbid.
fresh();
my @got = fetch('Muzz', $MUZZ);
my $text = $got[0][0] // '';
ok(scalar(@got == 1), '1: answered once');
ok(scalar($text =~ /Muzz is an American band based in New York City/), "1: Muzz gets the band's biography");
ok(scalar($text =~ /Paul Banks/ && $text !~ /<p|<link/), '1: ... cleaned to prose (no markup)');
ok(scalar(@IDCALLS == 1 && ($IDCALLS[0]{mbid} // '') eq $MUZZ && ($IDCALLS[0]{artist} // '') eq 'Muzz'),
   '1: the community API is asked with the name AND the mbid');
ok(scalar(($IDCALLS[0]{lang} // '') eq 'en'), "1: ... in MAI's content language");
ok(scalar(@PAGECALLS == 1 && ($PAGECALLS[0]{id} // 0) == 64177014 && ($PAGECALLS[0]{title} // '') eq 'Muzz (band)'
          && ($PAGECALLS[0]{lang} // '') eq 'en'), '1: the page read is the one MusicBrainz links (64177014, Muzz (band))');
ok(scalar(($CACHE{$KEY}[1] // 0) == $FOUND && ($CACHE{$KEY}[0] // '') =~ /American band/),
   '1: kept under the mbid for the found lifetime');
ok(scalar(!grep { /muzz/ && !/\Q$MUZZ\E/ } keys %CACHE), '1: nothing kept under the name');

# 2. Kept: the next open asks nothing.
@IDCALLS = (); @PAGECALLS = ();
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1 && ($got[0][0] // '') =~ /American band/ && !@IDCALLS && !@PAGECALLS),
   '2: a kept biography is served with no request');

# 3. The reply names ANOTHER act (the community API's fallback to the name).
fresh(); $IDREPLY = $REPLY_PRODUCER;
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1 && !defined $got[0][0]), "3: a reply for another act gives no biography");
ok(scalar(!@PAGECALLS), "3: ... and the other act's page is never read");
ok(scalar(defined $CACHE{$KEY} && $CACHE{$KEY}[0] eq '' && $CACHE{$KEY}[1] == $EMPTY),
   '3: ... kept as none for the empty lifetime');
@IDCALLS = ();
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1 && !defined $got[0][0] && !@IDCALLS), '3: a kept none is served with no request');

# 4. The mbid compare ignores case.
fresh(); $IDREPLY = { %$REPLY_MUZZ, mbid => uc $MUZZ };
@got = fetch('Muzz', $MUZZ);
ok(scalar(($got[0][0] // '') =~ /American band/), '4: the reply mbid is compared without case');

# 5. This act, but no Wikidata page.
fresh(); $IDREPLY = { name => 'Muzz', mbid => $MUZZ, bandcamp => 'https://muzztheband.bandcamp.com/' };
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1 && !defined $got[0][0] && !@PAGECALLS), '5: no Wikidata page, no biography, nothing read');
ok(scalar(($CACHE{$KEY}[1] // 0) == $EMPTY), '5: ... kept as none');
fresh(); $IDREPLY = { name => 'Muzz', mbid => $MUZZ, wikidata => { title => 'Muzz (band)', lang => 'en' } };
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1 && !defined $got[0][0] && !@PAGECALLS), '5: a Wikidata entry with no page id: nothing read');

# 6. A failed call: MAI hands back the hash with its error removed.
fresh(); $IDREPLY = {};
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1 && !defined $got[0][0]), '6: a failed call gives no biography');
ok(scalar(!exists $CACHE{$KEY}), '6: ... and keeps nothing');
$IDREPLY = $REPLY_MUZZ; @IDCALLS = ();
@got = fetch('Muzz', $MUZZ);
ok(scalar(@IDCALLS == 1 && ($got[0][0] // '') =~ /American band/), '6: the next open asks again and gets it');
fresh(); $IDREPLY = undef;
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1 && !defined $got[0][0] && !exists $CACHE{$KEY}), '6: an undefined reply the same');

# 7. The page reader finds nothing.
fresh(); $PAGEREPLY = $PAGE_NF;
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1 && !defined $got[0][0]), '7: a page MAI cannot read gives no biography');
ok(scalar(($CACHE{$KEY}[0] // 'x') eq '' && $CACHE{$KEY}[1] == $EMPTY), '7: ... kept as none');

# 8. Language: the reply's own page language, else MAI's.
fresh(); $LANG = 'de'; $IDREPLY = { %$REPLY_MUZZ, wikidata => { pageid => 64177014, title => 'Muzz (band)' } };
fetch('Muzz', $MUZZ);
ok(scalar(($IDCALLS[0]{lang} // '') eq 'de' && ($PAGECALLS[0]{lang} // '') eq 'de'),
   "8: with no page language in the reply, MAI's language is used for both");
fresh(); $LANG = 'de';
fetch('Muzz', $MUZZ);
ok(scalar(($IDCALLS[0]{lang} // '') eq 'de' && ($PAGECALLS[0]{lang} // '') eq 'en'),
   "8: the page is read in the reply's language (a page id belongs to one Wikipedia)");

# 9. MAI off: nothing asked.
fresh(); $MAI_ON = 0;
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1 && !defined $got[0][0] && !@IDCALLS), '9: MAI disabled: no biography, nothing asked');

# 10. Answered exactly once, whatever MAI does.
fresh(); $IDDIES = 1;
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1 && !defined $got[0][0]), '10: MAI dying: answered once, no biography');
fresh(); $IDTWICE = 1;
@got = fetch('Muzz', $MUZZ);
ok(scalar(@got == 1), '10: MAI calling back twice: answered once');

# 11. Nothing to ask with.
fresh();
ok(scalar((fetch('Muzz', undef))[0] && !@IDCALLS), '11: no mbid: answered, nothing asked');
ok(scalar((fetch('', $MUZZ))[0] && !@IDCALLS), '11: no name: answered, nothing asked');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
