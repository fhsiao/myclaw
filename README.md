# OpenClaw Hardened Docker Setup
## For RTX A5000 Laptop + llama-server (gpt-oss-20b) on Ubuntu 24.04

---

## File layout

```
openclaw-docker/
├── Dockerfile                  ← hardened image, OpenClaw 2026.4.25 pinned
├── docker-compose.yml          ← hardened compose with resource limits
├── seccomp-openclaw.json       ← custom seccomp profile (blocks ~60 dangerous syscalls)
├── setup-network.sh            ← iptables isolation (run once as root)
├── teardown-network.sh         ← removes iptables rules when done
├── config/                     ← auto-created; openclaw.json lands here
├── workspace/                  ← ONLY folder the agent can read/write
└── memory/                     ← agent memory persistence
```

---

## Step-by-step setup

### 1. Prepare host directories

```bash
mkdir -p ~/openclaw-docker/{config,workspace,memory}
cd ~/openclaw-docker
chmod 700 config memory     # only you can read config/memory
chmod 755 workspace         # openclaw writes here
```

### 2. Make scripts executable

```bash
chmod +x setup-network.sh teardown-network.sh
```

### 3. Start llama-server on the host (if not already running)

```bash
llama-server \
  -hf ggml-org/gpt-oss-20b-GGUF \
  --host 0.0.0.0 \
  --port 8888 \
  --ctx-size 32768 \
  --jinja \
  -b 4096 \
  -ub 2048 \
  -ngl 99 \
  --flash-attn on \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --n-cpu-moe 4 \
  --temp 0.0 \
  --top-p 0.95 \
  --top-k 0 \
  --min-p 0.0
```

**Important:** `--host 0.0.0.0` is required so the Docker bridge (172.31.200.1)
can reach it. `127.0.0.1` would NOT be reachable from inside the container.

### 4. Build the image

```bash
docker compose build
```

This bakes openclaw.json into the image. No interactive onboarding needed.

### 5. Bring up the container (creates the bridge network)

```bash
docker compose up -d
```

### 6. Apply iptables network isolation (run as root)

```bash
sudo ./setup-network.sh
```

This MUST be run after `docker compose up` so the bridge interface exists.

### 7. Verify isolation works

```bash
# This should FAIL (no internet from container):
docker compose exec openclaw-gateway \
  node -e "require('https').get('https://example.com', r => console.log('LEAK:', r.statusCode)).on('error', e => console.log('BLOCKED OK:', e.code))"

# This should SUCCEED (llama-server reachable):
docker compose exec openclaw-gateway \
  node -e "require('http').get('http://llama-host:8888/v1/models', r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>console.log('OK:', d.slice(0,80))) })"
```

### 8. Open Control UI

Browse to: http://127.0.0.1:18789

---

## Daily workflow

```bash
# Before a session: git checkpoint your workspace
git -C ~/openclaw-docker/workspace add -A && \
  git -C ~/openclaw-docker/workspace commit -m "pre-openclaw $(date -Iseconds)"

# Start
docker compose up -d

# Watch logs
docker compose logs -f openclaw-gateway

# Run a CLI command (e.g. check status)
docker compose run --rm --profile cli openclaw-cli status --all

# Stop
docker compose down

# After a session: review what changed
git -C ~/openclaw-docker/workspace diff HEAD~1
```

---

## Updating OpenClaw

1. Edit `Dockerfile`: change `OPENCLAW_VERSION=2026.4.25` to new version
2. Edit `docker-compose.yml`: change `image: openclaw-hardened:2026.4.25` to match
3. Rebuild: `docker compose build --no-cache`
4. Restart: `docker compose up -d`

**Why not `latest`?** Tags are mutable. Pinning to an exact version means you
know exactly what code is running and can audit the changelog before updating.

---

## Security controls summary

| Control | What it does |
|---|---|
| Pinned base image digest | Prevents silent base image swaps |
| Pinned OpenClaw version | No surprise auto-updates |
| `--read-only` filesystem | Container root FS is immutable |
| `--cap-drop=ALL` | No Linux capabilities (no raw sockets, no mounts, etc.) |
| `no-new-privileges` | Can't escalate via setuid binaries |
| Custom seccomp profile | Blocks ~60 dangerous syscalls incl. ptrace, mount, kexec |
| Isolated bridge network | Custom subnet, not default Docker bridge |
| iptables rules | Container can ONLY reach llama-server on :8888 |
| Port binding `127.0.0.1:` | Control UI not exposed to LAN |
| Non-root user (node:1000) | Agent runs as UID 1000, not root |
| `tmpfs` for /tmp | Scratch space never touches disk |
| Resource limits | 2 CPU, 2GB RAM — prevents runaway loops |
| `blocked_commands` in config | Agent can't run curl, wget, ssh, sudo, docker, etc. |
| `allow_install: false` | No skill/plugin installation from inside agent |
| `auto_update: false` | No background self-update |
| `telemetry: false` | No data sent to OpenClaw servers |
| Workspace-only writes | Agent filesystem access limited to ./workspace and /tmp |
| `dumb-init` as PID 1 | Proper signal handling, zombie process reaping |

---

## gpt-oss-20b tuning notes

`temperature: 0.0` — greedy decoding. For agentic tool loops you want the
model to make the same decision given the same context, not explore randomly.
The gpt-oss-20b reasoning chain already provides stochasticity through its
internal CoT — the final token selection should be deterministic.

`max_tokens: 4096` — gpt-oss uses extended chain-of-thought before tool calls.
4096 gives enough room for both CoT and the actual tool call JSON without
truncating mid-reasoning.

`contextWindow: 32768` — matches `--ctx-size 32768` in llama-server. If you
push this larger than what llama-server has allocated, you'll get truncation
errors at the llama-server level.
