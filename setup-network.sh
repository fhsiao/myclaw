#!/usr/bin/env bash
# =============================================================================
# setup-network.sh
# Run ONCE as root before "docker compose up".
# Creates iptables rules that:
#   - Allow openclaw container → host llama-server on port 8888 ONLY
#   - Block ALL other outbound traffic from the openclaw bridge
#   - Allow container → DNS (needed for Node.js internals)
#   - Allow established/related return traffic back in
#
# These rules survive docker compose restarts but NOT a host reboot.
# For persistence across reboots: install iptables-persistent and run
#   netfilter-persistent save   after running this script.
# =============================================================================
set -euo pipefail

BRIDGE="br-openclaw"
SUBNET="172.31.200.0/24"
CONTAINER_IP="172.31.200.10"
HOST_BRIDGE_IP="172.31.200.1"    # docker bridge gateway = your machine
LLAMA_PORT="8888"
OPENCLAW_PORT="18789"

echo "[+] Setting up OpenClaw network isolation..."

# ── 0. Wait for the bridge to exist (created by docker compose up) ─────────
# If running before compose up, the bridge may not exist yet.
# In that case, create it manually so iptables rules can reference it.
if ! ip link show "$BRIDGE" &>/dev/null; then
  echo "[!] Bridge $BRIDGE not found. Create it with: docker compose up -d"
  echo "    Then re-run this script, or run setup AFTER compose up."
  echo "    Continuing anyway — rules will apply once bridge appears."
fi

# ── 1. FORWARD chain: block all forwarding out of the openclaw bridge ───────
# Insert at top so these rules take precedence over Docker's ACCEPT rules.

# Allow ESTABLISHED/RELATED (return traffic for allowed outbound)
iptables -I FORWARD 1 \
  -i "$BRIDGE" \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT \
  -m comment --comment "openclaw: allow established return traffic"

# Allow openclaw → host llama-server port 8888 only
iptables -I FORWARD 2 \
  -i "$BRIDGE" \
  -s "$CONTAINER_IP" \
  -d "$HOST_BRIDGE_IP" \
  -p tcp --dport "$LLAMA_PORT" \
  -j ACCEPT \
  -m comment --comment "openclaw: allow llama-server on :8888"

# Block ALL other outbound from the openclaw bridge (catch-all DROP)
iptables -I FORWARD 3 \
  -i "$BRIDGE" \
  -j DROP \
  -m comment --comment "openclaw: block all other outbound"

# ── 2. INPUT chain: allow host to receive llama-server traffic from container
iptables -I INPUT 1 \
  -i "$BRIDGE" \
  -s "$CONTAINER_IP" \
  -d "$HOST_BRIDGE_IP" \
  -p tcp --dport "$LLAMA_PORT" \
  -j ACCEPT \
  -m comment --comment "openclaw: allow container to reach llama-server"

# ── 3. OUTPUT chain: allow established responses back to container ──────────
iptables -I OUTPUT 1 \
  -o "$BRIDGE" \
  -m conntrack --ctstate ESTABLISHED,RELATED \
  -j ACCEPT \
  -m comment --comment "openclaw: allow established back to container"

# ── 4. Prevent container from reaching host on any OTHER port ──────────────
# Docker normally allows container → host unrestricted via the bridge.
# This blocks everything except llama-server.
iptables -I INPUT 2 \
  -i "$BRIDGE" \
  -s "$CONTAINER_IP" \
  -d "$HOST_BRIDGE_IP" \
  -j DROP \
  -m comment --comment "openclaw: block container→host except llama-server"

# ── 5. Make llama-server listen on bridge IP (reminder, not automated) ──────
echo ""
echo "[!] REMINDER: Ensure llama-server is listening on the bridge IP."
echo "    Your llama-server command should include:"
echo "      --host 0.0.0.0   (or --host $HOST_BRIDGE_IP)"
echo "    It is currently configured for --host 0.0.0.0 port 8888."
echo ""

# ── 6. Show result ──────────────────────────────────────────────────────────
echo "[+] iptables rules applied:"
echo ""
echo "--- FORWARD ---"
iptables -L FORWARD -v -n --line-numbers | grep -E "openclaw|$BRIDGE" || true
echo ""
echo "--- INPUT ---"
iptables -L INPUT -v -n --line-numbers | grep -E "openclaw|$BRIDGE" || true
echo ""
echo "[+] Done. To persist across reboots:"
echo "    sudo apt-get install -y iptables-persistent"
echo "    sudo netfilter-persistent save"
echo ""
echo "[+] To verify isolation (should FAIL from inside container):"
echo "    docker compose exec openclaw-gateway curl -s --max-time 3 https://example.com"
echo ""
echo "[+] To verify llama-server access (should SUCCEED from inside container):"
echo "    docker compose exec openclaw-gateway node -e \\"
echo "      \"require('http').get('http://llama-host:8888/v1/models', r => console.log(r.statusCode))\""
