#!/usr/bin/env bash
# =============================================================================
# LiveTerminal — Client Installer (standalone fallback)
#
# THIS FILE IS NOT USED DIRECTLY.
# The server generates the install script dynamically at /install.sh
# with all config (IP, tokens, SSH key) pre-baked.
#
# Usage: curl -sSL http://<VPS_IP>:3000/install.sh | bash
# =============================================================================
echo "Error: This script should be downloaded from your LiveTerminal server."
echo ""
echo "Run this instead:"
echo "  curl -sSL http://<VPS_IP>:3000/install.sh | bash"
echo ""
exit 1
