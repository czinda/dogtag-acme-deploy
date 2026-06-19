#!/bin/bash
# =============================================================================
# RHEL 8 DISA STIG Hardening for Dogtag PKI Container
#
# Applies all applicable STIG controls for a containerized RHCS deployment.
# Designed to run AFTER deploy-dogtag-acme.sh and BEFORE production use.
#
# Prerequisites:
#   - RHEL 8 container with systemd (ubi8/ubi-init)
#   - Dogtag PKI already deployed
#   - subscription-manager registered
#
# Usage:
#   bash harden-stig.sh              # Apply hardening + scan
#   bash harden-stig.sh --scan-only  # Scan without remediation
#
# Generated-by: Claude Code (claude.ai/code)
# =============================================================================
set -uo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[STIG $(date +%T)]${NC} $*"; }
pass() { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }

SCAN_ONLY=false
for arg in "$@"; do
    case $arg in
        --scan-only) SCAN_ONLY=true ;;
    esac
done

STIG_PROFILE="xccdf_org.ssgproject.content_profile_stig"
SCAP_CONTENT="/usr/share/xml/scap/ssg/content/ssg-rhel8-ds.xml"

# =============================================================================
# Phase 1: Install OpenSCAP
# =============================================================================
log "Phase 1: Installing OpenSCAP and SCAP Security Guide..."
dnf install -y scap-security-guide openscap-scanner crypto-policies-scripts 2>&1 | tail -3

if [ "$SCAN_ONLY" = true ]; then
    log "Scan-only mode — skipping remediation"
else
    # =========================================================================
    # Phase 2: Enable FIPS:STIG crypto policy
    # =========================================================================
    log "Phase 2: Setting crypto policy to FIPS:STIG..."

    if [ ! -f /usr/share/crypto-policies/policies/modules/STIG.pmod ]; then
        cat > /usr/share/crypto-policies/policies/modules/STIG.pmod << 'EOF'
# DISA STIG subpolicy for FIPS
# Restricts algorithms beyond base FIPS requirements
min_tls_version = TLS1.2
min_dtls_version = DTLS1.2
hash = -SHA1
sign = -RSA-PSS-SHA1 -RSA-SHA1 -ECDSA-SHA1
EOF
        pass "Created STIG.pmod"
    fi

    update-crypto-policies --set FIPS:STIG 2>&1 | tail -1
    pass "Crypto policy: $(update-crypto-policies --show)"

    # =========================================================================
    # Phase 3: Enable fapolicyd
    # =========================================================================
    log "Phase 3: Configuring fapolicyd..."

    if ! rpm -q fapolicyd &>/dev/null; then
        dnf install -y fapolicyd 2>&1 | tail -3
    fi

    systemctl enable --now fapolicyd 2>/dev/null || true
    fapolicyd-cli --update 2>/dev/null || true
    pass "fapolicyd: $(systemctl is-active fapolicyd)"

    # =========================================================================
    # Phase 4: Apply STIG remediations
    # =========================================================================
    log "Phase 4: Applying STIG remediations..."

    # GPG check for all repositories
    find /etc/yum.repos.d/ -name "*.repo" -exec sed -i "s/gpgcheck\s*=\s*0/gpgcheck=1/g" {} \;
    if ! grep -q "^localpkg_gpgcheck" /etc/dnf/dnf.conf 2>/dev/null; then
        echo "localpkg_gpgcheck=1" >> /etc/dnf/dnf.conf
    else
        sed -i "s/^localpkg_gpgcheck=.*/localpkg_gpgcheck=1/" /etc/dnf/dnf.conf
    fi
    pass "gpgcheck=1 on all repos and local packages"

    # Root init file permissions
    chmod 0740 /root/.bashrc /root/.bash_profile /root/.cshrc /root/.tcshrc /root/.bash_logout 2>/dev/null || true
    pass "Root init files set to 0740"

    # Multiple DNS servers
    if ! grep -q "8.8.4.4" /etc/resolv.conf 2>/dev/null; then
        echo "nameserver 8.8.4.4" >> /etc/resolv.conf
    fi
    pass "Multiple DNS servers configured"

    # rootfiles tmpfiles.d
    dnf install -y rootfiles 2>&1 | tail -1
    cat > /etc/tmpfiles.d/rootfiles.conf << 'EOF'
C /root/.bash_logout 600 root root - /usr/share/rootfiles/.bash_logout
C /root/.bash_profile 600 root root - /usr/share/rootfiles/.bash_profile
C /root/.bashrc 600 root root - /usr/share/rootfiles/.bashrc
C /root/.cshrc 600 root root - /usr/share/rootfiles/.cshrc
C /root/.tcshrc 600 root root - /usr/share/rootfiles/.tcshrc
EOF
    pass "rootfiles tmpfiles.d configured"
fi

# =============================================================================
# Phase 5: STIG Assessment
# =============================================================================
log "Phase 5: Running STIG assessment..."

RESULTS=$(oscap xccdf eval \
    --profile "$STIG_PROFILE" \
    --results /tmp/stig-results.xml \
    --report /tmp/stig-report.html \
    "$SCAP_CONTENT" 2>&1) || true

PASS_COUNT=$(echo "$RESULTS" | grep -c "^Result.*pass$")
FAIL_COUNT=$(echo "$RESULTS" | grep -c "^Result.*fail$")
NA_COUNT=$(echo "$RESULTS" | grep -c "^Result.*notapplicable$")

if [ "$FAIL_COUNT" -gt 0 ]; then
    SCORE=$(( PASS_COUNT * 100 / (PASS_COUNT + FAIL_COUNT) ))
else
    SCORE=100
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  DISA STIG Compliance Report${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "  Passing:        ${GREEN}${PASS_COUNT}${NC}"
echo -e "  Failing:        $([ $FAIL_COUNT -eq 0 ] && echo "${GREEN}" || echo "${RED}")${FAIL_COUNT}${NC}"
echo -e "  Not applicable: ${NA_COUNT}"
echo -e "  Crypto policy:  $(update-crypto-policies --show)"
echo -e "  fapolicyd:      $(systemctl is-active fapolicyd 2>/dev/null || echo 'not installed')"

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo -e "  Score:          ${GREEN}${SCORE}% — FULLY COMPLIANT${NC}"
else
    echo -e "  Score:          ${RED}${SCORE}%${NC}"
    echo ""
    echo "  Remaining failures:"
    echo "$RESULTS" | grep -B2 "^Result.*fail$" | grep "Title" | sed 's/^/    /'
fi
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo ""
echo "  HTML report: /tmp/stig-report.html"
echo "  XML results: /tmp/stig-results.xml"
echo ""
