#!/usr/bin/env bash
# =============================================================================
# LiveTerminal - Server (VPS) Installer
# Installs: frps (tunnel relay) + Node.js web app (xterm.js dashboard)
# Usage:  curl -sSL https://<REPO>/server/install.sh | sudo bash
# =============================================================================
set -euo pipefail

# ── Colours & helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}[LiveTerminal]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }

# ── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Run as root: sudo bash install.sh"

# ── Detect package manager ───────────────────────────────────────────────────
if command -v apt-get &>/dev/null; then
    PKG="apt-get"
    $PKG update -qq
elif command -v dnf &>/dev/null; then
    PKG="dnf"
elif command -v yum &>/dev/null; then
    PKG="yum"
else
    fail "Unsupported package manager."
fi

# ── Configuration ────────────────────────────────────────────────────────────
FRP_VERSION="0.61.1"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  FRP_ARCH="amd64" ;;
    aarch64) FRP_ARCH="arm64" ;;
    *)       fail "Unsupported architecture: $ARCH" ;;
esac

FRP_DIR="/opt/frp"
FRP_CONF="/etc/frp/frps.toml"
BIND_PORT=7000
TOKEN_FILE="/etc/frp/.token"
APP_DIR="/opt/liveterminal"
WEB_PORT=3000

TUNNEL_PORT_MIN=10000
TUNNEL_PORT_MAX=20000
MOSH_PORT_MIN=30000
MOSH_PORT_MAX=40000

# ── 1. Install frps ─────────────────────────────────────────────────────────
info "Installing frp v${FRP_VERSION}..."
TMP=$(mktemp -d)
FRP_TAR="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR}"

curl -sSL --retry 3 -o "${TMP}/${FRP_TAR}" "$FRP_URL" \
    || fail "Failed to download frp."

tar -xzf "${TMP}/${FRP_TAR}" -C "$TMP"
mkdir -p "$FRP_DIR" /etc/frp

cp "${TMP}/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps" "$FRP_DIR/frps"
chmod +x "$FRP_DIR/frps"
rm -rf "$TMP"
ok "frps installed"

# ── 2. Generate frp auth token ──────────────────────────────────────────────
if [[ -f "$TOKEN_FILE" ]]; then
    AUTH_TOKEN=$(cat "$TOKEN_FILE")
    info "Reusing existing frp auth token."
else
    AUTH_TOKEN=$(openssl rand -hex 24)
    echo "$AUTH_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    ok "Generated frp auth token."
fi

# ── 3. Write frps.toml ──────────────────────────────────────────────────────
cat > "$FRP_CONF" <<TOML
# LiveTerminal - frp Server Config

bindPort = ${BIND_PORT}

auth.method = "token"
auth.token  = "${AUTH_TOKEN}"

allowPorts = [
  { start = ${TUNNEL_PORT_MIN}, end = ${TUNNEL_PORT_MAX} },
  { start = ${MOSH_PORT_MIN},  end = ${MOSH_PORT_MAX} }
]

webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "${AUTH_TOKEN:0:16}"

log.to    = "/var/log/frps.log"
log.level = "info"
log.maxDays = 7
TOML
ok "frps.toml written"

# ── 4. Install Node.js (if needed) ──────────────────────────────────────────
if ! command -v node &>/dev/null; then
    info "Installing Node.js..."
    if [[ "$PKG" == "apt-get" ]]; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    else
        curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
        $PKG install -y nodejs
    fi
    ok "Node.js installed ($(node -v))"
else
    ok "Node.js found ($(node -v))"
fi

# ── 5. Deploy web app ───────────────────────────────────────────────────────
info "Deploying web app..."
mkdir -p "$APP_DIR"

# Clone or copy web app files
# For curl|bash installs, we download from the repo
REPO_URL="https://raw.githubusercontent.com/IagoLast/movive/main"

# Create directory structure
mkdir -p "${APP_DIR}/public/css"

# Download web app files
for file in package.json server.js; do
    curl -sSL --retry 3 -o "${APP_DIR}/${file}" "${REPO_URL}/server/web/${file}" \
        || fail "Failed to download ${file}"
done

for file in index.html terminal.html; do
    curl -sSL --retry 3 -o "${APP_DIR}/public/${file}" "${REPO_URL}/server/web/public/${file}" \
        || fail "Failed to download ${file}"
