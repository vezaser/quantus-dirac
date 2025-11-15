#!/usr/bin/env bash
set -euo pipefail

###
#  Quantus DIRAC – instalacja node + miner (bez Dockera)
#  - Budowa z kodu (MINING.md)
#  - Automatyczne wygenerowanie node_key (P2P)
#  - Automatyczne wygenerowanie adresu nagród (jeśli trzeba)
###

RED="\e[31m"
GRN="\e[32m"
YEL="\e[33m"
CYN="\e[36m"
RST="\e[0m"

log()  { echo -e "${CYN}[$(date +'%H:%M:%S')]${RST} $*"; }
ok()   { echo -e "${GRN}✅${RST} $*"; }
warn() { echo -e "${YEL}⚠️${RST}  $*"; }
err()  { echo -e "${RED}❌${RST} $*"; }

if [[ $EUID -ne 0 ]]; then
  err "Uruchom ten skrypt jako root."
  exit 1
fi

echo "------------------------------------------------------"
echo -e "🚀 ${GRN}Quantus DIRAC – instalacja node + miner (bez Dockera)${RST}"
echo "------------------------------------------------------"

### 1. Pakiety systemowe
log "Instaluję pakiety systemowe..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y

apt-get install -y \
  build-essential pkg-config libssl-dev clang cmake git curl wget ca-certificates tmux \
  protobuf-compiler

ok "Pakiety zainstalowane."

### 2. Rust + nightly
if ! command -v cargo >/dev/null 2>&1; then
  log "Instaluję rustup + Rust nightly..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
else
  ok "Rust już jest – pomijam instalację."
fi

# załaduj środowisko Rust
source "$HOME/.cargo/env"

log "Ustawiam Rust nightly..."
rustup toolchain install nightly -y || true
rustup default nightly

ok "Rust gotowy: $(cargo --version)"

### 3. Katalogi
BASE="/root/quantus-src"
CHAIN="${BASE}/chain"
MINER="${BASE}/quantus-miner"
DATA="/var/lib/quantus"
NODE_KEY_FILE="${DATA}/node_key"

mkdir -p "$BASE"
mkdir -p "$DATA"

ok "Katalog źródeł: $BASE"
ok "Katalog danych: $DATA"

### 4. Pobranie chain
if [[ ! -d "$CHAIN" ]]; then
  log "Klonuję chain..."
  git clone https://github.com/Quantus-Network/chain.git "$CHAIN"
else
  log "chain istnieje – git pull..."
  (cd "$CHAIN" && git pull --ff-only) || true
fi

### 5. Budowa quantus-node
log "Buduję quantus-node..."
cd "$CHAIN"

if ! command -v protoc >/dev/null 2>&1; then
  err "Brak protoc mimo zainstalowanego protobuf-compiler."
  err "Sprawdź: apt-get install protobuf-compiler"
  exit 1
fi

cargo build --release -p quantus-node
install -Dm755 "$CHAIN/target/release/quantus-node" /usr/local/bin/quantus-node
ok "quantus-node zainstalowany."

### 6. AUTOMATYCZNE GENEROWANIE node_key (P2P)
if [[ -f "$NODE_KEY_FILE" ]]; then
  ok "Node key już istnieje: $NODE_KEY_FILE – nie generuję nowego."
else
  log "Brak node_key – generuję nowy P2P identity:"
  log "  quantus-node key generate-node-key --file $NODE_KEY_FILE"
  /usr/local/bin/quantus-node key generate-node-key --file "$NODE_KEY_FILE"
  ok "Node key zapisany w: $NODE_KEY_FILE"
fi

### 7. Pobranie i budowa quantus-miner
if [[ ! -d "$MINER" ]]; then
  log "Klonuję quantus-miner..."
  git clone https://github.com/Quantus-Network/quantus-miner.git "$MINER"
else
  log "quantus-miner istnieje – git pull..."
  (cd "$MINER" && git pull --ff-only) || true
fi

log "Buduję quantus-miner..."
cd "$MINER"
cargo build --release
install -Dm755 "$MINER/target/release/quantus-miner" /usr/local/bin/quantus-miner
ok "quantus-miner zainstalowany."

