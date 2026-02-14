const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");
const { Client: SSHClient } = require("ssh2");
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

// ── Config ──────────────────────────────────────────────────────────────────
const PORT = parseInt(process.env.PORT || "3000", 10);
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, "data");
const CLIENTS_FILE = path.join(DATA_DIR, "clients.json");
const SSH_KEY_FILE = path.join(DATA_DIR, "ssh_key");
const SSH_PUB_FILE = path.join(DATA_DIR, "ssh_key.pub");
const JOIN_TOKEN_FILE = path.join(DATA_DIR, "join_token");

// ── Init ────────────────────────────────────────────────────────────────────
fs.mkdirSync(DATA_DIR, { recursive: true });

// Generate SSH keypair for server → client connections
if (!fs.existsSync(SSH_KEY_FILE)) {
  const { execSync } = require("child_process");
  execSync(
    `ssh-keygen -t ed25519 -f "${SSH_KEY_FILE}" -N "" -C "liveterminal-server"`,
    { stdio: "ignore" }
  );
  console.log("[init] Generated server SSH keypair");
}
const SERVER_SSH_KEY = fs.readFileSync(SSH_KEY_FILE, "utf8");
const SERVER_SSH_PUB = fs.readFileSync(SSH_PUB_FILE, "utf8").trim();

// Join token — shared secret for client registration
let JOIN_TOKEN;
if (fs.existsSync(JOIN_TOKEN_FILE)) {
  JOIN_TOKEN = fs.readFileSync(JOIN_TOKEN_FILE, "utf8").trim();
} else {
  JOIN_TOKEN = crypto.randomBytes(16).toString("hex");
  fs.writeFileSync(JOIN_TOKEN_FILE, JOIN_TOKEN, { mode: 0o600 });
  console.log("[init] Generated join token");
}

// Clients DB (simple JSON)
function loadClients() {
  if (!fs.existsSync(CLIENTS_FILE)) return {};
  return JSON.parse(fs.readFileSync(CLIENTS_FILE, "utf8"));
}
function saveClients(clients) {
  fs.writeFileSync(CLIENTS_FILE, JSON.stringify(clients, null, 2), {
    mode: 0o600,
  });
}

// ── Express ─────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());
app.use(express.static(path.join(__dirname, "public")));

// Serve the client install script directly from the web app
// so developers can do: curl -sSL http://<VPS>:3000/install.sh | bash
const CLIENT_INSTALL = path.join(__dirname, "..", "..", "client", "install.sh");
app.get("/install.sh", (req, res) => {
  // Try bundled path first, then fallback to local copy
  const candidates = [
    CLIENT_INSTALL,
    path.join(__dirname, "install-client.sh"),
  ];
  for (const p of candidates) {
    if (fs.existsSync(p)) {
      res.type("text/plain").sendFile(p);
      return;
    }
  }
  res.status(404).send("# Client install script not found on this server.\n");
});

// API: get server SSH public key (clients need this during install)
app.get("/api/server-key", (req, res) => {
  res.json({ publicKey: SERVER_SSH_PUB });
});

// API: register a new client
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

// API: heartbeat from client
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

// API: validate access token (used by terminal page)
app.post("/api/auth", (req, res) => {
  const { clientId, accessToken } = req.body;
  const clients = loadClients();
  const client = clients[clientId];

  if (!client || client.accessToken !== hashToken(accessToken)) {
    return res.status(403).json({ error: "Invalid credentials" });
  }

  // Return a session token (valid for this browser session)
  const sessionToken = crypto.randomBytes(32).toString("hex");
  client.sessionToken = hashToken(sessionToken);
  client.sessionExpiry = Date.now() + 24 * 60 * 60 * 1000; // 24h
  saveClients(clients);

  res.json({ ok: true, sessionToken, user: client.user, sshPort: client.sshPort });
});

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

// ── HTTP + WebSocket server ─────────────────────────────────────────────────
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

  console.log(`[ws] Terminal session for ${clientId} (${client.user}@localhost:${client.sshPort})`);

  // SSH into the client's Mac through the frp tunnel
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

      // SSH → browser
      stream.on("data", (data) => {
        if (ws.readyState === ws.OPEN) {
          ws.send(JSON.stringify({ type: "data", data: data.toString("base64") }));
        }
      });

      stream.on("close", () => {
        console.log(`[ssh] Stream closed for ${clientId}`);
        ws.close();
      });

      stream.stderr.on("data", (data) => {
        if (ws.readyState === ws.OPEN) {
          ws.send(JSON.stringify({ type: "data", data: data.toString("base64") }));
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

  // Browser → SSH
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

  // Connect SSH
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
  console.log(`  Join token: ${JOIN_TOKEN}\n`);
});
