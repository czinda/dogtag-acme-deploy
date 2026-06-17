#!/bin/bash
# =============================================================================
# Dogtag PKI v11.9 CA + EST Responder Deployment
# Target: RHEL 8 with Red Hat Certificate System subscription
# Backend: 389 Directory Server (DS)
#
# EST (Enrollment over Secure Transport, RFC 7030) provides certificate
# enrollment via HTTPS using simple enrollment and re-enrollment operations.
#
# Supports two EST deployment methods:
#   --est-method=cli       (default) pki-server est CLI — step-by-step
#   --est-method=pkispawn  pkispawn -s EST — single command
#
# Usage:
#   bash deploy-dogtag-est.sh
#   bash deploy-dogtag-est.sh --est-method=pkispawn
#   bash deploy-dogtag-est.sh --ds-password=MyPass --admin-password=MyPass
# =============================================================================

set -euo pipefail

HOSTNAME=$(hostname -f)
DS_PORT=3389
DS_PASSWORD="Secret.123"
CA_ADMIN_PASSWORD="Secret.123"
EST_RA_PASSWORD="password4ESTUser"
EST_METHOD="cli"

for arg in "$@"; do
    case $arg in
        --est-method=*) EST_METHOD="${arg#*=}" ;;
        --ds-password=*) DS_PASSWORD="${arg#*=}" ;;
        --admin-password=*) CA_ADMIN_PASSWORD="${arg#*=}" ;;
        --est-ra-password=*) EST_RA_PASSWORD="${arg#*=}" ;;
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
    dnf install -y redhat-pki-server redhat-pki-ca redhat-pki-est \
        389-ds-base openldap-clients 2>&1 | tail -3
    log "Installed: $(rpm -q redhat-pki-ca --qf '%{VERSION}') + $(rpm -q redhat-pki-est --qf '%{NAME}-%{VERSION}')"
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
# Phase 3: Certificate Authority
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
    log "CA deployed."

    # Wait for CA
    for i in $(seq 1 30); do
        if curl -sk "https://${HOSTNAME}:8443/ca/admin/ca/getStatus" 2>/dev/null | grep -q "running"; then
            break
        fi
        sleep 2
    done
}

# =============================================================================
# Phase 4: Create EST RA agent in the CA
# =============================================================================
phase4_est_agent() {
    log "Phase 4: Creating EST RA agent in CA..."

    # Set up admin client NSS DB
    if [ ! -f /root/.dogtag/nssdb/cert9.db ]; then
        mkdir -p /root/.dogtag/nssdb
        certutil -N -d /root/.dogtag/nssdb --empty-password
        pki-server cert-export ca_signing --cert-file /tmp/ca_signing.crt
        certutil -A -d /root/.dogtag/nssdb -n ca_signing -t "CT,C,C" -i /tmp/ca_signing.crt
        pk12util -i /root/.dogtag/pki-tomcat/ca_admin_cert.p12 \
            -d /root/.dogtag/nssdb -W ${CA_ADMIN_PASSWORD}
    fi

    # Create est-ra-1 agent user
    pki -d /root/.dogtag/nssdb -n "PKI Administrator" \
        -U https://${HOSTNAME}:8443 \
        ca-user-add est-ra-1 --full-name "EST RA 1" \
        --type agentType --password ${EST_RA_PASSWORD} 2>&1 || warn "est-ra-1 may already exist"

    # Add to Certificate Manager Agents group
    pki -d /root/.dogtag/nssdb -n "PKI Administrator" \
        -U https://${HOSTNAME}:8443 \
        ca-group-member-add "Certificate Manager Agents" est-ra-1 2>&1 || warn "Already a member"

    log "EST RA agent 'est-ra-1' created in CA"

    # Update EST profile for username/password auth
    local PROFILE="/etc/pki/pki-tomcat/ca/profiles/ca/estServiceCert.cfg"
    if [ -f "${PROFILE}" ]; then
        log "  Updating estServiceCert profile for session auth..."
        sed -i 's/^auth.instance_id=.*/auth.instance_id=SessionAuthentication/' "${PROFILE}"
        grep -q "authz.acl" "${PROFILE}" || echo 'authz.acl=group="Certificate Manager Agents"' >> "${PROFILE}"
        sed -i 's/raClientAuthSubjectNameConstraintImpl/noConstraintImpl/g' "${PROFILE}"
        systemctl restart pki-tomcatd@pki-tomcat.service
        sleep 10
    fi
}

