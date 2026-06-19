#!/bin/bash
# Single-container first-boot: deploy DS + CA + ACME + pki CLI
MARKER="/var/lib/pki/.deployed"
if [ -f "$MARKER" ]; then
    echo "[first-boot] Already deployed — skipping"
    exit 0
fi

echo "[first-boot] Waiting for systemd..."
sleep 5

echo "[first-boot] Deploying Dogtag PKI CA + ACME..."
/usr/local/bin/deploy-dogtag-acme.sh

echo "[first-boot] Setting up pki CLI..."
pki -d /root/.dogtag/nssdb -c Secret.123 client-init --force 2>/dev/null
echo "Secret.123" > /root/.dogtag/nssdb/password.txt
chmod 600 /root/.dogtag/nssdb/password.txt
certutil -L -d /etc/pki/pki-tomcat/alias \
  -n "caSigningCert cert-pki-tomcat CA" -a > /tmp/ca.crt
certutil -A -d /root/.dogtag/nssdb \
  -n "CA Signing Certificate" -t "CT,C,C" \
  -a -i /tmp/ca.crt -f /root/.dogtag/nssdb/password.txt
pki -d /root/.dogtag/nssdb -c Secret.123 \
  pkcs12-import --pkcs12 /root/.dogtag/pki-tomcat/ca_admin_cert.p12 \
  --password Secret.123 2>/dev/null

echo "[first-boot] Enabling fapolicyd..."
systemctl enable --now fapolicyd 2>/dev/null || true
fapolicyd-cli --update 2>/dev/null || true

echo "[first-boot] Adding secondary DNS..."
grep -q "8.8.4.4" /etc/resolv.conf 2>/dev/null || \
  echo "nameserver 8.8.4.4" >> /etc/resolv.conf

touch "$MARKER"
echo "[first-boot] Deployment complete"
