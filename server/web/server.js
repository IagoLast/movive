const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");
const { Client: SSHClient } = require("ssh2");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

// ── Config ──────────────────────────────────────────────────────────────────
const PORT = parseInt(process.env.PORT || "3000", 10);
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, "data");
const CLIENTS_FILE = path.join(DATA_DIR, "clients.json");
const SSH_KEY_FILE = path.join(DATA_DIR, "ssh_key");
const SSH_PUB_FILE = path.join(DATA_DIR, "ssh_key.pub");
const JOIN_TOKEN_FILE = path.join(DATA_DIR, "join_token");
const FRP_TOKEN_FILE = "/etc/frp/.token";
const FRP_PORT = parseInt(process.env.FRP_PORT || "7000", 10);

// ── Init ────────────────────────────────────────────────────────────────────
fs.mkdirSync(DATA_DIR, { recursive: true });

// Generate SSH keypair for server → client connections
if (!fs.existsSync(SSH_KEY_FILE)) {
  execSync(
    `ssh-keygen -t ed25519 -f "${SSH_KEY_FILE}" -N "" -C "liveterminal-server"`,
    { stdio: "ignore" }
  );
  console.log("[init] Generated server SSH keypair");
}
const SERVER_SSH_KEY = fs.readFileSync(SSH_KEY_FILE, "utf8");
const SERVER_SSH_PUB = fs.readFileSync(SSH_PUB_FILE, "utf8").trim();

// Join token
let JOIN_TOKEN;
if (fs.existsSync(JOIN_TOKEN_FILE)) {
  JOIN_TOKEN = fs.readFileSync(JOIN_TOKEN_FILE, "utf8").trim();
} else {
  JOIN_TOKEN = crypto.randomBytes(16).toString("hex");
  fs.writeFileSync(JOIN_TOKEN_FILE, JOIN_TOKEN, { mode: 0o600 });
  console.log("[init] Generated join token");
}

// frp auth token (read from frps config)
let FRP_TOKEN = "";
if (fs.existsSync(FRP_TOKEN_FILE)) {
  FRP_TOKEN = fs.readFileSync(FRP_TOKEN_FILE, "utf8").trim();
}

// Detect VPS IP
let VPS_IP = process.env.VPS_IP || "";
if (!VPS_IP) {
  try {
    VPS_IP = execSync("curl -s4 ifconfig.me", { timeout: 5000 })
      .toString()
      .trim();
  } catch {
    VPS_IP = "YOUR_VPS_IP";
  }
}

// Clients DB
function loadClients() {
  if (!fs.existsSync(CLIENTS_FILE)) return {};
  return JSON.parse(fs.readFileSync(CLIENTS_FILE, "utf8"));
}
function saveClients(clients) {
  fs.writeFileSync(CLIENTS_FILE, JSON.stringify(clients, null, 2), {
    mode: 0o600,
  });
}

function hashToken(token) {
  return crypto.createHash("sha256").update(token).digest("hex");
}

function validateSession(clientId, sessionToken) {
  const clients = loadClients();
  const client = clients[clientId];
  if (!client) return null;
  if (client.sessionToken !== hashToken(sessionToken)) return null;
  if (Date.now() > client.sessionExpiry) return null;
  return client;
}

// ── Express ─────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

// ── Dynamic install.sh — plug and play, zero prompts ────────────────────────
app.get("/install.sh", (req, res) => {
  res.type("text/plain").send(generateInstallScript());
});

