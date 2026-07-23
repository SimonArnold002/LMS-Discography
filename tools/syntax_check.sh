#!/bin/zsh
# Syntax-check every plugin module WITHOUT an LMS install.
#
# WHY: `perl -c` on these files fails on the Mac because Slim::* isn't there,
# so checks were being skipped and replaced by eyeballing brace counts. That is
# not a check — a crude brace counter reported Sources.pm as +3 unbalanced when
# it was in fact syntactically perfect (2026-07-19).
#
# This generates throwaway stubs for the Slim modules (and the LMS-only
# `main::WEBUI` constant) into a temp dir, then compiles each module against
# them. It proves SYNTAX and load-time structure only — it does not run
# anything, and it cannot catch a logic error. Run it before every build;
# run tools/acceptance.py against the server after installing.
#
# Usage: tools/syntax_check.sh        (from the repo root)

set -e
ROOT="${0:A:h:h}"
S="$(mktemp -d)"
trap 'rm -rf "$S"' EXIT

mkdir -p "$S"/Slim/{Control,Networking,Plugin,Utils,Web} "$S"/JSON/XS "$S"/Plugins

cat > "$S/Slim/Utils/Log.pm" <<'EOF'
package Slim::Utils::Log;
use strict; use warnings;
require Exporter; our @ISA=('Exporter'); our @EXPORT=('logger');
sub logger { return bless {}, 'Slim::Utils::Log::Stub' }
our $AUTOLOAD; sub AUTOLOAD {} sub DESTROY {}
package Slim::Utils::Log::Stub;
our $AUTOLOAD; sub AUTOLOAD {} sub DESTROY {}
1;
EOF

cat > "$S/Slim/Utils/Prefs.pm" <<'EOF'
package Slim::Utils::Prefs;
use strict; use warnings;
require Exporter; our @ISA=('Exporter'); our @EXPORT=('preferences');
sub preferences { return bless {}, 'Slim::Utils::Prefs::Stub' }
our $AUTOLOAD; sub AUTOLOAD {} sub DESTROY {}
package Slim::Utils::Prefs::Stub;
our $AUTOLOAD; sub AUTOLOAD {} sub DESTROY {}
1;
EOF

cat > "$S/Slim/Utils/Strings.pm" <<'EOF'
package Slim::Utils::Strings;
use strict; use warnings;
require Exporter; our @ISA=('Exporter'); our @EXPORT_OK=('cstring','string');
sub cstring {''} sub string {''}
1;
EOF

cat > "$S/JSON/XS/VersionOneAndTwo.pm" <<'EOF'
package JSON::XS::VersionOneAndTwo;
use strict; use warnings;
require Exporter; our @ISA=('Exporter');
our @EXPORT=qw(to_json from_json objToJson jsonToObj);
sub to_json {''} sub from_json {{}} sub objToJson {''} sub jsonToObj {{}}
1;
EOF

for m in Slim/Utils/Cache Slim/Utils/PluginManager Slim/Utils/Timers \
         Slim/Control/Request Slim/Networking/SimpleAsyncHTTP \
         Slim/Plugin/OPMLBased Slim/Schema Slim/Web/Settings; do
  pkg="${m//\//::}"
  printf 'package %s;\nuse strict; use warnings;\nour $AUTOLOAD;\nsub AUTOLOAD {}\nsub DESTROY {}\nsub new { bless {}, shift }\n1;\n' "$pkg" > "$S/$m.pm"
done

ln -sfn "$ROOT/Discography" "$S/Plugins/Discography"

fail=0
for f in Sources API Browse Settings; do
  printf '%-10s ' "$f"
  if perl -I"$S" -I"$ROOT" -c "$S/Plugins/Discography/$f.pm" 2>&1 | grep -q 'syntax OK'; then
    echo OK
  else
    echo FAIL; perl -I"$S" -I"$ROOT" -c "$S/Plugins/Discography/$f.pm" 2>&1 | head -3; fail=1
  fi
done

# Plugin.pm references main::WEBUI, which only LMS defines.
printf '%-10s ' Plugin
if perl -I"$S" -I"$ROOT" -e "use constant WEBUI=>1; require '$S/Plugins/Discography/Plugin.pm';" 2>/dev/null; then
  echo OK
else
  echo FAIL; perl -I"$S" -I"$ROOT" -e "use constant WEBUI=>1; require '$S/Plugins/Discography/Plugin.pm';" 2>&1 | head -3; fail=1
fi


# ---------------------------------------------------------------------------
# CACHE_VERSION must be identical in all three modules AND match install.xml.
# Slim::Utils::Cache->new returns the EXISTING instance for a namespace and
# ignores later args, so whichever module loads first decides the version --
# a mismatch would silently leave stale caches behind, which is the exact
# failure this mechanism exists to prevent.
plugin_ver=$(sed -n 's|.*<version>\(.*\)</version>.*|\1|p' Discography/install.xml | head -1)
cv=$(grep -h "use constant CACHE_VERSION" Discography/API.pm Discography/Sources.pm Discography/Browse.pm \
     | sed "s/.*=> *'\([^']*\)'.*/\1/" | sort -u)
n=$(printf '%s\n' "$cv" | grep -c .)
if [ "$n" != "1" ]; then
    echo "CACHE_VERSION  FAIL - modules disagree: $(printf '%s ' $cv)"; exit 1
elif [ "$cv" != "$plugin_ver" ]; then
    echo "CACHE_VERSION  FAIL - '$cv' != install.xml '$plugin_ver' (bump it, or caches will not clear)"; exit 1
else
    echo "CACHE_VERSION  OK ($cv, matches install.xml)"
fi

# ---------------------------------------------------------------------------
# THE MIRROR AUTO-DETECT PROBE MBID MUST BE A REAL ARTIST.
#
# 0.30.0 shipped `a74b1b7f-06a0-4672-a641-eb3353aa608d`, which 404s everywhere:
# a mangled Radiohead id sharing only the first block. autodetectMirror
# validates by fetching that artist and comparing its name, so a wrong id makes
# the probe fail on EVERY candidate -- and the failure is indistinguishable
# from "no mirror running here". It therefore cannot be caught at runtime, by a
# stubbed unit test, or by reading the code: only by asking MusicBrainz.
#
# SKIPPED when offline, so this gate stays usable on a plane.
probe_mbid=$(sed -n "s/.*MB_PROBE_MBID *=> *'\([^']*\)'.*/\1/p" Discography/API.pm | head -1)
probe_name=$(sed -n "s/.*MB_PROBE_NAME *=> *'\([^']*\)'.*/\1/p" Discography/API.pm | head -1)
printf '%-14s ' 'PROBE_MBID'
probe_json=$(curl -s --max-time 8 -A "LMS-Discography-syntax-check/1.0 ( simon )" \
             "https://musicbrainz.org/ws/2/artist/$probe_mbid?fmt=json" 2>/dev/null)
if [ -z "$probe_json" ]; then
    echo "SKIP (no network)"
elif printf '%s' "$probe_json" | grep -q "\"name\":\"$probe_name\""; then
    echo "OK ($probe_mbid is $probe_name)"
else
    echo "FAIL - $probe_mbid is NOT $probe_name on MusicBrainz; mirror auto-detect can never succeed"
    printf '%s\n' "$probe_json" | head -c 200; echo
    fail=1
fi

exit $fail
