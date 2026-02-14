# LiveTerminal

Control **Claude Code** on your Mac from an iPhone — remotely, securely, with zero lag.

```
  Mac (Claude Code)  ←──frp tunnel──→  VPS  ←──mosh──→  iPhone (Blink Shell)
```

## Architecture

| Layer | Tool | Purpose |
|-------|------|---------|
| Transport | **mosh** | UDP-based, handles network switches and high latency |
| Persistence | **zellij** | Terminal multiplexer — sessions survive disconnects |
| Tunnel | **frp** | Reverse proxy through your VPS — you own the infra |
| Client | **Blink Shell** | iOS terminal with mosh support |

## Setup

### 1. Server (VPS) — one time

On your Linux VPS (Ubuntu/Debian/CentOS):

```bash
curl -sSL https://raw.githubusercontent.com/<YOUR_USER>/movive/main/server/install.sh | sudo bash
```

This installs `frps`, configures the firewall, and starts the service. At the end it prints:
- **VPS IP**
- **Auth token** (save this — the Mac client needs it)

### 2. Client (Mac) — one time

On your Mac:

```bash
curl -sSL https://raw.githubusercontent.com/<YOUR_USER>/movive/main/client/install.sh | bash
```

The script will ask for:
1. Your VPS IP
2. The auth token from step 1

It installs `mosh`, `zellij`, `frpc`, enables SSH, and prints:
- SSH/Mosh connection commands
- A **QR code** you can scan from your iPhone

### 3. Daily use

On the Mac, start the tunnel and session:

```bash
liveterminal
```

Then connect from your iPhone. Inside the session:

```bash
claude
```

To stop the tunnel:

```bash
liveterminal-stop
```

## Blink Shell (iPhone) Configuration

1. **Install** [Blink Shell](https://apps.apple.com/app/blink-shell-mosh-ssh/id1594898306) from the App Store.

2. **Add a new host:**
   - **Host:** any nickname (e.g. `mac`)
   - **Hostname:** your VPS IP
   - **Port:** the SSH tunnel port shown after install (e.g. `13742`)
   - **User:** your Mac username
   - **Key:** add your SSH key or use password

3. **Connect with Mosh** (recommended for mobile):
   - Open Blink and type:
     ```
     mosh --ssh='ssh -p <SSH_PORT>' --port=<MOSH_PORT> <user>@<VPS_IP>
     ```
   - Or create a Blink shortcut for this command.

4. **Alternative — SSH only:**
   ```
   ssh -p <SSH_PORT> <user>@<VPS_IP>
   ```

### Recommended Blink Settings

- **Font:** Menlo or SF Mono, size 12-14
- **Keyboard:** enable "Caps Lock as Ctrl" for easier terminal use
- **Appearance:** dark theme for outdoor streaming

## File Structure

```
.
├── client/
│   └── install.sh        # Mac installer
├── server/
│   ├── install.sh         # VPS installer
│   └── frps.toml          # Reference server config
└── README.md
```

## How It Works

1. **Mac** runs `frpc` which opens a reverse tunnel to your VPS on a unique port
2. **VPS** runs `frps` and forwards traffic from that port back to the Mac's SSH
3. **iPhone** connects via mosh/SSH to the VPS port → traffic reaches the Mac
4. **Zellij** keeps the terminal session alive even if the iPhone disconnects
5. Inside that persistent session, **Claude Code** keeps running

## Security Notes

- All traffic is encrypted (SSH/mosh)
- Auth token secures the frp tunnel — treat it like a password
- Each client gets a unique port derived from its client ID — no collisions
- The VPS never sees plaintext terminal content (end-to-end SSH)
- Remote Login on Mac is scoped to the installing user

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `frpc` won't connect | Check VPS IP/token in `~/.liveterminal/config` |
| Port conflict | Delete `~/.liveterminal/client_id` and re-run install |
| SSH refused | Verify Remote Login is on: System Settings > General > Sharing |
| Mosh timeout | Ensure UDP port is open on VPS firewall |
| Blink can't connect | Confirm you're using the tunnel port, not port 22 |

## License

MIT
