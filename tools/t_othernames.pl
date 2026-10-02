#!/usr/bin/env perl
#
# REGRESSION TEST - the same releases whichever name opened the page (resolver
# plan Part C, item C3; 2026-10-01).
#
# FIELD (measured on the rig, 0.56.16): "Kenshi Yonezu" showed 24 releases, while
# "米津玄師" (MusicBrainz's own name for him, same mbid 09d4a85c, same pool:
# Qobuz 73, TIDAL 43) read "No releases found". Every one of his 39 release
# groups was NO MATCH, because a page tests each streaming copy's credit against
# the name it was opened under, and the services credit "Kenshi Yonezu". The
# render then recorded him as having no releases, hiding his search rows for 7
# days. Genesis Mohanraj / Tommy Genesis (2026-09-30) is the same case.
#
# THE RULE: a copy credited under another of the artist's MusicBrainz names (its
# canonical name or an alias) is judged as that name's own page would judge it,
# title rules and artist check alike; a copy credited under the page's own name
# is judged exactly as before. Drives the REAL matchesFor, _norm and matcher.
#
# Standalone -- no LMS install needed:  perl tools/t_othernames.pl
#
use strict;
use warnings;
use FindBin;

BEGIN {
    for my $m (qw(Slim::Utils::Log Slim::Utils::Prefs Slim::Utils::Cache
                  Slim::Utils::Timers Slim::Networking::SimpleAsyncHTTP
                  Slim::Utils::Strings Slim::Utils::PluginManager
                  Slim::Control::Request Slim::Schema
                  JSON::XS::VersionOneAndTwo Plugins::Discography::Plugin)) {
        (my $p = $m) =~ s{::}{/}g; $INC{"$p.pm"} = 1;
    }
    no strict 'refs';
    *{'Slim::Utils::Log::logger'}          = sub { bless {}, 'T::Null' };
    *{'Slim::Utils::Cache::new'}           = sub { bless {}, 'T::Null' };
    *{'Plugins::Discography::DB::store'} = sub { bless {}, 'T::Null' }; $INC{'Plugins/Discography/DB.pm'} = 1;
    *{'Slim::Utils::Prefs::preferences'}   = sub { bless {}, 'T::Prefs' };
    *{'Plugins::Discography::Plugin::dbg'} = sub { };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs)) { push @{"${p}::ISA"}, 'Exporter' }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}
package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }
package main;

use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $S    = 'Plugins::Discography::Sources';
my $norm = $S->can('_norm');
my $for  = $S->can('_otherNamesFor');

binmode STDOUT, ':encoding(UTF-8)';
my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" } else { $fail++; print "FAIL - $n\n" }
}

my $YONEZU = "\x{7c73}\x{6d25}\x{7384}\x{5e2b}";   # 米津玄師, MusicBrainz's own name
my $SOURCES = [ { name => 'Qobuz' }, { name => 'Local', local => 1 } ];
my $n = 0;
sub copy {
    my ($title, $credit) = @_;
    $n++;
    return { name => "$credit - $title", line2 => $credit, _candTitle => $title,
             _candArtist => $credit, _albumid => "q$n", _svc => 'Qobuz' };
}
# Did the page opened as $page match $copy to the release group titled $rg?
sub hits {
    my ($page, $rg, $copies, %o) = @_;
    my $sec = $S->matchesFor({ Qobuz => $copies }, $page, $rg, $o{local}, undef, undef, undef,
        { sources => $SOURCES, (exists $o{other} ? (otherNames => $o{other}) : ()),
          %{ $o{opt} || {} } });
    my %got;
    for my $s (@$sec) { $got{ $s->{svc} } = [ map { $_->{_candTitle} } @{ $s->{items} } ] }
    return \%got;
}
sub qobuz { my $h = hits(@_); return join('|', @{ $h->{Qobuz} || [] }) }

