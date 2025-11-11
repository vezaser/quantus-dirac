#!/usr/bin/env bash
# install_quantus_dirac_compose_v0.4.2.sh
# Jednoetapowa instalacja Quantus Dirac (v0.4.2) w Docker + docker-compose

set -euo pipefail

BASE_DIR="/root/quantus-dirac"
DATA_DIR="$BASE_DIR/quantus_node_data"
IMAGE_NAME="ghcr.io/quantus-network/quantus-node:v0.4.2"

DEFAULT_NODE_NAME="C02"
DEFAULT_REWARDS_ADDRESS="qzo3MQuQtoueVnz57EHMyujwaSM2LB1PfSUos1w9pX2LUH76o"

if [[ "$EUID" -ne 0 ]]; then
  echo "Uruchom jako root: sudo bash install_quantus_dirac_compose_v0.4.2.sh"
  exit 1
fi

echo "🚀 Instalacja Quantus Dirac (v0.4.2) - Docker Compose"
echo

# --- Pobierz parametry od użytkownika (z domyślnymi wartościami) ---
read -rp "👉 Nazwa noda [${DEFAULT_NODE_NAME}]: " NODE_NAME
NODE_NAME="${NODE_NAME:-$DEFAULT_NODE_NAME}"

read -rp "👉 Adres nagród qz... [${DEFAULT_REWARDS_ADDRESS}]: " REWARDS_ADDRESS
REWARDS_ADDRESS="${REWARDS_ADDRESS:-$DEFAULT_REWARDS_ADDRESS}"

if [[ ! "$REWARDS_ADDRESS" =~ ^qz ]]; then
  echo "❌ Adres nagród musi zaczynać się od qz..."
  exit 1
fi

echo
echo "Używam:"
echo "  🏷️  Node name:      $NODE_NAME"
echo "  💰 Rewards address: $REWARDS_ADDRESS"
echo

# --- Przygotuj katalogi ---
mkdir -p "$DATA_DIR"
chmod 700 "$BASE_DIR"
# Katalog danych musi być zapisywalny dla procesu w kontenerze -> dajemy full rwx (typowy 1-user VPS)
chmod 777 "$DATA_DIR"

# --- Docker + docker compose ---
if ! command -v docker >/dev/null 2>&1; then
  echo "🐳 Instaluję Docker..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    echo "❌ Brak apt-get. Zainstaluj Docker ręcznie i uruchom ponownie."
    exit 1
  fi
fi

if ! systemctl is-active --quiet docker; then
  systemctl start docker || true
fi

dc() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    echo "❌ Brak docker compose. Zainstaluj plugin docker compose."
    exit 1
  fi
}

# --- Pobierz obraz ---
echo "⬇️ Pobieram obraz $IMAGE_NAME (jeśli nie jest lokalnie)..."
docker pull "$IMAGE_NAME"

# --- Wygeneruj node_key, jeśli nie istnieje ---
if [[ -f "$DATA_DIR/node_key" ]]; then
  echo "ℹ️ Istnieje już $DATA_DIR/node_key - nie generuję nowego."
else
  echo "🔑 Generuję node_key..."
  docker run --rm \
    -v "$DATA_DIR":/var/lib/quantus \
    "$IMAGE_NAME" \
    key generate-node-key --file /var/lib/quantus/node_key

  if [[ ! -f "$DATA_DIR/node_key" ]]; then
    echo "❌ Nie udało się wygenerować node_key."
    exit 1
  fi

  echo "✅ node_key zapisany w $DATA_DIR/node_key"
fi

# --- Zapisz rewards-address do pliku pomocniczego (opcjonalnie informacyjnie) ---
echo "$REWARDS_ADDRESS" > "$DATA_DIR/rewards-address.txt"

# --- Stwórz docker-compose.yml ---
cat > "$BASE_DIR/docker-compose.yml" <<EOF
services:
  quantus-node:
    image: $IMAGE_NAME
    container_name: quantus-node
    restart: unless-stopped
    command: >
      --validator
      --base-path /var/lib/quantus
      --chain dirac
      --node-key-file /var/lib/quantus/node_key
      --rewards-address $REWARDS_ADDRESS
      --name $NODE_NAME
      --execution native-else-wasm
      --wasm-execution compiled
      --db-cache 2048
      --unsafe-rpc-external
      --rpc-cors all
      --in-peers 256
      --out-peers 256
    volumes:
      - ./quantus_node_data:/var/lib/quantus
    ports:
      - "30333:30333"
      - "9944:9944"
EOF

echo "✅ Zapisano docker-compose.yml w $BASE_DIR"
echo

# --- Start noda ---
cd "$BASE_DIR"
dc down || true
dc up -d

echo "✅ Quantus Dirac (v0.4.2) uruchomiony w Docker."
echo
echo "📂 Katalog: $BASE_DIR"
echo "📂 Dane:    $DATA_DIR"
echo
echo "🔍 Sprawdź status:"
echo "  cd $BASE_DIR"
echo "  docker compose ps"
echo "  docker compose logs -f"
echo
echo "W logach szukaj:"
echo "  - peers > 0"
echo "  - 'Using provided rewards address: ... (qz...)'"
echo "  - 'Successfully mined and submitted a new block' (gdy kopie)"
