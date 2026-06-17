#!/bin/bash
# =============================================================================
# Dogtag PKI v11.9 CA + ACME Responder Deployment
# Target: RHEL 8 with Red Hat Certificate System subscription
# Backend: 389 Directory Server (DS)
#
# Supports two ACME deployment methods:
#   --acme-method=cli       (default) pki-server acme CLI — step-by-step
#   --acme-method=pkispawn  pkispawn -s ACME — single command
#
# Usage:
#   bash deploy-dogtag-acme.sh
#   bash deploy-dogtag-acme.sh --acme-method=pkispawn
#   bash deploy-dogtag-acme.sh --ds-password=MyPass --admin-password=MyPass
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
HOSTNAME=$(hostname -f)
DS_PORT=3389
DS_PASSWORD="Secret.123"
CA_ADMIN_PASSWORD="Secret.123"
ACME_METHOD="cli"

# Parse arguments
for arg in "$@"; do
    case $arg in
        --acme-method=*) ACME_METHOD="${arg#*=}" ;;
        --ds-password=*) DS_PASSWORD="${arg#*=}" ;;
        --admin-password=*) CA_ADMIN_PASSWORD="${arg#*=}" ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[$(date +%T)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%T)] WARN:${NC} $*"; }
err()  { echo -e "${RED}[$(date +%T)] ERROR:${NC} $*"; exit 1; }

# =============================================================================
# Phase 1: Packages
# =============================================================================
phase1_packages() {
    log "Phase 1: Installing packages..."
    subscription-manager repos --enable=certsys-10.8-for-rhel-8-x86_64-rpms 2>/dev/null || true
    dnf module enable -y pki-deps:10.6 pki-core:10.6 389-ds:1.4 2>&1 | tail -1
    dnf install -y redhat-pki-server redhat-pki-ca redhat-pki-acme \
        389-ds-base openldap-clients 2>&1 | tail -3
    log "Installed: $(rpm -q redhat-pki-ca --qf '%{VERSION}')"
}

# =============================================================================
# Phase 2: Directory Server
# =============================================================================
phase2_directory_server() {
    log "Phase 2: Setting up 389 Directory Server..."
    if dsctl pki-ds status &>/dev/null; then
        warn "DS instance 'pki-ds' already exists."
        return 0
    fi
    cat > /tmp/ds-setup.inf << EOF
[general]
full_machine_name = ${HOSTNAME}
start = True
[slapd]
instance_name = pki-ds
port = ${DS_PORT}
root_dn = cn=Directory Manager
root_password = ${DS_PASSWORD}
[backend-userroot]
suffix = dc=pki,dc=example,dc=com
create_suffix_entry = True
EOF
    dscreate from-file /tmp/ds-setup.inf
    rm -f /tmp/ds-setup.inf
    log "DS running on port ${DS_PORT}"
}

# =============================================================================
# Phase 3: Certificate Authority (via pkispawn)
# =============================================================================
phase3_ca() {
    log "Phase 3: Deploying CA..."
    if [ -d "/var/lib/pki/pki-tomcat/ca" ]; then
        warn "CA already deployed."
        return 0
    fi
    cat > /tmp/ca.cfg << EOF
[DEFAULT]
pki_instance_name = pki-tomcat
pki_https_port = 8443
pki_http_port = 8080
pki_admin_password = ${CA_ADMIN_PASSWORD}
pki_client_pkcs12_password = ${CA_ADMIN_PASSWORD}
pki_ds_hostname = ${HOSTNAME}
pki_ds_ldap_port = ${DS_PORT}
pki_ds_password = ${DS_PASSWORD}
pki_ds_base_dn = dc=ca,dc=pki,dc=example,dc=com
pki_ds_database = ca
pki_ds_remove_data = True
pki_security_domain_name = PKI Security Domain
pki_hostname = ${HOSTNAME}
[CA]
pki_admin_email = caadmin@${HOSTNAME}
pki_admin_name = caadmin
pki_admin_nickname = PKI Administrator
pki_admin_uid = caadmin
EOF
    pkispawn -f /tmp/ca.cfg -s CA
    rm -f /tmp/ca.cfg
    log "CA deployed. Admin cert: /root/.dogtag/pki-tomcat/ca_admin_cert.p12"
}

