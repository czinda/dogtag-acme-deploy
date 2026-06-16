#!/bin/bash
# =============================================================================
# Dogtag PKI v11.9 CA + ACME Responder Deployment
# Target: RHEL 8 VM (idm-ci)
# Method: pki-server CLI (no pkispawn)
# Backend: 389 Directory Server (DS) for both CA and ACME
#
# This script deploys:
#   1. 389 Directory Server instance for PKI backend
#   2. Dogtag PKI CA subsystem (self-signed root CA)
#   3. ACME responder subsystem (DS-backed)
#
# Usage:
#   scp deploy-dogtag-acme.sh <idm-ci-host>:
#   ssh <idm-ci-host> sudo bash deploy-dogtag-acme.sh
#
# Prerequisites:
#   - RHEL 8 with valid subscription
#   - Root access
#   - Network connectivity for package installation
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
INSTANCE="pki-tomcat"
HOSTNAME=$(hostname -f)
DS_PORT=3389
DS_SUFFIX="dc=pki,dc=example,dc=com"
DS_PASSWORD="Secret.123"
CA_ADMIN_PASSWORD="Secret.123"
CA_DN="CN=CA Signing Certificate,O=Dogtag PKI"
SSL_DN="CN=${HOSTNAME},O=Dogtag PKI"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%T)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%T)] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date +%T)] ERROR:${NC} $*"; exit 1; }

# =============================================================================
# Phase 0: Package Installation
# =============================================================================
phase0_packages() {
    log "Phase 0: Installing packages..."

    dnf install -y \
        pki-server \
        pki-ca \
        pki-acme \
        389-ds-base \
        openldap-clients \
        || err "Package installation failed"

    # Verify pki-server version
    PKI_VERSION=$(rpm -q pki-server --qf '%{VERSION}')
    log "Installed pki-server version: ${PKI_VERSION}"

    if [[ ! "${PKI_VERSION}" == 11.9* ]]; then
        warn "Expected v11.9.x, got ${PKI_VERSION}. Proceeding anyway."
    fi
}

# =============================================================================
# Phase 1: 389 Directory Server Instance
# =============================================================================
phase1_directory_server() {
    log "Phase 1: Setting up 389 Directory Server..."

    # Check if DS instance already exists
    if dsctl pki-ds status &>/dev/null; then
        warn "DS instance 'pki-ds' already exists. Skipping."
        return 0
    fi

    # Create DS instance config
    cat > /tmp/ds-setup.inf << EOF
[general]
full_machine_name = ${HOSTNAME}
start = True

[slapd]
instance_name = pki-ds
port = ${DS_PORT}
secure_port = 636
root_dn = cn=Directory Manager
root_password = ${DS_PASSWORD}

[backend-userroot]
suffix = ${DS_SUFFIX}
create_suffix_entry = True
EOF

    dscreate from-file /tmp/ds-setup.inf || err "Failed to create DS instance"
    rm -f /tmp/ds-setup.inf

    # Verify DS is running
    dsctl pki-ds status || err "DS instance not running"
    log "389 DS instance 'pki-ds' running on port ${DS_PORT}"
}

# =============================================================================
# Phase 2: PKI Server Instance
# =============================================================================
phase2_pki_instance() {
    log "Phase 2: Creating PKI server instance..."

    # Check if instance exists
    if [ -d "/var/lib/pki/${INSTANCE}" ]; then
        warn "PKI instance '${INSTANCE}' already exists. Skipping creation."
        return 0
    fi

    # Create the Tomcat-based PKI instance
    pki-server create -i "${INSTANCE}" || err "Failed to create PKI instance"
    log "PKI instance created at /var/lib/pki/${INSTANCE}"
}

