#!/usr/bin/env bash
# =============================================================================
# LiveTerminal - Server (VPS) Installer
# Configures frps + firewall on a Linux VPS so Mac clients can tunnel through.
# Usage:  curl -sSL https://raw.githubusercontent.com/<REPO>/server/install.sh | bash
# =============================================================================
set -euo pipefail

# ── Colours & helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { printf "${CYAN}[LiveTerminal]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }

# ── Root check ───────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Run this script as root (sudo bash install.sh)"

# ── Detect package manager ───────────────────────────────────────────────────
if command -v apt-get &>/dev/null; then
    PKG="apt-get"
elif command -v yum &>/dev/null; then
    PKG="yum"
elif command -v dnf &>/dev/null; then
    PKG="dnf"
else
    fail "Unsupported package manager. Install frp manually."
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

# Port range reserved for client tunnels (SSH + Mosh)
TUNNEL_PORT_MIN=10000
TUNNEL_PORT_MAX=20000
MOSH_PORT_MIN=30000
MOSH_PORT_MAX=40000

# ── Install frps binary ─────────────────────────────────────────────────────
info "Downloading frp v${FRP_VERSION} (${FRP_ARCH})..."
TMP=$(mktemp -d)
FRP_TAR="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR}"

if ! curl -sSL --retry 3 -o "${TMP}/${FRP_TAR}" "$FRP_URL"; then
    fail "Failed to download frp. Check your network."
fi

tar -xzf "${TMP}/${FRP_TAR}" -C "$TMP"
mkdir -p "$FRP_DIR" /etc/frp

cp "${TMP}/frp_${FRP_VERSION}_linux_${FRP_ARCH}/frps" "$FRP_DIR/frps"
chmod +x "$FRP_DIR/frps"
rm -rf "$TMP"
ok "frps binary installed to ${FRP_DIR}/frps"

# ── Generate auth token ─────────────────────────────────────────────────────
if [[ -f "$TOKEN_FILE" ]]; then
    AUTH_TOKEN=$(cat "$TOKEN_FILE")
    info "Reusing existing auth token."
else
    AUTH_TOKEN=$(openssl rand -hex 24)
    echo "$AUTH_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    ok "Generated new auth token."
fi

# ── Write frps.toml ─────────────────────────────────────────────────────────
cat > "$FRP_CONF" <<TOML
# LiveTerminal - frp Server Config
# Managed by install.sh — edit with care.

bindPort = ${BIND_PORT}

auth.method = "token"
auth.token  = "${AUTH_TOKEN}"

# Allow clients to claim ports in these ranges
allowPorts = [
  { start = ${TUNNEL_PORT_MIN}, end = ${TUNNEL_PORT_MAX} },
  { start = ${MOSH_PORT_MIN},  end = ${MOSH_PORT_MAX} }
]

# Dashboard (optional — access at http://<VPS_IP>:7500)
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "${AUTH_TOKEN:0:16}"

# Logging
log.to    = "/var/log/frps.log"
log.level = "info"
log.maxDays = 7
TOML
ok "Wrote ${FRP_CONF}"

# ── Firewall ─────────────────────────────────────────────────────────────────
info "Configuring firewall..."
if command -v ufw &>/dev/null; then
    ufw allow ${BIND_PORT}/tcp          comment "frp bind"       >/dev/null 2>&1
    ufw allow 7500/tcp                  comment "frp dashboard"  >/dev/null 2>&1
    ufw allow ${TUNNEL_PORT_MIN}:${TUNNEL_PORT_MAX}/tcp comment "frp SSH tunnels" >/dev/null 2>&1
    ufw allow ${MOSH_PORT_MIN}:${MOSH_PORT_MAX}/udp    comment "frp Mosh tunnels" >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    ok "UFW rules added."
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=${BIND_PORT}/tcp                              >/dev/null 2>&1
    firewall-cmd --permanent --add-port=7500/tcp                                      >/dev/null 2>&1
    firewall-cmd --permanent --add-port=${TUNNEL_PORT_MIN}-${TUNNEL_PORT_MAX}/tcp     >/dev/null 2>&1
    firewall-cmd --permanent --add-port=${MOSH_PORT_MIN}-${MOSH_PORT_MAX}/udp         >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ok "firewalld rules added."
else
    warn "No ufw/firewalld detected. Open ports ${BIND_PORT}, 7500, ${TUNNEL_PORT_MIN}-${TUNNEL_PORT_MAX}/tcp, ${MOSH_PORT_MIN}-${MOSH_PORT_MAX}/udp manually."
fi

# ── systemd service ──────────────────────────────────────────────────────────
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

systemctl daemon-reload
systemctl enable --now frps
ok "frps service running."

# ── Done ─────────────────────────────────────────────────────────────────────
VPS_IP=$(curl -s4 ifconfig.me || echo "<VPS_IP>")
cat <<BANNER

${GREEN}╔══════════════════════════════════════════════════════════════╗
║           LiveTerminal Server — Ready                        ║
╚══════════════════════════════════════════════════════════════╝${NC}

  VPS IP:          ${CYAN}${VPS_IP}${NC}
  frp bind port:   ${BIND_PORT}
  Auth token:      ${YELLOW}${AUTH_TOKEN}${NC}
  Dashboard:       http://${VPS_IP}:7500  (user: admin)

  ${YELLOW}Save the auth token — clients need it to connect.${NC}

BANNER
