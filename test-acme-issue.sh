#!/bin/bash
# =============================================================================
# ACME Certificate Issuance Test
# Tests ACME directory, nonce, CA direct issuance, and OCSP validation
# Usage: bash /root/test-acme-issue.sh [domain]
# =============================================================================
set -euo pipefail

ACME_URL="https://localhost:8443/acme/directory"
DOMAIN="${1:-test.localdomain}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[TEST $(date +%T)]${NC} $*"; }
pass() { echo -e "${GREEN}  ✓ PASS:${NC} $*"; }
fail() { echo -e "${RED}  ✗ FAIL:${NC} $*"; }

run_pki() {
    pki -d /root/.dogtag/nssdb -c Secret.123 \
        -U https://localhost:8443 \
        -n "PKI Administrator" \
        --ignore-cert-status BAD_CERT_DOMAIN \
        "$@"
}

log "=== ACME / CA Certificate Issuance Tests ==="
log "Server: ${ACME_URL}"
log "Domain: ${DOMAIN}"
echo ""

# ─── Test 1: ACME Directory ─────────────────────────────────────────────────
log "Test 1: ACME Directory"
DIRECTORY=$(curl -sk "${ACME_URL}")
if echo "${DIRECTORY}" | grep -q "newNonce"; then
    pass "ACME directory accessible"
    echo "${DIRECTORY}" | python3 -m json.tool
else
    fail "ACME directory not responding"
fi
echo ""

# ─── Test 2: Nonce ──────────────────────────────────────────────────────────
log "Test 2: ACME Nonce"
NEW_NONCE=$(echo "${DIRECTORY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['newNonce'])")
NONCE=$(curl -sk -I "${NEW_NONCE}" | grep -i replay-nonce | awk '{print $2}' | tr -d '\r')
if [ -n "${NONCE}" ]; then
    pass "Nonce received: ${NONCE:0:20}..."
else
    fail "No nonce returned"
fi
echo ""

# ─── Test 3: Generate CSR and submit cert request via CA ────────────────────
log "Test 3: Certificate Request (CA direct)"
KEYFILE="/tmp/test-${DOMAIN}.key"
CSRFILE="/tmp/test-${DOMAIN}.csr"

openssl req -new -newkey rsa:2048 -nodes \
    -keyout "${KEYFILE}" \
    -out "${CSRFILE}" \
    -subj "/CN=${DOMAIN}" 2>/dev/null

REQUEST_ID=$(run_pki ca-cert-request-submit \
    --profile caServerCert \
    --csr-file "${CSRFILE}" 2>&1 | grep "Request ID:" | awk '{print $3}')

if [ -n "${REQUEST_ID}" ]; then
    pass "Request submitted: ID ${REQUEST_ID}"
else
    fail "Certificate request failed"
    run_pki ca-cert-request-submit --profile caServerCert --csr-file "${CSRFILE}" 2>&1 | tail -5
fi
echo ""

# ─── Test 4: Approve the request ────────────────────────────────────────────
log "Test 4: Approve Certificate Request"
CERT_ID=""
if [ -n "${REQUEST_ID}" ]; then
    APPROVAL=$(run_pki ca-cert-request-approve "${REQUEST_ID}" --force 2>&1)
    CERT_ID=$(echo "${APPROVAL}" | grep "Certificate ID:" | awk '{print $3}')
    if [ -n "${CERT_ID}" ]; then
        pass "Certificate approved and issued: serial ${CERT_ID}"
    else
        fail "Approval failed"
        echo "${APPROVAL}" | tail -5
    fi
else
    fail "Skipped — no request ID"
fi
echo ""

# ─── Test 5: Download the issued cert ───────────────────────────────────────
log "Test 5: Download Certificate"
CERTFILE="/tmp/test-${DOMAIN}.crt"
if [ -n "${CERT_ID}" ]; then
    run_pki ca-cert-export "${CERT_ID}" --output-file "${CERTFILE}" 2>&1
    if [ -f "${CERTFILE}" ]; then
        pass "Certificate saved to ${CERTFILE}"
        openssl x509 -in "${CERTFILE}" -noout -subject -serial -dates
    else
        fail "Certificate file not created"
    fi
else
    fail "Skipped — no cert ID"
fi
echo ""

# ─── Test 6: Verify via OCSP ───────────────────────────────────────────────
log "Test 6: OCSP Verification"
if [ -f "${CERTFILE}" ] && [ -f "/tmp/ca.crt" ]; then
    OCSP_RESULT=$(openssl ocsp \
        -issuer /tmp/ca.crt \
        -cert "${CERTFILE}" \
        -url http://localhost:8080/ca/ocsp \
        -resp_text -noverify 2>&1)
    OCSP_STATUS=$(echo "${OCSP_RESULT}" | grep "Cert Status:" | awk '{print $3}')
    if [ "${OCSP_STATUS}" = "good" ]; then
        pass "OCSP status: good"
    else
        fail "OCSP status: ${OCSP_STATUS}"
    fi
    echo "${OCSP_RESULT}" | grep -E "Serial Number|Cert Status|This Update"
else
    fail "Skipped — missing cert or CA file"
fi
echo ""

# ─── Test 7: Revoke and re-check OCSP ──────────────────────────────────────
log "Test 7: Revoke and OCSP Re-check"
if [ -n "${CERT_ID}" ]; then
    run_pki ca-cert-revoke "${CERT_ID}" --force --reason unspecified 2>&1 | head -3

    OCSP_AFTER=$(openssl ocsp \
        -issuer /tmp/ca.crt \
        -cert "${CERTFILE}" \
        -url http://localhost:8080/ca/ocsp \
        -resp_text -noverify 2>&1)
    REVOKE_STATUS=$(echo "${OCSP_AFTER}" | grep "Cert Status:" | awk '{print $3}')
    if [ "${REVOKE_STATUS}" = "revoked" ]; then
        pass "OCSP correctly reports: revoked"
    else
        fail "OCSP reports: ${REVOKE_STATUS} (expected revoked)"
    fi
    echo "${OCSP_AFTER}" | grep -E "Serial Number|Cert Status|Revocation Time"
else
    fail "Skipped — no cert ID"
fi
echo ""

# ─── Summary ────────────────────────────────────────────────────────────────
log "=== Test Summary ==="
log "Key:  ${KEYFILE}"
log "CSR:  ${CSRFILE}"
log "Cert: ${CERTFILE}"
log "Serial: ${CERT_ID:-N/A}"
log "=== Done ==="
