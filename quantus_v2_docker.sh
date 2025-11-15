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
# 0) Usuwamy WSZYSTKO, co powoduje konflikt (docker.io, containerd.io)
###############################################################################
say "🧹 Czyszczę stare pakiety docker.io / containerd..."

apt-get remove -y docker.io docker-compose-plugin containerd.io containerd runc || true
apt-get autoremove -y || true

###############################################################################
# 1) Instalacja Docker CE (tylko z get.docker.com)
###############################################################################
say "🐳 Instaluję Docker CE (get.docker.com)..."

curl -fsSL https://get.docker.com | sh

systemctl enable docker
systemctl start docker

say "✅ Docker działa: $(docker --version)"

###############################################################################
# 2) Katalogi
###############################################################################
BASE="/root/quantus-dirac"
DATA="$BASE/data"

mkdir -p "$BASE" "$DATA"
cd "$BASE"

###############################################################################
# 3) quantus-node v0.4.2
###############################################################################
NODE_URL="https://github.com/Quantus-Network/chain/releases/download/v0.4.2/quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz"

say "⬇️ Pobieram quantus-node..."
curl -L "$NODE_URL" -o node.tar.gz
tar xzf node.tar.gz

install -m 755 quantus-node /usr/local/bin/quantus-node

###############################################################################
# 4) quantus-miner v0.3.0
###############################################################################
MINER_URL="https://github.com/Quantus-Network/quantus-miner/releases/download/v0.3.0/quantus-miner-linux-x86_64"

say "⬇️ Pobieram quantus-miner..."
curl -L "$MINER_URL" -o quantus-miner
chmod +x quantus-miner
install -m 755 quantus-miner /usr/local/bin/quantus-miner

###############################################################################
# 5) Rewards address (zgodne z MINING.md)
###############################################################################
say "💰 Czy masz adres qz...? (t/n)"
read HAVE

if [[ "$HAVE" =~ ^[TtYy]$ ]]; then
    read -rp "👉 Podaj adres qz...: " REWARD
else
    say "🪙 Generuję seed + address (quantus-node key quantus)..."
    KEYFILE="$BASE/keys_$(date +%F_%H-%M-%S).txt"

    quantus-node key quantus | tee "$KEYFILE"

    REWARD=$(grep '^Address:' "$KEYFILE" | awk '{print $2}')
    PHRASE=$(grep '^Phrase:' "$KEYFILE" | cut -d':' -f2-)

    say "📁 Klucze zapisane w $KEYFILE"
    say "   Address: $REWARD"
    say "   Seed: $PHRASE"
fi

say "ℹ️ Używam address: $REWARD"

###############################################################################
# 6) Node name
###############################################################################
read -rp "👉 Nazwa noda (np. C01): " NAME

###############################################################################
# 7) Worker count
###############################################################################
CPU=$(nproc)
WORKERS=$((CPU>1 ? CPU-1 : 1))

###############################################################################
# 8) Tworzenie docker-compose.yml
###############################################################################
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
# 9) Start
###############################################################################
docker compose down || true
docker compose up -d

say ""
say "🎉 GOTOWE!"
say "   Node logs : docker logs -f quantus-node"
say "   Miner logs: docker logs -f quantus-miner"
say "----------------------------------------------"
