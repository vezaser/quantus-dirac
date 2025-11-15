#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Quantus Dirac v0.4.2 — instalacja (Docker Compose, FIXED)"
sleep 1

BASE_DIR="/root/quantus-dirac"
DATA_DIR="$BASE_DIR/quantus_node_data"
IMAGE="ghcr.io/quantus-network/quantus-node:v0.4.2"

mkdir -p "$DATA_DIR"

############################################
# 1) Sprawdzenie i instalacja Docker
############################################
if ! command -v docker >/dev/null 2>&1; then
  echo "🐳 Instaluję Docker..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
  > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

systemctl start docker || true

# docker compose wrapper
dc() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

############################################
# 2) Nazwa noda
############################################
read -rp "👉 Podaj nazwę noda (np. C01): " NODE_NAME
NODE_NAME="${NODE_NAME:-Node01}"

############################################
# 3) Czy masz adres nagród?
############################################
read -rp "👉 Masz adres nagród qz...? [t/N]: " HAVE
HAVE="${HAVE:-N}"

if [[ "$HAVE" =~ ^[TtYy]$ ]]; then
  read -rp "👉 Wklej adres nagród: " REWARD
  if [[ -z "$REWARD" ]]; then
    echo "❌ Brak adresu!"
    exit 1
  fi
else
  echo "🪙 Generuję nowy adres nagród..."
  KEYFILE="$BASE_DIR/rewards_$(date +%F_%H%M%S).txt"

  docker run --rm "$IMAGE" key quantus | tee "$KEYFILE"
  chmod 600 "$KEYFILE"

  REWARD=$(awk '/Address:/ {print $2}' "$KEYFILE")
  echo "📌 Twój nowy adres nagród: $REWARD"
  read -rp "👉 Czy zapisałeś seed offline? [t/N]: " OK
  [[ "$OK" =~ ^[TtYy]$ ]] || exit 1
fi

############################################
# 4) Generowanie node_key jeśli nie istnieje
############################################
if [[ ! -f "$DATA_DIR/node_key" ]]; then
  echo "🔑 Generuję node_key..."
  docker run --rm \
    -v "$DATA_DIR":/var/lib/quantus \
    "$IMAGE" \
    key generate-node-key --file /var/lib/quantus/node_key
fi

chmod 666 "$DATA_DIR/node_key"
chmod 777 "$DATA_DIR"

############################################
# 5) Tworzenie docker-compose.yml
############################################
cat > "$BASE_DIR/docker-compose.yml" <<EOF
services:
  quantus-node:
    image: $IMAGE
    container_name: quantus-node
    restart: unless-stopped
    command: >
      --validator
      --base-path /var/lib/quantus
      --chain dirac
      --node-key-file /var/lib/quantus/node_key
      --rewards-address $REWARD
      --name $NODE_NAME
      --db-cache 2048
      --unsafe-rpc-external
      --rpc-cors all
    volumes:
      - ./quantus_node_data:/var/lib/quantus
    ports:
      - "30333:30333"
      - "9944:9944"
EOF

############################################
# 6) Start noda
############################################
cd "$BASE_DIR"
dc down || true
dc up -d

echo "🎉 Node uruchomiony!"
echo "🔍 Logi:"
echo "   docker compose logs -f quantus-node"
echo "📂 Dane: $DATA_DIR"
echo "🔑 Node key: $DATA_DIR/node_key"
echo "💰 Rewards: $REWARD"
