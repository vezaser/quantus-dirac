#!/usr/bin/env bash
set -euo pipefail

BASE="/root/quantus-dirac"
DATA="$BASE/data"

echo "🔧 Quantus Permission + Directory Auto-Fix"

cd "$BASE"

echo "📁 Tworzę poprawną strukturę katalogów dla Dirac…"

mkdir -p "$DATA/chains/dirac/db/full"
mkdir -p "$DATA/chains/dirac/network"
mkdir -p "$DATA/chains/dirac/keystore"

echo "🔍 Pobieram UID/GID użytkownika z kontenera…"

docker compose up -d quantus-node >/dev/null 2>&1 || true
sleep 3

NODE_UID=$(docker exec quantus-node id -u 2>/dev/null || echo "0")
NODE_GID=$(docker exec quantus-node id -g 2>/dev/null || echo "0")

echo "ℹ️ UID: $NODE_UID"
echo "ℹ️ GID: $NODE_GID"

echo "🧹 Naprawiam właścicieli katalogów…"
chown -R $NODE_UID:$NODE_GID "$DATA"

echo "🔐 Ustawiam chmod 755…"
chmod -R 755 "$DATA"

echo "🔄 Restart docker-compose…"

docker compose down
docker compose up -d

echo "⏳ Czekam 5 sekund…"
sleep 5

echo "📜 Ostatnie logi noda:"
docker logs --tail 30 quantus-node

echo "✅ FIX COMPLETED"