function generateInstallScript() {
  return `#!/usr/bin/env bash
# =============================================================================
# LiveTerminal — Mac Client Installer (auto-configured)
# Just run: curl -sSL http://${VPS_IP}:${PORT}/install.sh | bash
# =============================================================================
set -euo pipefail

RED='\\033[0;31m'; GREEN='\\033[0;32m'; YELLOW='\\033[1;33m'
CYAN='\\033[0;36m'; BOLD='\\033[1m'; NC='\\033[0m'

info()  { printf "\${CYAN}[LiveTerminal]\${NC} %s\\n" "$*"; }
ok()    { printf "\${GREEN}[✓]\${NC} %s\\n" "$*"; }
warn()  { printf "\${YELLOW}[!]\${NC} %s\\n" "$*"; }
fail()  { printf "\${RED}[✗]\${NC} %s\\n" "$*"; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "This script is for macOS only."

# ── Pre-configured by server ─────────────────────────────────────────────────
VPS_IP="${VPS_IP}"
WEB_PORT="${PORT}"
FRP_TOKEN="${FRP_TOKEN}"
FRP_PORT="${FRP_PORT}"
JOIN_TOKEN="${JOIN_TOKEN}"
SERVER_SSH_PUB="${SERVER_SSH_PUB}"
SERVER_URL="http://\${VPS_IP}:\${WEB_PORT}"

# ── Client identity ─────────────────────────────────────────────────────────
CONFIG_DIR="$HOME/.liveterminal"
mkdir -p "$CONFIG_DIR"
ID_FILE="\${CONFIG_DIR}/client_id"
TOKEN_FILE="\${CONFIG_DIR}/access_token"

if [[ -f "\$ID_FILE" ]]; then
    CLIENT_ID=$(cat "\$ID_FILE")
    ACCESS_TOKEN=$(cat "\$TOKEN_FILE")
    info "Existing client: \${CLIENT_ID}"
else
    CLIENT_ID="lt-$(openssl rand -hex 4)"
    ACCESS_TOKEN=$(openssl rand -hex 16)
    echo "\$CLIENT_ID" > "\$ID_FILE"
    echo "\$ACCESS_TOKEN" > "\$TOKEN_FILE"
    chmod 600 "\$TOKEN_FILE"
    ok "Client ID: \${CLIENT_ID}"
fi

# Deterministic port from client ID
HASH=$(echo -n "\$CLIENT_ID" | md5 | cut -c1-4)
PORT_OFFSET=$(( 16#\$HASH % 10000 ))
SSH_REMOTE_PORT=$(( 10000 + PORT_OFFSET ))
MOSH_REMOTE_PORT=$(( 30000 + PORT_OFFSET ))

# ── 1. Homebrew ──────────────────────────────────────────────────────────────
info "Checking Homebrew..."
if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/null \\
        || fail "Homebrew installation failed."
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile" 2>/dev/null || true
    fi
    ok "Homebrew installed."
else
    ok "Homebrew found."
fi

# ── 2. Packages ──────────────────────────────────────────────────────────────
for pkg in mosh zellij qrencode; do
    if brew list "\$pkg" &>/dev/null; then
        ok "\${pkg} already installed."
    else
        info "Installing \${pkg}..."
        brew install "\$pkg" < /dev/null || fail "Failed to install \${pkg}."
        ok "\${pkg} installed."
    fi
done

# ── 3. frpc ──────────────────────────────────────────────────────────────────
FRPC_BIN="/usr/local/bin/frpc"
if [[ -f "\$FRPC_BIN" ]]; then
    ok "frpc already installed."
else
    info "Downloading frpc..."
    FRP_VERSION="0.61.1"
    ARCH=$(uname -m)
    case "\$ARCH" in
        x86_64) FRP_ARCH="amd64" ;;
        arm64)  FRP_ARCH="arm64" ;;
        *)      fail "Unsupported: \$ARCH" ;;
    esac
    TMP=$(mktemp -d)
    curl -sSL --retry 3 -o "\${TMP}/frp.tar.gz" \\
        "https://github.com/fatedier/frp/releases/download/v\${FRP_VERSION}/frp_\${FRP_VERSION}_darwin_\${FRP_ARCH}.tar.gz" \\
        || fail "Failed to download frpc."
    tar -xzf "\${TMP}/frp.tar.gz" -C "\$TMP"
    sudo cp "\${TMP}"/frp_*/frpc "\$FRPC_BIN"
    sudo chmod +x "\$FRPC_BIN"
    rm -rf "\$TMP"
    ok "frpc installed"
fi

# ── 4. Enable SSH ────────────────────────────────────────────────────────────
info "Enabling macOS Remote Login..."
SSH_STATUS=$(sudo systemsetup -getremotelogin 2>/dev/null | awk '{print \$NF}')
if [[ "\$SSH_STATUS" == "On" ]]; then
    ok "Remote Login already enabled."
else
    sudo systemsetup -setremotelogin on 2>/dev/null \\
        || warn "Enable manually: System Settings > General > Sharing > Remote Login"
fi

# ── 5. Authorize server SSH key ──────────────────────────────────────────────
SSH_DIR="$HOME/.ssh"
mkdir -p "\$SSH_DIR" && chmod 700 "\$SSH_DIR"
AUTH_KEYS="\$SSH_DIR/authorized_keys"
if [[ -f "\$AUTH_KEYS" ]] && grep -qF "\$SERVER_SSH_PUB" "\$AUTH_KEYS" 2>/dev/null; then
    ok "Server key already authorized."
else
    echo "\$SERVER_SSH_PUB" >> "\$AUTH_KEYS"
    chmod 600 "\$AUTH_KEYS"
    ok "Server SSH key authorized."
fi

# ── 6. Register with server ─────────────────────────────────────────────────
info "Registering..."
MAC_USER=$(whoami)

REG=$(curl -sS -X POST "\${SERVER_URL}/api/register" \\
    -H "Content-Type: application/json" \\
    -d "{
        \\"joinToken\\": \\"\${JOIN_TOKEN}\\",
        \\"clientId\\": \\"\${CLIENT_ID}\\",
        \\"user\\": \\"\${MAC_USER}\\",
        \\"sshPort\\": \${SSH_REMOTE_PORT},
        \\"moshPort\\": \${MOSH_REMOTE_PORT},
        \\"accessToken\\": \\"\${ACCESS_TOKEN}\\"
    }" 2>/dev/null) || fail "Could not reach server."

if echo "\$REG" | python3 -c "import sys,json; assert json.load(sys.stdin).get('ok')" 2>/dev/null; then
    ok "Registered."
else
    fail "Registration failed."
fi

# ── 7. frpc config ───────────────────────────────────────────────────────────
cat > "\${CONFIG_DIR}/frpc.toml" <<TOML
serverAddr = "\${VPS_IP}"
serverPort = \${FRP_PORT}
auth.method = "token"
auth.token  = "\${FRP_TOKEN}"

[[proxies]]
name       = "\${CLIENT_ID}-ssh"
type       = "tcp"
localIP    = "127.0.0.1"
localPort  = 22
remotePort = \${SSH_REMOTE_PORT}

[[proxies]]
name       = "\${CLIENT_ID}-mosh"
type       = "udp"
localIP    = "127.0.0.1"
localPort  = \${MOSH_REMOTE_PORT}
remotePort = \${MOSH_REMOTE_PORT}
TOML

# ── 8. Start/stop scripts ───────────────────────────────────────────────────
cat > "\${CONFIG_DIR}/start.sh" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
DIR="$HOME/.liveterminal"
if ! pgrep -f "frpc.*frpc.toml" &>/dev/null; then
    echo "[LiveTerminal] Starting tunnel..."
    nohup frpc -c "\${DIR}/frpc.toml" > "\${DIR}/frpc.log" 2>&1 &
    sleep 2
    if pgrep -f "frpc.*frpc.toml" &>/dev/null; then
        echo "[✓] Tunnel active. Access your terminal from the web."
    else
        echo "[✗] Tunnel failed. Check \${DIR}/frpc.log"
        exit 1
    fi
else
    echo "[✓] Tunnel already running."
fi
LAUNCH
chmod +x "\${CONFIG_DIR}/start.sh"

cat > "\${CONFIG_DIR}/stop.sh" <<'STOP'
#!/usr/bin/env bash
pkill -f "frpc.*frpc.toml" 2>/dev/null && echo "Stopped." || echo "Not running."
STOP
chmod +x "\${CONFIG_DIR}/stop.sh"

# ── 9. Shell aliases ────────────────────────────────────────────────────────
SHELL_RC="$HOME/.zshrc"
[[ -f "\$SHELL_RC" ]] || SHELL_RC="$HOME/.bashrc"
if ! grep -q 'liveterminal' "\$SHELL_RC" 2>/dev/null; then
    printf '\\n# LiveTerminal\\nalias liveterminal="%s/start.sh"\\nalias liveterminal-stop="%s/stop.sh"\\n' "\$CONFIG_DIR" "\$CONFIG_DIR" >> "\$SHELL_RC"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
clear
TERMINAL_URL="\${SERVER_URL}/terminal.html?id=\${CLIENT_ID}"

cat <<'BANNER'

  ╦  ╦╦  ╦╔═╗╔╦╗╔═╗╦═╗╔╦╗╦╔╗╔╔═╗╦
  ║  ║╚╗╔╝║╣  ║ ║╣ ╠╦╝║║║║║║║╠═╣║
  ╩═╝╩ ╚╝ ╚═╝ ╩ ╚═╝╩╚═╩ ╩╩╝╚╝╩ ╩╩═╝

BANNER

printf "\${GREEN}  Installation complete!\${NC}\\n\\n"
printf "  \${BOLD}Your terminal:\${NC} \${CYAN}\${TERMINAL_URL}\${NC}\\n\\n"
printf "  \${BOLD}Credentials (save these):\${NC}\\n"
printf "  Client ID:     \${CYAN}\${CLIENT_ID}\${NC}\\n"
printf "  Access Token:  \${YELLOW}\${ACCESS_TOKEN}\${NC}\\n\\n"

# QR code
if command -v qrencode &>/dev/null; then
    printf "  \${BOLD}Scan to open:\${NC}\\n\\n"
    echo "\$TERMINAL_URL" | qrencode -t ANSIUTF8 -m 2
    printf "\\n"
fi

# ── 10. Auto-start tunnel ────────────────────────────────────────────────────
printf "  \${BOLD}Starting tunnel...\${NC}\\n"
nohup frpc -c "\${CONFIG_DIR}/frpc.toml" > "\${CONFIG_DIR}/frpc.log" 2>&1 &
sleep 2
if pgrep -f "frpc.*frpc.toml" &>/dev/null; then
    printf "  \${GREEN}[✓] Tunnel active!\${NC}\\n\\n"
    printf "  \${BOLD}You're all set.\${NC} Open the URL or scan the QR.\\n"
    printf "  To stop: \${CYAN}liveterminal-stop\${NC}\\n"
    printf "  To reconnect later: \${CYAN}liveterminal\${NC} (open a new terminal first)\\n\\n"
else
    printf "  \${RED}[!] Tunnel failed to start.\${NC} Check \${CONFIG_DIR}/frpc.log\\n\\n"
fi
`;
}

