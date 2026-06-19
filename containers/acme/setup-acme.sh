#!/bin/bash
# ACME container first-boot: deploy ACME responder with own Tomcat instance
set -uo pipefail

MARKER="/root/.acme-deployed"
if [ -f "$MARKER" ]; then
    echo "[acme] Already deployed — skipping"
    exit 0
fi

DS_HOST="${DS_HOST:-ds}"
DS_PORT="${DS_PORT:-3389}"
DS_PASSWORD="${DS_PASSWORD:-Secret.123}"
CA_HOST="${CA_HOST:-ca}"
CA_PORT="${CA_PORT:-8443}"
CA_ADMIN_PASSWORD="${CA_ADMIN_PASSWORD:-Secret.123}"
ACME_HTTPS_PORT="${ACME_HTTPS_PORT:-8443}"
ACME_HTTP_PORT="${ACME_HTTP_PORT:-8080}"

echo "[acme] Waiting for systemd and DNS..."
sleep 15

echo "[acme] Waiting for DS at ldap://${DS_HOST}:${DS_PORT}..."
for i in $(seq 1 90); do
    ldapsearch -x -H "ldap://${DS_HOST}:${DS_PORT}" -b "" -s base &>/dev/null && break
    echo "[acme]   Attempt $i/90 — DS not ready, waiting 5s..."
    sleep 5
done
ldapsearch -x -H "ldap://${DS_HOST}:${DS_PORT}" -b "" -s base &>/dev/null || {
    echo "[acme] ERROR: DS not reachable"; exit 1
}
echo "[acme] DS is ready"

echo "[acme] Waiting for CA at https://${CA_HOST}:${CA_PORT}..."
for i in $(seq 1 60); do
    curl -sk "https://${CA_HOST}:${CA_PORT}/ca/admin/ca/getStatus" 2>/dev/null | grep -q "running" && break
    echo "[acme]   Attempt $i/60 — CA not ready, waiting 10s..."
    sleep 10
done
curl -sk "https://${CA_HOST}:${CA_PORT}/ca/admin/ca/getStatus" 2>/dev/null | grep -q "running" || {
    echo "[acme] ERROR: CA not reachable"; exit 1
}
echo "[acme] CA is ready"

echo "[acme] Importing CA cert from shared volume..."
if [ -f /shared/ca.crt ]; then
    cp /shared/ca.crt /tmp/ca.crt
    echo "[acme] CA cert imported"
else
    echo "[acme] WARNING: /shared/ca.crt not found — fetching from CA..."
    curl -sk "https://${CA_HOST}:${CA_PORT}/ca/ee/ca/getCAChain" -o /tmp/ca-chain.p7b 2>/dev/null || true
fi

echo "[acme] Initializing ACME database in DS..."
ldapmodify -H "ldap://${DS_HOST}:${DS_PORT}" \
    -x -D "cn=Directory Manager" -w "${DS_PASSWORD}" \
    -f /usr/share/pki/acme/database/ds/schema.ldif 2>&1 | tail -1 || true

ldapadd -H "ldap://${DS_HOST}:${DS_PORT}" \
    -x -D "cn=Directory Manager" -w "${DS_PASSWORD}" \
    -f /usr/share/pki/acme/database/ds/index.ldif 2>/dev/null || true

ldapadd -H "ldap://${DS_HOST}:${DS_PORT}" \
    -x -D "cn=Directory Manager" -w "${DS_PASSWORD}" \
    -f /usr/share/pki/acme/database/ds/indextask.ldif 2>/dev/null || true

sleep 5

ldapadd -H "ldap://${DS_HOST}:${DS_PORT}" \
    -x -D "cn=Directory Manager" -w "${DS_PASSWORD}" \
    -f /usr/share/pki/acme/database/ds/create.ldif 2>/dev/null || true

ldapadd -H "ldap://${DS_HOST}:${DS_PORT}" \
    -x -D "cn=Directory Manager" -w "${DS_PASSWORD}" \
    -f /usr/share/pki/acme/realm/ds/create.ldif 2>/dev/null || true

echo "[acme] ACME database initialized"

echo "[acme] Deploying ACME via pkispawn..."
pkispawn \
    -f /usr/share/pki/server/examples/installation/acme.cfg \
    -s ACME \
    -D pki_instance_name=pki-acme \
    -D pki_https_port=${ACME_HTTPS_PORT} \
    -D pki_http_port=${ACME_HTTP_PORT} \
    -D pki_hostname=$(hostname -f) \
    -D pki_ds_url=ldap://${DS_HOST}:${DS_PORT} \
    -D pki_ds_password=${DS_PASSWORD} \
    -D acme_database_url=ldap://${DS_HOST}:${DS_PORT} \
    -D acme_database_bind_password=${DS_PASSWORD} \
    -D acme_issuer_url=https://${CA_HOST}:${CA_PORT} \
    -D acme_issuer_password=${CA_ADMIN_PASSWORD} \
    -D acme_realm_url=ldap://${DS_HOST}:${DS_PORT} \
    -D acme_realm_bind_password=${DS_PASSWORD} 2>&1

echo "[acme] Restarting ACME Tomcat..."
systemctl restart pki-tomcatd@pki-acme 2>/dev/null || true
sleep 15

echo "[acme] Verifying ACME..."
for i in $(seq 1 12); do
    curl -sk https://localhost:${ACME_HTTPS_PORT}/acme/directory 2>/dev/null | grep -q "newNonce" && break
    echo "[acme]   Attempt $i/12 — ACME starting, waiting 10s..."
    sleep 10
done

echo "[acme] ACME Directory:"
curl -sk https://localhost:${ACME_HTTPS_PORT}/acme/directory | python3 -m json.tool

echo "[acme] Enabling fapolicyd..."
systemctl enable --now fapolicyd 2>/dev/null || true
fapolicyd-cli --update 2>/dev/null || true

touch "$MARKER"
echo "[acme] ACME responder ready"
