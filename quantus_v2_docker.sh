#!/usr/bin/env bash
set -euo pipefail

say() { echo -e "$*"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    say "❌ Ten skrypt uruchom jako root:"
    say "   sudo $0"
    exit 1
  fi
}

need_root

say "🚀 Quantus DIRAC – node + miner z GOTOWYCH binarek (bez Dockera, bez kompilacji)"
say "-------------------------------------------------------------------------------"

# =====================================================================
# 1) Pakiety systemowe
# =====================================================================
say "📦 Instaluję podstawowe pakiety (Ubuntu/WSL)..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  curl \
  wget \
  ca-certificates \
  tmux

# =====================================================================
# 2) Katalog bazowy
# =====================================================================
BASE_DIR="/root/quantus-mining"
DATA_DIR="$BASE_DIR/data"

mkdir -p "$BASE_DIR" "$DATA_DIR"
cd "$BASE_DIR"

say "📁 Katalog bazowy: $BASE_DIR"
say "📁 Dane chain:     $DATA_DIR"

# =====================================================================
# 3) Pobieranie quantus-node v0.4.2 (DIRAC)
# =====================================================================
NODE_URL="https://github.com/Quantus-Network/chain/releases/download/v0.4.2/quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz"
NODE_TAR="quantus-node-v0.4.2-x86_64-unknown-linux-gnu.tar.gz"

say "⬇️  Pobieram quantus-node v0.4.2:"
say "    $NODE_URL"

curl -L "$NODE_URL" -o "$NODE_TAR"

say "📦 Rozpakowuję quantus-node..."
tar xzf "$NODE_TAR"

if [[ ! -f "quantus-node" ]]; then
  say "❌ W archiwum nie znaleziono pliku 'quantus-node'. Sprawdź strukturę release'a."
  exit 1
fi

install -m 755 quantus-node /usr/local/bin/quantus-node
say "✅ Zainstalowano /usr/local/bin/quantus-node"

# =====================================================================
# 4) Pobieranie quantus-miner v0.3.0
# =====================================================================
MINER_URL="https://github.com/Quantus-Network/quantus-miner/releases/download/v0.3.0/quantus-miner-linux-x86_64"
MINER_BIN_LOCAL="quantus-miner"

say "⬇️  Pobieram quantus-miner v0.3.0:"
say "    $MINER_URL"

curl -L "$MINER_URL" -o "$MINER_BIN_LOCAL"
chmod +x "$MINER_BIN_LOCAL"
install -m 755 "$MINER_BIN_LOCAL" /usr/local/bin/quantus-miner

say "✅ Zainstalowano /usr/local/bin/quantus-miner"

# =====================================================================
# 5) Adres nagród + nazwa noda (POPRAWIONE generowanie adresu)
# =====================================================================
say ""
say "💰 KONFIGURACJA ADRESU NAGRÓD"

read -rp "👉 Masz już adres (qz...) z appki/CLI? (t/n): " HAVE_ADDR
REWARD_ADDR=""

if [[ "$HAVE_ADDR" =~ ^[TtYy]$ ]]; then
  read -rp "👉 Wklej adres nagród (qz...): " REWARD_ADDR
else
  say "🪙 Generuję nowy adres (Dilithium) lokalnie binarką quantus-node..."
  GENFILE="$BASE_DIR/keys_$(date +%F_%H-%M-%S).txt"

  # Żeby nie wywalało całego skryptu przy nieudanej komendzie, tymczasowo wyłączamy 'set -e'
  set +e

  # 1. podejście – nowe CLI (generate --scheme dilithium)
  quantus-node key generate --scheme dilithium | tee "$GENFILE"
  STATUS=$?

  if [[ $STATUS -ne 0 ]]; then
    echo "ℹ️  'quantus-node key generate --scheme dilithium' nie działa (status $STATUS)."
    echo "   Próbuję starego formatu 'quantus-node key quantus'..."
    rm -f "$GENFILE"

    quantus-node key quantus | tee "$GENFILE"
    STATUS=$?
  fi

  # przywracamy 'set -e'
  set -e

  if [[ $STATUS -ne 0 ]]; then
    say "❌ Nie udało się wygenerować adresu ani nową, ani starą komendą."
    say "   Spróbuj ręcznie:  quantus-node key generate --scheme dilithium"
    exit 1
  fi

  REWARD_ADDR=$(grep '^Address:' "$GENFILE" | awk '{print $2}')

  if [[ -z "$REWARD_ADDR" ]]; then
    say "❌ Nie udało się odczytać linii 'Address:' z pliku $GENFILE."
    say "   Zawartość pliku:"
    cat "$GENFILE" || true
    exit 1
  fi

  say "📁 Klucze zapisane w: $GENFILE"
  say "   Address: $REWARD_ADDR"
  read -rp "✅ Zapisałeś seed/adres w bezpiecznym miejscu? (t/n): " OK
  [[ "$OK" =~ ^[TtYy]$ ]] || { say "❌ Przerwano przez użytkownika."; exit 1; }
