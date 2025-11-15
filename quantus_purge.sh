#!/usr/bin/env bash
set -e

echo "🧹 Quantus — FULL CLEANUP"
echo "--------------------------------------"

# 1. Stop services
echo "🛑 Stopping services..."
systemctl stop quantus-node 2>/dev/null || true
systemctl stop quantus-miner 2>/dev/null || true

# 2. Disable autostart
echo "🚫 Disabling autostart..."
systemctl disable quantus-node 2>/dev/null || true
systemctl disable quantus-miner 2>/dev/null || true

# 3. Remove systemd service files
echo "🗑️ Removing systemd files..."
rm -f /etc/systemd/system/quantus-node.service
rm -f /etc/systemd/system/quantus-miner.service
systemctl daemon-reload

# 4. Remove data directory
echo "🧨 Removing node data directory..."
rm -rf /var/lib/quantus

# 5. Remove source directories (if built from source)
echo "🧨 Removing source directories..."
rm -rf /root/quantus-src

# 6. Remove binaries
echo "🗑️ Removing binaries..."
rm -f /usr/local/bin/quantus-node
rm -f /usr/local/bin/quantus-miner

# 7. Remove generated keys
echo "🗑️ Removing generated key files..."
rm -f /root/quantus_key_*.txt
rm -f /root/node_key
rm -f /root/node_key.p2p

echo "--------------------------------------"
echo "✅ Quantus FULL CLEANUP COMPLETE"
echo "💡 System gotowy do nowej instalacji."
