#!/bin/bash
# Manage Ollama + Open WebUI as Apptainer instances
set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================
STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${STACK_DIR}/config.sh"
CONFIG_DIST="${STACK_DIR}/config.sh.dist"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "!! No config.sh found." >&2
    if [[ -f "$CONFIG_DIST" ]]; then
        echo "   Copy the template and edit it:" >&2
        echo "   cp ${CONFIG_DIST##*/} ${CONFIG_FILE##*/}" >&2
    fi
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Derived / fixed paths (not user-tunable)
export APPTAINER_CONFIGDIR="${STACK_DIR}/.apptainer"

IMAGE_DIR="${STACK_DIR}/images"
OLLAMA_SIF="${IMAGE_DIR}/ollama.sif"
OPENWEBUI_SIF="${IMAGE_DIR}/open-webui.sif"

OLLAMA_DATA="${STACK_DIR}/ollama-data"
OPENWEBUI_DATA="${STACK_DIR}/openwebui-data"
OLLAMA_CONTAINER_DATA="/opt/ollama"

OLLAMA_INSTANCE="ollama"
OPENWEBUI_INSTANCE="open-webui"

WEBUI_SECRET_KEY_FILE="${STACK_DIR}/.webui_secret_key"

LOG_DIR="${APPTAINER_CONFIGDIR}/instances/logs/$(hostname)/${USER}"

# Sanity check required vars
: "${OLLAMA_ADDRESS:?missing in config.sh}"
: "${OLLAMA_PORT:?missing in config.sh}"
: "${OPENWEBUI_PORT:?missing in config.sh}"
: "${OLLAMA_FALLBACK_CORES:?missing in config.sh}"

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
    apptainer instance start \
        --nv \
        --bind "${OLLAMA_DATA}:${OLLAMA_CONTAINER_DATA}" \
        --bind "${EXTRA_BINDS}" \
        --env "OLLAMA_HOST=${OLLAMA_ADDRESS}:${OLLAMA_PORT}" \
        --env "OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}" \
        --env "OMP_NUM_THREADS=${cores}" \
        --env "GOMAXPROCS=${cores}" \
        "$OLLAMA_SIF" "$OLLAMA_INSTANCE"

    echo ">> Launching ollama serve inside instance..."
    nohup taskset -c "0-$((cores - 1))" \
        apptainer exec \
            --env "OLLAMA_HOST=${OLLAMA_ADDRESS}:${OLLAMA_PORT}" \
            --env "OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}" \
            --env "OMP_NUM_THREADS=${cores}" \
            --env "GOMAXPROCS=${cores}" \
            --env "OLLAMA_MODELS=${OLLAMA_CONTAINER_DATA}/models" \
            --env "HOME=${OLLAMA_CONTAINER_DATA}" \
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

    echo ">> Waiting for Ollama API..."
    for i in {1..30}; do
        curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" >/dev/null && break
        sleep 1
    done
    
    echo ">> Applying num_thread=${cores} to all installed models..."
    set_threads "$cores"

    echo
    apptainer instance list
    echo
    echo ">> Open WebUI:  http://${OPENWEBUI_URL}:${OPENWEBUI_PORT}"
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

ollama_cmd() {
    if ! apptainer instance list | grep -q "^${OLLAMA_INSTANCE}\b"; then
        echo "!! Ollama instance not running -- start it first." >&2
        exit 1
    fi
    apptainer exec "instance://${OLLAMA_INSTANCE}" ollama "$@"
}

pull_model() {
    [[ $# -eq 0 ]] && { echo "Usage: $0 pull <model>..."; exit 1; }
    for model in "$@"; do
        echo ">> Pulling $model"
        ollama_cmd pull "$model"
    done
    local cores
    cores=$(determine_cores "")
    echo ">> Re-applying num_thread=${cores}..."
    set_threads "$cores"
}

list_models() { ollama_cmd list; }

rm_model() {
    [[ $# -eq 0 ]] && { echo "Usage: $0 rm <model> [<model>...]"; exit 1; }
    for model in "$@"; do
        echo ">> Removing $model"
        ollama_cmd rm "$model"
    done
}

set_threads() {
    local threads="${1:-}"
    [[ -z "$threads" ]] && { echo "Usage: $0 set-threads <n>"; exit 1; }

    if ! apptainer instance list | grep -q "^${OLLAMA_INSTANCE}\b"; then
        echo "!! Ollama instance not running." >&2
        exit 1
    fi

    local models
    models=$(ollama_cmd list 2>/dev/null | awk 'NR>1 && $1!="" {print $1}')
    [[ -z "$models" ]] && { echo "   (no models installed)"; return 0; }

    # Stage Modelfile inside the bound data dir (visible in container)
    local stage_host="${OLLAMA_DATA}/.modelfiles"
    local stage_cont="${OLLAMA_CONTAINER_DATA}/.modelfiles"
    mkdir -p "$stage_host"

    for model in $models; do
        echo ">> Setting num_thread=$threads on $model"
        cat > "${stage_host}/Modelfile" <<EOF
FROM ${model}
PARAMETER num_thread ${threads}
EOF
        apptainer exec \
            "instance://${OLLAMA_INSTANCE}" \
            ollama create "${model}" -f "${stage_cont}/Modelfile" >/dev/null \
            || echo "   !! failed on $model (skipping)"
    done

    rm -rf "$stage_host"
}

# ============================================================
# DISPATCH
# ============================================================
case "${1:-}" in
    init)
        if [[ "${2:-}" == "force" ]]; then init_force; else init; fi ;;
    start)        shift; start "${1:-}" ;;
    stop)         stop ;;
    restart)      shift; stop; sleep 2; start "${1:-}" ;;
    status)       status ;;
    logs)         shift; logs "${1:-}" ;;
    shell)        shift; shell_into "${1:-}" ;;
    pull)         shift; pull_model "$@" ;;
    list|models)  list_models ;;
    rm)           shift; rm_model "$@" ;;
    ollama)       shift; ollama_cmd "$@" ;;   # passthrough for any other ollama subcommand
    set-threads)  shift; set_threads "${1:-}" ;;
    *)
        cat <<EOF
Usage: $0 <command> [args]

Commands:
  init [force]     Pull images into ./images/ (force re-pulls)
  start [cores]    Start both instances (optional core count override)
  stop             Stop both instances
  restart [cores]  Stop + start
  status           List running instances
  pull <model>...  Pull one or more models into Ollama
  list             List installed models
  rm <model>...    Remove models
  ollama <args>    Run any ollama subcommand inside the instance
  set-threads <n>  Set num_thread on every installed model
  logs <name>      Tail logs of an instance (ollama | open-webui)
  shell <name>     Open a shell inside a running instance
EOF
        exit 1
        ;;
esac
