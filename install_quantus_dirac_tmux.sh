#!/usr/bin/env bash
# install_quantus_dirac_tmux.sh
# Instalacja Quantus Dirac (node + external miner) na tmux, bez Dockera.
# - pyta o nazwę noda
# - pyta o adres nagród
# - pobiera quantus-node v0.4.2 (Dirac)
# - pobiera quantus-miner (miner-cli 1.0.0+aa9e7ca5 – URL możesz podmienić)
# - generuje node_key (jeśli brak)
# - tworzy run-node.sh i run-miner.sh
# - uruchamia w tmux (sesja: quantus, okna: node/miner)

set -euo pipefail

BASE_DIR="/root/quantus-dirac"
BIN_NODE="$BASE_DIR/quantus-node"
BIN_MINER="$BASE_DIR/quantus-miner"
CHAIN_DIR="$BASE_DIR/chain_data_dir"
NODE_KEY_FILE="$BASE_DIR/node_key"

# ⚠️ PODMIENISZ W RAZIE CZEGO JEŚLI LINKI SIĘ ZMIENIĄ:
NODE_URL="https://github.com/Quantus-Network/chain/releases/download/v0.4.2/quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz"
MINER_URL="https://github.com/Quantus-Network/quantus-miner/releases/download/v1.0.0/quantus-miner-linux-x86_64"

if [[ "$EUID" -ne 0 ]]; then
  echo "❌ Uruchom skrypt jako root: sudo bash install_quantus_dirac_tmux.sh"
  exit 1
fi

echo "🚀 Instalacja Quantus Dirac (node + external miner) na tmux"
echo "   Katalog bazowy: $BASE_DIR"
echo

# 1) Pytanie o nazwę noda
read -rp "👉 Podaj nazwę noda (np. Mi3): " NODE_NAME
if [[ -z "${NODE_NAME}" ]]; then
  echo "❌ Nazwa noda nie może być pusta."
  exit 1
fi

# 2) Pytanie o adres nagród
read -rp "👉 Podaj adres nagród (qz...): " REWARDS_ADDRESS
if [[ -z "${REWARDS_ADDRESS}" ]]; then
  echo "❌ Adres nagród nie może być pusty."
  exit 1
fi

if [[ ! "${REWARDS_ADDRESS}" =~ ^qz ]]; then
  echo "❌ Adres nagród musi zaczynać się od 'qz'."
  exit 1
fi

echo
echo "📋 Podsumowanie:"
echo "  🏷️  Node name:      ${NODE_NAME}"
echo "  💰 Rewards address: ${REWARDS_ADDRESS}"
echo "  📂 BASE_DIR:        ${BASE_DIR}"
echo

# 3) Pakiety
echo "📦 Instaluję wymagane pakiety (curl, wget, tmux, ca-certificates)..."
apt-get update -y >/dev/null
apt-get install -y curl wget tmux ca-certificates >/dev/null

# 4) Katalogi
echo "📁 Tworzę katalog: $BASE_DIR"
mkdir -p "$BASE_DIR"
mkdir -p "$CHAIN_DIR"

# 5) Zabijamy stare procesy / tmux
echo "🧹 Zabijam stare procesy Quantus (jeśli są)..."
pkill -f "$BIN_NODE" 2>/dev/null || true
pkill -f "$BIN_MINER" 2>/dev/null || true
tmux kill-session -t quantus 2>/dev/null || true

cd "$BASE_DIR"

# 6) Pobieramy quantus-node, jeśli go nie ma
if [[ ! -x "$BIN_NODE" ]]; then
  echo "⬇️ Pobieram quantus-node (Dirac v0.4.2)..."
  rm -f node.tar.gz
  wget -O node.tar.gz "$NODE_URL"
  tar xzf node.tar.gz
  # Zazwyczaj w tarze jest plik 'quantus-node' w bieżącym katalogu
  if [[ ! -f "$BIN_NODE" && -f "./quantus-node" ]]; then
    mv ./quantus-node "$BIN_NODE"
  fi
  chmod +x "$BIN_NODE"