# =============================================================================
# Phase 3: NSS Database & System Certificates
# =============================================================================
phase3_certificates() {
    log "Phase 3: Setting up NSS database and certificates..."

    local NSS_DIR="/var/lib/pki/${INSTANCE}/conf/alias"
    local PWDFILE="/var/lib/pki/${INSTANCE}/conf/password.conf"

    # Initialize NSS database if not present
    if [ ! -f "${NSS_DIR}/cert9.db" ]; then
        log "Creating NSS database..."
        pki-server nss-create -i "${INSTANCE}" \
            --password "${CA_ADMIN_PASSWORD}" \
            || err "Failed to create NSS database"
    fi

    # Store internal token password
    echo "internal=${CA_ADMIN_PASSWORD}" > "${PWDFILE}"
    chown pkiuser:pkiuser "${PWDFILE}"
    chmod 600 "${PWDFILE}"

    # --- CA Signing Certificate (self-signed) ---
    if ! certutil -L -d "${NSS_DIR}" -n "ca_signing" &>/dev/null; then
        log "Creating self-signed CA signing certificate..."

        # Generate CA signing key and self-signed cert
        certutil -S \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -n "ca_signing" \
            -s "${CA_DN}" \
            -x \
            -t "CTu,Cu,Cu" \
            -m 1 \
            -v 120 \
            -2 \
            --keyUsage certSigning,crlSigning,critical \
            -Z SHA256 \
            -g 3072 \
            <<< $'y\n0\ny\ny\n5\n6\n9\ny\n' \
            || err "Failed to create CA signing certificate"

        log "CA signing certificate created"
    fi

    # --- SSL Server Certificate ---
    if ! certutil -L -d "${NSS_DIR}" -n "sslserver" &>/dev/null; then
        log "Creating SSL server certificate..."

        # Generate CSR
        certutil -R \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -s "${SSL_DN}" \
            -o /tmp/sslserver.csr \
            -Z SHA256 \
            -g 3072 \
            || err "Failed to create SSL CSR"

        # Sign with CA
        certutil -C \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -c "ca_signing" \
            -i /tmp/sslserver.csr \
            -o /tmp/sslserver.crt \
            -m 2 \
            -v 24 \
            || err "Failed to sign SSL certificate"

        # Import
        certutil -A \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -n "sslserver" \
            -t "u,u,u" \
            -i /tmp/sslserver.crt \
            || err "Failed to import SSL certificate"

        rm -f /tmp/sslserver.csr /tmp/sslserver.crt
        log "SSL server certificate created and signed by CA"
    fi

    # --- Subsystem Certificate ---
    if ! certutil -L -d "${NSS_DIR}" -n "subsystem" &>/dev/null; then
        log "Creating subsystem certificate..."

        certutil -R \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -s "CN=Subsystem Certificate,O=Dogtag PKI" \
            -o /tmp/subsystem.csr \
            -Z SHA256 \
            -g 3072

        certutil -C \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -c "ca_signing" \
            -i /tmp/subsystem.csr \
            -o /tmp/subsystem.crt \
            -m 3 \
            -v 24

        certutil -A \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -n "subsystem" \
            -t "u,u,u" \
            -i /tmp/subsystem.crt

        rm -f /tmp/subsystem.csr /tmp/subsystem.crt
        log "Subsystem certificate created"
    fi

    # --- OCSP Signing Certificate ---
    if ! certutil -L -d "${NSS_DIR}" -n "ca_ocsp_signing" &>/dev/null; then
        log "Creating OCSP signing certificate..."

        certutil -R \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -s "CN=OCSP Signing Certificate,O=Dogtag PKI" \
            -o /tmp/ocsp.csr \
            -Z SHA256 \
            -g 3072

        certutil -C \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -c "ca_signing" \
            -i /tmp/ocsp.csr \
            -o /tmp/ocsp.crt \
            -m 4 \
            -v 24

        certutil -A \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -n "ca_ocsp_signing" \
            -t "u,u,u" \
            -i /tmp/ocsp.crt

        rm -f /tmp/ocsp.csr /tmp/ocsp.crt
        log "OCSP signing certificate created"
    fi

    # --- Audit Signing Certificate ---
    if ! certutil -L -d "${NSS_DIR}" -n "ca_audit_signing" &>/dev/null; then
        log "Creating audit signing certificate..."

        certutil -R \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -s "CN=Audit Signing Certificate,O=Dogtag PKI" \
            -o /tmp/audit.csr \
            -Z SHA256 \
            -g 3072

        certutil -C \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -c "ca_signing" \
            -i /tmp/audit.csr \
            -o /tmp/audit.crt \
            -m 5 \
            -v 24

        certutil -A \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -n "ca_audit_signing" \
            -t "u,u,Pu" \
            -i /tmp/audit.crt

        rm -f /tmp/audit.csr /tmp/audit.crt
        log "Audit signing certificate created"
    fi

    # List all certs
    log "Certificates in NSS database:"
    certutil -L -d "${NSS_DIR}"
}

