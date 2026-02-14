#!/usr/bin/env bash
# =============================================================================
# LiveTerminal - Mac Client Installer
# Installs deps, opens an frp tunnel, registers with the server, and prints
# the URL where the developer can access their terminal from any browser.
# Usage:  curl -sSL http://<VPS_IP>:3000/install.sh | bash
# =============================================================================
set -euo pipefail

# ── Colours & helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}[LiveTerminal]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }

# ── macOS check ──────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || fail "This script is for macOS only."

# ── Prompt for server info ───────────────────────────────────────────────────
CONFIG_DIR="$HOME/.liveterminal"
CONFIG_FILE="${CONFIG_DIR}/config"

load_or_prompt_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        info "Existing config found: VPS=${VPS_IP}"
        printf "  Use this config? [Y/n] "
        read -r answer
        if [[ "$answer" =~ ^[Nn] ]]; then
            prompt_config
        fi
    else
        prompt_config
    fi
}

prompt_config() {
    mkdir -p "$CONFIG_DIR"
    printf "\n${BOLD}LiveTerminal Setup${NC}\n\n"

    printf "  VPS IP (from server install): "
    read -r VPS_IP
    [[ -z "$VPS_IP" ]] && fail "VPS IP is required."

    printf "  Join Token (from server install): "
    read -r JOIN_TOKEN
    [[ -z "$JOIN_TOKEN" ]] && fail "Join token is required."

    printf "  Web port [3000]: "
    read -r WEB_PORT
    WEB_PORT="${WEB_PORT:-3000}"

    # frp auth token (from server install)
    printf "  frp Auth Token (from server install): "
    read -r FRP_TOKEN
    [[ -z "$FRP_TOKEN" ]] && fail "frp auth token is required."

    printf "  frp Server Port [7000]: "
    read -r FRP_PORT
    FRP_PORT="${FRP_PORT:-7000}"

    cat > "$CONFIG_FILE" <<EOF
VPS_IP="${VPS_IP}"
JOIN_TOKEN="${JOIN_TOKEN}"
WEB_PORT="${WEB_PORT}"
FRP_TOKEN="${FRP_TOKEN}"
FRP_PORT="${FRP_PORT}"
EOF
    chmod 600 "$CONFIG_FILE"
    ok "Config saved"
}

load_or_prompt_config

SERVER_URL="http://${VPS_IP}:${WEB_PORT}"

# ── Generate unique client ID ────────────────────────────────────────────────
ID_FILE="${CONFIG_DIR}/client_id"
TOKEN_FILE="${CONFIG_DIR}/access_token"

if [[ -f "$ID_FILE" ]]; then
    CLIENT_ID=$(cat "$ID_FILE")
    ACCESS_TOKEN=$(cat "$TOKEN_FILE")
    info "Existing client: ${CLIENT_ID}"
else
    CLIENT_ID="lt-$(openssl rand -hex 4)"
    ACCESS_TOKEN=$(openssl rand -hex 16)
    echo "$CLIENT_ID" > "$ID_FILE"
    echo "$ACCESS_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    ok "Client ID: ${CLIENT_ID}"
fi

# Deterministic port from client ID
HASH=$(echo -n "$CLIENT_ID" | md5 | cut -c1-4)
PORT_OFFSET=$(( 16#$HASH % 10000 ))
SSH_REMOTE_PORT=$(( 10000 + PORT_OFFSET ))
MOSH_REMOTE_PORT=$(( 30000 + PORT_OFFSET ))

# ── 1. Homebrew ──────────────────────────────────────────────────────────────
info "Checking Homebrew..."
if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || fail "Homebrew installation failed."

    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        SHELL_RC="$HOME/.zprofile"
        if ! grep -q 'homebrew' "$SHELL_RC" 2>/dev/null; then
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$SHELL_RC"
        fi
    fi
    ok "Homebrew installed."
else
    ok "Homebrew found."
fi

# ── 2. Install packages ─────────────────────────────────────────────────────
PACKAGES=(mosh zellij qrencode)
for pkg in "${PACKAGES[@]}"; do
    if brew list "$pkg" &>/dev/null; then
        ok "${pkg} already installed."
    else
        info "Installing ${pkg}..."
        brew install "$pkg" || fail "Failed to install ${pkg}."
        ok "${pkg} installed."
    fi
done

# ── 3. Install frpc ─────────────────────────────────────────────────────────
FRP_VERSION="0.61.1"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  FRP_ARCH="amd64" ;;
    arm64)   FRP_ARCH="arm64" ;;
    *)       fail "Unsupported architecture: $ARCH" ;;
esac

