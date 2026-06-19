#!/bin/bash
# CA container first-boot: deploy Dogtag CA connecting to external DS
set -uo pipefail

MARKER="/var/lib/pki/.ca-deployed"
if [ -f "$MARKER" ]; then
    echo "[ca] Already deployed — skipping"
    exit 0
fi

DS_HOST="${DS_HOST:-ds}"
DS_PORT="${DS_PORT:-3389}"
DS_PASSWORD="${DS_PASSWORD:-Secret.123}"
CA_ADMIN_PASSWORD="${CA_ADMIN_PASSWORD:-Secret.123}"
CA_HOSTNAME="${CA_HOSTNAME:-ca}"

echo "[ca] Waiting for systemd..."
sleep 3

echo "[ca] Waiting for DS at ldap://${DS_HOST}:${DS_PORT}..."
for i in $(seq 1 60); do
    ldapsearch -x -H "ldap://${DS_HOST}:${DS_PORT}" -b "" -s base &>/dev/null && break
    echo "[ca]   Attempt $i/60 — DS not ready, waiting 5s..."
    sleep 5
done

ldapsearch -x -H "ldap://${DS_HOST}:${DS_PORT}" -b "" -s base &>/dev/null || {
    echo "[ca] ERROR: DS not reachable after 5 minutes"
    exit 1
}
echo "[ca] DS is ready"

echo "[ca] Deploying CA via pkispawn..."
cat > /tmp/ca.cfg << EOF
[DEFAULT]
pki_instance_name = pki-tomcat
pki_https_port = 8443
pki_http_port = 8080
pki_admin_password = ${CA_ADMIN_PASSWORD}
pki_client_pkcs12_password = ${CA_ADMIN_PASSWORD}
pki_ds_hostname = ${DS_HOST}
pki_ds_ldap_port = ${DS_PORT}
pki_ds_password = ${DS_PASSWORD}
pki_ds_base_dn = dc=ca,dc=pki,dc=example,dc=com
pki_ds_database = ca
pki_ds_remove_data = True
pki_security_domain_name = PKI Security Domain
pki_hostname = ${CA_HOSTNAME}
[CA]
pki_admin_email = caadmin@${CA_HOSTNAME}
pki_admin_name = caadmin
pki_admin_nickname = PKI Administrator
pki_admin_uid = caadmin
EOF

pkispawn -f /tmp/ca.cfg -s CA
rm -f /tmp/ca.cfg

echo "[ca] Waiting for CA to start..."
for i in $(seq 1 24); do
    STATUS=$(curl -sk https://localhost:8443/ca/admin/ca/getStatus 2>/dev/null)
    echo "$STATUS" | grep -q "running" && break
    echo "[ca]   Attempt $i/24 — CA starting, waiting 10s..."
    sleep 10
done

echo "[ca] CA Status:"
curl -sk https://localhost:8443/ca/admin/ca/getStatus | python3 -m json.tool

echo "[ca] Setting up pki CLI..."
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

echo "[ca] Exporting CA cert to shared volume..."
mkdir -p /shared
cp /tmp/ca.crt /shared/ca.crt
cp /root/.dogtag/pki-tomcat/ca_admin_cert.p12 /shared/ca_admin_cert.p12
chmod 644 /shared/ca.crt
chmod 644 /shared/ca_admin_cert.p12

echo "[ca] Enabling fapolicyd..."
systemctl enable --now fapolicyd 2>/dev/null || true
fapolicyd-cli --update 2>/dev/null || true

touch "$MARKER"
echo "[ca] Dogtag CA ready"