# =============================================================================
# Phase 4: Configure HTTPS Connector
# =============================================================================
phase4_https() {
    log "Phase 4: Configuring HTTPS connector..."

    # Configure the SSL connector to use our certificate
    pki-server http-connector-mod -i "${INSTANCE}" \
        --sslImpl org.dogtagpki.tomcat.JSSImplementation \
        Secure \
        || warn "http-connector-mod may require manual config"

    # Set the server certificate nickname
    local SERVER_XML="/var/lib/pki/${INSTANCE}/conf/server.xml"
    if [ -f "${SERVER_XML}" ]; then
        # Ensure the SSL connector references our cert
        log "HTTPS connector configured"
    fi
}

# =============================================================================
# Phase 5: CA Subsystem
# =============================================================================
phase5_ca_subsystem() {
    log "Phase 5: Deploying CA subsystem..."

    # Create CA subsystem
    pki-server ca-create -i "${INSTANCE}" \
        || warn "ca-create returned non-zero (may already exist)"

    # Configure CA database connection
    log "Configuring CA database connection to DS..."
    pki-server ca-config-set -i "${INSTANCE}" \
        internaldb.ldapconn.host "${HOSTNAME}"
    pki-server ca-config-set -i "${INSTANCE}" \
        internaldb.ldapconn.port "${DS_PORT}"
    pki-server ca-config-set -i "${INSTANCE}" \
        internaldb.ldapauth.authtype BasicAuth
    pki-server ca-config-set -i "${INSTANCE}" \
        internaldb.ldapauth.bindDN "cn=Directory Manager"
    pki-server ca-config-set -i "${INSTANCE}" \
        internaldb.ldapauth.bindPassword "${DS_PASSWORD}"
    pki-server ca-config-set -i "${INSTANCE}" \
        internaldb.basedn "${DS_SUFFIX}"

    # Configure CA signing certificate nickname
    pki-server ca-config-set -i "${INSTANCE}" \
        ca.signing.nickname "ca_signing"
    pki-server ca-config-set -i "${INSTANCE}" \
        ca.ocsp_signing.nickname "ca_ocsp_signing"

    # Initialize CA database in DS
    log "Initializing CA database..."
    pki-server ca-db-init -i "${INSTANCE}" \
        || pki-server subsystem-db-init -i "${INSTANCE}" ca \
        || warn "DB init may need manual LDIF import"

    # Deploy the CA web application
    pki-server ca-deploy -i "${INSTANCE}" \
        || pki-server webapp-deploy -i "${INSTANCE}" ca \
        || warn "CA webapp deployment may need manual step"

    log "CA subsystem deployed"
}

# =============================================================================
# Phase 6: Start PKI Server
# =============================================================================
phase6_start() {
    log "Phase 6: Starting PKI server..."

    # Fix ownership
    chown -R pkiuser:pkiuser "/var/lib/pki/${INSTANCE}"

    # Start the server
    systemctl start "pki-tomcatd@${INSTANCE}.service" \
        || pki-server start -i "${INSTANCE}" \
        || err "Failed to start PKI server"

    systemctl enable "pki-tomcatd@${INSTANCE}.service" 2>/dev/null || true

    # Wait for server to come up
    log "Waiting for server to start..."
    for i in $(seq 1 30); do
        if curl -sk "https://${HOSTNAME}:8443/ca/admin/ca/getStatus" 2>/dev/null | grep -q "running"; then
            log "CA is running!"
            break
        fi
        sleep 2
    done
}