# ---------------------------------------------------------------------------
# 1. THE FIELD CASE: the page opened under MusicBrainz's own name.
# ---------------------------------------------------------------------------
# MusicBrainz's aliases for 09d4a85c (read 2026-10-01): "Kenshi Yonezu" and the
# Korean search hint "켄시 요네즈" (its third, "米津玄師", is the name itself).
my $KOREAN = "\x{cf04}\x{c2dc} \x{c694}\x{b124}\x{c988}";
my @other = ($norm->('Kenshi Yonezu'), $norm->($KOREAN));
my $stray = copy('STRAY SHEEP', 'Kenshi Yonezu');
ok(scalar(qobuz($YONEZU, 'STRAY SHEEP', [ $stray ]) eq ''),
   "1: control (the bug): opened as \x{7c73}\x{6d25}\x{7384}\x{5e2b} with no other names, the copy is rejected");
ok(scalar(qobuz($YONEZU, 'STRAY SHEEP', [ $stray ], other => \@other) eq 'STRAY SHEEP'),
   '1: with his other MusicBrainz names, a copy credited "Kenshi Yonezu" matches');
ok(scalar(qobuz('Kenshi Yonezu', 'STRAY SHEEP', [ $stray ]) eq 'STRAY SHEEP'),
   '1: the page opened as "Kenshi Yonezu" matches it as before');
ok(scalar(qobuz($YONEZU, 'STRAY SHEEP', [ copy('STRAY SHEEP', 'Someone Else') ], other => \@other) eq ''),
   '1: a copy credited to nobody of his names is still rejected');
ok(scalar(qobuz($YONEZU, 'BOOTLEG', [ $stray ], other => \@other) eq ''),
   '1: ... and a copy of another title is still rejected');

# The index path the list page takes (peekPool's first-token buckets).
ok(scalar(qobuz($YONEZU, 'STRAY SHEEP', [ $stray ], other => \@other,
                opt => { index => { Qobuz => { stray => [ $stray ] } } }) eq 'STRAY SHEEP'),
   '1: the same through the candidate index');

# ---------------------------------------------------------------------------
# 2. JUDGED UNDER THAT NAME'S OWN RULES, not just let through the artist check.
#    Tommy Genesis's self-titled album: on her canonical page the self-titled
#    rule wants the EXACT title (0.11.1), so "Tommy Genesis Live at the Roxy" is
#    not it. Opened as "Genesis Mohanraj" (an alias), the page's own name would
#    read it as the album plus an edition suffix.
# ---------------------------------------------------------------------------
my $tg = [ $norm->('Tommy Genesis') ];
ok(scalar(qobuz('Genesis Mohanraj', 'Tommy Genesis', [ copy('Tommy Genesis', 'Tommy Genesis') ], other => $tg)
          eq 'Tommy Genesis'),
   '2: opened under her alias, her self-titled album matches');
ok(scalar(qobuz('Genesis Mohanraj', 'Tommy Genesis', [ copy('Tommy Genesis Live at the Roxy', 'Tommy Genesis') ],
                other => $tg) eq ''),
   "2: ... and a longer title does not: the canonical page's exact self-titled rule decides");
ok(scalar(qobuz('Tommy Genesis', 'Tommy Genesis', [ copy('Tommy Genesis Live at the Roxy', 'Tommy Genesis') ]) eq ''),
   '2: control: her canonical page rejects it too');

# ---------------------------------------------------------------------------
# 3. A COPY CREDITED UNDER THE PAGE'S OWN NAME IS JUDGED EXACTLY AS BEFORE, never
#    under the other names. The Beatles' self-titled group must not take "The
#    Beatles 1962-1966" (0.11.1); under the alias "Beatles" it would (not
#    self-titled there, so the edition-suffix rule reads it as the album).
# ---------------------------------------------------------------------------
ok(scalar(qobuz('The Beatles', 'The Beatles', [ copy('The Beatles 1962-1966', 'The Beatles') ],
                other => [ $norm->('Beatles') ]) eq ''),
   "3: credited under the page's own name -> never retried under an alias");