# =============================================================================
# Phase 4: ACME Responder
# =============================================================================
phase4_acme_cli() {
    log "Phase 4: Deploying ACME (pki-server CLI method)..."

    # Create
    log "  Creating ACME responder..."
    pki-server acme-create

    # Configure database
    log "  Configuring database..."
    pki-server acme-database-mod --type ds \
        -Durl=ldap://${HOSTNAME}:${DS_PORT} \
        -DbindPassword=${DS_PASSWORD}

    # Configure issuer
    log "  Configuring issuer..."
    pki-server acme-issuer-mod --type pki \
        -Durl=https://${HOSTNAME}:8443 \
        -Dusername=caadmin \
        -Dpassword=${CA_ADMIN_PASSWORD}

    # Configure realm
    log "  Configuring realm..."
    pki-server acme-realm-mod --type ds \
        -Durl=ldap://${HOSTNAME}:${DS_PORT} \
        -DbindPassword=${DS_PASSWORD}

    # Deploy
    log "  Deploying webapp..."
    pki-server acme-deploy
}

phase4_acme_pkispawn() {
    log "Phase 4: Deploying ACME (pkispawn method)..."

    pkispawn \
        -f /usr/share/pki/server/examples/installation/acme.cfg \
        -s ACME \
        -D acme_database_url=ldap://${HOSTNAME}:${DS_PORT} \
        -D acme_database_bind_password=${DS_PASSWORD} \
        -D acme_issuer_url=https://${HOSTNAME}:8443 \
        -D acme_issuer_password=${CA_ADMIN_PASSWORD} \
        -D acme_realm_url=ldap://${HOSTNAME}:${DS_PORT} \
        -D acme_realm_bind_password=${DS_PASSWORD}
}

# =============================================================================
# Phase 5: Initialize ACME Database & Realm (required for both methods)
# =============================================================================
phase5_acme_init() {
    log "Phase 5: Initializing ACME database and realm in DS..."

    ldapmodify -h ${HOSTNAME} -p ${DS_PORT} \
        -x -D "cn=Directory Manager" -w ${DS_PASSWORD} \
        -f /usr/share/pki/acme/database/ds/schema.ldif 2>&1 | tail -1 || true

    ldapadd -h ${HOSTNAME} -p ${DS_PORT} \
        -x -D "cn=Directory Manager" -w ${DS_PASSWORD} \
        -f /usr/share/pki/acme/database/ds/index.ldif 2>/dev/null || true

    ldapadd -h ${HOSTNAME} -p ${DS_PORT} \
        -x -D "cn=Directory Manager" -w ${DS_PASSWORD} \
        -f /usr/share/pki/acme/database/ds/indextask.ldif 2>/dev/null || true

    sleep 5

    ldapadd -h ${HOSTNAME} -p ${DS_PORT} \
        -x -D "cn=Directory Manager" -w ${DS_PASSWORD} \
        -f /usr/share/pki/acme/database/ds/create.ldif 2>/dev/null || true

    ldapadd -h ${HOSTNAME} -p ${DS_PORT} \
        -x -D "cn=Directory Manager" -w ${DS_PASSWORD} \
        -f /usr/share/pki/acme/realm/ds/create.ldif 2>/dev/null || true

    log "ACME database and realm initialized"
}

# =============================================================================
# Phase 6: Restart & Verify
# =============================================================================
phase6_verify() {
    log "Phase 6: Restarting and verifying..."

    systemctl restart pki-tomcatd@pki-tomcat.service
    sleep 15

    log "CA Status:"
    curl -sk "https://${HOSTNAME}:8443/ca/admin/ca/getStatus" | python3 -m json.tool

    echo ""
    log "ACME Directory:"
    curl -sk "https://${HOSTNAME}:8443/acme/directory" | python3 -m json.tool

    echo ""
    log "=========================================="
    log "Deployment Complete"
    log "=========================================="
    log "  ACME Method: ${ACME_METHOD}"
    log "  CA URL:      https://${HOSTNAME}:8443/ca"
    log "  ACME URL:    https://${HOSTNAME}:8443/acme/directory"
    log "  Admin cert:  /root/.dogtag/pki-tomcat/ca_admin_cert.p12"
    log "  Packages:    $(rpm -q redhat-pki-ca redhat-pki-acme --qf '%{NAME}-%{VERSION} ')"
    log "=========================================="
    log ""
    log "Test with certbot:"
    log "  certbot certonly --server https://${HOSTNAME}:8443/acme/directory \\"
    log "    --standalone --no-verify-ssl -d test.example.com"
}

# =============================================================================
# Main
# =============================================================================
main() {
    log "Dogtag PKI v11.9 — CA + ACME Deployment"
    log "Target: ${HOSTNAME}"
    log "ACME method: ${ACME_METHOD}"
    log "======================================="

    phase1_packages
    phase2_directory_server
    phase3_ca

    case "${ACME_METHOD}" in
        cli)      phase4_acme_cli ;;
        pkispawn) phase4_acme_pkispawn ;;
        *)        err "Unknown ACME method: ${ACME_METHOD}. Use 'cli' or 'pkispawn'." ;;
    esac

    phase5_acme_init
    phase6_verify
}

main "$@"