FRPC_BIN="/usr/local/bin/frpc"
if [[ -f "$FRPC_BIN" ]]; then
    ok "frpc already installed."
else
    info "Downloading frpc v${FRP_VERSION}..."
    TMP=$(mktemp -d)
    FRP_TAR="frp_${FRP_VERSION}_darwin_${FRP_ARCH}.tar.gz"
    FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR}"

    curl -sSL --retry 3 -o "${TMP}/${FRP_TAR}" "$FRP_URL" \
        || fail "Failed to download frpc."

    tar -xzf "${TMP}/${FRP_TAR}" -C "$TMP"
    sudo cp "${TMP}/frp_${FRP_VERSION}_darwin_${FRP_ARCH}/frpc" "$FRPC_BIN"
    sudo chmod +x "$FRPC_BIN"
    rm -rf "$TMP"
    ok "frpc installed"
fi

# ── 4. Enable Remote Login (SSH) ────────────────────────────────────────────
info "Enabling macOS Remote Login..."
SSH_STATUS=$(sudo systemsetup -getremotelogin 2>/dev/null | awk '{print $NF}')
if [[ "$SSH_STATUS" == "On" ]]; then
    ok "Remote Login already enabled."
else
    sudo systemsetup -setremotelogin on 2>/dev/null \
        || warn "Could not enable Remote Login. Enable in System Settings > General > Sharing > Remote Login."
fi

# ── 5. Get server SSH key and authorize it ───────────────────────────────────
info "Fetching server SSH key..."
SERVER_PUB_KEY=$(curl -sSL "${SERVER_URL}/api/server-key" | python3 -c "import sys,json; print(json.load(sys.stdin)['publicKey'])" 2>/dev/null) \
    || fail "Could not fetch server SSH key. Is the server running at ${SERVER_URL}?"

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
AUTH_KEYS="$SSH_DIR/authorized_keys"

if [[ -f "$AUTH_KEYS" ]] && grep -qF "$SERVER_PUB_KEY" "$AUTH_KEYS" 2>/dev/null; then
    ok "Server key already authorized."
else
    echo "$SERVER_PUB_KEY" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    ok "Server SSH key added to authorized_keys."
fi

# ── 6. Register with server ─────────────────────────────────────────────────
info "Registering with server..."
MAC_USER=$(whoami)

REG_RESPONSE=$(curl -sSL -X POST "${SERVER_URL}/api/register" \
    -H "Content-Type: application/json" \
    -d "{
        \"joinToken\": \"${JOIN_TOKEN}\",
        \"clientId\": \"${CLIENT_ID}\",
        \"user\": \"${MAC_USER}\",
        \"sshPort\": ${SSH_REMOTE_PORT},
        \"moshPort\": ${MOSH_REMOTE_PORT},
        \"accessToken\": \"${ACCESS_TOKEN}\"
    }" 2>/dev/null) || fail "Registration failed. Check server connection."

if echo "$REG_RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('ok')" 2>/dev/null; then
    ok "Registered with server."
else
    ERROR=$(echo "$REG_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','Unknown'))" 2>/dev/null || echo "Unknown")
    fail "Registration failed: ${ERROR}"
fi

# ── 7. Write frpc config ────────────────────────────────────────────────────
FRPC_CONF="${CONFIG_DIR}/frpc.toml"

cat > "$FRPC_CONF" <<TOML
# LiveTerminal — frpc client config
# Client ID: ${CLIENT_ID}

serverAddr = "${VPS_IP}"
serverPort = ${FRP_PORT}

auth.method = "token"
auth.token  = "${FRP_TOKEN}"

# SSH tunnel
[[proxies]]
name       = "${CLIENT_ID}-ssh"
type       = "tcp"
localIP    = "127.0.0.1"
localPort  = 22
remotePort = ${SSH_REMOTE_PORT}

# Mosh tunnel (UDP)
[[proxies]]
name       = "${CLIENT_ID}-mosh"
type       = "udp"
localIP    = "127.0.0.1"
localPort  = ${MOSH_REMOTE_PORT}
remotePort = ${MOSH_REMOTE_PORT}
TOML
ok "frpc config written"

# ── 8. Zellij config ────────────────────────────────────────────────────────
ZELLIJ_DIR="$HOME/.config/zellij"
mkdir -p "$ZELLIJ_DIR"

if [[ ! -f "${ZELLIJ_DIR}/config.kdl" ]]; then
    cat > "${ZELLIJ_DIR}/config.kdl" <<'KDL'
default_shell "zsh"
pane_frames false
default_layout "compact"
mouse_mode true
scroll_buffer_size 50000
copy_on_select true
KDL
    ok "Zellij config created."
fi

