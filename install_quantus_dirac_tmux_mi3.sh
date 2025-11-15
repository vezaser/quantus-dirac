#!/usr/bin/env bash
# install_quantus_dirac_tmux_mi3.sh
# Prosta instalka Quantus Dirac (Mi3 + external miner) na tmux

set -euo pipefail

# --- KONFIG ---
BASE_DIR="/root/quantus-dirac"
DATA_DIR="$BASE_DIR/chain_data_dir"
NODE_BIN="$BASE_DIR/quantus-node"
MINER_BIN="$BASE_DIR/quantus-miner"
NODE_KEY_FILE="$BASE_DIR/node_key"

NODE_NAME="Mi3"
REWARDS_ADDRESS="qzqE22pZ2GSJpMmAr7uezPcb62ZmKd8RR846q6S3jaFQcM6V2"

# UWAGA: jeśli link do binarek się kiedyś zmieni, popraw tu:
NODE_TAR_URL="https://github.com/Quantus-Network/chain/releases/download/v0.4.2/quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz"
MINER_URL="https://github.com/Quantus-Network/quantus-miner/releases/download/v0.3.0/quantus-miner-linux-x86_64"

TMUX_SESSION="quantus-dirac"

# --- CHECK ROOT ---
if [[ "$EUID" -ne 0 ]]; then
  echo "Uruchom jako root: sudo bash $0"
  exit 1
fi

echo "🚀 Instalacja Quantus Dirac (Mi3 + external miner, tmux)"
echo "   BASE_DIR: $BASE_DIR"
echo "   NODE:     $NODE_NAME"
echo "   REWARDS:  $REWARDS_ADDRESS"
echo

# --- Pakiety ---
echo "📦 Instaluję wymagane pakiety (curl, wget, tmux, ca-certificates)..."
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y curl wget tmux ca-certificates
else
  echo "❌ Brak apt-get. Ten skrypt zakłada Ubuntu/Debiana."
  exit 1
fi

# --- STOP STARE NODY / MINERY / TMUX ---
echo "🧹 Zatrzymuję stare procesy quantus-node / quantus-miner / tmux..."

systemctl stop quantus-node 2>/dev/null || true
systemctl stop quantus-miner 2>/dev/null || true
systemctl disable quantus-node 2>/dev/null || true
systemctl disable quantus-miner 2>/dev/null || true

pkill -f quantus-node 2>/dev/null || true
pkill -f quantus-miner 2>/dev/null || true

tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# --- KATALOGI ---
echo "📁 Tworzę katalog: $BASE_DIR"
mkdir -p "$BASE_DIR"
mkdir -p "$DATA_DIR"

# Dla prostoty – pełne prawa do katalogu danych (pojedyńczy VPS, jeden user)
chmod 700 "$BASE_DIR"
chmod 777 "$DATA_DIR"

cd "$BASE_DIR"

# --- POBRANIE quantus-node ---
if [[ -x "$NODE_BIN" ]]; then
  echo "ℹ️ Binarna quantus-node już istnieje: $NODE_BIN"
else
  echo "⬇️ Pobieram quantus-node (Dirac v0.4.2)..."
  rm -f node.tar.gz || true
  curl -L "$NODE_TAR_URL" -o node.tar.gz

  echo "📦 Rozpakowuję quantus-node..."
  tar -xzf node.tar.gz

  # 1) najpierw spróbuj lokalny ./quantus-node
  if [[ -f "./quantus-node" ]]; then
    NODE_BIN="$BASE_DIR/quantus-node"
    chmod +x "$NODE_BIN"
    echo "✅ quantus-node znaleziony w katalogu: $NODE_BIN"
  else
    # 2) jeśli jest w podkatalogu, znajdź pierwszy plik o tej nazwie
    FOUND_NODE="$(find . -type f -name 'quantus-node' | head -n 1 || true)"
    if [[ -z "$FOUND_NODE" ]]; then
      echo "❌ Nie znaleziono pliku quantus-node po rozpakowaniu."
      echo "   Sprawdź zawartość node.tar.gz ręcznie: tar -tzf node.tar.gz"
      exit 1
    fi
    NODE_BIN="$(readlink -f "$FOUND_NODE")"
    chmod +x "$NODE_BIN"
    echo "✅ quantus-node znaleziony: $NODE_BIN"
  fi
fi

# --- POBRANIE quantus-miner ---
if [[ -x "$MINER_BIN" ]]; then
  echo "ℹ️ Binarna quantus-miner już istnieje: $MINER_BIN"
else
  echo "⬇️ Pobieram quantus-miner..."
  curl -L "$MINER_URL" -o "$MINER_BIN"
  chmod +x "$MINER_BIN"
  echo "✅ quantus-miner zapisany jako: $MINER_BIN"
fi

# --- NODE KEY ---
if [[ -f "$NODE_KEY_FILE" ]]; then
  echo "ℹ️ node_key już istnieje: $NODE_KEY_FILE"
else
  echo "🔑 Generuję node_key..."
  "$NODE_BIN" key generate-node-key --file "$NODE_KEY_FILE"
  echo "✅ node_key zapisany w: $NODE_KEY_FILE"
fi

# --- INFO O USTAWIENIACH ---
echo
echo "🔧 Konfiguracja:"
echo "  Node name:      $NODE_NAME"
echo "  Rewards address:$REWARDS_ADDRESS"
echo "  Data dir:       $DATA_DIR"
echo "  Node key:       $NODE_KEY_FILE"
echo

# --- LICZBA WORKERÓW DLA MINERA ---
TOTAL_CORES=$(nproc)
if (( TOTAL_CORES > 1 )); then
  WORKERS=$(( TOTAL_CORES - 1 ))
else
  WORKERS=1
fi

echo "⚙️ Wykryto rdzeni CPU: $TOTAL_CORES -> miner workers: $WORKERS"
echo

# --- START TMUX: NODE + MINER ---
echo "🟢 Startuję tmux session: $TMUX_SESSION"

# Komenda noda (Dirac + external miner)
NODE_CMD="$NODE_BIN \
  --validator \
  --chain dirac \
  --sync full \
  --base-path $DATA_DIR \
  --node-key-file $NODE_KEY_FILE \
  --rewards-address $REWARDS_ADDRESS \
  --name $NODE_NAME \
  --external-miner-url http://127.0.0.1:9833 \
  --prometheus-port 9616 \
  --rpc-port 9944 \
  --in-peers 256 \
  --out-peers 256 \
  --unsafe-rpc-external \
  --rpc-cors all"

# Komenda minera
MINER_CMD="$MINER_BIN \
  --engine cpu-fast \
  --port 9833 \
  --workers $WORKERS"

# Nowa sesja tmux z nodem
tmux new-session -d -s "$TMUX_SESSION" "$NODE_CMD"

# Drugie okno (pane) z minerem
tmux split-window -v -t "$TMUX_SESSION:0" "$MINER_CMD"

echo
echo "✅ Node + external miner uruchomione w tmux: $TMUX_SESSION"
echo
echo "📜 Jak oglądać logi na żywo:"
echo "  tmux attach -t $TMUX_SESSION"
echo "    - góra: node"
echo "    - dół:  miner"
echo "  wyjście z tmux (bez zatrzymywania): CTRL+B, potem D"
echo
echo "🔍 Szybki health check RPC:"
echo "  curl -s -H 'Content-Type: application/json' \\"
echo "    -d '{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"system_health\",\"params\":[]}' \\"
echo "    http://127.0.0.1:9944 | jq"
echo
echo "Gotowe. VPS może się rozłączyć, node i miner dalej będą działały w tmux."
