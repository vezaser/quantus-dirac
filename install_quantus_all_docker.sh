#!/usr/bin/env bash
set -euo pipefail

say() { echo -e "$*"; }

# ----------------------------------------
#  AUTOMATYCZNA INSTALACJA DOCKERA (Ubuntu/Debian/Fedora/Rocky/Alma/CentOS)
# ----------------------------------------
install_docker() {
  say "🐳 Instaluję Docker (get.docker.com)..."

  # Upewnij się, że jest curl
  if ! command -v curl >/dev/null 2>&1; then
    say "ℹ️ Brak curl – instaluję..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y
      apt-get install -y curl
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y curl
    elif command -v yum >/dev/null 2>&1; then
      yum install -y curl
    else
      say "❌ Nie mogę zainstalować curl (brak apt/dnf/yum). Zainstaluj curl ręcznie i uruchom skrypt ponownie."
      exit 1
    fi
  fi

  # Oficjalny skrypt Dockera – działa na większości dystrybucji
  curl -fsSL https://get.docker.com | sh

  # Włącz usługę docker (jeśli jest systemd)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker || true
  fi

  say "✅ Docker zainstalowany (get.docker.com)."
}

# Jeśli Docker nie jest zainstalowany → instaluj
if ! command -v docker >/dev/null 2>&1; then
  say "⚠️ Docker nie jest zainstalowany — próbuję zainstalować automatycznie..."
  install_docker
fi

say "✔️ Docker wykryty: $(docker --version 2>/dev/null || echo OK)"

# Helper dla docker compose / docker-compose
docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    say "❌ Nie znaleziono docker compose ani docker-compose."
    say "Zainstaluj Docker Compose (plugin lub binary) i spróbuj ponownie."
    exit 1
  fi
}

say "🚀 Quantus (DIRAC) — Node + Miner w Dockerze (ALL-IN-ONE)"
say "---------------------------------------------------------"

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

# 2) Pobranie binarki quantus-node, jeśli nie ma
if [[ ! -x "$WORKDIR/quantus-node" ]]; then
  say "⬇️ Pobieram quantus-node v0.4.2 (binarna)..."
  URL="https://github.com/Quantus-Network/chain/releases/download/v0.4.2/quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz"
  curl -L "$URL" -o quantus-node.tar.gz
  tar xzf quantus-node.tar.gz
  chmod +x quantus-node
  rm -f quantus-node.tar.gz
  say "✅ Binarka quantus-node gotowa: $WORKDIR/quantus-node"
fi

# 3) Generowanie node_key, jeśli nie istnieje
NODE_KEY_PATH="$WORKDIR/quantus_node_data/node_key"
if [[ ! -f "$NODE_KEY_PATH" ]]; then
  say "🔑 Brak node_key – generuję nowy klucz węzła..."
  ./quantus-node key generate-node-key --file "$NODE_KEY_PATH"
  chmod 600 "$NODE_KEY_PATH"
  say "✅ node_key zapisany w: $NODE_KEY_PATH (chmod 600)"
else
  say "ℹ️ Istnieje już node_key w: $NODE_KEY_PATH – używam istniejącego."
fi

# 4) Pytania o node + adres nagród
read -rp "👉 Podaj nazwę swojego noda (np. C01): " NODE_NAME
read -rp "👉 Czy masz adres do nagród? (t/n): " HAVE_ADDR

REWARD_ADDR=""
if [[ "$HAVE_ADDR" =~ ^[TtYy]$ ]]; then
  read -rp "🔗 Wklej adres nagród (qz...): " REWARD_ADDR
