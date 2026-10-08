#!/usr/bin/env perl
#
# REGRESSION TEST — a release page lists its OWN versions, all of them (0.56.51).
#
# FIELD, 2026-10-07 (Simon, Stan Getz, "Getz / Gilberto"): the Qobuz versions of
# the 1964 album were "Getz/Gilberto", "Getz/Gilberto #2", "Getz / Gilberto
# '76" and "Getz / Gilberto" (2023), while Qobuz lists the album four times.
# Three causes, all measured on the rig and in Qobuz's own lists:
#
#   1. "#2" and "'76" are their own MusicBrainz albums on the same page, but
#      the edition-suffix rule read "getz gilberto 2" / "getz gilberto 76" as
#      editions of "getz gilberto". FIX: a copy whose title is EXACTLY another
#      group's on this page belongs to that group (matchesFor's pageTitles).
#   2. Qobuz lists three 1964 "Getz/Gilberto" albums (tr097unrzq42a 18 tracks,
#      jzbek1vkmssja 8, np5innplc97oa 10) whose rows read the same, and versions
#      were deduplicated on name|line2, so one survived. FIX: one row per album
#      id (Simon: "under all services we need to expose the versions they have
#      and not throw them away").
#   3. At most 4 copies per service were kept, and a copy past the cap counted
#      as unclaimed. FIX: MAX_PER_SVC 20.
#
# Plus the label that tells the look-alikes apart where a service gives one:
# Qobuz's album `version` ("Expanded Edition", "Remastered") after the title.
#
# The OWNER RULE HAS A TRAP, caught while writing it and pinned in section 3:
# Kraftwerk's album "Radio‐Aktivität" matches its Qobuz copy "Radio-Activity"
# through an alias, and the page also has a SINGLE "Radio-Activity". Handing the
# copy to the single would orphan it (a single never takes an album-sized copy),
# so only an owner that can take the copy counts.
#
# Standalone -- no LMS install needed:  perl tools/t_versions.pl
#
use strict;
use warnings;
use utf8;
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
    *{'Slim::Control::Request::executeRequest'} = sub { bless {}, 'T::Req' };
    for my $p (qw(Slim::Utils::Log Slim::Utils::Prefs)) { push @{"${p}::ISA"}, 'Exporter' }
    @{'Slim::Utils::Log::EXPORT'}   = ('logger');
    @{'Slim::Utils::Prefs::EXPORT'} = ('preferences');
}
package T::Null;  our $AUTOLOAD; sub AUTOLOAD { return } sub DESTROY { }
package T::Prefs; sub get { 1 } sub set { 1 } sub init { 1 } sub setChange { 1 }
package T::Req;   sub getResult { [] }
package main;

binmode STDOUT, ':utf8';
use File::Temp ();
my $tmp = File::Temp->newdir();
mkdir "$tmp/Plugins" or die "mkdir: $!";
symlink "$FindBin::Bin/../Discography", "$tmp/Plugins/Discography" or die "symlink: $!";
unshift @INC, "$tmp";
require Plugins::Discography::Sources;
my $SRC  = 'Plugins::Discography::Sources';
my $norm = $SRC->can('_norm');

my ($pass, $fail) = (0, 0);
sub ok {
    my ($c, $n) = @_;
    die "ok() called without a test name - wrap the condition in scalar()\n" unless defined $n;
    if (scalar $c) { $pass++; print "ok   - $n\n" } else { $fail++; print "FAIL - $n\n" }
}

my @SOURCES = ({ name => 'Local', local => 1 }, { name => 'Qobuz' });

