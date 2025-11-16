#!/usr/bin/env bash
# install_quantus_dirac_compose_v0.4.2.sh
# Jednoetapowa instalacja Quantus Dirac (v0.4.2) w Docker + docker-compose
# - generuje node_key
# - obsługuje adres nagród: posiadany lub nowo wygenerowany (z potwierdzeniem zapisu seedu)
# - stawia docker-compose z quantus-node

set -euo pipefail

BASE_DIR="/root/quantus-dirac"
DATA_DIR="$BASE_DIR/quantus_node_data"
IMAGE_NAME="ghcr.io/quantus-network/quantus-node:v0.4.2"

DEFAULT_NODE_NAME="C02"

if [[ "$EUID" -ne 0 ]]; then
  echo "Uruchom jako root: sudo bash install_quantus_dirac_compose_v0.4.2.sh"
  exit 1
fi

echo "🚀 Instalacja Quantus Dirac (v0.4.2) - Docker Compose"
echo

# --- Nazwa noda ---
read -rp "👉 Nazwa noda [${DEFAULT_NODE_NAME}]: " NODE_NAME
NODE_NAME="${NODE_NAME:-$DEFAULT_NODE_NAME}"

# --- Adres nagród: masz / nie masz? ---
REWARDS_ADDRESS=""

read -rp "👉 Masz już adres do nagród (qz...)? [t/N]: " HAVE_ADDR
HAVE_ADDR="${HAVE_ADDR:-N}"

if [[ "$HAVE_ADDR" =~ ^[TtYy]$ ]]; then
  read -rp "👉 Wpisz swój adres nagród (qz...): " MANUAL_ADDR
  if [[ -z "$MANUAL_ADDR" ]]; then
    echo "❌ Nie podano adresu nagród."
    exit 1
  fi
  if [[ ! "$MANUAL_ADDR" =~ ^qz ]]; then
    echo "❌ Adres nagród musi zaczynać się od 'qz'."
    exit 1
  fi
  REWARDS_ADDRESS="$MANUAL_ADDR"
  echo "✅ Użyjemy istniejącego adresu nagród: $REWARDS_ADDRESS"
else
  echo
  echo "💰 Nie masz adresu nagród - wygenerujemy NOWY (seed + address)."
  echo "   Uwaga: seed daje pełną kontrolę nad środkami. Zapisz go offline."
fi

echo
echo "Parametry noda:"
echo "  🏷️  Node name: $NODE_NAME"
[[ -n "$REWARDS_ADDRESS" ]] && echo "  💰 Rewards address: $REWARDS_ADDRESS (istniejący)"
echo

# --- Przygotuj katalogi ---
mkdir -p "$DATA_DIR"
chmod 700 "$(dirname "$BASE_DIR")" 2>/dev/null || true
# DATA_DIR musi być zapisywalny dla kontenera -> dajemy 777 (prosty setup na VPS pod jednego usera)
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
    echo "❌ Brak apt-get. Zainstaluj Docker ręcznie."
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
  echo "ℹ️ node_key już istnieje: $DATA_DIR/node_key"
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
  echo "✅ node_key zapisany w: $DATA_DIR/node_key"
fi

# --- Jeśli nie było adresu nagród: generujemy nowy (seed + address) ---
if [[ -z "$REWARDS_ADDRESS" ]]; then
  echo
  echo "💳 Generuję nowy adres nagród (key quantus)..."
  KEY_FILE="$BASE_DIR/keys_dirac_$(date +%F_%H%M%S).txt"

  # Zapis na ekran + do pliku na hoście (pełne dane: seed + address)
  docker run --rm "$IMAGE_NAME" key quantus | tee "$KEY_FILE"

  chmod 600 "$KEY_FILE"
  echo
  echo "⚠️ Pełne dane (SEED + ADDRESS) zapisane w: $KEY_FILE"
  echo "   ZRÓB BACKUP tego pliku (offline, menedżer haseł, papier)."
  echo

  # Wymuś potwierdzenie zapisu seedu
  read -rp "👉 Czy zapisałeś seed w bezpiecznym miejscu? [t/N]: " CONFIRM_SEED
  CONFIRM_SEED="${CONFIRM_SEED:-N}"
  if [[ ! "$CONFIRM_SEED" =~ ^[TtYy]$ ]]; then
    echo "❌ Nie potwierdzono zapisu seedu. Instalacja przerwana."
    echo "   Plik z danymi: $KEY_FILE"
    exit 1
  fi

  # Wyciągnij Address: z pliku
  REWARDS_ADDRESS="$(awk '/Address:/ {print $2; exit}' "$KEY_FILE" || true)"
  if [[ -z "$REWARDS_ADDRESS" ]]; then
    echo "❌ Nie udało się odczytać Address: z $KEY_FILE"
    exit 1
  fi

  echo "✅ Nowy adres nagród: $REWARDS_ADDRESS"
fi

# --- Zapisz rewards-address pomocniczo do pliku ---
echo "$REWARDS_ADDRESS" > "$DATA_DIR/rewards-address.txt"

echo
echo "Finalna konfiguracja:"
echo "  🏷️  Node name:      $NODE_NAME"
echo "  💰 Rewards address: $REWARDS_ADDRESS"
echo "  📂 Dane:            $DATA_DIR"
echo

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

echo "✅ Quantus Dirac (v0.4.2) uruchomiony w Docker Compose."
echo
echo "📂 Katalog: $BASE_DIR"
echo "📂 Dane:    $DATA_DIR"
echo
echo "🔍 Sprawdź:"
echo "  cd $BASE_DIR"
echo "  docker compose ps"
echo "  docker compose logs -f"
echo
echo "Szukaj w logach m.in.:"
echo "  - 'Using provided rewards address: ... (qz...)'"
echo "  - peers > 0"
echo "  - 'Successfully mined and submitted a new block'"
echo
echo "Pamiętaj: plik z seedem (keys_dirac_*.txt) zachowaj offline i NIE udostępniaj nikomu."
