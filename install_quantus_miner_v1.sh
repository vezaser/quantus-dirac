#!/usr/bin/env bash
set -euo pipefail

echo "🚀 Instalator Quantus Miner v1.0.0 (Docker)"

# 1. Sprawdzenie, czy jest docker
if ! command -v docker &>/dev/null; then
  echo "❌ Brak dockera! Zainstaluj docker przed uruchomieniem tego skryptu."
  exit 1
fi

# 2. Podstawowe pakiety (git do klonowania)
echo "📦 Instaluję wymagane pakiety (git)..."
apt-get update -y >/dev/null
apt-get install -y git >/dev/null

# 3. Klonowanie / aktualizacja repo quantus-miner
cd /root

if [ -d "/root/quantus-miner" ]; then
  echo "📁 Katalog /root/quantus-miner już istnieje — aktualizuję repo..."
  cd /root/quantus-miner
  git fetch --all --tags
else
  echo "📥 Klonuję repozytorium quantus-miner..."
  git clone https://github.com/Quantus-Network/quantus-miner.git
  cd /root/quantus-miner
fi

echo "🔀 Przełączam na tag v1.0.0..."
git checkout v1.0.0

# 4. Tworzenie / nadpisanie Dockerfile
echo "🧾 Tworzę Dockerfile dla quantus-miner v1.0.0..."
cat > Dockerfile << 'EOF'
FROM rust:1.82 as builder
WORKDIR /app
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim
WORKDIR /app
RUN apt-get update -y && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/quantus-miner /usr/local/bin/quantus-miner
ENTRYPOINT ["quantus-miner"]
EOF

# 5. Budowa obrazu Docker
echo "🐳 Buduję obraz local/quantus-miner:latest..."
docker build -t local/quantus-miner:latest .

echo "✅ Obraz zbudowany. Dostępne obrazy:"
docker images | grep quantus-miner || true

# 6. Restart docker-compose w /root/quantus-dirac
if [ -d "/root/quantus-dirac" ]; then
  echo "🔁 Restartuję docker compose w /root/quantus-dirac (node + miner)..."
  cd /root/quantus-dirac
  docker compose down
  docker compose up -d

  echo "📊 Status kontenerów Quantus:"
  docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' | grep quantus || true
else
  echo "⚠️ Uwaga: katalog /root/quantus-dirac nie istnieje."
  echo "   Skrypt NIE uruchomił docker-compose. Zadbaj, aby node był skonfigurowany tam wcześniej."
fi

echo "🎉 Gotowe. Quantus Miner v1.0.0 zbudowany jako local/quantus-miner:latest."
