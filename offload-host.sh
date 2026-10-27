#!/usr/bin/env bash
set -euo pipefail

usage="Usage: $0 user@host [--host-key FILE] [--monitor-key FILE] [--scheduler-key FILE] [--project ID]"
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

while [[ $# -gt 0 ]]; do
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
if [[ ! -d venv ]]; then python3 -m venv venv; fi
source venv/bin/activate
bash -e setup.sh
bash -e build.sh
sudo systemctl enable --now docker
REMOTE

printf 'Host prepared. Open a new SSH session for Docker group access:\n  ssh %s\n  cd ~/unfaasener && source venv/bin/activate\n' "$target"
