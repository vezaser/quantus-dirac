#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Instalacja Quantus Dirac (tmux, external miner)"

# ==========================
# PYTANIA
# ==========================
read -rp "👉 Podaj nazwę noda (np. Mi3): " NODE_NAME
if [[ -z "$NODE_NAME" ]]; then
  echo "❌ Nazwa noda nie może być pusta"
  exit 1
fi

read -rp "👉 Podaj adres nagród (qz...): " REWARDS
if [[ ! "$REWARDS" =~ ^qz ]]; then
  echo "❌ Adres nagród MUSI zaczynać się od qz"
  exit 1
fi

BASE_DIR="/root/quantus-dirac"
NODE="$BASE_DIR/quantus-node"
MINER="$BASE_DIR/quantus-miner"
DATA="/root/.quantus-dirac"

echo
echo "📌 Konfiguracja:"
echo "    🏷️ Node name:        $NODE_NAME"
echo "    💰 Rewards address:   $REWARDS"
echo "    📂 Node directory:    $BASE_DIR"
echo "    📂 Data directory:    $DATA"
echo

sleep 1

# ==========================
# Instalacja pakietów
# ==========================
echo "📦 Instaluję wymagane pakiety..."
apt-get update -y
apt-get install -y tmux wget curl ca-certificates

# ==========================
# Czyścimy stare procesy
# ==========================
echo "🧹 Zabijam stare procesy Quantus..."
pkill -f quantus-node || true
pkill -f quantus-miner || true
tmux kill-session -t quantus 2>/dev/null || true

# ==========================
# Pobranie binarek
# ==========================
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

echo "⬇️ Pobieram quantus-node..."
wget -q https://github.com/Quantus-Network/chain/releases/download/v0.4.2/quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz
tar -xzf quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz
mv quantus-node "$NODE"
chmod +x "$NODE"

echo "⬇️ Pobieram quantus-miner..."
wget -q https://github.com/Quantus-Network/quantus-miner/releases/download/v0.3.0/quantus-miner-linux-x86_64
mv quantus-miner-linux-x86_64 "$MINER"
chmod +x "$MINER"

# ==========================
# Przygotowanie katalogów
# ==========================
mkdir -p "$DATA"
chmod 700 "$DATA"

# ==========================
# Generowanie node_key
# ==========================
echo "🔑 Generuję node_key..."
"$NODE" key generate-node-key --file "$DATA/node_key"

echo "✅ node_key zapisany w: $DATA/node_key"
echo

# ==========================
# Tworzenie tmux session
# ==========================
echo "🧰 Uruchamiam tmux session: quantus"

tmux new-session -d -s quantus

# ==========================
# Okno 1 — NODE
# ==========================
tmux rename-window -t quantus:0 "node"
tmux send-keys -t quantus:0 "
$NODE \
  --validator \
  --chain dirac \
  --base-path $DATA \
  --node-key-file $DATA/node_key \
  --rewards-address $REWARDS \
  --name $NODE_NAME \
  --in-peers 256 \
  --out-peers 256 \
  --unsafe-rpc-external \
  --rpc-cors all \
  --db-cache 2048
" C-m

# ==========================
# Okno 2 — MINER
# ==========================
tmux new-window -t quantus -n miner
tmux send-keys -t quantus:1 "
$MINER \
  --engine cpu-fast \
  --port 9833 \
  --workers \$((\$(nproc)-1))
" C-m

# ==========================
# Info
# ==========================
echo
echo "✅ Instalacja zakończona!"
echo
echo "📌 Otwórz node:"
echo "    tmux attach -t quantus -c node"
echo
echo "📌 Otwórz miner:"
echo "    tmux select-window -t quantus:1"
echo
echo "📌 Wyjście z tmux (node działa dalej):"
echo "    CTRL + B, potem D"
echo
echo "📊 Status Peers:"
echo "curl -s -H \"Content-Type: application/json\" -d '{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"system_health\",\"params\":[]}' http://127.0.0.1:9944 | jq"
