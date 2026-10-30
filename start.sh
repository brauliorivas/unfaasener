#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 0 || $1 == --help ]]; then
    echo "Usage: $0 user@host [--mode latency|cost] [--initialize]"; exit 0
fi
host=$1; shift
mode=; initialize=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --initialize) initialize=true; shift ;;
        --mode) mode=${2:?Missing mode}; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[[ "$host" != -* ]] || exit 1
case "$mode" in ''|latency|cost) ;; *) echo 'Invalid mode.' >&2; exit 1 ;; esac

ssh "$host" "bash -se -- '$mode' '$initialize'" <<'REMOTE'
set -o pipefail
export PATH="$HOME/.juliaup/bin:$HOME/google-cloud-sdk/bin:$PATH"
export TZ=UTC PYTHONUNBUFFERED=1
cd "$HOME/unfaasener"
source venv/bin/activate
workflow=ImageProcessingWorkflow
mode=${1:-$(sed -n 's/^mode[[:space:]]*=[[:space:]]*//p' scheduler/rankerConfig.ini)}
case "$mode" in latency|cost) ;; *) echo 'Invalid configured mode.' >&2; exit 1 ;; esac
pidfile="$HOME/.unfaasener.pids"
[[ ! -f "$pidfile" ]] || { echo 'Run stop.sh before starting again.' >&2; exit 1; }
log="$PWD/scheduler/logs/initialDeploy.log"

if [[ "$2" == true ]]; then
    docker ps --format '{{.ID}} {{.Image}}' |
        awk '$2 ~ /^name:ImageProcessing_/ {print $1}' | xargs -r docker stop
    python3 scheduler/resetLastDecisions.py "$workflow" 1 "$mode"
    python3 host-agents/execution-agent/cleanup-queue.py vmSubscriber1 vm0
else
    sed -i "s/^mode[[:space:]]*=.*/mode = $mode/" scheduler/rankerConfig.ini
fi

# Save the PID and start time so stop.sh can recognize these processes.
: > "$pidfile"
save_pid() { printf '%s %s\n' "$!" "$(awk '{print $22}' "/proc/$!/stat")" >> "$pidfile"; }
rm -f scheduler/juliaStdin scheduler/juliaStdout
mkfifo scheduler/juliaStdin scheduler/juliaStdout
nohup julia scheduler/rpsMultiHostSolver.jl >> "$log" 2>&1 < /dev/null &
save_pid
python3 log-parser/get-workflow-logs/getWorkflowLogs.py "$workflow" 1 >> "$log" 2>&1
cd host-agents/monitoring-agent
nohup ./monitoringAgent >> "$log" 2>&1 < /dev/null &
save_pid
sleep 10
cd ../execution-agent
nohup python3 vmModule.py vmSubscriber1 vm0 >> "$log" 2>&1 < /dev/null &
save_pid
cd ../..
nohup python3 log-parser/get-workflow-logs/getWorkflowLogs.py "$workflow" 0 >> "$log" 2>&1 < /dev/null &
save_pid
nohup python3 scheduler/garbageCollector.py >> "$log" 2>&1 < /dev/null &
save_pid
echo "Agents launched. Log: $log"
REMOTE
