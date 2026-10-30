#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || $1 == --help ]]; then echo "Usage: $0 user@host"; exit 0; fi
[[ "$1" != -* ]] || exit 1
ssh "$1" 'bash -se' <<'REMOTE'
pidfile="$HOME/.unfaasener.pids"
[[ -f "$pidfile" ]] || { echo 'No saved agent processes.'; exit 0; }
while read -r pid born; do
    if [[ -r /proc/$pid/stat && $(awk '{print $22}' "/proc/$pid/stat") == "$born" ]]; then
        kill "$pid" 2>/dev/null || true
    fi
done < "$pidfile"
rm -f "$pidfile" "$HOME/unfaasener/scheduler/juliaStdin" "$HOME/unfaasener/scheduler/juliaStdout"
echo 'Stop signals sent to the saved agents.'
REMOTE
