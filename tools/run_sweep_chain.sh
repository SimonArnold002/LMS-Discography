#!/bin/zsh
# Wait for the browse pass to finish, then run the remaining phases in order.
# Phases are serialised deliberately: they all hit the same server and the same
# streaming services, and running them together would both skew the timings and
# double the API load.
cd "$(dirname "$0")/.." || exit 1

while pgrep -f "library_sweep.py browse" > /dev/null; do sleep 20; done
echo "=== browse finished at $(date) ==="

python3 -u tools/library_sweep.py search   || echo "search phase exited $?"
echo "=== search finished at $(date) ==="

python3 -u tools/library_sweep.py variants || echo "variants phase exited $?"
echo "=== variants finished at $(date) ==="

python3 -u tools/library_sweep.py report
echo "=== report written at $(date) ==="