### 8. Nazwa noda
echo
read -rp "👉 Podaj nazwę swojego noda (np. C01, Q20): " NODE_NAME
NODE_NAME=${NODE_NAME:-"QuantusNode"}
ok "Nazwa noda: $NODE_NAME"

### 9. Adres do nagród
echo
read -rp "👉 Czy masz już adres do nagród (qz...) ? (t/n): " HAS_ADDR
HAS_ADDR=${HAS_ADDR,,}
REWARDS_ADDR=""

if [[ "$HAS_ADDR" == "t" ]]; then
  read -rp "👉 Wklej adres nagród qz... : " REWARDS_ADDR
else
  warn "Generuję nowy 24-słowowy seed + adres przez:"
  echo "     quantus-node key quantus"
  KEYFILE="/root/quantus_key_$(date +%Y%m%d_%H%M%S).txt"
  /usr/local/bin/quantus-node key quantus | tee "$KEYFILE"
  echo
  ok "Zapisano do pliku: $KEYFILE"
  warn "ZAPISZ SEED (24 słowa) oraz adres!!!"
  while true; do
    read -rp "👉 Czy skopiowałeś seed i adres? (t/n): " OKCOP
    OKCOP=${OKCOP,,}
    if [[ "$OKCOP" == "t" ]]; then
      read -rp "👉 Wklej adres nagród qz... : " REWARDS_ADDR
      break
    else
      warn "Skopiuj seed i adres z pliku: $KEYFILE"
    fi
  done
fi

if [[ -z "$REWARDS_ADDR" ]]; then
  err "Adres nagród jest pusty! Przerywam."
  exit 1
fi

ok "Używam adresu nagród: $REWARDS_ADDR"

### 10. Worker threads dla minera
CPU=$(nproc)
DEF=$((CPU>1?CPU-1:1))
read -rp "👉 Wykryto $CPU rdzeni. Ile workerów ma mieć miner? [domyślnie $DEF]: " W_IN
WORKERS=${W_IN:-$DEF}
ok "Miner będzie miał $WORKERS workerów."

### 11. Systemd – Node
log "Tworzę /etc/systemd/system/quantus-node.service"

cat >/etc/systemd/system/quantus-node.service <<EOF
[Unit]
Description=Quantus Node (Dirac)
After=network-online.target
Wants=network-online.target

[Service]
User=root
ExecStart=/usr/local/bin/quantus-node \\
  --validator \\
  --chain dirac \\
  --base-path /var/lib/quantus \\
  --node-key-file ${NODE_KEY_FILE} \\
  --rewards-address ${REWARDS_ADDR} \\
  --name ${NODE_NAME} \\
  --execution native-else-wasm \\
  --wasm-execution compiled \\
  --db-cache 2048 \\
  --unsafe-rpc-external \\
  --rpc-cors all \\
  --in-peers 256 \\
  --out-peers 256 \\
  --external-miner-url http://127.0.0.1:9833
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

### 12. Systemd – Miner
log "Tworzę /etc/systemd/system/quantus-miner.service"

cat >/etc/systemd/system/quantus-miner.service <<EOF
[Unit]
Description=Quantus External Miner
After=network-online.target quantus-node.service

[Service]
User=root
ExecStart=/usr/local/bin/quantus-miner --engine cpu-fast --port 9833 --workers ${WORKERS}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

### 13. Start usług
log "Uruchamiam usługi..."
systemctl daemon-reload
systemctl enable quantus-node quantus-miner
systemctl restart quantus-node quantus-miner
ok "Node i Miner uruchomione!"

echo
echo "------------------------------------------------------"
echo -e "🎉 ${GRN}INSTALACJA ZAKOŃCZONA${RST}"
echo "------------------------------------------------------"
echo
echo "📜 Logi noda:"
echo "   journalctl -u quantus-node -f -n 100"
echo
echo "📜 Logi minera:"
echo "   journalctl -u quantus-miner -f -n 100"
echo
echo "📡 Status:"
echo "   systemctl status quantus-node"
echo "   systemctl status quantus-miner"
echo
