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

if [[ "$target" == -* ]]; then echo 'Expected an SSH host.' >&2; exit 1; fi
if [[ ! "$project" =~ ^[a-z][a-z0-9-]{4,61}[a-z0-9]$ ]]; then
    echo 'Invalid project ID.' >&2
    exit 1
fi

ssh "$target" 'bash -se' <<'REMOTE'
set -o pipefail
export PATH="$HOME/.juliaup/bin:$HOME/google-cloud-sdk/bin:$PATH"
sudo apt-get update
sudo apt-get install -y git curl ca-certificates gnupg build-essential

. /etc/os-release

sudo apt-get install -y software-properties-common

case "$VERSION_ID" in
    22.04)
        sudo add-apt-repository -y ppa:deadsnakes/ppa
        ;;
    24.04)
        sudo add-apt-repository -y universe
        ;;
    *)
        echo "Unsupported Ubuntu version: $VERSION_ID" >&2
        exit 1
        ;;
esac

sudo apt-get update
sudo apt-get install -y python3.12 python3.12-venv

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

# The CLI uses your user login; the Python agents use their separate JSON keys.
ssh -t "$target" 'export PATH="$HOME/google-cloud-sdk/bin:$PATH"; gcloud auth login --no-launch-browser'

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
gcloud config set project "$1"
sed -i "s/^projectid *=.*/projectid = $1/" project-config.ini
if [[ ! -x venv/bin/pip ]]; then
    python3.12 -m venv venv
fi
source venv/bin/activate
bash -e setup.sh
bash -e build.sh
sudo systemctl enable --now docker
REMOTE

echo "Setup complete. Start with: ./start.sh $target --initialize"
