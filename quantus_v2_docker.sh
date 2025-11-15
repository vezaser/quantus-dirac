#!/usr/bin/env bash
set -euo pipefail

say() { echo -e "$*"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    say "❌ Uruchom jako root!"
    exit 1
  fi
}

need_root

say "🚀 Quantus DIRAC — instalacja NODE + MINER (Docker)"
say "-----------------------------------------------------"

###############################################################################
# 1) Podstawowe pakiety (BEZ dockera, BEZ containerd)
###############################################################################
say "📦 Sprawdzam / instaluję podstawowe pakiety (curl, wget, git, ca-certificates)..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git ca-certificates

###############################################################################
# 2) Docker — tylko jeśli go NIE ma
###############################################################################
if command -v docker >/dev/null 2>&1; then
    say "🐳 Docker już jest zainstalowany: $(docker --version)"
    say "✔ Pomijam instalację Dockera."
else
    say "🐳 Docker nie znaleziony — instaluję Docker CE (get.docker.com)..."

    curl -fsSL https://get.docker.com | sh

    systemctl enable docker
    systemctl start docker

    say "✔ Docker zainstalowany: $(docker --version)"
fi

###############################################################################
# 3) Katalogi
###############################################################################
BASE="/root/quantus-dirac"
DATA="$BASE/data"

mkdir -p "$BASE" "$DATA"
cd "$BASE"

say "📁 Katalog bazowy: $BASE"
say "📁 Dane chain:     $DATA"

###############################################################################
# 4) quantus-node v0.4.2
###############################################################################
NODE_URL="https://github.com/Quantus-Network/chain/releases/download/v0.4.2/quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz"

say "⬇️ Pobieram quantus-node..."
curl -L "$NODE_URL" -o node.tar.gz
tar xzf node.tar.gz

if [[ ! -f "quantus-node" ]]; then
  say "❌ Nie znaleziono binarki quantus-node po rozpakowaniu!"
  exit 1
fi

install -m 755 quantus-node /usr/local/bin/quantus-node
say "✅ Zainstalowano /usr/local/bin/quantus-node"

###############################################################################
# 5) quantus-miner v0.3.0
###############################################################################
MINER_URL="https://github.com/Quantus-Network/quantus-miner/releases/download/v0.3.0/quantus-miner-linux-x86_64"

say "⬇️ Pobieram quantus-miner..."
curl -L "$MINER_URL" -o quantus-miner
chmod +x quantus-miner
install -m 755 quantus-miner /usr/local/bin/quantus-miner
say "✅ Zainstalowano /usr/local/bin/quantus-miner"

###############################################################################
# 6) Rewards address (zgodnie z MINING.md)
###############################################################################
say ""
say "💰 KONFIGURACJA — ADRES DO NAGRÓD (qz...)"
read -rp "👉 Masz już adres qz...? (t/n): " HAVE

REWARD=""

if [[ "$HAVE" =~ ^[TtYy]$ ]]; then
    read -rp "👉 Podaj adres qz...: " REWARD
else
    say "🪙 Generuję seed + address (quantus-node key quantus)..."
    KEYFILE="$BASE/keys_$(date +%F_%H-%M-%S).txt"

    # Tymczasowo wyłączamy set -e, żeby przypadkowy status !=0 nie zabił skryptu
    set +e
    quantus-node key quantus | tee "$KEYFILE"
    STATUS=$?
    set -e

    if [[ $STATUS -ne 0 ]]; then
        say "❌ Błąd podczas generowania klucza (exit code: $STATUS)."
        say "   Sprawdź ręcznie: quantus-node key quantus"
        exit 1
    fi

    REWARD=$(grep '^Address:' "$KEYFILE" | awk '{print $2}')
    PHRASE=$(grep '^Phrase:' "$KEYFILE" | cut -d':' -f2-)

    if [[ -z "${REWARD:-}" ]]; then
        say "❌ Nie udało się wyciągnąć Address: z $KEYFILE"
        say "   Zawartość pliku:"
        cat "$KEYFILE" || true
        exit 1
    fi

    say "📄 Klucze zapisane w: $KEYFILE"
    say "   Address: $REWARD"
    say "   Seed (24 wyrazy):$PHRASE"
    read -rp "👉 Czy zapisałeś SEED w bezpiecznym miejscu? (t/n): " OK
    [[ "$OK" =~ ^[TtYy]$ ]] || { say "❌ Anulowano"; exit 1; }
fi

say "ℹ️ Używam address: $REWARD"

###############################################################################
# 7) Nazwa noda
###############################################################################
read -rp "👉 Nazwa noda (np. C01): " NAME

###############################################################################
# 8) Worker count (dla minera)
###############################################################################
CPU=$(nproc)
WORKERS=$((CPU>1 ? CPU-1 : 1))
say "⚙️ Ustawiam $WORKERS workerów (CPU: $CPU)"

###############################################################################
# 9) Tworzenie docker-compose.yml
###############################################################################
say "📦 Tworzę docker-compose.yml..."

cat > docker-compose.yml <<EOF
services:
  quantus-node:
    image: ghcr.io/quantus-network/quantus-node:v0.4.2
    container_name: quantus-node
    restart: unless-stopped
    command: >
      --base-path /var/lib/quantus
      --chain dirac
      --name $NAME
      --rewards-address $REWARD
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

###############################################################################
# 10) Start
###############################################################################
say "🚀 Startuję node + miner (docker compose)..."
docker compose down || true
docker compose up -d

say ""
say "🎉 GOTOWE!"
say "   Node logs : docker logs -f quantus-node"
say "   Miner logs: docker logs -f quantus-miner"
say "   Dane      : $DATA"
say "----------------------------------------------"
