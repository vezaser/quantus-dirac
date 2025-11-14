#!/usr/bin/env bash
set -euo pipefail

say() { echo -e "$*"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    say "❌ Ten skrypt najlepiej uruchomić jako root:"
    say "   sudo $0"
    exit 1
  fi
}

need_root

say "🚀 Quantus – instalacja noda + minera BEZ Dockera (wg MINING.md)"
say "    Budowa z GitHuba + external miner na 127.0.0.1:9833"
say "-------------------------------------------------------------------------------"

# =====================================================================
# 1) Pakiety systemowe (Ubuntu / Debian / WSL)
# =====================================================================
say "📦 Instaluję wymagane pakiety (Ubuntu/WSL)..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  build-essential \
  curl \
  wget \
  git \
  pkg-config \
  libssl-dev \
  clang \
  cmake \
  ca-certificates \
  tmux

# =====================================================================
# 2) Rust nightly (jak w MINING.md)
# =====================================================================
if ! command -v cargo >/dev/null 2>&1; then
  say "⬇️  Instaluję Rust (rustup + nightly)..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

if [[ -f "$HOME/.cargo/env" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"
fi

say "🔧 Konfiguruję Rust nightly..."
rustup toolchain install nightly >/dev/null 2>&1 || true
rustup default nightly >/dev/null 2>&1 || true

say "ℹ️  Wersja cargo:"
cargo --version || true

# =====================================================================
# 3) Katalogi robocze
# =====================================================================
BASE_DIR="/root/quantus-mining"
CHAIN_DIR="$BASE_DIR/chain"
MINER_SRC_DIR="$BASE_DIR/quantus-miner"
DATA_DIR="$BASE_DIR/data"

mkdir -p "$BASE_DIR" "$DATA_DIR"
cd "$BASE_DIR"

say "📁 Katalog bazowy: $BASE_DIR"
say "📁 Dane chain:     $DATA_DIR"

# =====================================================================
# 4) Klonowanie i budowa quantus-node (wg MINING.md)
# =====================================================================
if [[ ! -d "$CHAIN_DIR" ]]; then
  say "⬇️  Klonuję repozytorium Quantus chain..."
  git clone https://github.com/Quantus-Network/chain.git "$CHAIN_DIR"
else
  say "🔁 Repo chain już istnieje, robię git pull..."
  cd "$CHAIN_DIR"
  git pull --ff-only || true
fi

cd "$CHAIN_DIR"

say "🛠  Buduję quantus-node (cargo build --release -p quantus-node)..."
cargo build --release -p quantus-node

NODE_BIN="$CHAIN_DIR/target/release/quantus-node"

if [[ ! -x "$NODE_BIN" ]]; then
  say "❌ Nie znaleziono zbudowanej binarki quantus-node w $NODE_BIN"
  exit 1
fi

install -m 755 "$NODE_BIN" /usr/local/bin/quantus-node
say "✅ Zainstalowano /usr/local/bin/quantus-node"

# =====================================================================
# 5) Adres nagród (według sekcji Rewards address w MINING.md)
# =====================================================================
say ""
say "💰 KONFIGURACJA ADRESU NAGRÓD"
read -rp "👉 Masz już adres (qz...) z appki/CLI? (t/n): " HAVE_ADDR

REWARD_ADDR=""

if [[ "$HAVE_ADDR" =~ ^[TtYy]$ ]]; then
  read -rp "👉 Wklej adres nagród (qz...): " REWARD_ADDR
else
  say "🔐 Generuję nowy adres (quantus-node key quantus)..."
  GENFILE="$BASE_DIR/keys_$(date +%F_%H-%M-%S).txt"

  quantus-node key quantus | tee "$GENFILE"

  REWARD_ADDR=$(grep '^Address:' "$GENFILE" | awk '{print $2}')

  if [[ -z "$REWARD_ADDR" ]]; then
    say "❌ Nie udało się odczytać Address: z pliku $GENFILE."
    exit 1
  fi

  say "📁 Klucze zapisane w: $GENFILE"
  read -rp "✅ Zapisałeś seed/adres w bezpiecznym miejscu? (t/n): " OK
  [[ "$OK" =~ ^[TtYy]$ ]] || { say "❌ Przerwano przez użytkownika."; exit 1; }
fi

say "ℹ️  Używam adresu nagród: $REWARD_ADDR"

read -rp "👉 Podaj nazwę noda (np. C01, Baku, Dzikigon): " NODE_NAME

# =====================================================================
# 6) Klonowanie i budowa quantus-miner (wg MINING.md)
# =====================================================================
cd "$BASE_DIR"

if [[ ! -d "$MINER_SRC_DIR" ]]; then
  say "⬇️  Klonuję repo quantus-miner..."
  git clone https://github.com/Quantus-Network/quantus-miner.git "$MINER_SRC_DIR"
else
  say "🔁 Repo quantus-miner już istnieje, robię git pull..."
  cd "$MINER_SRC_DIR"
  git pull --ff-only || true
fi

cd "$MINER_SRC_DIR"

say "🛠  Buduję quantus-miner (cargo build --release)..."
cargo build --release

MINER_BIN="$MINER_SRC_DIR/target/release/quantus-miner"

if [[ ! -x "$MINER_BIN" ]]; then
  say "❌ Nie znaleziono zbudowanej binarki quantus-miner w $MINER_BIN"
  exit 1
fi

install -m 755 "$MINER_BIN" /usr/local/bin/quantus-miner
say "✅ Zainstalowano /usr/local/bin/quantus-miner"

# =====================================================================
# 7) Liczba workerów dla minera
# =====================================================================
CPUS=$(nproc 2>/dev/null || echo 2)
WORKERS=$(( CPUS>1 ? CPUS-1 : 1 ))
say "⚙️  Workerów dla minera: $WORKERS (CPU: $CPUS)"

# =====================================================================
# 8) Skrypty startowe: node + miner (wg MINING.md, ale na Dirac)
# =====================================================================
cd "$BASE_DIR"

# Node: Dirac + external miner
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
  # 👉 gdy będziesz mieć poprawnie wygenerowany klucz validatora,
  # możesz dodać tu:  --validator
EOF

chmod +x run_node.sh

# Miner: tak jak w MINING.md (RUST_LOG=info ./target/release/quantus-miner), ale w wersji z parametrami
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

# tmux: node + miner
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
# 9) Podsumowanie
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
say "📌 Gdy ogarniemy klucz validatora (secret_dilithium),"
say "    dopiszemy flagę --validator do run_node.sh i zrobimy z tego pełny validator."