done

curl -sSL --retry 3 -o "${APP_DIR}/public/css/style.css" "${REPO_URL}/server/web/public/css/style.css" \
    || fail "Failed to download style.css"

# Install npm dependencies
cd "$APP_DIR"
npm install --production 2>/dev/null
ok "Web app deployed to ${APP_DIR}"

# ── 6. Firewall ─────────────────────────────────────────────────────────────
info "Configuring firewall..."
if command -v ufw &>/dev/null; then
    ufw allow 22/tcp                                            comment "SSH"            >/dev/null 2>&1 || true
    ufw allow ${BIND_PORT}/tcp                                  comment "frp bind"       >/dev/null 2>&1 || true
    ufw allow 7500/tcp                                          comment "frp dashboard"  >/dev/null 2>&1 || true
    ufw allow ${WEB_PORT}/tcp                                   comment "LiveTerminal"   >/dev/null 2>&1 || true
    ufw allow ${TUNNEL_PORT_MIN}:${TUNNEL_PORT_MAX}/tcp         comment "SSH tunnels"    >/dev/null 2>&1 || true
    ufw allow ${MOSH_PORT_MIN}:${MOSH_PORT_MAX}/udp             comment "Mosh tunnels"   >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
    ok "UFW rules added."
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=22/tcp                                    >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=${BIND_PORT}/tcp                          >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=7500/tcp                                  >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=${WEB_PORT}/tcp                           >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=${TUNNEL_PORT_MIN}-${TUNNEL_PORT_MAX}/tcp >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port=${MOSH_PORT_MIN}-${MOSH_PORT_MAX}/udp     >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld rules added."
else
    warn "No firewall detected. Open ports manually: 22, ${BIND_PORT}, 7500, ${WEB_PORT}, ${TUNNEL_PORT_MIN}-${TUNNEL_PORT_MAX}/tcp, ${MOSH_PORT_MIN}-${MOSH_PORT_MAX}/udp"
fi

# ── 7. systemd services ─────────────────────────────────────────────────────

# frps service
cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=LiveTerminal - frp Server
After=network.target

[Service]
Type=simple
ExecStart=${FRP_DIR}/frps -c ${FRP_CONF}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# Web app service
cat > /etc/systemd/system/liveterminal.service <<EOF
[Unit]
Description=LiveTerminal - Web App
After=network.target frps.service

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
ExecStart=$(which node) server.js
Restart=always
RestartSec=5
Environment=PORT=${WEB_PORT}
Environment=DATA_DIR=${APP_DIR}/data
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now frps
systemctl enable --now liveterminal
ok "Services running (frps + liveterminal)"

# ── 8. Wait for web app to generate join token ──────────────────────────────
sleep 3
JOIN_TOKEN=""
JOIN_TOKEN_FILE="${APP_DIR}/data/join_token"
if [[ -f "$JOIN_TOKEN_FILE" ]]; then
    JOIN_TOKEN=$(cat "$JOIN_TOKEN_FILE")
fi

# ── Done ─────────────────────────────────────────────────────────────────────
VPS_IP=$(curl -s4 ifconfig.me 2>/dev/null || echo "<VPS_IP>")

cat <<BANNER

${GREEN}╔══════════════════════════════════════════════════════════════════╗
║               LiveTerminal Server — Ready                        ║
╚══════════════════════════════════════════════════════════════════╝${NC}

  ${BOLD}VPS IP:${NC}          ${CYAN}${VPS_IP}${NC}
  ${BOLD}Web Dashboard:${NC}   ${CYAN}http://${VPS_IP}:${WEB_PORT}${NC}
  ${BOLD}frp Dashboard:${NC}   http://${VPS_IP}:7500 (user: admin)

  ${BOLD}frp Auth Token:${NC}  ${YELLOW}${AUTH_TOKEN}${NC}
  ${BOLD}Join Token:${NC}      ${YELLOW}${JOIN_TOKEN}${NC}

  ${YELLOW}Developers need these two values to install the client:${NC}
    1. VPS IP:      ${VPS_IP}
    2. Join Token:  ${JOIN_TOKEN}

  ${BOLD}Client install command:${NC}
  ${CYAN}curl -sSL http://${VPS_IP}:${WEB_PORT}/install.sh | bash${NC}

BANNER
