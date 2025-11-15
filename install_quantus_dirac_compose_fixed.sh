#!/usr/bin/env bash
#
# install_quantus_dirac_compose.sh
# Stabilna instalacja Quantus Dirac (v0.4.2)
# - poprawiona ścieżka danych
# - poprawione uprawnienia (brak PermissionDenied)
# - poprawne generowanie node_key
# - poprawne generowanie rewards-address
# - poprawne docker-compose
# - pełna zgodność z MINING.md
#

set -euo pipefail

BASE_DIR="/root/quantus-dirac"
DATA_DIR="$BASE_DIR/data"
IMAGE="ghcr.io/quantus-network/quantus-node:v0.4.2"

mkdir -p "$BASE_DIR"
mkdir -p "$DATA_DIR"

echo "🚀 Instalacja Quantus Dirac (v0.4.2)"
echo "📁 Katalog: $BASE_DIR"
echo

# ==============================
# 1. POPRAWNE UPRAWNIENIA
# ==============================
echo "🔧 Naprawiam uprawnienia..."
chmod -R 777 "$DATA_DIR"

# ==============================
# 2. NAZWA NODA
# ==============================
DEFAULT_NODE="Node01"
read -rp "👉 Nazwa noda [${DEFAULT_NODE}]: " NODE_NAME
NODE_NAME="${NODE_NAME:-$DEFAULT_NODE}"

# ==============================
# 3. ADRES NAGRÓD
# ==============================
REWARDS_ADDRESS=""
read -rp "👉 Masz adres nagród? (t/N): " HAVE_ADDR
HAVE_ADDR="${HAVE_ADDR:-N}"

if [[ "$HAVE_ADDR" =~ ^[TtYy]$ ]]; then
    read -rp "👉 Wklej adres (qz...): " REWARDS_ADDRESS
else
    echo "🔐 Generuję nowy adres nagród..."
    KEY_FILE="$BASE_DIR/keys_$(date +%F_%H%M%S).txt"

    docker run --rm "$IMAGE" key quantus | tee "$KEY_FILE"
    chmod 600 "$KEY_FILE"

    REWARDS_ADDRESS=$(awk '/Address:/ {print $2; exit}' "$KEY_FILE")

    echo "📌 Adres: $REWARDS_ADDRESS"
    read -rp "👉 Czy zapisałeś seed? (t/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[TtYy]$ ]] || { echo "❌ Przerwano."; exit 1; }
fi

echo "💰 Rewards-address = $REWARDS_ADDRESS"

# ==============================
# 4. GENEROWANIE NODE_KEY
# ==============================
if [[ ! -f "$DATA_DIR/node_key" ]]; then
    echo "🔑 Generuję node_key..."
    docker run --rm \
        -v "$DATA_DIR":/var/lib/quantus \
        "$IMAGE" \
        key generate-node-key --file /var/lib/quantus/node_key
fi

chmod 666 "$DATA_DIR/node_key"

echo "📌 node_key zapisany w $DATA_DIR/node_key"

# ==============================
# 5. TWORZENIE DOCKER-COMPOSE
# ==============================
cat > "$BASE_DIR/docker-compose.yml" <<EOF
services:
  quantus-node:
    image: $IMAGE
    container_name: quantus-node
    restart: unless-stopped
    command: >
      --validator
      --chain dirac
      --base-path /var/lib/quantus
      --node-key-file /var/lib/quantus/node_key
      --rewards-address $REWARDS_ADDRESS
      --name $NODE_NAME
      --db-cache 2048
      --unsafe-rpc-external
      --rpc-cors all
      --in-peers 256
      --out-peers 256
    volumes:
      - ./data:/var/lib/quantus
    ports:
      - "30333:30333"
      - "9944:9944"
EOF

echo "📄 docker-compose.yml zapisany."

# ==============================
# 6. INSTALACJA DOCKERA
# ==============================
if ! command -v docker >/dev/null 2>&1; then
    echo "🐳 Instaluję Docker..."
    apt-get update -y
    apt-get install -y docker.io docker-compose-plugin
fi

systemctl start docker || true

# ==============================
# 7. START
# ==============================
cd "$BASE_DIR"
docker compose down || true
docker compose up -d

echo
echo "🎉 Quantus Dirac uruchomiony!"
echo "👉 Logi noda: docker compose logs -f quantus-node"
echo "👉 Sprawdź peers > 0 i import bloków."
