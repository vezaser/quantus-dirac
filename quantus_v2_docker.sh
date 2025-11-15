#!/usr/bin/env bash
set -euo pipefail

say() { echo -e "$*"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    say "❌ Uruchom jako root:"
    say "   sudo $0"
    exit 1
  fi
}

need_root

say "🚀 Quantus DIRAC — instalacja node + miner (Docker)"
say "    ✔ w pełni zgodne z MINING.md"
say "-----------------------------------------------------"

### 1) Pakiety systemowe
say "📦 Instaluję wymagane pakiety..."
export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y \
  curl wget git ca-certificates \
  docker.io docker-compose-plugin

systemctl enable docker
systemctl start docker

### 2) Katalog bazowy
BASE="/root/quantus-dirac"
DATA="$BASE/data"

mkdir -p "$BASE" "$DATA"

cd "$BASE"

say "📁 Katalog bazowy: $BASE"

### 3) Pobieranie quantus-node (DIRAC v0.4.2)
NODE_URL="https://github.com/Quantus-Network/chain/releases/download/v0.4.2/quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz"
NODE_TAR="node.tar.gz"

say "⬇️ Pobieram quantus-node v0.4.2..."
curl -L "$NODE_URL" -o "$NODE_TAR"
tar xzf "$NODE_TAR"

if [[ ! -f "quantus-node" ]]; then
  say "❌ Błąd: nie znaleziono binarki quantus-node po rozpakowaniu!"
  exit 1
fi

install -m 755 quantus-node /usr/local/bin/quantus-node
say "✅ Zainstalowano quantus-node"

### 4) Pobieranie quantus-miner (v0.3.0)
MINER_URL="https://github.com/Quantus-Network/quantus-miner/releases/download/v0.3.0/quantus-miner-linux-x86_64"

say "⬇️ Pobieram quantus-miner v0.3.0..."
curl -L "$MINER_URL" -o quantus-miner
chmod +x quantus-miner
install -m 755 quantus-miner /usr/local/bin/quantus-miner

say "✅ Zainstalowano quantus-miner"

### 5) Adres nagród — zgodnie z MINING.md
say ""
say "💰 KONFIGURACJA ADRESU NAGRÓD (wg MINING.md)"
read -rp "👉 Masz już adres qz...? (t/n): " HAVE

REWARD_ADDR=""

if [[ "$HAVE" =~ ^[TtYy]$ ]]; then
  read -rp "👉 Wklej adres qz...: " REWARD_ADDR
else
  say "🪙 Generuję nowy adres: quantus-node key quantus..."
  KEYFILE="$BASE/keys_rewards_$(date +%F_%H-%M-%S).txt"

  # NIE Dilithium – tylko SR25519 (mining.md)
  quantus-node key quantus | tee "$KEYFILE"

  REWARD_ADDR=$(grep '^Address:' "$KEYFILE" | awk '{print $2}')
  PHRASE=$(grep '^Phrase:' "$KEYFILE" | cut -d':' -f2-)

  if [[ -z "$REWARD_ADDR" ]]; then
    say "❌ Nie udało się wyciągnąć Address: z $KEYFILE"
    exit 1
  fi

  say "📄 Klucze zapisane w: $KEYFILE"
  say "   Address: $REWARD_ADDR"
  say "   SEED (24 słowa): $PHRASE"

  read -rp "👉 Czy zapisałeś SEED w bezpiecznym miejscu? (t/n): " OK
  [[ "$OK" =~ ^[TtYy]$ ]] || { say "❌ Anulowano"; exit 1; }
fi

say "ℹ️ Używam address: $REWARD_ADDR"

### 6) Nazwa noda
read -rp "👉 Podaj nazwę noda (np. C01): " NODE_NAME

### 7) Liczba workerów minera
CPUS=$(nproc)
WORKERS=$((CPUS>1 ? CPUS-1 : 1))

say "⚙️ Miner workers: $WORKERS (CPU: $CPUS)"

### 8) Tworzenie docker-compose.yml
cat > docker-compose.yml <<EOF
services:
  quantus-node:
    image: ghcr.io/quantus-network/quantus-node:v0.4.2
    container_name: quantus-node
    restart: unless-stopped
    command: >
      --base-path /var/lib/quantus
      --chain dirac
      --name $NODE_NAME
      --rewards-address $REWARD_ADDR
      --execution native-else-wasm
      --wasm-execution compiled
      --db-cache 2048
      --unsafe-rpc-external
      --rpc-cors all
      --in-peers 256
      --out-peers 256
      --external-miner-url http://quantus-miner:9833
      --bootnodes /dns/q.boot.quantus.network/tcp/31337/p2p/12D3KooWRPZzBFe6KJzrqVgHut1R4x1vXhY2hzYo2f8fy8p2y5Aa
      --bootnodes /dns/q.boot.quantus.network/udp/31337/quic-v1/p2p/12D3KooWRPZzBFe6KJzrqVgHut1R4x1vXhY2hzYo2f8fy8p2y5Aa
    volumes:
      - ./data:/var/lib/quantus
    ports:
      - "30333:30333"
      - "9944:9944"

  quantus-miner:
    container_name: quantus-miner
    image: alpine:latest
    restart: unless-stopped
    command: ["/usr/local/bin/quantus-miner","--engine","cpu-fast","--port","9833","--workers","$WORKERS"]
    volumes:
      - /usr/local/bin/quantus-miner:/usr/local/bin/quantus-miner
    depends_on:
      - quantus-node
EOF

### 9) Start
say "🚀 Uruchamiam Docker Compose..."
docker compose down || true
docker compose up -d

say ""
say "✅ GOTOWE!"
say "   Dane:     $BASE/data"
say "   Node:     docker logs -f quantus-node"
say "   Miner:    docker logs -f quantus-miner"
say ""
say "🌐 Po kilku minutach powinno być widać peery + joby miningowe."