// ── API ─────────────────────────────────────────────────────────────────────
app.get("/api/server-key", (req, res) => {
  res.json({ publicKey: SERVER_SSH_PUB });
});

app.post("/api/register", (req, res) => {
  const { joinToken, clientId, user, sshPort, moshPort, accessToken } =
    req.body;

  if (joinToken !== JOIN_TOKEN) {
    return res.status(403).json({ error: "Invalid join token" });
  }
  if (!clientId || !user || !sshPort || !accessToken) {
    return res.status(400).json({ error: "Missing required fields" });
  }

  const clients = loadClients();
  clients[clientId] = {
    user,
    sshPort: parseInt(sshPort, 10),
    moshPort: parseInt(moshPort, 10),
    accessToken: hashToken(accessToken),
    registeredAt: new Date().toISOString(),
    lastSeen: new Date().toISOString(),
  };
  saveClients(clients);

  console.log(
    `[register] Client ${clientId} (${user}@localhost:${sshPort}) registered`
  );
  res.json({ ok: true, url: `/terminal.html?id=${clientId}` });
});

app.post("/api/heartbeat", (req, res) => {
  const { clientId, accessToken } = req.body;
  const clients = loadClients();
  const client = clients[clientId];

  if (!client || client.accessToken !== hashToken(accessToken)) {
    return res.status(403).json({ error: "Unauthorized" });
  }

  client.lastSeen = new Date().toISOString();
  saveClients(clients);
  res.json({ ok: true });
});