# A Qobuz copy in the shape Plugins::Qobuz::Plugin::_albumItem renders it
# (name "Artist - Title\n(year)", line1 the title, line2 "main artists (year)"),
# decorated as Sources::_decorate does. The 1964 ids are Qobuz's real ones.
sub qcopy {
    my ($id, $title, $year, $size) = @_;
    return { name => "Stan Getz - $title\n($year)", line1 => $title,
             line2 => "Stan Getz, João Gilberto ($year)", type => 'playlist',
             _svc => 'Qobuz', _albumid => $id, _candTitle => $title, _candArtist => 'Stan Getz',
             _year => $year, _size => $size // 'album' };
}
my @POOL = (
    qcopy('tr097unrzq42a', 'Getz/Gilberto',         1964),
    qcopy('0060253775767', 'Getz/Gilberto #2',      1964),
    qcopy('rucw5wphq9i3b', "Getz / Gilberto \x{2018}76", 2016),
    qcopy('hxclg2p52cdab', 'Getz / Gilberto',       2023),
    qcopy('jzbek1vkmssja', 'Getz/Gilberto',         1964),
    qcopy('np5innplc97oa', 'Getz/Gilberto',         1964),
);

# The page's groups, as Browse::_rivalsByTitle keys them (MusicBrainz's titles,
# measured 2026-10-07: b248d212, 1ae98569, 7240b056).
my %PAGE = (
    $norm->('Getz / Gilberto')   => [ { mbid => 'b248d212', type => 'Album', year => 1964 } ],
    $norm->('Getz/Gilberto #2')  => [ { mbid => '1ae98569', type => 'Album', year => 1966 } ],
    $norm->("Getz/Gilberto '76") => [ { mbid => '7240b056', type => 'Album', year => 2016 } ],
);
sub qobuzIds {
    my ($secs) = @_;
    my ($q) = grep { $_->{svc} eq 'Qobuz' } @{ $secs || [] };
    return $q ? [ map { $_->{_albumid} } @{ $q->{items} } ] : [];
}
sub matches {
    my ($title, $rg, %o) = @_;
    return $SRC->matchesFor({ Qobuz => $o{pool} || \@POOL }, 'Stan Getz', $title, $o{local} || [],
        $rg, {}, $o{rivals},
        { sources => \@SOURCES, rgType => $o{type} // 'Album', aliases => $o{aliases},
          ($o{nopage} ? () : (pageTitles => $o{page} || \%PAGE)) });
}

# ================================================================== 1
print "# 1. the field case: Getz / Gilberto lists its own four copies, and only those\n";
{
    my $ids = qobuzIds(matches('Getz / Gilberto', 'b248d212'));
    ok(scalar(!grep { $_ eq '0060253775767' } @$ids), '1: "Getz/Gilberto #2" is NOT listed (its own album on this page)');
    ok(scalar(!grep { $_ eq 'rucw5wphq9i3b' } @$ids), "1: \"Getz / Gilberto \x{2018}76\" is NOT listed (curly quote, its own album)");
    ok(scalar("@$ids" eq 'tr097unrzq42a hxclg2p52cdab jzbek1vkmssja np5innplc97oa'),
       "1: the four real copies, in Qobuz's order: @$ids");

    my $old = qobuzIds(matches('Getz / Gilberto', 'b248d212', nopage => 1));
    ok(scalar(grep { $_ eq '0060253775767' } @$old),
       '1: CONTROL: without the page\'s titles the edition-suffix rule still takes "#2" (so section 1 tests the new rule)');

    my $two = qobuzIds(matches('Getz/Gilberto #2', '1ae98569'));
    ok(scalar("@$two" eq '0060253775767'), "1: the #2 album keeps ITS copy: @$two");
    my $s76 = qobuzIds(matches("Getz/Gilberto '76", '7240b056'));
    ok(scalar("@$s76" eq 'rucw5wphq9i3b'), "1: the '76 album keeps ITS copy: @$s76");
}

# ================================================================== 2
print "# 2. one row per album id: look-alike editions are all kept; the same album once\n";
{
    my $ids = qobuzIds(matches('Getz / Gilberto', 'b248d212'));
    ok(scalar((grep { /^(?:tr097unrzq42a|jzbek1vkmssja|np5innplc97oa)$/ } @$ids) == 3),
       '2: all three 1964 "Getz/Gilberto" (identical name and line2) are listed');
    my @twice = (qcopy('tr097unrzq42a', 'Getz/Gilberto', 1964), qcopy('tr097unrzq42a', 'Getz/Gilberto', 1964));
    my $once = qobuzIds(matches('Getz / Gilberto', 'b248d212', pool => \@twice));
    ok(scalar(@$once == 1), '2: the SAME album id listed twice is one row');
    my @noid = map { my $c = qcopy("x$_", 'Getz/Gilberto', 1964); delete $c->{_albumid}; $c } 1 .. 2;
    my $nid = qobuzIds(matches('Getz / Gilberto', 'b248d212', pool => \@noid));
    ok(scalar(@$nid == 1), '2: a copy with NO album id keeps the old name|line2 key');
    my @local = ({ _svc => 'Local', _albumid => 51512, _candTitle => 'Getz/Gilberto',
                   _candArtist => 'Stan Getz', name => 'Getz/Gilberto', _size => 'album' },
                 { _svc => 'Local', _albumid => 60001, _candTitle => 'Getz/Gilberto',
                   _candArtist => 'Stan Getz', name => 'Getz/Gilberto', _size => 'album' });
    my $secs = matches('Getz / Gilberto', 'b248d212', local => \@local);
    my ($l) = grep { $_->{svc} eq 'Local' } @$secs;
    ok(scalar($l && @{ $l->{items} } == 2), '2: two owned copies of one album are two Local rows');
}

# ================================================================== 3
print "# 3. only an owner that can TAKE the copy counts (Kraftwerk's Radio-Activity)\n";
{
    my %page = (
        $norm->("Radio\x{2010}Aktivit\x{e4}t") => [ { mbid => 'rg-album',  type => 'Album' } ],
        $norm->('Radio-Activity')              => [ { mbid => 'rg-single', type => 'Single' } ],
    );
    my @pool = (
        { %{ qcopy('q-album',  'Radio-Activity', 1975, 'album')  }, _candArtist => 'Kraftwerk', line2 => 'Kraftwerk' },
        { %{ qcopy('q-single', 'Radio-Activity', 1976, 'single') }, _candArtist => 'Kraftwerk', line2 => 'Kraftwerk' },
    );
    my $kw = sub {
        my ($title, $rg, $type, %o) = @_;
        qobuzIds($SRC->matchesFor({ Qobuz => \@pool }, 'Kraftwerk', $title, [], $rg, {}, undef,
            { sources => \@SOURCES, rgType => $type, aliases => $o{aliases},
              ($o{nopage} ? () : (pageTitles => \%page)) }));
    };
    my $album = $kw->("Radio\x{2010}Aktivit\x{e4}t", 'rg-album', 'Album', aliases => ['Radio-Activity']);
    ok(scalar(grep { $_ eq 'q-album' } @$album),
       '3: the album keeps its album-sized copy (the single owns the title but cannot take it)');
    ok(scalar(!grep { $_ eq 'q-single' } @$album),
       '3: ... and gives up the single-sized copy, which the single CAN take');
    my $single = $kw->('Radio-Activity', 'rg-single', 'Single');
    ok(scalar("@$single" eq 'q-single'), "3: the single takes only its own copy: @$single");
    my $old = $kw->("Radio\x{2010}Aktivit\x{e4}t", 'rg-album', 'Album', aliases => ['Radio-Activity'], nopage => 1);
    ok(scalar(@$old == 2), '3: CONTROL: without the page\'s titles the album took both copies');
}

# ================================================================== 4
print "# 4. a group the page cannot show owns nothing (as for the rival rule)\n";
{
    my %page = ($norm->('Getz / Gilberto') => [ { mbid => 'b248d212', type => 'Album' } ]);
    my $ids = qobuzIds(matches('Getz / Gilberto', 'b248d212', page => \%page));
    ok(scalar(grep { $_ eq '0060253775767' } @$ids),
       '4: with "#2" not among the page\'s groups (hidden or bootleg), its copy stays a version, as before');
}

# ================================================================== 5
print "# 5. MAX_PER_SVC: up to 20 copies per service are kept\n";
{
    my $cap = $SRC->can('MAX_PER_SVC')->();
    ok(scalar($cap == 20), "5: the cap is 20 (was 4): $cap");
    my @many = map { qcopy("c$_", "Getz/Gilberto", 1964) } 1 .. 25;
    my $ids = qobuzIds(matches('Getz / Gilberto', 'b248d212', pool => \@many));
    ok(scalar(@$ids == 20), '5: 25 copies -> 20 rows (' . scalar(@$ids) . ')');
    my @six = map { qcopy("s$_", "Getz/Gilberto", 1964) } 1 .. 6;
    ok(scalar(@{ qobuzIds(matches('Getz / Gilberto', 'b248d212', pool => \@six)) } == 6),
       '5: six real copies are six rows (the old cap kept four)');
}

# ================================================================== 6
print "# 6. the service's own edition name goes on the row's title, display only\n";
{
    my $dec = $SRC->can('_decorate');
    my $row = sub { my ($l1) = @_; { name => "Stan Getz - x", line1 => $l1, image => 'https://c/x.jpg' } };
    my %al  = (id => 'tr097unrzq42a', title => 'Getz/Gilberto', tracks_count => 18);

    my $r = $row->('Getz/Gilberto');
    $dec->($r, 'Qobuz', { %al, version => 'Expanded Edition' }, 'Stan Getz');
    ok(scalar($r->{line1} eq 'Getz/Gilberto (Expanded Edition)'), "6: line1 carries the version: $r->{line1}");
    ok(scalar($r->{_candTitle} eq 'Getz/Gilberto'), '6: matching still reads the RAW title');
    ok(scalar($r->{name} eq 'Stan Getz - x'), '6: name (the favourites title, the extras merge key) is untouched');

    $r = $row->('Getz/Gilberto (Hi-Res)');
    $dec->($r, 'Qobuz', { %al, version => 'Remastered' }, 'Stan Getz');
    ok(scalar($r->{line1} eq 'Getz/Gilberto (Remastered) (Hi-Res)'),
       "6: the version goes right after the title, before the plugin's own label: $r->{line1}");

    $r = $row->('Getz/Gilberto (Expanded Edition)');
    $dec->($r, 'Qobuz', { %al, title => 'Getz/Gilberto (Expanded Edition)', version => 'Expanded Edition' }, 'Stan Getz');
    ok(scalar($r->{line1} eq 'Getz/Gilberto (Expanded Edition)'), '6: a title that already says it is not doubled');

    # FIELD, 2026-10-07: Kraftwerk's Qobuz copy read "(2009 Digital Remaster) (2009 Remaster)".
    my %ra = (id => 'ra1', title => 'Radio-Activity (2009 Digital Remaster)', tracks_count => 12);
    $r = $row->('Radio-Activity (2009 Digital Remaster)');
    $dec->($r, 'Qobuz', { %ra, version => '2009 Remaster' }, 'Kraftwerk');
    ok(scalar($r->{line1} eq 'Radio-Activity (2009 Digital Remaster)'),
       "6: every word of the version already in the title, not added: $r->{line1}");
    $r = $row->('Radio-Activity (2009 Digital Remaster)');
    $dec->($r, 'Qobuz', { %ra, version => 'Remaster 2009' }, 'Kraftwerk');
    ok(scalar($r->{line1} eq 'Radio-Activity (2009 Digital Remaster)'), '6: in any order');
    $r = $row->('Radio-Activity (2009 Digital Remaster)');
    $dec->($r, 'Qobuz', { %ra, version => '2020 Remaster' }, 'Kraftwerk');
    ok(scalar($r->{line1} eq 'Radio-Activity (2009 Digital Remaster) (2020 Remaster)'),
       "6: one word missing (2020) still adds it: $r->{line1}");
    $r = $row->('Getz/Gilberto');
    $dec->($r, 'Qobuz', { %al, version => 'Remastered' }, 'Stan Getz');
    ok(scalar($r->{line1} eq 'Getz/Gilberto (Remastered)'), '6: control: a version absent from the title is added');

    $r = $row->('Getz/Gilberto');
    $dec->($r, 'Qobuz', { %al, version => 'expanded edition' }, 'Stan Getz');
    $dec->($r, 'Qobuz', { %al, version => 'Expanded Edition' }, 'Stan Getz');
    ok(scalar($r->{line1} eq 'Getz/Gilberto (expanded edition)'), '6: case-blind, and decorating twice adds it once');

    for my $v (undef, '', '   ', { x => 1 }) {
        $r = $row->('Getz/Gilberto');
        $dec->($r, 'Qobuz', { %al, version => $v }, 'Stan Getz');
        ok(scalar($r->{line1} eq 'Getz/Gilberto'),
           '6: no version (' . (defined $v ? (ref $v ? 'a ref' : "'$v'") : 'undef') . ') leaves the row alone');
    }
    $r = { name => 'Spectrum BY Sonic Boom' };
    $dec->($r, 'Spotify', { id => 's1', title => 'Spectrum', version => 'Deluxe' }, 'Sonic Boom');
    ok(scalar(!defined $r->{line1}), '6: a row with no line1 is left alone');

    $r = $row->('Getz/Gilberto');
    $dec->($r, 'Tidal', { %al, version => '2014 Remaster' }, 'Stan Getz');
    ok(scalar($r->{line1} eq 'Getz/Gilberto (2014 Remaster)'), '6: any service that sends the field gets it');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
