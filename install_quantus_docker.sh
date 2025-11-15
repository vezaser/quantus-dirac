#!/usr/bin/env bash
set -euo pipefail

say() { echo -e "$*"; }

# ----------------------------------------
#  AUTOMATYCZNA INSTALACJA DOCKERA
# ----------------------------------------
install_docker() {
  say "🐳 Instaluję Docker..."

  if command -v apt-get >/dev/null 2>&1; then
    # Ubuntu / Debian
    apt-get update -y
    apt-get install -y \
      ca-certificates \
      curl \
      gnupg \
      lsb-release

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" \
      -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
$(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list

    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now docker || true
    fi

  elif command -v dnf >/dev/null 2>&1; then
    # Fedora / CentOS / Rocky / Alma
    dnf -y install dnf-plugins-core
    # Spróbuj repo Fedory, jeśli się nie uda – repo CentOS
    dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo || \
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

    dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

    if command -v systemctl >/dev/null 2>&1; then
      systemctl enable --now docker || true
    fi

  else
    say "❌ Nie mogę automatycznie zainstalować Dockera na tym systemie."
    say "Zainstaluj Docker ręcznie i uruchom skrypt ponownie."
    exit 1
  fi

  say "✅ Docker zainstalowany."
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
  read -rp "🔗 Wklej adres nagród (qz...): " REWARD_ADDR
else
  say "🪙 Generuję nowy adres w kontenerze nodowym..."
  docker pull ghcr.io/quantus-network/quantus-node:v0.4.2 >/dev/null
  GENFILE="keys_dirac_${NODE_NAME}_$(date +%F_%H-%M-%S).txt"
  docker run --rm ghcr.io/quantus-network/quantus-node:v0.4.2 \
    key generate --scheme dilithium | tee "$GENFILE" >/dev/null
  REWARD_ADDR=$(grep '^Address:' "$GENFILE" | awk '{print $2}')
  [[ -n "$REWARD_ADDR" ]] || { say "❌ Nie udało się odczytać adresu."; exit 1; }
  say "📄 Klucze zapisane: $WORKDIR/$GENFILE"
  read -rp "✅ Zapisałeś seed/adres? (t/n): " OK
  [[ "$OK" =~ ^[TtYy]$ ]] || { say "❌ Przerwano."; exit 1; }
fi

# 3) Dockerfile dla minera (build from source w obrazie)
cat > Dockerfile.miner <<'EOF'
FROM rust:1.81-bullseye AS builder
# Zależności do niektórych crate'ów
RUN apt-get update -y && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev clang cmake git ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /src
# Pobranie źródeł
RUN git clone https://github.com/Quantus-Network/quantus-miner .
# Próba przejścia na tag v1.0 (jeśli istnieje)
ARG MINER_TAG=v1.0
RUN git fetch --all --tags -q && (git checkout -q "${MINER_TAG}" || true)
# Build
RUN cargo build --release

FROM debian:bullseye-slim
RUN useradd -m miner && \
    apt-get update -y && apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/target/release/quantus-miner /usr/local/bin/quantus-miner
USER miner
EXPOSE 9833
# Domyślne: silnik CPU FAST, port 9833; WORKERS nadpiszesz w compose
ENTRYPOINT ["quantus-miner"]
EOF

say "🧱 Buduję obraz minera (local/quantus-miner:latest)..."
docker build -f Dockerfile.miner -t local/quantus-miner:latest --build-arg MINER_TAG=v1.0 .

# 4) Wylicz workers (rdzenie-1, minimum 1)
CPUS=$(nproc 2>/dev/null || echo 2)
WORKERS=$(( CPUS>1 ? CPUS-1 : 1 ))

# 5) docker-compose.yml (bez przestarzałego 'version')
cat > docker-compose.yml <<EOF
services:
  quantus-node:
    image: ghcr.io/quantus-network/quantus-node:v0.4.2
    container_name: quantus-node
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
      - ./quantus_node_data:/var/lib/quantus
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

# 6) Start
say "🐳 Uruchamiam Docker Compose (node + miner)..."
docker_compose up -d

# 7) Krótki health-check
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
say "   • Sprawdź: docker ps"
say "   • Logi node:  docker logs -f quantus-node"
say "   • Logi miner: docker logs -f quantus-miner"
