# Local LLM Stack

Self-hosted Ollama + Open WebUI deployed as Apptainer instances. Multi-user
chat with isolated histories, suitable for shared workstations or HPC nodes.

## Requirements

- Apptainer >= 1.1
- ~20 GB disk for images and base models
- NVIDIA GPU + drivers (optional)

## Quick start

If you are running this on your local computer, just setup the environment and start the server:

```bash
# clone repo
git clone https://github.com/UPPMAX/ollama-openwebui.git
cd ollama-openwebui

# start it
./manage.sh init                          # pull container images
./manage.sh start                         # start both services
./manage.sh pull qwen2.5-coder:1.5b-base  # pull a model
```

Open [http://localhost:8080](http://localhost:8080). The first user to register becomes admin.

## HPC/server specific

If you run this on a node at a HPC center, or any other server you have access to, you will likely not be able to connect to the web server since HPC centres and servers usually have firewalls that will block it. Fortunately we can use port forwarding over SSH to be able to reach it anyway. Follow the same steps as above, but also open a SSH connection to your HPC cluster/server and specify that you want to forward port 8080 on your computer to localhost:8080 on the remote computer:

```bash
ssh -A -L 8080:localhost:8080 user@example.com
```

If you are at a HPC center this is likely the login node, and you are not supposed to run demanding stuff there. Then you have to reserve a worker node in you cluster and start the server there. To do the port forwarding to the worker node, you will likely have to use the login node as a *jump host* (`-J`), since worker nodes usually are not directly accessible from outside of the cluster:

```bash
ssh -A -L 8080:localhost:8080 -J user@example.com user@worker001.example.com
```

SSH will then connect first to the jump host (login node) and then connect to the worker node (worker001), and forward port 8080 on your computer to localhost:8080 on the worker node.

That's it, just one additional SSH command and you can host your server anywhere :)


## Layout

```
llm-stack/
├── manage.sh
├── config.sh              # configuration file
├── images/                # .sif container images
├── ollama-data/           # models
├── openwebui-data/        # users, chats (SQLite)
├── .webui_secret_key      # auto-generated
└── .apptainer/            # instance state, logs, OCI cache
```

## Configuration

Copy the template and edit:

```bash
cp config.sh.dist config.sh
$EDITOR config.sh
```

Then `./manage.sh restart` to apply.

`config.sh.dist` is the canonical list of available options. `config.sh` is
gitignored so per-host settings don't end up in version control.

Static paths (data dirs, image locations, instance names) live in `manage.sh`
itself and aren't usually changed.

### CPU cores

If there is no GPU in the node, ollama will run the models on the CPU instead. It will try to use all the cores unless you tell it not to.

`./manage.sh start` picks the core count in this order:

1. Explicit argument: `./manage.sh start 8`
2. Your SLURM booking minus 1 core for the webui: `$SLURM_CPUS_PER_TASK - 1`
3. All cores minus 1 core for the webui: `OLLAMA_FALLBACK_CORES` in the config file

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

To enable users to create API keys, the admin must enable it under Admin Panel -> Settings -> General -> Enable API Keys.

## Code completion (Continue.dev) in VSCode

This example assumes you have the following models pulled, and that the OpenWebUI is reachable on `http://localhost:8080`

```bash
./manage.sh pull qwen2.5-coder:7b qwen2.5-coder:1.5b-base nomic-embed-text
```

Install the Continue.dev plugin for VSCode:

```bash
code --install-extension Continue.continue
```

To enable users to create API keys, the admin must enable it under Admin Panel -> Settings -> General -> Enable API Keys.
Each user generates a personal API key in Open WebUI under
Settings -> Account -> API Keys, then puts it in `~/.continue/config.json`:

```json
{
  "models": [
    {
      "title": "Qwen2.5-Coder 7B",
      "provider": "openai",
      "model": "qwen2.5-coder:7b",
      "apiBase": "http://localhost:8080/api",
      "apiKey": "sk-USER-KEY"
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen2.5-Coder 1.5B",
    "provider": "ollama",
    "model": "qwen2.5-coder:1.5b-base",
    "apiBase": "http://localhost:8080/ollama",
    "apiKey": "sk-USER-KEY"
  },
  "embeddingsProvider": {
    "provider": "ollama",
    "model": "nomic-embed-text",
    "apiBase": "http://localhost:8080/ollama",
    "apiKey": "sk-USER-KEY"
  }
}
```

Routing through Open WebUI rather than directly at Ollama gives per-user
authentication. The Ollama port is bound to `127.0.0.1` by default, so it
isn't reachable from outside the host anyway.

Code completion should work straight away, and press `Ctrl+L` to open a chat window.

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

`manage.sh` auto-detects `$SLURM_CPUS_PER_TASK`. Example batch script (untested, but out-of-scope for now):

```bash
#!/bin/bash

# these options will wary depending on your HPC center
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