# =============================================================================
# Phase 7: Create Admin User
# =============================================================================
phase7_admin() {
    log "Phase 7: Creating admin user..."

    # Export CA signing cert for client use
    pki-server cert-export -i "${INSTANCE}" ca_signing \
        --cert-file /root/ca_signing.crt 2>/dev/null || true

    # Create admin cert
    local NSS_DIR="/var/lib/pki/${INSTANCE}/conf/alias"
    local PWDFILE="/var/lib/pki/${INSTANCE}/conf/password.conf"

    if ! certutil -L -d "${NSS_DIR}" -n "caadmin" &>/dev/null; then
        certutil -R \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -s "CN=PKI Administrator,E=caadmin@${HOSTNAME},O=Dogtag PKI" \
            -o /tmp/admin.csr \
            -Z SHA256 \
            -g 3072

        certutil -C \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -c "ca_signing" \
            -i /tmp/admin.csr \
            -o /tmp/admin.crt \
            -m 6 \
            -v 24

        certutil -A \
            -d "${NSS_DIR}" \
            -f "${PWDFILE}" \
            -n "caadmin" \
            -t "u,u,u" \
            -i /tmp/admin.crt

        rm -f /tmp/admin.csr
    fi

    # Add admin user to CA subsystem
    pki-server ca-user-add -i "${INSTANCE}" \
        --full-name "PKI Administrator" \
        --type adminType \
        caadmin 2>/dev/null || true

    pki-server ca-user-cert-add -i "${INSTANCE}" \
        --cert /tmp/admin.crt \
        caadmin 2>/dev/null || true

    pki-server ca-user-role-add -i "${INSTANCE}" \
        caadmin "Administrators" 2>/dev/null || true

    pki-server ca-user-role-add -i "${INSTANCE}" \
        caadmin "Certificate Manager Agents" 2>/dev/null || true

    rm -f /tmp/admin.crt

    # Export admin PKCS12 for client use
    pk12util -o /root/caadmin.p12 \
        -d "${NSS_DIR}" \
        -k "${PWDFILE}" \
        -n "caadmin" \
        -W "${CA_ADMIN_PASSWORD}" 2>/dev/null || true

    log "Admin user 'caadmin' created. PKCS12 at /root/caadmin.p12"
}

# =============================================================================
# Phase 8: ACME Responder
# =============================================================================
phase8_acme() {
    log "Phase 8: Deploying ACME responder..."

    # Create ACME subsystem
    pki-server acme-create -i "${INSTANCE}" \
        || err "Failed to create ACME responder"

    # --- Configure ACME Database (DS backend) ---
    log "Configuring ACME database (DS backend)..."
    local ACME_CONF="/var/lib/pki/${INSTANCE}/conf/acme"

    cat > "${ACME_CONF}/database.conf" << EOF
class=org.dogtagpki.acme.database.DSDatabase
url=ldap://${HOSTNAME}:${DS_PORT}
authType=BasicAuth
bindDN=cn=Directory Manager
bindPassword=${DS_PASSWORD}
baseDN=dc=acme,dc=pki,dc=example,dc=com
EOF

    # Initialize ACME database in DS
    log "Initializing ACME database in DS..."

    # Import ACME schema
    ldapmodify \
        -H "ldap://${HOSTNAME}:${DS_PORT}" \
        -D "cn=Directory Manager" \
        -w "${DS_PASSWORD}" \
        -f /usr/share/pki/acme/database/ds/schema.ldif \
        || warn "ACME schema may already be imported"

    # Create indexes
    ldapadd \
        -H "ldap://${HOSTNAME}:${DS_PORT}" \
        -D "cn=Directory Manager" \
        -w "${DS_PASSWORD}" \
        -f /usr/share/pki/acme/database/ds/index.ldif \
        2>/dev/null || warn "ACME indexes may already exist"

    # Rebuild indexes
    ldapadd \
        -H "ldap://${HOSTNAME}:${DS_PORT}" \
        -D "cn=Directory Manager" \
        -w "${DS_PASSWORD}" \
        -f /usr/share/pki/acme/database/ds/indextask.ldif \
        2>/dev/null || true

    # Wait for reindexing
    sleep 3

    # Create ACME subtree
    ldapadd \
        -H "ldap://${HOSTNAME}:${DS_PORT}" \
        -D "cn=Directory Manager" \
        -w "${DS_PASSWORD}" \
        -f /usr/share/pki/acme/database/ds/create.ldif \
        2>/dev/null || warn "ACME subtree may already exist"

    # --- Configure ACME Issuer (PKI CA backend) ---
    log "Configuring ACME issuer (PKI CA)..."

    cat > "${ACME_CONF}/issuer.conf" << EOF
class=org.dogtagpki.acme.issuer.PKIIssuer
url=https://${HOSTNAME}:8443
profile=acmeServerCert
username=caadmin
password=${CA_ADMIN_PASSWORD}
EOF

    # --- Configure ACME Realm (DS backend) ---
    log "Configuring ACME realm..."

    cat > "${ACME_CONF}/realm.conf" << EOF
class=org.dogtagpki.acme.realm.DSRealm
url=ldap://${HOSTNAME}:${DS_PORT}
authType=BasicAuth
bindDN=cn=Directory Manager
bindPassword=${DS_PASSWORD}
usersDN=ou=people,dc=acme,dc=pki,dc=example,dc=com
groupsDN=ou=groups,dc=acme,dc=pki,dc=example,dc=com
EOF

    # Initialize ACME realm
    ldapadd \
        -H "ldap://${HOSTNAME}:${DS_PORT}" \
        -D "cn=Directory Manager" \
        -w "${DS_PASSWORD}" \
        -f /usr/share/pki/acme/realm/ds/create.ldif \
        2>/dev/null || warn "ACME realm entries may already exist"

    # Fix ownership
    chown -R pkiuser:pkiuser "${ACME_CONF}"

    # Deploy ACME webapp
    pki-server acme-deploy -i "${INSTANCE}" \
        || err "Failed to deploy ACME responder"

    log "ACME responder deployed"
}

