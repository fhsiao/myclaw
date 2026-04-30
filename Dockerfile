# =============================================================================
# OpenClaw Hardened Dockerfile
# Target: RTX A5000 Laptop host running llama-server on :8888
# Version: 2026.4.25 (latest stable, not the beta)
# Base:    node:22-bookworm-slim (same base as official ghcr.io image)
#          Pinned by digest to prevent mutable-tag supply chain attacks.
#          Re-pin with: docker pull node:22-bookworm-slim && docker inspect
# =============================================================================

# Pin to exact digest — tags are mutable, digests are not.
# To refresh: docker pull node:22-bookworm-slim --quiet && \
#   docker inspect node:22-bookworm-slim | grep '"Id"'
FROM node:22-bookworm-slim@sha256:6d735b4d33660225271fda0a412802746658c3a1b975507b2803ed299609760a

# ── Build arguments ──────────────────────────────────────────────────────────
# Explicit version pin. Change this to update OpenClaw.
# 2026.4.25 is the latest STABLE (not beta) as of 2026-04-29.
ARG OPENCLAW_VERSION=2026.4.25

# ── Labels ───────────────────────────────────────────────────────────────────
LABEL maintainer="fbuh"
LABEL openclaw.version="${OPENCLAW_VERSION}"
LABEL security.hardened="true"

# ── System dependencies ──────────────────────────────────────────────────────
# Install only strictly required packages. No curl, no wget, no ssh clients,
# no compilers — nothing that helps an agent break out or exfiltrate data.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      dumb-init \
      git \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# ── Non-root user ────────────────────────────────────────────────────────────
# Official image already ships a 'node' user (UID 1000 / GID 1000).
# We create a dedicated openclaw group for clarity and future ACL control.
RUN groupadd -r -g 1001 openclaw \
 && usermod -aG openclaw node

# ── Directory layout ─────────────────────────────────────────────────────────
# /app           → OpenClaw installation (read-only at runtime via --read-only)
# /data/config   → openclaw.json, .env  (mounted from host at runtime)
# /data/workspace→ agent working directory (mounted from host at runtime)
# /data/memory   → persistent agent memory  (mounted from host at runtime)
# /tmp/openclaw  → ephemeral scratch (tmpfs at runtime)
RUN mkdir -p /app /data/config /data/workspace /data/memory \
 && chown -R node:openclaw /app /data \
 && chmod 750 /data/config /data/workspace /data/memory

WORKDIR /app

# ── Install OpenClaw (pinned version, no auto-update) ────────────────────────
# Install as root (required — npm global writes to /usr/local/lib/node_modules).
# We drop to non-root user AFTER install for all runtime operations.
RUN npm install --global \
      openclaw@${OPENCLAW_VERSION} \
 && npm cache clean --force

# Verify the binary is reachable before dropping privileges
RUN openclaw --version

# Drop to non-root for all subsequent RUN, CMD, ENTRYPOINT
USER node

# ── Baked-in OpenClaw config ─────────────────────────────────────────────────
# This config is baked into the image so the agent starts deterministically
# without requiring interactive onboarding.
# IMPORTANT: No secrets here — API keys come from environment variables
# injected at runtime via docker-compose.yml.
#
# The config is written to /data/config/openclaw.json.
# At runtime, OPENCLAW_CONFIG_DIR=/data/config is set so OpenClaw finds it.
#
# gpt-oss-20b tuning rationale:
#   temperature=0.0   → fully deterministic token selection (greedy decoding)
#   top_p=0.95        → nucleus sampling off when temp=0, kept as safety floor
#   max_tokens=4096   → enough for tool calls + reasoning; gpt-oss CoT is verbose
#   contextWindow=32768 → matches llama-server --ctx-size 32768
#   timeout=120000    → 2 min; MoE with 3.6B active is fast but tool loops are long

RUN cat > /data/config/openclaw.json << 'EOF'
{
  "models": {
    "providers": {
      "llamaserver": {
        "api": "openai-completions",
        "baseUrl": "http://LLAMA_HOST:8888/v1",
        "apiKey": "no-key-required",
        "timeout": 120000,
        "models": [
          {
            "id": "gpt-oss-20b",
            "name": "GPT-OSS 20B (local llama-server)",
            "contextWindow": 32768,
            "maxOutput": 4096
          }
        ]
      }
    }
  },

  "agents": {
    "defaults": {
      "model": {
        "primary": "llamaserver/gpt-oss-20b"
      },
      "params": {
        "temperature": 0.0,
        "top_p": 0.95,
        "presence_penalty": 0.0,
        "frequency_penalty": 0.0,
        "max_tokens": 4096
      },
      "sandbox": {
        "enabled": false
      }
    }
  },

  "gateway": {
    "host": "0.0.0.0",
    "port": 18789,
    "bind": "loopback",
    "max_connections": 5,
    "log_level": "warn",
    "pid_file": "/tmp/openclaw/gateway.pid",
    "auto_update": false,
    "telemetry": false
  },

  "hands": {
    "shell": {
      "enabled": true,
      "timeout": 30000,
      "blocked_commands": [
        "curl", "wget", "nc", "netcat", "ncat", "socat",
        "ssh", "scp", "sftp", "rsync",
        "python3 -c", "python -c",
        "bash -i", "sh -i",
        "chmod 777", "chmod +s",
        "sudo", "su",
        "dd", "mkfs", "fdisk",
        "iptables", "nft",
        "docker", "podman", "kubectl"
      ]
    },
    "browser": {
      "enabled": false
    },
    "filesystem": {
      "writable_paths": [
        "/data/workspace",
        "/tmp/openclaw"
      ],
      "blocked_paths": [
        "/data/config",
        "/data/memory",
        "/app",
        "/etc",
        "/proc",
        "/sys",
        "/dev",
        "/run"
      ]
    }
  },

  "memory": {
    "enabled": true,
    "path": "/data/memory",
    "max_context_tokens": 2000,
    "auto_save": true
  },

  "heartbeat": {
    "enabled": false
  },

  "skills": {
    "allow_install": false
  },

  "env": {}
}
EOF

# ── Entrypoint ────────────────────────────────────────────────────────────────
# dumb-init: proper PID 1, forwards signals correctly, reaps zombies.
# This matters for an agent that spawns subprocesses.
ENTRYPOINT ["/usr/bin/dumb-init", "--"]

# Default command: start the gateway.
# OPENCLAW_CONFIG_DIR and OPENCLAW_WORKSPACE_DIR are set in docker-compose.yml.
CMD ["openclaw", "gateway", "start", "--no-open"]

# ── Runtime metadata ──────────────────────────────────────────────────────────
EXPOSE 18789
VOLUME ["/data/config", "/data/workspace", "/data/memory"]
