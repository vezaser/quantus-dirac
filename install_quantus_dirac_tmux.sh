#!/usr/bin/env bash
# install_quantus_dirac_tmux.sh
# Instalacja Quantus Dirac (Dirac v0.4.2) + external miner (miner-cli 1.0.0) w jednym tmux (node + miner jednocześnie)

set -euo pipefail

BASE_DIR="/root/quantus-dirac"
DATA_DIR="$BASE_DIR/data"
SESSION_NAME="quantus"

NODE_BIN="$BASE_DIR/quantus-node"
MINER_BIN="$BASE_DIR/quantus-miner"

NODE_URL="https://github.com/Quantus-Network/chain/releases/download/v0.4.2/quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz"
MINER_URL="https://github.com/Quantus-Network/quantus-miner/releases/download/v1.0.0/quantus-miner-linux-x86_64"

if [[ "$EUID" -ne 0 ]]; then
  echo "❌ Uruchom skrypt jako root (sudo su)."
  exit 1
fi

echo "🚀 Instalacja Quantus Dirac (node + external miner w tmux)"
echo "   BASE_DIR: $BASE_DIR"
echo

echo "📦 Instaluję wymagane pakiety (curl, wget, tmux, ca-certificates, jq)..."
apt-get update -y
apt-get install -y curl wget tmux ca-certificates jq

echo "🧹 Zabijam stare procesy quantus-node / quantus-miner / tmux..."
pkill -f quantus-node 2>/dev/null || true
pkill -f quantus-miner 2>/dev/null || true
tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

mkdir -p "$BASE_DIR" "$DATA_DIR"
cd "$BASE_DIR"

##########################
# NODE (v0.4.2)
##########################
echo "⬇️ Sprawdzam binarkę quantus-node..."
if [[ ! -x "$NODE_BIN" ]]; then
  echo "   Pobieram quantus-node v0.4.2..."
  TMP_TAR="$(mktemp /tmp/quantus-node.XXXXX.tar.gz)"
  curl -L -o "$TMP_TAR" "$NODE_URL"
  tar -xzf "$TMP_TAR"
  rm -f "$TMP_TAR"
  chmod +x quantus-node
  echo "   ✅ quantus-node gotowy."
else
  echo "   ℹ️ quantus-node już istnieje – pomijam pobieranie."
fi

##########################
# MINER (v1.0.0)
##########################
echo "⬇️ Sprawdzam binarkę quantus-miner (miner-cli 1.0.0)..."
if [[ ! -x "$MINER_BIN" ]]; then
  echo "   Pobieram quantus-miner v1.0.0..."
  curl -L -o "$MINER_BIN" "$MINER_URL"
  chmod +x "$MINER_BIN"
  echo "   ✅ quantus-miner (miner-cli 1.0.0) gotowy."
else
  echo "   ℹ️ quantus-miner już istnieje – pomijam pobieranie."
fi

##########################
# Nazwa noda
##########################
read -rp "👉 Podaj nazwę noda [MiX]: " NODE_NAME
NODE_NAME="${NODE_NAME:-MiX}"

##########################
# Adres nagród
##########################
REWARDS=""
read -rp "👉 Masz już adres nagród qz...? [t/N]: " HAVE_ADDR
HAVE_ADDR="${HAVE_ADDR:-N}"

if [[ "$HAVE_ADDR" =~ ^[TtYy]$ ]]; then
  read -rp "👉 Wklej adres nagród (qz...): " REWARDS
  if [[ -z "$REWARDS" ]]; then
    echo "❌ Nie podano adresu nagród."
    exit 1
  fi
  if [[ ! "$REWARDS" =~ ^qz ]]; then
    echo "❌ Adres nagród musi zaczynać się od 'qz'."
    exit 1
  fi
else
  KEY_FILE="$BASE_DIR/keys_dirac_$(date +%F_%H%M%S).txt"
  echo
  echo "💰 Generuję NOWY seed + adres nagród (key quantus)..."
  "$NODE_BIN" key quantus | tee "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  REWARDS="$(awk '/Address:/ {print $2; exit}' "$KEY_FILE" || true)"

  if [[ -z "$REWARDS" ]]; then
    echo "❌ Nie udało się odczytać Address: z $KEY_FILE"
    exit 1
  fi

  echo
  echo "⚠️ SEED + ADDRESS zapisane w: $KEY_FILE"
  echo "   ZRÓB BACKUP tego pliku (offline, password manager, kartka)."
  read -rp "👉 Czy zapisałeś seed w bezpiecznym miejscu? [t/N]: " CONFIRM_SEED
  CONFIRM_SEED="${CONFIRM_SEED:-N}"
  if [[ ! "$CONFIRM_SEED" =~ ^[TtYy]$ ]]; then
    echo "❌ Nie potwierdzono zapisu seedu. Instalacja przerwana."
    exit 1
  fi
fi

##########################
# node_key
##########################
NODEKEY="$DATA_DIR/node_key"
if [[ -f "$NODEKEY" ]]; then
  echo "ℹ️ node_key już istnieje: $NODEKEY"
else
  echo "🔑 Generuję node_key..."
  "$NODE_BIN" key generate-node-key --file "$NODEKEY"
  echo "   ✅ node_key zapisany w: $NODEKEY"
fi

chmod 700 "$DATA_DIR"

##########################
# Wątki minera
##########################
CPU=$(nproc)
WORKERS=$(( CPU>1 ? CPU-1 : 1 ))
echo "🧮 CPU: $CPU, ustalam workers dla minera: $WORKERS"

##########################
# Start tmux: jedno okno, 2 panele (node + miner)
##########################
echo
echo "🖥️ Uruchamiam tmux session '$SESSION_NAME' (góra node, dół miner)..."

tmux new-session -d -s "$SESSION_NAME" -n main \
  "cd $BASE_DIR && ./quantus-node \
    --validator \
    --chain dirac \
    --base-path $DATA_DIR \
    --node-key-file $NODEKEY \
    --rewards-address $REWARDS \
    --name $NODE_NAME \
    --db-cache 2048 \
    --unsafe-rpc-external \
    --rpc-cors all \
    --in-peers 256 \
    --out-peers 256 \
    --external-miner-url http://127.0.0.1:9833 \
    --prometheus-port 9616 \
    --rpc-port 9944"

tmux split-window -v -t "$SESSION_NAME:0" \
  "cd $BASE_DIR && ./quantus-miner \
    --engine cpu-fast \
    --port 9833 \
    --workers $WORKERS"

tmux select-layout -t "$SESSION_NAME:0" tiled >/dev/null 2>&1 || true

echo
echo "✅ Node + miner uruchomione w tmux (session: $SESSION_NAME)"
echo
echo "🔌 Dołączenie do sesji:"
echo "   tmux attach -t $SESSION_NAME"
echo
echo "   Góra: node, dół: miner"
echo "   Wyjście (bez zatrzymywania): CTRL+B, potem D"
echo
echo "🔍 Szybki health-check:"
echo "   curl -s -H 'Content-Type: application/json' \\"
echo "        -d '{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"system_health\",\"params\":[]}' \\"
echo "        http://127.0.0.1:9944 | jq"
echo
echo "Szukaj w logach noda m.in.:"
echo "   peers > 0,  'Using provided rewards address',  'Successfully mined and submitted a new block'"