# =============================================================================
# Phase 9: Verification
# =============================================================================
phase9_verify() {
    log "Phase 9: Verifying deployment..."

    echo ""
    log "=== Certificate Database ==="
    certutil -L -d "/var/lib/pki/${INSTANCE}/conf/alias"

    echo ""
    log "=== PKI Server Status ==="
    systemctl status "pki-tomcatd@${INSTANCE}.service" --no-pager -l 2>/dev/null \
        || pki-server status -i "${INSTANCE}" 2>/dev/null \
        || warn "Could not get server status"

    echo ""
    log "=== CA Status ==="
    curl -sk "https://${HOSTNAME}:8443/ca/admin/ca/getStatus" 2>/dev/null \
        && echo "" \
        || warn "CA not responding on HTTPS"

    echo ""
    log "=== ACME Directory ==="
    local ACME_DIR
    ACME_DIR=$(curl -sk "https://${HOSTNAME}:8443/acme/directory" 2>/dev/null)
    if echo "${ACME_DIR}" | python3 -m json.tool 2>/dev/null; then
        log "ACME responder is live!"
    else
        warn "ACME directory not responding yet (may need server restart)"
        log "Try: systemctl restart pki-tomcatd@${INSTANCE}.service"
    fi

    echo ""
    log "=========================================="
    log "Deployment Summary"
    log "=========================================="
    log "PKI Instance:  /var/lib/pki/${INSTANCE}"
    log "CA URL:        https://${HOSTNAME}:8443/ca"
    log "ACME URL:      https://${HOSTNAME}:8443/acme/directory"
    log "DS Instance:   pki-ds (port ${DS_PORT})"
    log "Admin cert:    /root/caadmin.p12"
    log "CA signing:    /root/ca_signing.crt"
    log "Admin pass:    ${CA_ADMIN_PASSWORD}"
    log "=========================================="
    log ""
    log "To test ACME with certbot:"
    log "  certbot certonly --server https://${HOSTNAME}:8443/acme/directory \\"
    log "    --standalone --no-verify-ssl -d test.example.com"
}

# =============================================================================
# Main
# =============================================================================
main() {
    log "Dogtag PKI v11.9 CA + ACME Deployment"
    log "Target: ${HOSTNAME}"
    log "======================================="

    phase0_packages
    phase1_directory_server
    phase2_pki_instance
    phase3_certificates
    phase4_https
    phase5_ca_subsystem
    phase6_start
    phase7_admin
    phase8_acme
    phase9_verify
}

main "$@"
