#!/usr/bin/env bash
set -u
set -o pipefail

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
# 1) Podstawowe pakiety
###############################################################################
apt-get update -y
apt-get install -y curl wget git ca-certificates

###############################################################################
# 2) Docker — tylko jeśli nie ma
###############################################################################
if command -v docker >/dev/null 2>&1; then
    say "🐳 Docker już jest: $(docker --version)"
else
    say "🐳 Instaluję Docker CE..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
fi

###############################################################################
# 3) Katalogi
###############################################################################
BASE="/root/quantus-dirac"
DATA="$BASE/data"

mkdir -p "$DATA"
cd "$BASE"

###############################################################################
# 4) Pobieranie binarek
###############################################################################
NODE_URL="https://github.com/Quantus-Network/chain/releases/download/v0.4.2/quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz"
MINER_URL="https://github.com/Quantus-Network/quantus-miner/releases/download/v0.3.0/quantus-miner-linux-x86_64"

curl -L "$NODE_URL" -o node.tar.gz
tar xzf node.tar.gz
install -m 755 quantus-node /usr/local/bin/quantus-node

curl -L "$MINER_URL" -o quantus-miner
chmod +x quantus-miner
install -m 755 quantus-miner /usr/local/bin/quantus-miner

###############################################################################
# 5) Rewards address — wersja 100% stabilna
###############################################################################
say "💰 Masz adres qz...? (t/n)"
read HAVE

if [[ "$HAVE" =~ ^[TtYy]$ ]]; then
    read -rp "👉 Podaj adres qz...: " REWARD
else
    say "🪙 Generuję seed i adres..."

    KEYFILE="$BASE/keys_$(date +%F_%H-%M-%S).txt"

    # Wyłączamy pipefail i set -e TYLKO tu
    set +e
    /usr/local/bin/quantus-node key quantus > "$KEYFILE" 2>&1
    set -e

    REWARD=$(grep -m1 '^Address:' "$KEYFILE" | awk '{print $2}')
    PHRASE=$(grep -m1 '^Phrase:' "$KEYFILE" | cut -d':' -f2-)

    if [[ -z "$REWARD" ]]; then
        say "❌ Nie udało się odczytać Address z pliku:"
        cat "$KEYFILE"
        exit 1
    fi

    say "📄 Klucze: $KEYFILE"
    say "   Address: $REWARD"
    say "   Seed: $PHRASE"

    read -rp "👉 Zapisałeś seed? (t/n): " OK
    [[ "$OK" =~ ^[TtYy]$ ]] || exit 1
fi

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
# 8) POPRAWIONY docker-compose — działa!
###############################################################################
cat > docker-compose.yml <<EOF
services:
  quantus-node:
    user: root
    image: ghcr.io/quantus-network/quantus-node:v0.4.2
    container_name: quantus-node
    restart: unless-stopped
    command: >
      --base-path /var/lib/quantus
      --chain dirac
      --name $NAME
      --rewards-address $REWARD
      --unsafe-rpc-external
      --rpc-cors all
      --external-miner-url http://quantus-miner:9833
    volumes:
      - ./data:/var/lib/quantus
    ports:
      - "30333:30333"
      - "9944:9944"

  quantus-miner:
    user: root
    container_name: quantus-miner
    image: alpine:latest
    restart: unless-stopped
    command: ["/usr/local/bin/quantus-miner","--engine","cpu-fast","--port","9833","--workers","$WORKERS"]
    volumes:
      - /usr/local/bin/quantus-miner:/usr/local/bin/quantus-miner
EOF

###############################################################################
# 9) Fix permissions (NAPRAWIA twój błąd!)
###############################################################################
chown -R root:root "$DATA"

###############################################################################
# 10) Start
###############################################################################
docker compose down || true
docker compose up -d

say "🎉 GOTOWE!"
say "   ➜ docker logs -f quantus-node"
say "   ➜ docker logs -f quantus-miner"
