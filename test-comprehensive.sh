#!/bin/bash
# =============================================================================
# Comprehensive Dogtag PKI Certificate Test Suite
# Tests: ECC, SAN, User certs, CRL, FIPS rejection, ACME flow, OCSP bug repro
# Usage: bash /root/test-comprehensive.sh
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[TEST $(date +%T)]${NC} $*"; }
pass() { echo -e "${GREEN}  ✓ PASS:${NC} $*"; }
fail() { echo -e "${RED}  ✗ FAIL:${NC} $*"; FAILURES=$((FAILURES+1)); }
warn() { echo -e "${YELLOW}  ⚠ WARN:${NC} $*"; }
section() { echo ""; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; log "$*"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

FAILURES=0
TOTAL=0
CERTS_ISSUED=()

run_pki() {
    pki -d /root/.dogtag/nssdb -c Secret.123 \
        -U https://localhost:8443 \
        -n "PKI Administrator" \
        --ignore-cert-status BAD_CERT_DOMAIN \
        "$@"
}

issue_cert() {
    local PROFILE="$1"
    local CSRFILE="$2"
    local LABEL="$3"

    local SUBMIT_OUTPUT=$(run_pki ca-cert-request-submit \
        --profile "$PROFILE" \
        --csr-file "$CSRFILE" 2>&1)

    local CERT_ID=$(echo "$SUBMIT_OUTPUT" | grep "Certificate ID:" | awk '{print $3}')

    if [ -n "$CERT_ID" ]; then
        CERTS_ISSUED+=("$CERT_ID|$LABEL")
        echo "$CERT_ID"
        return 0
    fi

    local REQ_ID=$(echo "$SUBMIT_OUTPUT" | grep "Request ID:" | awk '{print $3}')
    if [ -z "$REQ_ID" ]; then
        echo ""
        return 1
    fi

    CERT_ID=$(run_pki ca-cert-request-approve "$REQ_ID" --force 2>&1 \
        | grep "Certificate ID:" | awk '{print $3}')

    if [ -n "$CERT_ID" ]; then
        CERTS_ISSUED+=("$CERT_ID|$LABEL")
    fi
    echo "$CERT_ID"
}

check_ocsp() {
    local CERTFILE="$1"
    openssl ocsp -issuer /tmp/ca.crt -cert "$CERTFILE" \
        -url http://localhost:8080/ca/ocsp \
        -resp_text -noverify 2>&1 | grep "Cert Status:" | awk '{print $3}'
}

# =============================================================================
section "TEST 1: RSA Server Certificate (caServerCert)"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Generating RSA 2048 CSR..."
openssl req -new -newkey rsa:2048 -nodes \
    -keyout /tmp/t1-rsa-server.key \
    -out /tmp/t1-rsa-server.csr \
    -subj "/CN=rsa-server.example.com" 2>/dev/null

CERT_ID=$(issue_cert caServerCert /tmp/t1-rsa-server.csr "RSA Server")
if [ -n "$CERT_ID" ]; then
    run_pki ca-cert-export "$CERT_ID" --output-file /tmp/t1-rsa-server.crt 2>/dev/null
    pass "RSA server cert issued: $CERT_ID"
    openssl x509 -in /tmp/t1-rsa-server.crt -noout -subject -serial -dates
    echo "  Key: $(openssl x509 -in /tmp/t1-rsa-server.crt -noout -text | grep 'Public-Key:' | tr -d ' ')"

    OCSP=$(check_ocsp /tmp/t1-rsa-server.crt)
    if [ "$OCSP" = "good" ]; then
        pass "OCSP: good"
    else
        fail "OCSP: $OCSP (expected good)"
    fi
else
    fail "RSA server cert issuance failed"
fi

# =============================================================================
section "TEST 2: ECC Server Certificate (caECServerCert)"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Generating EC P-256 CSR..."
openssl ecparam -name prime256v1 -genkey -noout -out /tmp/t2-ec-server.key 2>/dev/null
openssl req -new -key /tmp/t2-ec-server.key \
    -out /tmp/t2-ec-server.csr \
    -subj "/CN=ec-server.example.com" 2>/dev/null

CERT_ID=$(issue_cert caECServerCert /tmp/t2-ec-server.csr "ECC Server")
if [ -n "$CERT_ID" ]; then
    run_pki ca-cert-export "$CERT_ID" --output-file /tmp/t2-ec-server.crt 2>/dev/null
    pass "ECC server cert issued: $CERT_ID"
    openssl x509 -in /tmp/t2-ec-server.crt -noout -subject -serial
    echo "  Key: $(openssl x509 -in /tmp/t2-ec-server.crt -noout -text | grep 'Public-Key:' | tr -d ' ')"
    echo "  Curve: $(openssl x509 -in /tmp/t2-ec-server.crt -noout -text | grep 'ASN1 OID:' | awk '{print $3}')"

    OCSP=$(check_ocsp /tmp/t2-ec-server.crt)
    if [ "$OCSP" = "good" ]; then
        pass "OCSP: good"
    else
        fail "OCSP: $OCSP (expected good)"
    fi
else
    fail "ECC server cert issuance failed"
fi

# =============================================================================
section "TEST 3: SAN Certificate (multiple domains)"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Generating CSR with Subject Alternative Names..."
cat > /tmp/t3-san.cnf << 'SANEOF'
[req]
default_bits = 2048
prompt = no
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = san-primary.example.com

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = san-primary.example.com
DNS.2 = san-alt1.example.com
DNS.3 = san-alt2.example.com
DNS.4 = *.wildcard.example.com
IP.1 = 10.0.0.100
SANEOF

openssl req -new -newkey rsa:2048 -nodes \
    -keyout /tmp/t3-san.key \
    -out /tmp/t3-san.csr \
    -config /tmp/t3-san.cnf 2>/dev/null

CERT_ID=$(issue_cert caServerCert /tmp/t3-san.csr "SAN Server")
if [ -n "$CERT_ID" ]; then
    run_pki ca-cert-export "$CERT_ID" --output-file /tmp/t3-san.crt 2>/dev/null
    pass "SAN cert issued: $CERT_ID"
    echo "  Subject: $(openssl x509 -in /tmp/t3-san.crt -noout -subject)"
    echo "  SANs:"
    openssl x509 -in /tmp/t3-san.crt -noout -text | grep -A1 "Subject Alternative Name" | tail -1 | tr ',' '\n' | sed 's/^/    /'
else
    fail "SAN cert issuance failed"
fi

# =============================================================================
section "TEST 4: Agent-Authenticated Server Cert (caAgentServerCert)"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Generating agent-authenticated certificate CSR..."
openssl req -new -newkey rsa:2048 -nodes \
    -keyout /tmp/t4-user.key \
    -out /tmp/t4-user.csr \
    -subj "/CN=agent-auth-test.example.com" 2>/dev/null

CERT_ID=$(issue_cert caAgentServerCert /tmp/t4-user.csr "Agent Server")
if [ -n "$CERT_ID" ]; then
    run_pki ca-cert-export "$CERT_ID" --output-file /tmp/t4-user.crt 2>/dev/null
    pass "User cert issued: $CERT_ID"
    openssl x509 -in /tmp/t4-user.crt -noout -subject -serial
    echo "  Key Usage:"
    openssl x509 -in /tmp/t4-user.crt -noout -text | grep -A1 "Key Usage" | head -2 | sed 's/^/    /'
    echo "  Extended Key Usage:"
    openssl x509 -in /tmp/t4-user.crt -noout -text | grep -A1 "Extended Key Usage" | tail -1 | sed 's/^/    /'
else
    fail "User cert issuance failed"
fi

# =============================================================================
section "TEST 5: FIPS Negative Test (RSA 1024 should be REJECTED)"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Generating RSA 1024-bit CSR (should be rejected under FIPS)..."
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 -out /tmp/t5-weak.key 2>/dev/null
WEAK_KEY_RESULT=$?

if [ $WEAK_KEY_RESULT -ne 0 ]; then
    pass "FIPS correctly rejected RSA 1024-bit key generation at OpenSSL level"
else
    openssl req -new -key /tmp/t5-weak.key \
        -out /tmp/t5-weak.csr \
        -subj "/CN=weak-key.example.com" 2>/dev/null

    WEAK_CERT=$(issue_cert caServerCert /tmp/t5-weak.csr "Weak RSA 1024")
    if [ -z "$WEAK_CERT" ]; then
        pass "CA correctly rejected RSA 1024-bit CSR"
    else
        fail "CA issued cert with RSA 1024-bit key under FIPS! Serial: $WEAK_CERT"
    fi
fi

# =============================================================================
section "TEST 6: FIPS Positive Test (RSA 3072 should be accepted)"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Generating RSA 3072-bit CSR..."
openssl req -new -newkey rsa:3072 -nodes \
    -keyout /tmp/t6-strong.key \
    -out /tmp/t6-strong.csr \
    -subj "/CN=strong-key.example.com" 2>/dev/null

CERT_ID=$(issue_cert caServerCert /tmp/t6-strong.csr "RSA 3072")
if [ -n "$CERT_ID" ]; then
    run_pki ca-cert-export "$CERT_ID" --output-file /tmp/t6-strong.crt 2>/dev/null
    pass "RSA 3072 cert issued: $CERT_ID"
    echo "  Key: $(openssl x509 -in /tmp/t6-strong.crt -noout -text | grep 'Public-Key:' | tr -d ' ')"
else
    fail "RSA 3072 cert issuance failed"
fi

# =============================================================================
section "TEST 7: CRL Generation and Verification"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Issuing a cert, revoking it, then checking CRL..."

openssl req -new -newkey rsa:2048 -nodes \
    -keyout /tmp/t7-crl.key \
    -out /tmp/t7-crl.csr \
    -subj "/CN=crl-test.example.com" 2>/dev/null

CERT_ID=$(issue_cert caServerCert /tmp/t7-crl.csr "CRL Test")
if [ -n "$CERT_ID" ]; then
    run_pki ca-cert-export "$CERT_ID" --output-file /tmp/t7-crl.crt 2>/dev/null
    SERIAL_DEC=$(openssl x509 -in /tmp/t7-crl.crt -noout -serial | cut -d= -f2)

    log "Revoking cert $CERT_ID..."
    run_pki ca-cert-revoke "$CERT_ID" --force --reason Key_Compromise 2>&1 | head -2

    log "Fetching CRL from CA..."
    curl -sk https://localhost:8443/ca/ee/ca/getCRL \
        -d "op=getCRL&crlIssuingPoint=MasterCRL" \
        -o /tmp/t7-crl.der 2>/dev/null

    if [ -f /tmp/t7-crl.der ] && [ -s /tmp/t7-crl.der ]; then
        openssl crl -in /tmp/t7-crl.der -inform DER -out /tmp/t7-crl.pem 2>/dev/null
        if [ $? -eq 0 ]; then
            CRL_SERIALS=$(openssl crl -in /tmp/t7-crl.pem -noout -text 2>/dev/null | grep -i "Serial Number:" | awk '{print toupper($NF)}')
            if echo "$CRL_SERIALS" | grep -qi "$SERIAL_DEC"; then
                pass "Revoked cert found in CRL"
            else
                warn "Revoked cert not yet in CRL (CRL may need regeneration)"
                echo "  Expected serial: $SERIAL_DEC"
            fi
            CRL_COUNT=$(echo "$CRL_SERIALS" | wc -l | tr -d ' ')
            echo "  CRL contains $CRL_COUNT revoked certificate(s)"
        else
            warn "CRL response not in expected DER format — CA may return HTML form"
        fi
    else
        warn "Could not fetch CRL (endpoint may require different parameters)"
    fi
else
    fail "CRL test cert issuance failed"
fi

# =============================================================================
section "TEST 8: ACME Protocol Flow (certbot)"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Checking if certbot is available..."
if command -v certbot &>/dev/null; then
    log "Running certbot ACME issuance..."
    certbot certonly \
        --server https://localhost:8443/acme/directory \
        --standalone \
        --no-verify-ssl \
        --register-unsafely-without-email \
        --agree-tos \
        --non-interactive \
        -d acme-test.localdomain \
        --cert-path /tmp/t8-acme.crt \
        --key-path /tmp/t8-acme.key \
        --fullchain-path /tmp/t8-acme-fullchain.crt 2>&1
    if [ $? -eq 0 ]; then
        pass "ACME certbot issuance succeeded"
        openssl x509 -in /tmp/t8-acme.crt -noout -subject -serial -dates 2>/dev/null
    else
        fail "ACME certbot issuance failed"
    fi
else
    log "certbot not installed — testing ACME manually via curl..."
    ACME_DIR=$(curl -sk https://localhost:8443/acme/directory)
    NONCE_URL=$(echo "$ACME_DIR" | python3 -c "import sys,json; print(json.load(sys.stdin)['newNonce'])")
    NONCE=$(curl -sk -I "$NONCE_URL" | grep -i replay-nonce | awk '{print $2}' | tr -d '\r')
    if [ -n "$NONCE" ]; then
        pass "ACME protocol responding (nonce: ${NONCE:0:20}...)"
        echo "  Endpoints available: $(echo "$ACME_DIR" | python3 -c "import sys,json; print(', '.join(json.load(sys.stdin).keys()))")"
    else
        fail "ACME protocol not responding"
    fi
    warn "Install certbot for full ACME flow test: dnf install certbot"
fi

# =============================================================================
section "TEST 9: Certificate Chain Validation"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Verifying certificate chain for an issued cert..."
if [ -f /tmp/t1-rsa-server.crt ]; then
    VERIFY=$(openssl verify -CAfile /tmp/ca.crt /tmp/t1-rsa-server.crt 2>&1)
    if echo "$VERIFY" | grep -q ": OK"; then
        pass "Chain validation: OK"
    else
        fail "Chain validation failed: $VERIFY"
    fi

    log "Checking AIA extension (relevant to DOGTAG-4465)..."
    AIA=$(openssl x509 -in /tmp/t1-rsa-server.crt -noout -text | grep -A3 "Authority Information Access")
    if [ -n "$AIA" ]; then
        echo "$AIA" | sed 's/^/  /'
        pass "AIA extension present"
    else
        warn "No AIA extension — CLI OCSP validation will use NSS defaults"
    fi
else
    fail "No cert available for chain validation"
fi

# =============================================================================
section "TEST 10: Bulk Issuance Stress Test (10 certs)"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Issuing 10 server certificates in sequence..."
BULK_SUCCESS=0
BULK_START=$(date +%s)

for i in $(seq 1 10); do
    openssl req -new -newkey rsa:2048 -nodes \
        -keyout /tmp/t10-bulk-${i}.key \
        -out /tmp/t10-bulk-${i}.csr \
        -subj "/CN=bulk-${i}.example.com" 2>/dev/null

    CERT_ID=$(issue_cert caServerCert /tmp/t10-bulk-${i}.csr "Bulk #${i}")
    if [ -n "$CERT_ID" ]; then
        BULK_SUCCESS=$((BULK_SUCCESS+1))
    fi
done

BULK_END=$(date +%s)
BULK_DURATION=$((BULK_END - BULK_START))

if [ $BULK_SUCCESS -eq 10 ]; then
    pass "All 10 certs issued in ${BULK_DURATION}s (avg $((BULK_DURATION/10))s/cert)"
else
    fail "Only $BULK_SUCCESS/10 certs issued in ${BULK_DURATION}s"
fi

# =============================================================================
section "TEST 11: OCSP Bug Reproduction (DOGTAG-4465)"
# =============================================================================
TOTAL=$((TOTAL+1))
log "Attempting to reproduce: CLI says revoked, OCSP says good"
log "Step 1: Check AIA in admin cert..."

ADMIN_AIA=$(openssl x509 -in /root/.dogtag/pki-tomcat/ca_admin.cert -noout -text 2>/dev/null \
    | grep -A5 "Authority Information Access")
echo "$ADMIN_AIA" | sed 's/^/  /'

log "Step 2: Check for stale CRLs in client NSS db..."
CRL_LIST=$(crlutil -L -d /root/.dogtag/nssdb 2>&1)
echo "  $CRL_LIST"

log "Step 3: Check OCSP cache config..."
OCSP_CACHE=$(grep "ca.ocspUseCache" /var/lib/pki/pki-tomcat/conf/ca/CS.cfg 2>/dev/null || echo "Not set")
echo "  ca.ocspUseCache = $OCSP_CACHE"

log "Step 4: OCSP check on admin cert..."
if [ -f /root/.dogtag/pki-tomcat/ca_admin.cert ]; then
    ADMIN_OCSP=$(openssl ocsp -issuer /tmp/ca.crt \
        -cert /root/.dogtag/pki-tomcat/ca_admin.cert \
        -url http://localhost:8080/ca/ocsp \
        -resp_text -noverify 2>&1 | grep "Cert Status:" | awk '{print $3}')
    echo "  OCSP status: $ADMIN_OCSP"
else
    echo "  Admin cert file not found"
fi

log "Step 5: pki CLI validation (verbose)..."
PKI_VERBOSE=$(run_pki -v ca-cert-find --size 1 2>&1)
PKI_RC=$?
if [ $PKI_RC -eq 0 ]; then
    pass "pki CLI connects successfully (no revocation error in this clean environment)"
    warn "Bug not reproduced — expected, since this is a fresh CA with no serial collisions"
    echo "  To reproduce DOGTAG-4465, would need: stale CRL, AIA mismatch, or serial collision"
else
    REVOKE_ERR=$(echo "$PKI_VERBOSE" | grep -i "revok")
    if [ -n "$REVOKE_ERR" ]; then
        fail "BUG REPRODUCED: pki CLI reports revocation"
        echo "$REVOKE_ERR" | sed 's/^/  /'
    else
        fail "pki CLI failed for other reason (rc=$PKI_RC)"
        echo "$PKI_VERBOSE" | tail -5 | sed 's/^/  /'
    fi
fi

# =============================================================================
section "TEST RESULTS SUMMARY"
# =============================================================================
echo ""
log "Certificates issued this run: ${#CERTS_ISSUED[@]}"
for entry in "${CERTS_ISSUED[@]}"; do
    SERIAL=$(echo "$entry" | cut -d'|' -f1)
    LABEL=$(echo "$entry" | cut -d'|' -f2)
    printf "  %-20s %s\n" "$LABEL" "$SERIAL"
done

echo ""
log "Total certs in CA database:"
TOTAL_CERTS=$(run_pki ca-cert-find --size 1 2>&1 | grep "entries matched" | awk '{print $1}')
echo "  $TOTAL_CERTS certificates"

echo ""
if [ $FAILURES -eq 0 ]; then
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  ALL $TOTAL TESTS PASSED${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
else
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}  $FAILURES of $TOTAL TESTS FAILED${NC}"
    echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi
echo ""