ok(scalar(qobuz('The Beatles', 'The Beatles', [ copy('The Beatles', 'The Beatles') ],
                other => [ $norm->('Beatles') ]) eq 'The Beatles'),
   '3: ... and its exact title still matches');
ok(scalar(qobuz('Radiohead', 'OK Computer', [ copy('OK Computer', 'Radiohead') ],
                other => [ $norm->('On A Friday') ]) eq 'OK Computer'),
   '3: an ordinary page with aliases matches as before');

# ---------------------------------------------------------------------------
# 4. THE RELEASE GROUP'S OWN ALIASES AND EDITION TITLES, under the other name too.
# ---------------------------------------------------------------------------
my $kw = [ $norm->('Kraftwerk') ];
my $kpage = "\x{30af}\x{30e9}\x{30d5}\x{30c8}\x{30ef}\x{30fc}\x{30af}";   # a page opened under a katakana alias
ok(scalar(qobuz($kpage, 'Computerwelt', [ copy('Computer World', 'Kraftwerk') ], other => $kw,
                opt => { aliases => [ 'Computer World' ] }) eq 'Computer World'),
   "4: the group's alias title, credited under another of the artist's names");
ok(scalar(qobuz($kpage, 'Tour de France Soundtracks', [ copy('Tour de France', 'Kraftwerk') ], other => $kw,
                opt => { editions => [ [ $norm->('Tour de France'), 'Tour de France', 0 ] ] }) eq 'Tour de France'),
   "4: an edition title, likewise");

# ---------------------------------------------------------------------------
# 5. LIBRARY COPIES are unchanged: the library join already proves the artist
#    (0.24.0), so they are judged under the page's own name, as before.
# ---------------------------------------------------------------------------
{
    my $loc = { name => 'STRAY SHEEP', _candTitle => 'STRAY SHEEP', _candArtist => 'Kenshi Yonezu',
                _albumid => 'L1', local => 1 };
    my $h = hits($YONEZU, 'STRAY SHEEP', [], local => [ $loc ], other => \@other);
    ok(scalar(@{ $h->{Local} || [] } == 1), '5: an owned copy matches, as it did without the other names');
    $h = hits($YONEZU, 'STRAY SHEEP', [], local => [ $loc ]);
    ok(scalar(@{ $h->{Local} || [] } == 1), '5: ... control: and without them');
}

# ---------------------------------------------------------------------------
# 6. _otherNamesFor, directly.
# ---------------------------------------------------------------------------
my $mine = $norm->($YONEZU);
ok(scalar(@{ $for->($mine, [], 'Kenshi Yonezu') } == 0), '6: no other names -> none');
ok(scalar(@{ $for->($mine, \@other, '') } == 0), '6: an empty credit -> none');
ok(scalar(@{ $for->($norm->('Kenshi Yonezu'), \@other, 'Kenshi Yonezu') } == 0),
   "6: the page's own name matches the credit -> none (judged as before)");
ok(scalar("@{ $for->($mine, \@other, 'Kenshi Yonezu') }" eq $norm->('Kenshi Yonezu')),
   '6: the other name the credit matches');
ok(scalar("@{ $for->($mine, [ $norm->('Kenshi Yonezu'), $norm->($KOREAN), $norm->('Yonezu Kenshi') ],
                       'Kenshi Yonezu') }" eq $norm->('Kenshi Yonezu') . ' ' . $norm->('Yonezu Kenshi')),
   '6: every other name the credit matches, in order (the artist test ignores word order)');
{
    my %memo;
    $for->($mine, \@other, 'Kenshi Yonezu', \%memo);
    ok(scalar(@{ $for->($mine, [ $norm->('Nobody') ], 'Kenshi Yonezu', \%memo) } == 1),
       "6: the memo answers a credit it has seen (one answer per credit for a page's names)");
    $for->($mine, \@other, 'Someone Else', \%memo);
    ok(scalar(exists $memo{'Someone Else'} && !@{ $memo{'Someone Else'} }),
       '6: ... a credit matching none is remembered too (keyed as the service gives it)');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
