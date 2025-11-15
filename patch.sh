#!/usr/bin/env bash
set -euo pipefail

BASE="/root/quantus-dirac"
DATA="$BASE/data"

echo "🔧 Quantus Permission Auto-Fix"
echo "📁 Katalog z danymi: $DATA"

cd "$BASE"

# Sprawdzamy czy kontener node działa
if ! docker ps --format '{{.Names}}' | grep -q '^quantus-node$'; then
  echo "⚠️ Kontener quantus-node nie działa — uruchamiam go chwilowo..."
  docker compose up -d quantus-node
  sleep 3
fi

echo "🔍 Pobieram UID/GID użytkownika wewnątrz kontenera quantus-node..."

NODE_UID=$(docker exec quantus-node id -u 2>/dev/null || echo "0")
NODE_GID=$(docker exec quantus-node id -g 2>/dev/null || echo "0")

if [[ -z "$NODE_UID" || -z "$NODE_GID" ]]; then
  echo "❌ Nie udało się pobrać UID/GID z kontenera."
  exit 1
fi

echo "ℹ️  Node UID: $NODE_UID"
echo "ℹ️  Node GID: $NODE_GID"

echo "📦 Zatrzymuję kontenery..."
docker compose down || true

echo "🧹 Naprawiam właściciela katalogu data/..."
chown -R $NODE_UID:$NODE_GID "$DATA"

echo "🛂 Ustawiam chmod 755..."
chmod -R 755 "$DATA"

echo "🚀 Startuję kontenery ponownie..."
docker compose up -d

echo "⏳ Czekam 5 sekund..."
sleep 5

echo "🔎 Sprawdzam logi noda..."
docker logs --tail 20 quantus-node

echo ""
echo "✅ FIX ZAKOŃCZONY!"
echo "Jeśli w logach nie ma już 'Permission denied', node powinien działać."
echo "Aby śledzić logi na żywo:"
echo "   docker logs -f quantus-node"
