#!/usr/bin/env bash
set -euo pipefail

say() {
  echo -e "$*"
}

# Sprawdzenie wymaganych narzędzi
need() {
  command -v "$1" >/dev/null 2>&1 || {
    say "❌ Brak: $1. Zainstaluj i uruchom ponownie."
    exit 1
  }
}

need docker

say "🚀 Quantus (DIRAC) — Node + Miner w Dockerze"
say "---------------------------------------------"

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

# 2) Pytania
read -rp "👉 Podaj nazwę swojego noda (np. C01): " NODE_NAME

read -rp "👉 Czy masz adres do nagród? (t/n): " HAVE_ADDR
REWARD_ADDR=""

if [[ "$HAVE_ADDR" =~ ^[TtYy]$ ]]; then
  read -rp "👉 Wklej adres nagród (qz...): " REWARD_ADDR
else
  say "🔐 Generuję nowy adres w kontenerze nodowym..."
  docker pull ghcr.io/quantus-network/quantus-node:v0.4.2 >/dev/null

  GENFILE="keys_dirac_${NODE_NAME}_$(date +%F_%H-%M-%S).txt"

  docker run --rm ghcr.io/quantus-network/quantus-node:v0.4.2 \
    key generate --scheme dilithium | tee "$GENFILE" >/dev/null

  REWARD_ADDR=$(grep '^Address:' "$GENFILE" | awk '{print $2}')

  [[ -n "$REWARD_ADDR" ]] || {
    say "❌ Nie udało się odczytać adresu z pliku $GENFILE."
    exit 1
  }

  say "📁 Klucze zapisane: $WORKDIR/$GENFILE"
  read -rp "✅ Zapisałeś seed/adres? (t/n): " OK
  [[ "$OK" =~ ^[TtYy]$ ]] || {
    say "❌ Przerwano przez użytkownika."
    exit 1
  }
fi

say "ℹ️  Użyję adresu nagród: $REWARD_ADDR"
say "ℹ️  Nazwa noda: $NODE_NAME"

# 3) Dockerfile dla minera (build from source w obrazie)
cat > Dockerfile.miner <<'EOF'
FROM rust:1.81-bullseye AS builder

# Zależności do niektórych crate'ów
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev clang cmake git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Pobranie źródeł
RUN git clone https://github.com/Quantus-Network/quantus-miner .

# Próba przejścia na tag v1.0 (jeśli istnieje)
ARG MINER_TAG=v1.0
RUN git fetch --all --tags -q && (git checkout -q "${MINER_TAG}" || true)

# Build
RUN cargo build --release

# Runtime na Ubuntu (stabilniejsze repozytoria niż debian-slim na części sieci)
FROM ubuntu:24.04

RUN useradd -m miner && \
    apt-get update -y && apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/target/release/quantus-miner /usr/local/bin/quantus-miner

USER miner

EXPOSE 9833

# Domyślne: silnik CPU FAST, port 9833; WORKERS nadpiszesz w compose
ENTRYPOINT ["quantus-miner"]
EOF

say "🛠  Buduję obraz minera (local/quantus-miner:latest)..."
docker build -f Dockerfile.miner -t local/quantus-miner:latest --build-arg MINER_TAG=v1.0 .

# 4) Wylicz workers (rdzenie-1, minimum 1)
CPUS=$(nproc 2>/dev/null || echo 2)
WORKERS=$(( CPUS>1 ? CPUS-1 : 1 ))
say "⚙️  Workerów dla minera: $WORKERS (CPU: $CPUS)"

# 5) docker-compose.yml (bez przestarzałego 'version')
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

# 6) Start
say "🐳 Uruchamiam Docker Compose (node + miner)..."
docker compose up -d

# 7) Krótki health-check
say "⏳ Czekam 10s i sprawdzam logi..."
sleep 10

say "----- NODE (ostatnie linie) -----"
docker logs --since 30s quantus-node 2>&1 | tail -n 50 || true

say "----- MINER (ostatnie linie) ----"
docker logs --since 30s quantus-miner 2>&1 | tail -n 50 || true

say "---------------------------------"
say "✅ GOTOWE!"
say " • Node:   $NODE_NAME"
say " • Rewards: $REWARD_ADDR"
say " • Sprawdź:   docker ps"
say " • Logi node: docker logs -f quantus-node"
say " • Logi miner: docker logs -f quantus-miner"
