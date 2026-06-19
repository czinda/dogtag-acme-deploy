#!/bin/bash
# DS container first-boot: create 389 Directory Server instance
set -uo pipefail

MARKER="/root/.ds-deployed"
if [ -f "$MARKER" ]; then
    echo "[ds] Already deployed — skipping"
    exit 0
fi

DS_PORT="${DS_PORT:-3389}"
DS_PASSWORD="${DS_PASSWORD:-Secret.123}"
DS_SUFFIX="${DS_SUFFIX:-dc=pki,dc=example,dc=com}"

echo "[ds] Waiting for systemd..."
sleep 3

echo "[ds] Creating 389 DS instance..."
cat > /tmp/ds-setup.inf << EOF
[general]
full_machine_name = $(hostname -f)
start = True
[slapd]
instance_name = pki-ds
port = ${DS_PORT}
root_dn = cn=Directory Manager
root_password = ${DS_PASSWORD}
[backend-userroot]
suffix = ${DS_SUFFIX}
create_suffix_entry = True
EOF

dscreate from-file /tmp/ds-setup.inf
rm -f /tmp/ds-setup.inf

echo "[ds] Verifying..."
dsctl pki-ds status
ldapsearch -x -H ldap://localhost:${DS_PORT} -b "" -s base 2>&1 | head -3

touch "$MARKER"
echo "[ds] 389 DS ready on port ${DS_PORT}"
