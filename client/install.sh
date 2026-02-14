#!/usr/bin/env bash
# =============================================================================
# LiveTerminal - Mac Client Installer
# Sets up: Homebrew, mosh, zellij, frpc, SSH, and prints connection info + QR.
# Usage:  curl -sSL https://raw.githubusercontent.com/<REPO>/client/install.sh | bash
# =============================================================================
set -euo pipefail

# ── Colours & helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}[LiveTerminal]${NC} %s\n" "$*"; }
ok()    { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
fail()  { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }

# ── Prompt for VPS info ──────────────────────────────────────────────────────
CONFIG_DIR="$HOME/.liveterminal"
CONFIG_FILE="${CONFIG_DIR}/config"

load_or_prompt_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        info "Loaded existing config from ${CONFIG_FILE}"
        info "VPS: ${VPS_IP}  Token: ${AUTH_TOKEN:0:8}..."
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
    printf "\n${BOLD}LiveTerminal Setup${NC}\n"
    printf "Enter your VPS IP (from server install): "
    read -r VPS_IP
    [[ -z "$VPS_IP" ]] && fail "VPS IP is required."

    printf "Enter the auth token (from server install): "
    read -r AUTH_TOKEN
    [[ -z "$AUTH_TOKEN" ]] && fail "Auth token is required."

    printf "Enter the frp server port [7000]: "
    read -r SERVER_PORT
    SERVER_PORT="${SERVER_PORT:-7000}"

    cat > "$CONFIG_FILE" <<EOF
VPS_IP="${VPS_IP}"
AUTH_TOKEN="${AUTH_TOKEN}"
SERVER_PORT="${SERVER_PORT}"
EOF
    chmod 600 "$CONFIG_FILE"
    ok "Config saved to ${CONFIG_FILE}"
}

load_or_prompt_config

# ── macOS check ──────────────────────────────────────────────────────────────
[[ "$(uname)" == "Darwin" ]] || fail "This script is for macOS only."

# ── Generate unique client ID ────────────────────────────────────────────────
ID_FILE="${CONFIG_DIR}/client_id"
if [[ -f "$ID_FILE" ]]; then
    CLIENT_ID=$(cat "$ID_FILE")
else
    CLIENT_ID="lt-$(openssl rand -hex 4)"
    echo "$CLIENT_ID" > "$ID_FILE"
fi
ok "Client ID: ${CLIENT_ID}"