fi

say "ℹ️  Używam adresu nagród: $REWARD_ADDR"
read -rp "👉 Podaj nazwę noda (np. C01, Baku, Dzikigon): " NODE_NAME

# =====================================================================
# 6) Liczba workerów dla minera
# =====================================================================
CPUS=$(nproc 2>/dev/null || echo 2)
WORKERS=$(( CPUS>1 ? CPUS-1 : 1 ))
say "⚙️  Workerów dla minera: $WORKERS (CPU: $CPUS)"

# =====================================================================
# 7) Skrypty startowe: node + miner
# =====================================================================
cd "$BASE_DIR"

cat > run_node.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

cd "$BASE_DIR"

RUST_LOG=\${RUST_LOG:-info,sc_consensus_pow=debug}

exec env RUST_LOG="\$RUST_LOG" quantus-node \\
  --base-path "$DATA_DIR" \\
  --chain dirac \\
  --name "$NODE_NAME" \\
  --rewards-address "$REWARD_ADDR" \\
  --execution native-else-wasm \\
  --wasm-execution compiled \\
  --db-cache 2048 \\
  --unsafe-rpc-external \\
  --rpc-cors all \\
  --in-peers 256 \\
  --out-peers 256 \\
  --external-miner-url "http://127.0.0.1:9833" \\
  --bootnodes /dns/q.boot.quantus.network/tcp/31337/p2p/12D3KooWRPZzBFe6KJzrqVgHut1R4x1vXhY2hzYo2f8fy8p2y5Aa \\
  --bootnodes /dns/q.boot.quantus.network/udp/31337/quic-v1/p2p/12D3KooWRPZzBFe6KJzrqVgHut1R4x1vXhY2hzYo2f8fy8p2y5Aa
  # 👉 Jak będziemy mieć przygotowany secret_dilithium dla kolegi,
  # można tu dodać:  --validator
EOF

chmod +x run_node.sh

cat > run_miner.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

cd "$BASE_DIR"

RUST_LOG=\${RUST_LOG:-info}

exec env RUST_LOG="\$RUST_LOG" quantus-miner \\
  --engine cpu-fast \\
  --port 9833 \\
  --workers "$WORKERS"
EOF

chmod +x run_miner.sh

cat > run_tmux.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SESSION="quantus-mining"

if ! command -v tmux >/dev/null 2>&1; then
  echo "❌ Brak tmux – zainstaluj: sudo apt-get install -y tmux"
  exit 1
fi

cd /root/quantus-mining

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "ℹ️  Sesja tmux '$SESSION' już istnieje."
  echo "   Dołącz: tmux attach -t $SESSION"
  exit 0
fi

tmux new-session -d -s "$SESSION" "./run_node.sh"
sleep 5
tmux new-window -t "$SESSION" "./run_miner.sh"

echo "✅ Uruchomiono noda + minera w tmux (sesja: $SESSION)."
echo "   Dołącz: tmux attach -t $SESSION"
EOF

chmod +x run_tmux.sh

# =====================================================================
# 8) Podsumowanie
# =====================================================================
say ""
say "✅ Instalacja zakończona."
say "   Katalog bazowy: $BASE_DIR"
say "   Dane chain:     $DATA_DIR"
say "   Node name:      $NODE_NAME"
say "   Rewards addr:   $REWARD_ADDR"
say ""
say "▶️ Uruchamianie ręczne:"
say "   cd $BASE_DIR"
say "   ./run_node.sh"
say "   ./run_miner.sh"
say ""
say "▶️ Uruchamianie w tmux (node + miner):"
say "   cd $BASE_DIR"
say "   ./run_tmux.sh"
say "   tmux attach -t quantus-mining"
say ""
say "📌 Jak już ustalimy secret_dilithium dla tego noda kolegi,"
say "    dopiszemy --validator do run_node.sh i zrobimy z tego pełny validator."