# =============================================================================
# Phase 5a: EST Responder — pki-server CLI method
# =============================================================================
phase5_est_cli() {
    log "Phase 5: Deploying EST (pki-server CLI method)..."

    log "  Creating EST subsystem..."
    pki-server est-create

    log "  Configuring backend..."
    cat > /var/lib/pki/pki-tomcat/conf/est/backend.conf << EOF
class=org.dogtagpki.est.DogtagRABackend
url=https://${HOSTNAME}:8443
profile=estServiceCert
username=est-ra-1
password=${EST_RA_PASSWORD}
EOF

    log "  Configuring authorizer..."
    cat > /var/lib/pki/pki-tomcat/conf/est/authorizer.conf << EOF
class=org.dogtagpki.est.ExternalProcessRequestAuthorizer
executable=/usr/share/pki/est/bin/estauthz
enrollMatchTLSSubjSAN=false
enrollMatchSubjSAN=false
EOF

    log "  Configuring realm (in-memory for testing)..."
    cat > /var/lib/pki/pki-tomcat/conf/est/realm.conf << EOF
class=com.netscape.cms.realm.PKIInMemoryRealm
username=est-test-user
password=Secret.123
roles=EST Users
EOF

    chown -R pkiuser:pkiuser /var/lib/pki/pki-tomcat/conf/est

    log "  Deploying EST webapp..."
    pki-server est-deploy
}

# =============================================================================
# Phase 5b: EST Responder — pkispawn method
# =============================================================================
phase5_est_pkispawn() {
    log "Phase 5: Deploying EST (pkispawn method)..."

    pkispawn \
        -f /usr/share/pki/server/examples/installation/est.cfg \
        -s EST \
        -D est_realm_url=ldap://${HOSTNAME}:${DS_PORT} \
        -D est_realm_bind_password=${DS_PASSWORD} \
        -D pki_security_domain_password=${CA_ADMIN_PASSWORD} \
        -v 2>&1 | tail -10
}

# =============================================================================
# Phase 6: Restart & Verify
# =============================================================================
phase6_verify() {
    log "Phase 6: Restarting and verifying..."

    systemctl restart pki-tomcatd@pki-tomcat.service
    sleep 15

    # Export CA cert for verification
    pki-server cert-export ca_signing --cert-file /tmp/ca_signing.crt 2>/dev/null || true

    log "CA Status:"
    curl -sk "https://${HOSTNAME}:8443/ca/admin/ca/getStatus" | python3 -m json.tool

    echo ""
    log "EST /cacerts test:"
    EST_RESULT=$(curl -s --cacert /tmp/ca_signing.crt \
        "https://${HOSTNAME}:8443/.well-known/est/cacerts" 2>&1)
    if [ -n "${EST_RESULT}" ] && [ "${EST_RESULT}" != "" ]; then
        echo "${EST_RESULT}" | openssl base64 -d | openssl pkcs7 -inform der -print_certs | openssl x509 -noout -subject -issuer 2>/dev/null \
            && log "EST /cacerts: OK" \
            || warn "EST /cacerts returned data but could not parse"
    else
        warn "EST /cacerts returned empty response"
    fi

    echo ""
    log "=========================================="
    log "Deployment Complete"
    log "=========================================="
    log "  EST Method:  ${EST_METHOD}"
    log "  CA URL:      https://${HOSTNAME}:8443/ca"
    log "  EST URL:     https://${HOSTNAME}:8443/.well-known/est/"
    log "  EST cacerts: https://${HOSTNAME}:8443/.well-known/est/cacerts"
    log "  EST enroll:  https://${HOSTNAME}:8443/.well-known/est/simpleenroll"
    log "  Admin cert:  /root/.dogtag/pki-tomcat/ca_admin_cert.p12"
    log "  EST RA user: est-ra-1 (password: ${EST_RA_PASSWORD})"
    log "  Packages:    $(rpm -q redhat-pki-ca redhat-pki-est --qf '%{NAME}-%{VERSION} ')"
    log "=========================================="
    log ""
    log "Test enrollment:"
    log "  pki nss-cert-request --csr test.csr --ext /usr/share/pki/server/certs/sslserver.conf --subject 'CN=test.example.com'"
    log "  openssl req -in test.csr -outform der | openssl base64 -out test.p10"
    log "  curl --cacert /tmp/ca_signing.crt --anyauth -u est-test-user:Secret.123 \\"
    log "    --data-binary @test.p10 -H 'Content-Type: application/pkcs10' \\"
    log "    -o newCert.p7 https://${HOSTNAME}:8443/.well-known/est/simpleenroll"
}

# =============================================================================
# Main
# =============================================================================
main() {
    log "Dogtag PKI v11.9 — CA + EST Deployment"
    log "Target: ${HOSTNAME}"
    log "EST method: ${EST_METHOD}"
    log "======================================="

    phase1_packages
    phase2_directory_server
    phase3_ca
    phase4_est_agent

    case "${EST_METHOD}" in
        cli)      phase5_est_cli ;;
        pkispawn) phase5_est_pkispawn ;;
        *)        err "Unknown EST method: ${EST_METHOD}. Use 'cli' or 'pkispawn'." ;;
    esac

    phase6_verify
}

main "$@"
