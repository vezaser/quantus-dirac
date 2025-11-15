#!/usr/bin/env bash
set -euo pipefail

###
#  Quantus DIRAC – instalacja node + miner (bez Dockera)
#  - buduje z kodu wg MINING.md
#  - tworzy systemd service dla noda i minera
#  - generuje adres nagród 24-słowowy przez `quantus-node key quantus`
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
  err "Uruchom ten skrypt jako root (sudo)."
  exit 1
fi

echo "------------------------------------------------------"
echo -e "🚀 ${GRN}Quantus DIRAC – instalacja node + miner (bez Dockera)${RST}"
echo "    (zgodnie z MINING.md, budowa z cargo)"
echo "------------------------------------------------------"

### 1. Pakiety systemowe
log "Instaluję wymagane pakiety (build-essential, Rust, itp.)..."

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
  build-essential pkg-config libssl-dev clang cmake git curl wget ca-certificates \
  tmux

ok "Pakiety zainstalowane."

### 2. Rust + nightly (wymagane przez MINING.md)
if ! command -v cargo >/dev/null 2>&1; then
  log "Rust nie wykryty – instaluję rustup + nightly..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
else
  ok "Rust już zainstalowany – pomijam instalację rustup."
fi

# Załaduj środowisko Rust
if [[ -f "$HOME/.cargo/env" ]]; then
  # dla root: HOME zazwyczaj /root
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"
fi

log "Ustawiam toolchain nightly..."
rustup toolchain install nightly -y || true
rustup default nightly

ok "Rust nightly gotowy: $(cargo --version)"

### 3. Ścieżki / katalogi
BASE_DIR="/root/quantus-src"
CHAIN_DIR="${BASE_DIR}/chain"
MINER_DIR="${BASE_DIR}/quantus-miner"
DATA_DIR="/var/lib/quantus"

mkdir -p "$BASE_DIR"
mkdir -p "$DATA_DIR"

ok "Katalogi źródeł: ${BASE_DIR}"
ok "Katalog danych noda: ${DATA_DIR}"

### 4. Pobranie źródeł chain (quantus-node)
if [[ ! -d "$CHAIN_DIR" ]]; then
  log "Klonuję repozytorium chain..."
  git clone https://github.com/Quantus-Network/chain.git "$CHAIN_DIR"
else
  log "Repo chain już istnieje – robię git pull..."
  (cd "$CHAIN_DIR" && git pull --ff-only) || true
fi

### 5. Budowa quantus-node
log "Buduję quantus-node (cargo build --release -p quantus-node)..."
cd "$CHAIN_DIR"
cargo build --release -p quantus-node
ok "quantus-node zbudowany."

install -Dm755 "$CHAIN_DIR/target/release/quantus-node" /usr/local/bin/quantus-node
ok "Zainstalowano /usr/local/bin/quantus-node"

### 6. Pobranie i budowa quantus-miner
if [[ ! -d "$MINER_DIR" ]]; then
  log "Klonuję repozytorium quantus-miner..."
  git clone https://github.com/Quantus-Network/quantus-miner.git "$MINER_DIR"
else
  log "Repo quantus-miner już istnieje – git pull..."
  (cd "$MINER_DIR" && git pull --ff-only) || true
fi

log "Buduję quantus-miner (cargo build --release)..."
cd "$MINER_DIR"
cargo build --release
ok "quantus-miner zbudowany."

install -Dm755 "$MINER_DIR/target/release/quantus-miner" /usr/local/bin/quantus-miner
ok "Zainstalowano /usr/local/bin/quantus-miner"

### 7. Node key (P2P)
# Użyjemy --node-key-file /var/lib/quantus/node_key
NODE_KEY_FILE="${DATA_DIR}/node_key"
if [[ -f "$NODE_KEY_FILE" ]]; then
  ok "Plik node key już istnieje: ${NODE_KEY_FILE}"
  warn "Jeśli chcesz NOWY node identity, usuń ten plik ręcznie i uruchom skrypt jeszcze raz."
else
  log "Plik node key zostanie AUTOMATYCZNIE utworzony przez noda przy pierwszym starcie."
fi

### 8. Nazwa noda
echo
read -rp "👉 Podaj nazwę swojego noda (np. C01, Baku01, C20): " NODE_NAME
NODE_NAME=${NODE_NAME:-"QuantusNode"}

ok "Ustawiam nazwę noda na: ${NODE_NAME}"

### 9. Adres do nagród
echo
read -rp "👉 Czy masz już adres do nagród (qz...) ? (t/n): " HAS_ADDR
HAS_ADDR=${HAS_ADDR,,}  # lower-case