# ── 9. Create start/stop scripts ────────────────────────────────────────────
cat > "${CONFIG_DIR}/start.sh" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
CONFIG_DIR="$HOME/.liveterminal"
source "${CONFIG_DIR}/config"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'

# Start frpc
if ! pgrep -f "frpc.*frpc.toml" &>/dev/null; then
    printf "${CYAN}[LiveTerminal]${NC} Starting tunnel...\n"
    nohup frpc -c "${CONFIG_DIR}/frpc.toml" > "${CONFIG_DIR}/frpc.log" 2>&1 &
    sleep 2
    if pgrep -f "frpc.*frpc.toml" &>/dev/null; then
        printf "${GREEN}[✓]${NC} Tunnel active.\n"
    else
        echo "[!] Tunnel failed. Check ${CONFIG_DIR}/frpc.log"
        exit 1
    fi
else
    printf "${GREEN}[✓]${NC} Tunnel already running.\n"
fi

# Heartbeat
ACCESS_TOKEN=$(cat "${CONFIG_DIR}/access_token")
CLIENT_ID=$(cat "${CONFIG_DIR}/client_id")
curl -sS -X POST "http://${VPS_IP}:${WEB_PORT}/api/heartbeat" \
    -H "Content-Type: application/json" \
    -d "{\"clientId\":\"${CLIENT_ID}\",\"accessToken\":\"${ACCESS_TOKEN}\"}" >/dev/null 2>&1 || true

# Zellij
SESSION="liveterminal"
if zellij list-sessions 2>/dev/null | grep -q "$SESSION"; then
    zellij attach "$SESSION"
else
    zellij --session "$SESSION"
fi
LAUNCH
chmod +x "${CONFIG_DIR}/start.sh"

cat > "${CONFIG_DIR}/stop.sh" <<'STOP'
#!/usr/bin/env bash
echo "Stopping frpc tunnel..."
pkill -f "frpc.*frpc.toml" 2>/dev/null && echo "Done." || echo "Not running."
STOP
chmod +x "${CONFIG_DIR}/stop.sh"

# ── 10. Shell aliases ───────────────────────────────────────────────────────
SHELL_RC="$HOME/.zshrc"
[[ -f "$SHELL_RC" ]] || SHELL_RC="$HOME/.bashrc"

if ! grep -q 'liveterminal' "$SHELL_RC" 2>/dev/null; then
    cat >> "$SHELL_RC" <<ALIAS

# LiveTerminal
alias liveterminal="${CONFIG_DIR}/start.sh"
alias liveterminal-stop="${CONFIG_DIR}/stop.sh"
ALIAS
    ok "Added aliases to ${SHELL_RC}"
fi

# ── Output ───────────────────────────────────────────────────────────────────
clear

cat <<'BANNER'

  ╦  ╦╦  ╦╔═╗╔╦╗╔═╗╦═╗╔╦╗╦╔╗╔╔═╗╦
  ║  ║╚╗╔╝║╣  ║ ║╣ ╠╦╝║║║║║║║╠═╣║
  ╩═╝╩ ╚╝ ╚═╝ ╩ ╚═╝╩╚═╩ ╩╩╝╚╝╩ ╩╩═╝

BANNER

TERMINAL_URL="${SERVER_URL}/terminal.html?id=${CLIENT_ID}"

printf "${GREEN}  Installation complete!${NC}\n\n"
printf "  ${BOLD}Your terminal URL:${NC}\n"
printf "  ${CYAN}${TERMINAL_URL}${NC}\n\n"
printf "  ${BOLD}Credentials:${NC}\n"
printf "  Client ID:     ${CYAN}${CLIENT_ID}${NC}\n"
printf "  Access Token:  ${YELLOW}${ACCESS_TOKEN}${NC}\n\n"
printf "  ${BOLD}Tunnel ports:${NC}\n"
printf "  SSH:  ${SSH_REMOTE_PORT}    Mosh: ${MOSH_REMOTE_PORT}\n\n"

# QR code to terminal URL
if command -v qrencode &>/dev/null; then
    printf "  ${BOLD}Scan to open terminal:${NC}\n\n"
    echo "$TERMINAL_URL" | qrencode -t ANSIUTF8 -m 2
    printf "\n"
fi

printf "  ${BOLD}Quick Start:${NC}\n"
printf "  1. Run ${CYAN}liveterminal${NC} to start the tunnel + session\n"
printf "  2. Open the URL above in any browser\n"
printf "  3. Log in with your Client ID + Access Token\n"
printf "  4. Run ${CYAN}claude${NC} inside the terminal\n\n"
printf "  ${BOLD}Stop:${NC} ${CYAN}liveterminal-stop${NC}\n\n"