app.post("/api/auth", (req, res) => {
  const { clientId, accessToken } = req.body;
  const clients = loadClients();
  const client = clients[clientId];

  if (!client || client.accessToken !== hashToken(accessToken)) {
    return res.status(403).json({ error: "Invalid credentials" });
  }

  const sessionToken = crypto.randomBytes(32).toString("hex");
  client.sessionToken = hashToken(sessionToken);
  client.sessionExpiry = Date.now() + 24 * 60 * 60 * 1000;
  saveClients(clients);

  res.json({
    ok: true,
    sessionToken,
    user: client.user,
    sshPort: client.sshPort,
  });
});

// ── WebSocket terminal ──────────────────────────────────────────────────────
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: "/ws" });

wss.on("connection", (ws, req) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const clientId = url.searchParams.get("id");
  const sessionToken = url.searchParams.get("session");

  const client = validateSession(clientId, sessionToken);
  if (!client) {
    ws.send(JSON.stringify({ type: "error", message: "Unauthorized" }));
    ws.close();
    return;
  }

  console.log(
    `[ws] Terminal session for ${clientId} (${client.user}@localhost:${client.sshPort})`
  );

  const ssh = new SSHClient();
  let stream = null;

  ssh.on("ready", () => {
    console.log(`[ssh] Connected to ${clientId}`);
    ssh.shell({ term: "xterm-256color", cols: 120, rows: 40 }, (err, s) => {
      if (err) {
        ws.send(JSON.stringify({ type: "error", message: err.message }));
        ws.close();
        return;
      }
      stream = s;

      stream.on("data", (data) => {
        if (ws.readyState === ws.OPEN) {
          ws.send(
            JSON.stringify({ type: "data", data: data.toString("base64") })
          );
        }
      });

      stream.on("close", () => {
        console.log(`[ssh] Stream closed for ${clientId}`);
        ws.close();
      });

      stream.stderr.on("data", (data) => {
        if (ws.readyState === ws.OPEN) {
          ws.send(
            JSON.stringify({ type: "data", data: data.toString("base64") })
          );
        }
      });
    });
  });

  ssh.on("error", (err) => {
    console.error(`[ssh] Error for ${clientId}: ${err.message}`);
    ws.send(
      JSON.stringify({ type: "error", message: `SSH error: ${err.message}` })
    );
    ws.close();
  });

  ssh.on("close", () => {
    if (ws.readyState === ws.OPEN) ws.close();
  });

  ws.on("message", (raw) => {
    try {
      const msg = JSON.parse(raw);
      if (msg.type === "data" && stream) {
        stream.write(Buffer.from(msg.data, "base64"));
      } else if (msg.type === "resize" && stream) {
        stream.setWindow(msg.rows, msg.cols, 0, 0);
      }
    } catch {}
  });

  ws.on("close", () => {
    console.log(`[ws] Disconnected ${clientId}`);
    ssh.end();
  });

  ssh.connect({
    host: "127.0.0.1",
    port: client.sshPort,
    username: client.user,
    privateKey: SERVER_SSH_KEY,
    readyTimeout: 10000,
    keepaliveInterval: 15000,
    keepaliveCountMax: 5,
  });
});

// ── Start ───────────────────────────────────────────────────────────────────
server.listen(PORT, "0.0.0.0", () => {
  console.log(`\n  LiveTerminal server running on http://0.0.0.0:${PORT}`);
  console.log(`  VPS IP: ${VPS_IP}`);
  console.log(`  Join token: ${JOIN_TOKEN}\n`);
});