else
  say "🪙 Generuję nowy adres (Dilithium) lokalnie binarką quantus-node..."
  GENFILE="keys_dirac_${NODE_NAME}_$(date +%F_%H-%M-%S).txt"
  ./quantus-node key generate --scheme dilithium | tee "$GENFILE" >/dev/null
  REWARD_ADDR=$(grep '^Address:' "$GENFILE" | awk '{print $2}')
  [[ -n "$REWARD_ADDR" ]] || { say "❌ Nie udało się odczytać adresu z pliku ${GENFILE}."; exit 1; }
  say "📄 Klucze zapisane: $WORKDIR/$GENFILE"
  read -rp "✅ Zapisałeś seed/adres? (t/n): " OK
  [[ "$OK" =~ ^[TtYy]$ ]] || { say "❌ Przerwano."; exit 1; }
fi

# 5) Ustalenie sufiksu volume (SELinux :Z na Fedory/Rocky/Alma)
VOLUME_SUFFIX=""
if command -v getenforce >/dev/null 2>&1; then
  if [[ "$(getenforce 2>/dev/null || echo Permissive)" == "Enforcing" ]]; then
    VOLUME_SUFFIX=":Z"
  fi
fi

# 6) Dockerfile dla minera (build from source w obrazie)
cat > Dockerfile.miner <<'EOF'
FROM rust:1.81-bullseye AS builder
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev clang cmake git ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone https://github.com/Quantus-Network/quantus-miner .
ARG MINER_TAG=v1.0
RUN git fetch --all --tags -q && (git checkout -q "${MINER_TAG}" || true)
RUN cargo build --release

FROM debian:bullseye-slim
RUN useradd -m miner && \
    apt-get update -y && apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/target/release/quantus-miner /usr/local/bin/quantus-miner
USER miner
EXPOSE 9833
ENTRYPOINT ["quantus-miner"]
EOF

say "🧱 Buduję obraz minera (local/quantus-miner:latest)..."
docker build -f Dockerfile.miner -t local/quantus-miner:latest --build-arg MINER_TAG=v1.0 .

# 7) Wylicz workers (rdzenie-1, minimum 1)
CPUS=$(nproc 2>/dev/null || echo 2)
WORKERS=$(( CPUS>1 ? CPUS-1 : 1 ))

# 8) docker-compose.yml – z node_key, --node-key-file i user: \"0:0\"
cat > docker-compose.yml <<EOF
services:
  quantus-node:
    image: ghcr.io/quantus-network/quantus-node:v0.4.2
    container_name: quantus-node
    user: "0:0"
    restart: unless-stopped
    command: >
      --validator
      --base-path /var/lib/quantus
      --chain dirac
      --node-key-file /var/lib/quantus/node_key
      --rewards-address ${REWARD_ADDR}
      --name ${NODE_NAME}
      --execution native-else-wasm
      --wasm-execution compiled
      --db-cache 2048
      --unsafe-rpc-external
      --rpc-cors all
      --in-peers 256
      --out-peers 256
      --external-miner-url http://quantus-miner:9833
    volumes:
      - ./quantus_node_data:/var/lib/quantus${VOLUME_SUFFIX}
    ports:
      - "30333:30333"
      - "9944:9944"

  quantus-miner:
    image: local/quantus-miner:latest
    container_name: quantus-miner
    restart: unless-stopped
    command: ["--engine","cpu-fast","--port","9833","--workers","${WORKERS}"]
    depends_on:
      - quantus-node
EOF

# 9) Start
say "🐳 Uruchamiam Docker Compose (node + miner)..."
docker_compose up -d

# 10) Krótki health-check
say "⏳ Czekam 10s i sprawdzam logi..."
sleep 10
say "----- NODE (ostatnie linie) -----"
docker logs --since 30s quantus-node 2>&1 | tail -n 50 || true
say "----- MINER (ostatnie linie) ----"
docker logs --since 30s quantus-miner 2>&1 | tail -n 50 || true
say "---------------------------------"

say "🎯 GOTOWE!"
say "   • Node: ${NODE_NAME}"
say "   • Rewards: ${REWARD_ADDR}"
say "   • Logi node:  docker logs -f quantus-node"
say "   • Logi miner: docker logs -f quantus-miner"