REWARDS_ADDR=""

if [[ "$HAS_ADDR" == "t" || "$HAS_ADDR" == "y" ]]; then
  read -rp "👉 Wklej swój adres (qz...): " REWARDS_ADDR
else
  echo
  warn "Nie masz adresu – wygenerujemy NOWY 24-słowowy seed + adres wg:"
  echo "     quantus-node key quantus  (z MINING.md)"
  echo
  KEY_FILE="/root/quantus_dirac_key_$(date +'%Y%m%d_%H%M%S').txt"
  log "Generuję nowy klucz i zapisuję do: ${KEY_FILE}"
  echo
  /usr/local/bin/quantus-node key quantus | tee "${KEY_FILE}"
  echo
  ok "CAŁY powyższy output został zapisany do: ${KEY_FILE}"
  warn "ZAPISZ BEZPIECZNIE 24 słowa seeda ORAZ adres (qz...)."

  while true; do
    echo
    read -rp "👉 Czy skopiowałeś już seed i adres? (t/n): " COPIED
    COPIED=${COPIED,,}
    if [[ "$COPIED" == "t" || "$COPIED" == "y" ]]; then
      echo
      read -rp "👉 Wklej teraz ADRES (qz...) z wygenerowanego klucza: " REWARDS_ADDR
      break
    else
      warn "Skopiuj seed i adres z pliku: ${KEY_FILE}, potem odpowiedz 't'."
    fi
  done
fi

if [[ -z "$REWARDS_ADDR" ]]; then
  err "Adres nagród jest pusty – nie mogę kontynuować."
  exit 1
fi

ok "Użyję adresu nagród: ${REWARDS_ADDR}"

### 10. Worker threads dla minera
CPU_TOTAL=$(nproc || echo 1)
WORKERS=$(( CPU_TOTAL > 1 ? CPU_TOTAL - 1 : 1 ))

echo
read -rp "👉 Wykryto ${CPU_TOTAL} rdzeni. Ile workerów ma mieć miner? [domyślnie ${WORKERS}]: " WORKERS_IN
if [[ -n "${WORKERS_IN:-}" ]]; then
  WORKERS=${WORKERS_IN}
fi

ok "Miner będzie startował z --workers ${WORKERS}"

### 11. Tworzenie systemd service – quantus-node
log "Tworzę plik /etc/systemd/system/quantus-node.service ..."

cat >/etc/systemd/system/quantus-node.service <<EOF
[Unit]
Description=Quantus Dirac Node
After=network-online.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=${DATA_DIR}
ExecStart=/usr/local/bin/quantus-node \\
  --validator \\
  --chain dirac \\
  --base-path ${DATA_DIR} \\
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
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

ok "quantus-node.service zapisany."

### 12. systemd service – quantus-miner
log "Tworzę plik /etc/systemd/system/quantus-miner.service ..."

cat >/etc/systemd/system/quantus-miner.service <<EOF
[Unit]
Description=Quantus External Miner
After=network-online.target quantus-node.service
Wants=network-online.target

[Service]
User=root
WorkingDirectory=${DATA_DIR}
ExecStart=/usr/local/bin/quantus-miner --engine cpu-fast --port 9833 --workers ${WORKERS}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

ok "quantus-miner.service zapisany."

### 13. Start usług
log "Przeładowuję systemd i włączam usługi..."
systemctl daemon-reload
systemctl enable quantus-node quantus-miner
systemctl restart quantus-node quantus-miner

ok "Node i miner uruchomione."

echo
echo "------------------------------------------------------"
echo -e "🎉 ${GRN}Instalacja Quantus DIRAC (bez Dockera) zakończona!${RST}"
echo "------------------------------------------------------"
echo
echo "📍 Najważniejsze rzeczy:"
echo "  • Dane noda:          ${DATA_DIR}"
echo "  • Node key (P2P):     ${NODE_KEY_FILE} (utworzy się przy pierwszym starcie jeśli nie istnieje)"
echo "  • Adres nagród:       ${REWARDS_ADDR}"
echo "  • Nazwa noda:         ${NODE_NAME}"
echo
echo "📜 Jak sprawdzać logi:"
echo "  • Node  (tail + follow):"
echo "      journalctl -u quantus-node -f -n 100"
echo "  • Miner (tail + follow):"
echo "      journalctl -u quantus-miner -f -n 100"
echo
echo "📡 Status usług:"
echo "      systemctl status quantus-node"
echo "      systemctl status quantus-miner"
echo
echo "✅ Jeśli w logach noda widzisz synchro i peers > 0 oraz brak błędów,"
echo "   a w logach minera 'Received mining job' itd. – wszystko działa."
echo
