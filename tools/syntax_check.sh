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

exit $fail
