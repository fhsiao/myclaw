#!/usr/bin/env bash
# =============================================================================
# teardown-network.sh — removes the OpenClaw iptables rules
# Run as root when you're done with openclaw sessions.
# =============================================================================
set -euo pipefail

echo "[+] Removing OpenClaw iptables rules..."

# Remove by comment match — safer than line number removal
for table in INPUT FORWARD OUTPUT; do
  # Loop because there may be multiple matching rules
  while iptables -L "$table" -n --line-numbers 2>/dev/null \
        | grep -q "openclaw"; do
    LINE=$(iptables -L "$table" -n --line-numbers \
           | grep "openclaw" | head -1 | awk '{print $1}')
    iptables -D "$table" "$LINE"
    echo "  Removed rule $LINE from $table"
  done
done

echo "[+] Done. All OpenClaw iptables rules removed."
