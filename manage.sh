#!/bin/bash
# Manage Ollama + Open WebUI as Apptainer instances
set -euo pipefail

# ============================================================
# CONFIGURATION  -- edit here
# ============================================================
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep all Apptainer state (incl. instance logs) inside the stack dir
export APPTAINER_CONFIGDIR="${STACK_DIR}/.apptainer"

# Images
IMAGE_DIR="${STACK_DIR}/images"
OLLAMA_SIF="${IMAGE_DIR}/ollama.sif"
OPENWEBUI_SIF="${IMAGE_DIR}/open-webui.sif"

# Source URIs (used by `init`)
OLLAMA_URI="docker://ollama/ollama:latest"
OPENWEBUI_URI="docker://ghcr.io/open-webui/open-webui:main"

# Persistent data dirs
OLLAMA_DATA="${STACK_DIR}/ollama-data"
OPENWEBUI_DATA="${STACK_DIR}/openwebui-data"

# Instance names
OLLAMA_INSTANCE="ollama"
OPENWEBUI_INSTANCE="open-webui"

# Ports
OLLAMA_PORT=11434
OLLAMA_ADDRESS=127.0.0.1
OPENWEBUI_PORT=8080

# Extra host paths to expose inside the containers
EXTRA_BINDS="/crex,/proj"

# Open WebUI auth
WEBUI_AUTH="true"
ENABLE_SIGNUP="true"
DEFAULT_USER_ROLE="pending"
WEBUI_SECRET_KEY_FILE="${STACK_DIR}/.webui_secret_key"

# Ollama tuning
OLLAMA_NUM_PARALLEL=2
OLLAMA_FALLBACK_CORES=15

# ============================================================
# Helpers
# ============================================================
determine_cores() {
    local explicit="${1:-}"
    if [[ -n "$explicit" ]]; then
        echo "$explicit"
    elif [[ -n "${SLURM_CPUS_PER_TASK:-}" ]]; then
        echo $(( SLURM_CPUS_PER_TASK - 1 ))
    else
        echo "$OLLAMA_FALLBACK_CORES"
    fi
}

logs_dir_for() {
    # Apptainer's per-instance log path
    echo "${APPTAINER_CONFIGDIR}/instances/logs/$(hostname)/${USER}/${1}"
}

# ============================================================
# COMMANDS
# ============================================================
init() {
    mkdir -p "$IMAGE_DIR" "$OLLAMA_DATA" "$OPENWEBUI_DATA" "$APPTAINER_CONFIGDIR"

    if [[ -f "$OLLAMA_SIF" ]]; then
        echo ">> $OLLAMA_SIF already exists, skipping (use 'init force' to re-pull)"
    else
        echo ">> Pulling Ollama image..."
        apptainer pull "$OLLAMA_SIF" "$OLLAMA_URI"
    fi

    if [[ -f "$OPENWEBUI_SIF" ]]; then
        echo ">> $OPENWEBUI_SIF already exists, skipping (use 'init force' to re-pull)"
    else
        echo ">> Pulling Open WebUI image..."
        apptainer pull "$OPENWEBUI_SIF" "$OPENWEBUI_URI"
    fi

    echo ">> Init done."
}

init_force() {
    rm -f "$OLLAMA_SIF" "$OPENWEBUI_SIF"
    init
}

ensure_secret_key() {
    if [[ ! -s "$WEBUI_SECRET_KEY_FILE" ]]; then
        echo ">> Generating WEBUI_SECRET_KEY at $WEBUI_SECRET_KEY_FILE"
        head -c 32 /dev/urandom | base64 > "$WEBUI_SECRET_KEY_FILE"
        chmod 600 "$WEBUI_SECRET_KEY_FILE"
    fi
}

LOG_DIR="${APPTAINER_CONFIGDIR}/instances/logs/$(hostname)/${USER}"