# Deterministic port from client ID (hash → range 10000-19999)
HASH=$(echo -n "$CLIENT_ID" | md5 | cut -c1-4)
PORT_OFFSET=$(( 16#$HASH % 10000 ))
SSH_REMOTE_PORT=$(( 10000 + PORT_OFFSET ))
MOSH_REMOTE_PORT=$(( 30000 + PORT_OFFSET ))
info "Assigned SSH tunnel port: ${SSH_REMOTE_PORT}"
info "Assigned Mosh tunnel port: ${MOSH_REMOTE_PORT}"

# ── 1. Homebrew ──────────────────────────────────────────────────────────────
info "Checking Homebrew..."
if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || fail "Homebrew installation failed."

    # Add to PATH for Apple Silicon
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        # Persist in shell profile
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
    ok "frpc installed to ${FRPC_BIN}"
fi

# ── 4. Enable Remote Login (SSH) ────────────────────────────────────────────
info "Enabling macOS Remote Login (SSH)..."
SSH_STATUS=$(sudo systemsetup -getremotelogin 2>/dev/null | awk '{print $NF}')
if [[ "$SSH_STATUS" == "On" ]]; then
    ok "Remote Login already enabled."
else
    sudo systemsetup -setremotelogin on 2>/dev/null \
        || warn "Could not enable Remote Login automatically. Enable it in System Settings > General > Sharing > Remote Login."
fi

# ── 5. Write frpc config ────────────────────────────────────────────────────
FRPC_CONF="${CONFIG_DIR}/frpc.toml"
MAC_USER=$(whoami)

cat > "$FRPC_CONF" <<TOML
# LiveTerminal — frpc client config
# Auto-generated. Client ID: ${CLIENT_ID}

serverAddr = "${VPS_IP}"
serverPort = ${SERVER_PORT}

auth.method = "token"
auth.token  = "${AUTH_TOKEN}"

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
ok "frpc config written to ${FRPC_CONF}"

# ── 6. Zellij default session ───────────────────────────────────────────────
ZELLIJ_DIR="$HOME/.config/zellij"
mkdir -p "$ZELLIJ_DIR"

if [[ ! -f "${ZELLIJ_DIR}/config.kdl" ]]; then
    cat > "${ZELLIJ_DIR}/config.kdl" <<'KDL'
// LiveTerminal — Zellij config
// Optimised for remote Claude Code sessions

default_shell "zsh"
pane_frames false
default_layout "compact"
mouse_mode true
scroll_buffer_size 50000
copy_on_select true

theme "default"
KDL
    ok "Zellij config created."
else
    ok "Zellij config already exists (keeping yours)."
fi

# ── 7. Create launch script ─────────────────────────────────────────────────
LAUNCH_SCRIPT="${CONFIG_DIR}/start.sh"
cat > "$LAUNCH_SCRIPT" <<'LAUNCH'
#!/usr/bin/env bash
# LiveTerminal — Start tunnel + Zellij session
set -euo pipefail

CONFIG_DIR="$HOME/.liveterminal"
source "${CONFIG_DIR}/config"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Start frpc in background if not running
if ! pgrep -f "frpc.*frpc.toml" &>/dev/null; then
    echo -e "${CYAN}[LiveTerminal]${NC} Starting tunnel..."
    nohup frpc -c "${CONFIG_DIR}/frpc.toml" > "${CONFIG_DIR}/frpc.log" 2>&1 &
    sleep 2
    if pgrep -f "frpc.*frpc.toml" &>/dev/null; then
        echo -e "${GREEN}[✓]${NC} Tunnel active."
    else
        echo -e "\033[0;31m[✗]\033[0m Tunnel failed. Check ${CONFIG_DIR}/frpc.log"
        exit 1
    fi
else
    echo -e "${GREEN}[✓]${NC} Tunnel already running."
fi

# Start or attach to Zellij session
SESSION_NAME="liveterminal"
if zellij list-sessions 2>/dev/null | grep -q "$SESSION_NAME"; then
    echo -e "${CYAN}[LiveTerminal]${NC} Attaching to existing session..."
    zellij attach "$SESSION_NAME"
else
    echo -e "${CYAN}[LiveTerminal]${NC} Creating new Zellij session..."
    zellij --session "$SESSION_NAME"
fi
LAUNCH
chmod +x "$LAUNCH_SCRIPT"
ok "Launch script: ${LAUNCH_SCRIPT}"

# ── 8. Create stop script ───────────────────────────────────────────────────
STOP_SCRIPT="${CONFIG_DIR}/stop.sh"
cat > "$STOP_SCRIPT" <<'STOP'
#!/usr/bin/env bash
# LiveTerminal — Stop tunnel
set -euo pipefail
echo "Stopping frpc tunnel..."
pkill -f "frpc.*frpc.toml" 2>/dev/null && echo "Done." || echo "Not running."
STOP
chmod +x "$STOP_SCRIPT"

# ── 9. Mosh server wrapper (for UDP through frp) ────────────────────────────
MOSH_WRAPPER="${CONFIG_DIR}/mosh-server-wrapper.sh"
cat > "$MOSH_WRAPPER" <<WRAPPER
#!/usr/bin/env bash
# Forces mosh-server to use the assigned tunnel port
export MOSH_SERVER_NETWORK_TMOUT=604800
exec mosh-server new -p ${MOSH_REMOTE_PORT} -- \$SHELL
WRAPPER
chmod +x "$MOSH_WRAPPER"

# ── 10. Shell alias ─────────────────────────────────────────────────────────
SHELL_RC="$HOME/.zshrc"
[[ -f "$SHELL_RC" ]] || SHELL_RC="$HOME/.bashrc"

if ! grep -q 'liveterminal' "$SHELL_RC" 2>/dev/null; then
    cat >> "$SHELL_RC" <<ALIAS

# LiveTerminal
alias liveterminal="${LAUNCH_SCRIPT}"
alias liveterminal-stop="${STOP_SCRIPT}"
ALIAS
    ok "Added 'liveterminal' alias to ${SHELL_RC}"
fi

# ── Final output ─────────────────────────────────────────────────────────────
clear

# ASCII banner
cat <<'BANNER'

  ╦  ╦╦  ╦╔═╗╔╦╗╔═╗╦═╗╔╦╗╦╔╗╔╔═╗╦
  ║  ║╚╗╔╝║╣  ║ ║╣ ╠╦╝║║║║║║║╠═╣║
  ╩═╝╩ ╚╝ ╚═╝ ╩ ╚═╝╩╚═╩ ╩╩╝╚╝╩ ╩╩═╝

BANNER

printf "${GREEN}  ✓ Installation complete!${NC}\n\n"

printf "  ${BOLD}Connection Info${NC}\n"
printf "  ─────────────────────────────────────────\n"
printf "  Client ID:       ${CYAN}${CLIENT_ID}${NC}\n"
printf "  VPS:             ${CYAN}${VPS_IP}${NC}\n"
printf "  SSH Port:        ${CYAN}${SSH_REMOTE_PORT}${NC}\n"
printf "  Mosh Port (UDP): ${CYAN}${MOSH_REMOTE_PORT}${NC}\n\n"

SSH_CMD="ssh -p ${SSH_REMOTE_PORT} ${MAC_USER}@${VPS_IP}"
MOSH_CMD="mosh --ssh='ssh -p ${SSH_REMOTE_PORT}' --port=${MOSH_REMOTE_PORT} ${MAC_USER}@${VPS_IP}"

printf "  ${BOLD}SSH Command:${NC}\n"
printf "  ${YELLOW}${SSH_CMD}${NC}\n\n"

printf "  ${BOLD}Mosh Command (recommended):${NC}\n"
printf "  ${YELLOW}${MOSH_CMD}${NC}\n\n"

# QR code with the SSH connection string
if command -v qrencode &>/dev/null; then
    printf "  ${BOLD}Scan this QR to get the connection string:${NC}\n\n"
    echo "$SSH_CMD" | qrencode -t ANSIUTF8 -m 2
    printf "\n"
fi

printf "  ${BOLD}Quick Start:${NC}\n"
printf "  1. Run ${CYAN}liveterminal${NC} to start tunnel + session\n"
printf "  2. On iPhone (Blink Shell), connect with the SSH/Mosh command above\n"
printf "  3. Inside the session, run: ${CYAN}claude${NC}\n\n"

printf "  ${BOLD}Stop:${NC} ${CYAN}liveterminal-stop${NC}\n\n"
