#!/usr/bin/env bash
set -euo pipefail

usage="Usage: $0 user@host [--host-key FILE] [--monitor-key FILE] [--scheduler-key FILE] [--project ID] [--logs-only]"
if [[ $# -eq 0 || $1 == --help ]]; then
    echo "$usage"
    exit 0
fi
target=$1
shift
host_key=
monitor_key=
scheduler_key=
project=serverless-research-espol
logs_only=false

while [[ $# -gt 0 ]]; do
    if [[ $1 == --logs-only ]]; then
        logs_only=true
        shift
        continue
    fi
    if [[ $# -lt 2 ]]; then echo "$usage"; exit 1; fi
    case "$1" in
        --host-key) host_key=$2 ;;
        --monitor-key) monitor_key=$2 ;;
        --scheduler-key) scheduler_key=$2 ;;
        --project) project=$2 ;;
        *) echo "$usage"; exit 1 ;;
    esac
    shift 2
done

follow_logs() {
    echo 'Following UnFaaSener logs. Ctrl+C stops viewing; the agents keep running.'
    ssh -t "$target" 'exec tail -n 30 -F "$HOME/unfaasener/scheduler/logs/initialDeploy.log" "$HOME/unfaasener/scheduler/logs/scheduler.log"'
}

if [[ "$logs_only" == true ]]; then
    follow_logs
    exit 0
fi

ssh "$target" 'bash -se' <<'REMOTE'
set -o pipefail
export PATH="$HOME/.juliaup/bin:$HOME/google-cloud-sdk/bin:$PATH"
sudo apt-get update
sudo apt-get install -y git curl ca-certificates gnupg python3-pip python3-venv build-essential

if ! command -v gcloud >/dev/null; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg |
        sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/cloud.google.gpg
    echo 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' |
        sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y google-cloud-cli
fi

if ! command -v julia >/dev/null; then
    curl -fsSL https://install.julialang.org | sh -s -- --yes
fi

if [[ ! -d "$HOME/unfaasener" ]]; then
    git clone https://github.com/brauliorivas/unfaasener.git "$HOME/unfaasener"
fi
mkdir -p "$HOME/unfaasener/scheduler/key" "$HOME/unfaasener/host-agents/execution-agent"
REMOTE

copy_key() {
    if ssh "$target" "test -f unfaasener/$2"; then return; fi
    if [[ -z "$1" || ! -f "$1" ]]; then
        echo "Missing $2: supply its key argument."
        exit 1
    fi
    scp -- "$1" "$target:unfaasener/$2"
    ssh "$target" "chmod 600 unfaasener/$2"
}
copy_key "$host_key" host-agents/execution-agent/vmExeModule.json
copy_key "$monitor_key" scheduler/key/monitoringKey.json
copy_key "$scheduler_key" scheduler/key/schedulerKey.json

printf -v project_arg '%q' "$project"
ssh "$target" "bash -se -- $project_arg" <<'REMOTE'
export PATH="$HOME/.juliaup/bin:$HOME/google-cloud-sdk/bin:$PATH"
cd "$HOME/unfaasener"
gcloud auth activate-service-account --key-file=host-agents/execution-agent/vmExeModule.json --project="$1"
sed -i "s/^projectid *=.*/projectid = $1/" project-config.ini
if [[ ! -x venv/bin/pip ]]; then python3 -m venv venv; fi
source venv/bin/activate
bash -e setup.sh
bash -e build.sh
sudo systemctl enable --now docker
REMOTE

ssh "$target" 'bash -se' <<'REMOTE'
export PATH="$HOME/.juliaup/bin:$HOME/google-cloud-sdk/bin:$PATH"
export TZ=UTC PYTHONUNBUFFERED=1
cd "$HOME/unfaasener"
source venv/bin/activate
if pgrep -u "$USER" -f '^bash initialDeploy.sh ' >/dev/null; then
    echo 'UnFaaSener is already running.'
    exit 0
fi
rm -f scheduler/juliaStdin scheduler/juliaStdout
python3 scheduler/resetRoutingDecisions.py ImageProcessingWorkflow 1
warmup_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for request in 1 2 3; do
    gcloud functions call ImageProcessing_GetInput --region=northamerica-northeast1 \
        --data='{"message":"test.png"}' --format='value(result)'
done
for attempt in {1..12}; do
    finished=$(gcloud functions logs read ImageProcessing_Resize --region=northamerica-northeast1 \
        --start-time="$warmup_start" --limit=100 --format='value(log)' |
        grep -c "finished with status: 'ok'" || true)
    if [[ "$finished" -ge 3 ]]; then break; fi
    sleep 5
done
if [[ "$finished" -lt 3 ]]; then
    echo 'Warm-up did not complete; check the function logs.'
    exit 1
fi
nohup bash initialDeploy.sh ImageProcessingWorkflow 1 latency \
    > scheduler/logs/initialDeploy.log 2>&1 < /dev/null &
printf 'UnFaaSener started (PID %s). Log: ~/unfaasener/scheduler/logs/initialDeploy.log\n' "$!"
REMOTE

follow_logs
