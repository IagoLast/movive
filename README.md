# LiveTerminal

Control **Claude Code** on your Mac from any browser or iPhone — remotely, securely, with zero lag.

```
  Dev Mac 1 ──frpc──┐                          ┌── Browser / iPhone
  Dev Mac 2 ──frpc──┤── VPS (frps + web app) ──┤── Browser / iPhone
  Dev Mac 3 ──frpc──┤   xterm.js dashboard     └── Browser / iPhone
                    └───────────────────────────
```

## How It Works

1. **You** deploy the server on a VPS (DigitalOcean, Hetzner, etc.)
2. **Each developer** runs `curl | bash` on their Mac to install the client
3. The Mac opens an **frp reverse tunnel** to the VPS
4. The VPS runs a **web app** with xterm.js — each developer gets their own terminal URL
5. Open the URL from any browser (desktop, iPhone, iPad) — you get a full terminal on the Mac
6. **Zellij** keeps the session alive if you disconnect

## Architecture

| Layer | Tool | Purpose |
|-------|------|---------|
| Transport | **SSH + frp** | Encrypted reverse tunnel through VPS |
| Persistence | **zellij** | Session survives disconnects |
| Tunnel | **frp** (frps/frpc) | You own the infrastructure |
| Web terminal | **xterm.js + ssh2** | Full terminal in the browser |
| Mobile | **Blink Shell** (optional) | Native mosh client for iOS |

## Setup

### 1. Server (VPS) — one time

```bash
curl -sSL https://raw.githubusercontent.com/IagoLast/movive/main/server/install.sh | sudo bash
```

This installs `frps` + a Node.js web app and prints:
- **VPS IP**
- **frp Auth Token**
- **Join Token**

Save all three.

### 2. Client (Mac) — each developer

```bash
curl -sSL http://<VPS_IP>:3000/install.sh | bash
```

The script asks for the VPS IP, Join Token, and frp Auth Token, then:
1. Installs Homebrew, mosh, zellij, frpc, qrencode
2. Enables SSH (Remote Login) on macOS
3. Fetches the server's SSH public key and adds it to `authorized_keys`
4. Registers with the server API
5. Writes the frpc tunnel config
6. Prints a **terminal URL** + **QR code**

### 3. Daily use

**On the Mac** — start the tunnel:
```bash
liveterminal
```

**From any browser** — open your terminal URL:
```
http://<VPS_IP>:3000/terminal.html?id=lt-xxxxxxxx
```

Log in with your Client ID + Access Token. You get a full terminal. Run `claude` inside it.

**Stop:**
```bash
liveterminal-stop
```

## File Structure

```
.
├── client/
│   └── install.sh              # Mac installer (curl | bash)
├── server/
│   ├── install.sh              # VPS installer (curl | sudo bash)
│   ├── frps.toml               # Reference frp server config
│   └── web/
│       ├── package.json
│       ├── server.js           # Express + WebSocket + SSH2
│       └── public/
│           ├── index.html      # Login page
│           ├── terminal.html   # xterm.js terminal
│           └── css/
│               └── style.css
└── README.md
```

## Security

- All terminal traffic is encrypted (SSH end-to-end through the tunnel)
- Each developer gets a unique client ID, access token, and port
- The server uses an ed25519 SSH key to connect to client Macs
- Join token prevents unauthorized registrations
- Session tokens expire after 24h
- The VPS never sees plaintext terminal content

## Blink Shell (iPhone, optional)

For native mosh performance on iOS:

1. Install [Blink Shell](https://apps.apple.com/app/blink-shell-mosh-ssh/id1594898306)
2. Add a host: **Hostname** = VPS IP, **Port** = your SSH tunnel port, **User** = your Mac username
3. Connect: `ssh -p <SSH_PORT> <user>@<VPS_IP>`

Or use the web terminal — it works on any browser including Safari on iPhone.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `frpc` won't connect | Check VPS IP and frp auth token in `~/.liveterminal/config` |
| Web terminal shows "SSH error" | Ensure `liveterminal` is running on the Mac |
| Port conflict | Delete `~/.liveterminal/client_id` and re-run install |
| SSH refused on Mac | Enable Remote Login: System Settings > General > Sharing |
| Registration fails | Verify the Join Token matches the server |

## License

MIT