start() {
    if [[ ! -f "$OLLAMA_SIF" || ! -f "$OPENWEBUI_SIF" ]]; then
        echo "!! Images missing -- run '$0 init' first." >&2
        exit 1
    fi

    local cores
    cores=$(determine_cores "${1:-}")
    echo ">> Ollama will use $cores CPU cores"

    mkdir -p "$OLLAMA_DATA" "$OPENWEBUI_DATA" "$LOG_DIR"

    echo ">> Starting Ollama instance ($OLLAMA_INSTANCE)..."
    taskset -c "0-$((cores - 1))" \
    apptainer instance start \
        --nv \
        --bind "${OLLAMA_DATA}:/root/.ollama" \
        --bind "${EXTRA_BINDS}" \
        --env "OLLAMA_HOST=${OLLAMA_ADDRESS}:${OLLAMA_PORT}" \
        --env "OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}" \
        --env "OMP_NUM_THREADS=${cores}" \
        --env "GOMAXPROCS=${cores}" \
        "$OLLAMA_SIF" "$OLLAMA_INSTANCE"

    echo ">> Launching ollama serve inside instance..."
    nohup apptainer exec \
        --env "OLLAMA_HOST=${OLLAMA_ADDRESS}:${OLLAMA_PORT}" \
        --env "OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}" \
        --env "OMP_NUM_THREADS=${cores}" \
        --env "GOMAXPROCS=${cores}" \
        "instance://${OLLAMA_INSTANCE}" \
        ollama serve \
        >> "${LOG_DIR}/${OLLAMA_INSTANCE}.out" \
        2>> "${LOG_DIR}/${OLLAMA_INSTANCE}.err" &

    ensure_secret_key
    WEBUI_SECRET_KEY="$(cat "$WEBUI_SECRET_KEY_FILE")"

    echo ">> Starting Open WebUI instance ($OPENWEBUI_INSTANCE)..."
    apptainer instance start \
        --bind "${OPENWEBUI_DATA}:/app/backend/data" \
        --bind "${EXTRA_BINDS}" \
        --env "OLLAMA_BASE_URL=http://${OLLAMA_ADDRESS}:${OLLAMA_PORT}" \
        --env "WEBUI_AUTH=${WEBUI_AUTH}" \
        --env "ENABLE_SIGNUP=${ENABLE_SIGNUP}" \
        --env "DEFAULT_USER_ROLE=${DEFAULT_USER_ROLE}" \
        --env "WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}" \
        --env "PORT=${OPENWEBUI_PORT}" \
        "$OPENWEBUI_SIF" "$OPENWEBUI_INSTANCE"

    echo ">> Launching open-webui inside instance..."
    nohup apptainer exec \
        --env "OLLAMA_BASE_URL=http://${OLLAMA_ADDRESS}:${OLLAMA_PORT}" \
        --env "WEBUI_AUTH=${WEBUI_AUTH}" \
        --env "ENABLE_SIGNUP=${ENABLE_SIGNUP}" \
        --env "DEFAULT_USER_ROLE=${DEFAULT_USER_ROLE}" \
        --env "WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}" \
        --env "PORT=${OPENWEBUI_PORT}" \
        "instance://${OPENWEBUI_INSTANCE}" \
        bash /app/backend/start.sh \
        >> "${LOG_DIR}/${OPENWEBUI_INSTANCE}.out" \
        2>> "${LOG_DIR}/${OPENWEBUI_INSTANCE}.err" &

    sleep 2
    echo
    apptainer instance list
    echo
    echo ">> Open WebUI:  http://$(hostname):${OPENWEBUI_PORT}"
    echo ">> Ollama API:  http://${OLLAMA_ADDRESS}:${OLLAMA_PORT}"
    echo ">> Logs:        ${LOG_DIR}/<instance>.{out,err}"
}

stop() {
    apptainer instance stop "$OPENWEBUI_INSTANCE" 2>/dev/null || true
    apptainer instance stop "$OLLAMA_INSTANCE"    2>/dev/null || true
    echo ">> Stopped."
}

status() { apptainer instance list; }

logs_dir_for() {
    echo "${APPTAINER_CONFIGDIR}/instances/logs/$(hostname)/${USER}"
}

logs() {
    local name="${1:-}"
    [[ -z "$name" ]] && { echo "Usage: $0 logs <instance>"; exit 1; }
    local logdir
    logdir=$(logs_dir_for)
    local files=( "${logdir}/${name}.out" "${logdir}/${name}.err" )
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || { echo "Missing: $f"; exit 1; }
    done
    tail -F "${files[@]}"
}

shell_into() {
    local name="${1:-$OLLAMA_INSTANCE}"
    apptainer shell "instance://${name}"
}

# ============================================================
# DISPATCH
# ============================================================
case "${1:-}" in
    init)
        if [[ "${2:-}" == "force" ]]; then init_force; else init; fi ;;
    start)   shift; start "${1:-}" ;;
    stop)    stop ;;
    restart) shift; stop; sleep 2; start "${1:-}" ;;
    status)  status ;;
    logs)    shift; logs "${1:-}" ;;
    shell)   shift; shell_into "${1:-}" ;;
    *)
        cat <<EOF
Usage: $0 <command> [args]

Commands:
  init [force]     Pull images into ./images/ (force re-pulls)
  start [cores]    Start both instances (optional core count override)
  stop             Stop both instances
  restart [cores]  Stop + start
  status           List running instances
  logs <name>      Tail logs of an instance (ollama | open-webui)
  shell <name>     Open a shell inside a running instance
EOF
        exit 1
        ;;
esac