else
  echo "ℹ️ quantus-node już istnieje: $BIN_NODE"
fi

# 7) Pobieramy quantus-miner (miner-cli 1.0.0...) jeśli go nie ma
if [[ ! -x "$BIN_MINER" ]]; then
  echo "⬇️ Pobieram quantus-miner (miner-cli 1.0.0+aa9e7ca5)..."
  rm -f quantus-miner
  wget -O "$BIN_MINER" "$MINER_URL"
  chmod +x "$BIN_MINER"
else
  echo "ℹ️ quantus-miner już istnieje: $BIN_MINER"
fi

# 8) Generujemy node_key, jeśli brak
if [[ ! -f "$NODE_KEY_FILE" ]]; then
  echo "🔑 Generuję node_key..."
  "$BIN_NODE" key generate-node-key --file "$NODE_KEY_FILE"
  echo "✅ node_key zapisany w: $NODE_KEY_FILE"
else
  echo "ℹ️ node_key już istnieje: $NODE_KEY_FILE"
fi

# 9) Tworzymy run-node.sh
cat > "$BASE_DIR/run-node.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$BASE_DIR"

exec "$BIN_NODE" \\
  --validator \\
  --chain dirac \\
  --base-path "$CHAIN_DIR" \\
  --node-key-file "$NODE_KEY_FILE" \\
  --rewards-address "$REWARDS_ADDRESS" \\
  --name "$NODE_NAME" \\
  --unsafe-rpc-external \\
  --rpc-cors all \\
  --in-peers 256 \\
  --out-peers 256 \\
  --prometheus-port 9616 \\
  --rpc-port 9944 \\
  --external-miner-url "http://127.0.0.1:9833/"
EOF

chmod +x "$BASE_DIR/run-node.sh"

# 10) Tworzymy run-miner.sh
#    Używamy (nproc - 1), minimum 1 worker
WORKERS=1
CPU_TOTAL=\$(nproc || echo 1)
if [[ "\$CPU_TOTAL" -gt 1 ]]; then
  WORKERS=\$((CPU_TOTAL - 1))
fi

cat > "$BASE_DIR/run-miner.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$BASE_DIR"

echo "⛏️ Startuję quantus-miner z \$WORKERS worker(s)..."
exec "$BIN_MINER" \\
  --engine cpu-fast \\
  --port 9833 \\
  --workers \$WORKERS
EOF

chmod +x "$BASE_DIR/run-miner.sh"

# 11) Start w tmux: sesja 'quantus', okno 0: node, okno 1: miner
echo "🎛  Uruchamiam node + miner w tmux (sesja: quantus)..."
tmux new-session -d -s quantus "bash $BASE_DIR/run-node.sh"
tmux new-window  -t quantus:1 -n miner "bash $BASE_DIR/run-miner.sh"

echo
echo "✅ Gotowe!"
echo
echo "📌 Jak używać:"
echo "  • Podejrzyj sesje tmux:   tmux ls"
echo "  • Wejdź w logi noda:      tmux attach -t quantus   (okno 0: node)"
echo "  • Przełącz na minera:     Ctrl+B, potem 1"
echo "  • Wyjście z tmux bez stopu:  Ctrl+B, potem D"
echo
echo "🔁 Jeśli chcesz zmienić nazwę noda lub adres nagród:"
echo "  1) Uruchom skrypt ponownie: bash install_quantus_dirac_tmux.sh"
echo "  2) Podać nową nazwę / adres"
echo "  3) Skrypt zabije stare procesy, nadpisze run-node.sh/run-miner.sh i wystartuje wszystko od nowa."
echo
echo "🔍 Szybki health-check RPC:"
echo "  curl -s -H \"Content-Type: application/json\" \\"
echo "    -d '{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"system_health\",\"params\":[]}' \\"
echo "    http://127.0.0.1:9944 | jq"
echo
echo "ℹ️ Pamiętaj, żeby ewentualnie dopisać bootnodes do run-node.sh, jeśli będziesz chciał wymusić więcej peers."
