#!/usr/bin/env bash
set -euo pipefail

say() {
  echo -e "$*"
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    say "❌ Brak: $1. Zainstaluj i uruchom ponownie."
    exit 1
  }
}

need docker
# przyda się też curl lub wget
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  say "❌ Brak curl ani wget. Zainstaluj (w WSL: 'sudo apt-get install -y curl')."
  exit 1
fi

say "🚀 Quantus DIRAC — node + miner w Dockerze (wersja bez apt-get w kontenerach)"
say "----------------------------------------------------------------------------"

# 0) Sprzątanie
say "🧹 Czyszczę stare kontenery/obrazy..."
docker ps -a --format '{{.Names}}' | grep -E '^quantus-(node|miner)$' >/dev/null 2>&1 && \
  docker stop quantus-node quantus-miner >/dev/null 2>&1 || true
docker rm -f quantus-node quantus-miner >/dev/null 2>&1 || true
docker image rm -f local/quantus-miner:latest >/dev/null 2>&1 || true

# 1) Katalog roboczy
WORKDIR="/root/quantus-dirac"
mkdir -p "$WORKDIR/quantus_node_data"
cd "$WORKDIR"

# 2) Pytania o node
read -rp "👉 Podaj nazwę swojego noda (np. C01): " NODE_NAME

read -rp "👉 Czy masz adres do nagród (qz...)? (t/n): " HAVE_ADDR
REWARD_ADDR=""

if [[ "$HAVE_ADDR" =~ ^[TtYy]$ ]]; then
  read -rp "👉 Wklej adres nagród (qz...): " REWARD_ADDR
else
  say "🔐 Generuję nowy adres w kontenerze z nodem..."
  docker pull ghcr.io/quantus-network/quantus-node:v0.4.2 >/dev/null

  GENFILE="keys_dirac_${NODE_NAME}_$(date +%F_%H-%M-%S).txt"

  docker run --rm ghcr.io/quantus-network/quantus-node:v0.4.2 \
    key generate --scheme dilithium | tee "$GENFILE"

  REWARD_ADDR=$(grep '^Address:' "$GENFILE" | awk '{print $2}')

  if [[ -z "$REWARD_ADDR" ]]; then
    say "❌ Nie udało się odczytać adresu z pliku $GENFILE."
    exit 1
  fi

  say "📁 Klucze zapisane w: $WORKDIR/$GENFILE"
  read -rp "✅ Zapisałeś seed/adres? (t/n): " OK
  [[ "$OK" =~ ^[TtYy]$ ]] || { say "❌ Przerwano przez użytkownika."; exit 1; }
fi

say "ℹ️  Używam adresu nagród: $REWARD_ADDR"
say "ℹ️  Nazwa noda:           $NODE_NAME"

# 3) Pobieramy gotowy binarek quantus-miner na hosta (do katalogu roboczego)
MINER_URL="https://github.com/Quantus-Network/quantus-miner/releases/download/v0.3.0/quantus-miner-linux-x86_64"
say "⬇️  Pobieram quantus-miner z:"
say "    $MINER_URL"

if command -v curl >/dev/null 2>&1; then
  curl -L "$MINER_URL" -o quantus-miner
else
  wget -O quantus-miner "$MINER_URL"
fi

chmod +x quantus-miner

# 4) Tworzymy prosty Dockerfile.miner BEZ apt-get
cat > Dockerfile.miner <<'EOF'
FROM debian:bullseye-slim

# prosty user, bez apt-get
RUN useradd -m miner

# binarka dostarczona z kontekstu builda
COPY quantus-miner /usr/local/bin/quantus-miner

USER miner
EXPOSE 9833

ENTRYPOINT ["quantus-miner"]
EOF

say "🛠  Buduję obraz minera (local/quantus-miner:latest) — bez apt-get..."
docker build -f Dockerfile.miner -t local/quantus-miner:latest .

# 5) Obliczamy liczbę wątków dla minera
CPUS=$(nproc 2>/dev/null || echo 2)
WORKERS=$(( CPUS>1 ? CPUS-1 : 1 ))
say "⚙️  Workerów dla minera: $WORKERS (CPU: $CPUS)"

# 6) docker-compose.yml (node + miner)
cat > docker-compose.yml <<EOF
services:
  quantus-node:
    image: ghcr.io/quantus-network/quantus-node:v0.4.2
    container_name: quantus-node
    restart: unless-stopped
    command:
      - --validator
      - --base-path
      - /var/lib/quantus
      - --chain
      - dirac
      - --node-key-file
      - /var/lib/quantus/node_key
      - --rewards-address
      - $REWARD_ADDR
      - --name
      - $NODE_NAME
      - --execution
      - native-else-wasm
      - --wasm-execution
      - compiled
      - --db-cache
      - "2048"
      - --unsafe-rpc-external
      - --rpc-cors
      - all
      - --in-peers
      - "256"
      - --out-peers
      - "256"
      - --external-miner-url
      - http://quantus-miner:9833
      - --bootnodes
      - /dns/q.boot.quantus.network/tcp/31337/p2p/12D3KooWRPZzBFe6KJzrqVgHut1R4x1vXhY2hzYo2f8fy8p2y5Aa
      - --bootnodes
      - /dns/q.boot.quantus.network/udp/31337/quic-v1/p2p/12D3KooWRPZzBFe6KJzrqVgHut1R4x1vXhY2hzYo2f8fy8p2y5Aa
    volumes:
      - ./quantus_node_data:/var/lib/quantus
    ports:
      - "30333:30333/tcp"
      - "30333:30333/udp"
      - "9944:9944"
      - "9616:9616"

  quantus-miner:
    image: local/quantus-miner:latest
    container_name: quantus-miner
    restart: unless-stopped
    command: ["--engine","cpu-fast","--port","9833","--workers","$WORKERS"]
    depends_on:
      - quantus-node
EOF

# 7) Start
say "🐳 Uruchamiam docker compose (node + miner)..."
docker compose up -d

# 8) Krótki podgląd logów
say "⏳ Czekam 10 sekund i pokazuję logi..."
sleep 10

say "----- NODE (ostatnie linie) -----"
docker logs --since 30s quantus-node 2>&1 | tail -n 50 || true

say "----- MINER (ostatnie linie) ----"
docker logs --since 30s quantus-miner 2>&1 | tail -n 50 || true

say "---------------------------------"
say "✅ GOTOWE!"
say " • Katalog:  $WORKDIR"
say " • Node:     $NODE_NAME"
say " • Rewards:  $REWARD_ADDR"
say ""
say "Sprawdź:"
say "  docker ps"
say "  docker logs -f quantus-node"
say "  docker logs -f quantus-miner"
