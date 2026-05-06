# Local LLM Stack

Self-hosted Ollama + Open WebUI deployed as Apptainer instances. Multi-user
chat with isolated histories, suitable for shared workstations or HPC nodes.

## Requirements

- Apptainer >= 1.1
- ~20 GB disk for images and base models
- NVIDIA GPU + drivers (optional, for `--nv`)

## Quick start

```bash
./manage.sh init                     # pull container images
./manage.sh start                    # start both services
./manage.sh pull qwen2.5-coder:7b
```

Open <http://localhost:8080>. The first user to register becomes admin.

## Layout

```
llm-stack/
├── manage.sh
├── images/                # .sif container images
├── ollama-data/           # models
├── openwebui-data/        # users, chats (SQLite)
├── .webui_secret_key      # auto-generated
└── .apptainer/            # instance state, logs, OCI cache
```

## Configuration

Edit the variables at the top of `manage.sh` and run `./manage.sh restart`.

| Variable | Purpose | Default |
|---|---|---|
| `OLLAMA_ADDRESS` | Interface Ollama binds to | `127.0.0.1` |
| `OLLAMA_PORT` | Ollama API port | 11434 |
| `OPENWEBUI_PORT` | Web UI port | 8080 |
| `EXTRA_BINDS` | Host paths exposed in containers | `/crex,/proj` |
| `ENABLE_SIGNUP` | Show signup form | `true` |
| `DEFAULT_USER_ROLE` | Role for new signups | `pending` |
| `OLLAMA_NUM_PARALLEL` | Concurrent requests per model | 2 |
| `OLLAMA_FALLBACK_CORES` | Cores when no SLURM/arg given | 15 |

### CPU cores

`./manage.sh start` picks the core count in this order:

1. Explicit argument: `./manage.sh start 8`
2. `$SLURM_CPUS_PER_TASK - 1`
3. `OLLAMA_FALLBACK_CORES`

The chosen count is enforced two ways: `taskset` for kernel affinity, and a
`num_thread` parameter baked into each model via Modelfile so llama.cpp itself
doesn't oversubscribe.

## Commands

```
init [force]      Pull images
start [cores]     Start both services
stop              Stop both services
restart [cores]   Stop + start
status            List running instances
logs <name>       Tail logs (ollama | open-webui)
shell <name>      Shell into an instance

pull <model>...   Pull Ollama models
list              List installed models
rm <model>...     Remove models
ollama <args>     Pass through to ollama
set-threads <n>   Re-apply num_thread to all models
```

## User management

The first signup becomes admin. With `DEFAULT_USER_ROLE=pending`, new accounts
need approval from Admin Panel -> Users.

To stop accepting new signups once your team is onboarded, set
`ENABLE_SIGNUP="false"` and restart. Admins can still create accounts manually.

For OAuth/SSO, see the Open WebUI [docs](https://docs.openwebui.com/features/sso/)
and add the relevant env vars to the Open WebUI exec block in `manage.sh`.

## Code completion (Continue.dev)

Each user generates a personal API key in Open WebUI under
Settings -> Account -> API Keys, then puts it in `~/.continue/config.json`:

```json
{
  "models": [{
    "title": "Qwen2.5-Coder 7B",
    "provider": "openai",
    "model": "qwen2.5-coder:7b",
    "apiBase": "http://your-server:8080/api",
    "apiKey": "sk-USER-KEY"
  }],
  "tabAutocompleteModel": {
    "title": "Qwen2.5-Coder 1.5B",
    "provider": "openai",
    "model": "qwen2.5-coder:1.5b-base",
    "apiBase": "http://your-server:8080/api",
    "apiKey": "sk-USER-KEY"
  }
}
```

Routing through Open WebUI rather than directly at Ollama gives per-user
authentication. The Ollama port is bound to `127.0.0.1` by default, so it
isn't reachable from outside the host anyway.

## Networking

Ollama binds to `OLLAMA_ADDRESS:OLLAMA_PORT`, defaulting to `127.0.0.1:11434`.
Only Open WebUI (running on the same host) can reach it; users connect through
the authenticated web UI on port 8080.

If you want to expose the Ollama API to other hosts (e.g. for a separate
Continue.dev setup that doesn't go through Open WebUI), set
`OLLAMA_ADDRESS=0.0.0.0` and firewall the port appropriately. Note that the
Ollama API has no authentication of its own.

For HTTPS on the web UI, put a reverse proxy (Caddy, nginx) in front of
port 8080.

## SLURM

`manage.sh` auto-detects `$SLURM_CPUS_PER_TASK`. Example batch script:

```bash
#!/bin/bash
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --gres=gpu:1
#SBATCH --time=24:00:00

cd /path/to/llm-stack
./manage.sh start
while ./manage.sh status | grep -q ollama; do sleep 60; done
```

## Troubleshooting

**"could not connect to ollama server"** — `ollama serve` didn't start inside
the instance. Check `./manage.sh logs ollama`; usually a `restart` fixes it.

**Open WebUI: "Required environment variable not found"** — empty
`WEBUI_SECRET_KEY`. Stop, delete `.webui_secret_key`, start again.

**Ollama maxes all cores despite the limit** — `num_thread` Modelfile wasn't
applied. Run `./manage.sh set-threads 15`. This happens to models pulled
outside `manage.sh pull`.

**Models go to `~/.ollama` instead of `./ollama-data`** — Apptainer mounts
your host `$HOME` into the container, which shadows the bind. The fix (in
`start()`) is to pass `OLLAMA_MODELS` and `HOME` as env vars to `ollama serve`.

**`set-threads` says "no Modelfile found"** — bind mounts under `/tmp` are
shadowed by Apptainer's auto-mounted host `/tmp`. Stage the Modelfile inside
the already-bound data dir instead.

## Migrating to Docker Compose

The env vars and data dirs translate directly:

```yaml
services:
  ollama:
    image: ollama/ollama:latest
    volumes:
      - ./ollama-data:/root/.ollama
    environment:
      - OLLAMA_HOST=0.0.0.0:11434   # internal to compose network
    deploy:
      resources:
        reservations:
          devices: [{driver: nvidia, count: all, capabilities: [gpu]}]

  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    ports:
      - "8080:8080"
    volumes:
      - ./openwebui-data:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - WEBUI_AUTH=true
      - DEFAULT_USER_ROLE=pending
    depends_on:
      - ollama
```

Under Docker, Ollama can bind `0.0.0.0` safely because the compose network
isolates it from the host. The `taskset` and `num_thread` workarounds become
unnecessary — cgroup `cpus:` limits make `nproc` report the right count, and
llama.cpp auto-detects correctly.
