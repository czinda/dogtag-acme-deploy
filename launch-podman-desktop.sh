#!/bin/bash
# =============================================================================
# Dogtag PKI CA + ACME — macOS / Linux Podman Desktop Launcher
#
# Usage:
#   bash launch-podman-desktop.sh --build     # Build images (one-time)
#   bash launch-podman-desktop.sh             # Launch pod
#   bash launch-podman-desktop.sh --down      # Tear down
#   bash launch-podman-desktop.sh --status    # Check endpoints
#   bash launch-podman-desktop.sh --test      # Run test suites
#   bash launch-podman-desktop.sh --logs      # Follow container logs
#
# Generated-by: Claude Code (claude.ai/code)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POD_YAML="$SCRIPT_DIR/dogtag-pki-pod.yaml"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${CYAN}[dogtag]${NC} $*"; }
ok()   { echo -e "${GREEN}  OK:${NC} $*"; }
fail() { echo -e "${RED}  FAIL:${NC} $*"; }

# ── Preflight ─────────────────────────────────────────────────────────────────
check_podman() {
    if ! command -v podman &>/dev/null; then
        fail "Podman is not installed."
        echo "  Install from: https://podman-desktop.io/"
        exit 1
    fi
    log "Podman: $(podman --version)"
}

# ── Build ─────────────────────────────────────────────────────────────────────
do_build() {
    if [ -z "${RHSM_USERNAME:-}" ] || [ -z "${RHSM_PASSWORD:-}" ]; then
        fail "RHSM_USERNAME and RHSM_PASSWORD must be set."
        echo ""
        echo -e "${YELLOW}  Option 1: Export them:${NC}"
        echo "    export RHSM_USERNAME=your-user"
        echo "    export RHSM_PASSWORD=your-pass"
        echo ""
        echo -e "${YELLOW}  Option 2: Source from encrypted env:${NC}"
        echo "    source <(age -d -i ~/.config/age/keys.txt ~/.claude/.env.age)"
        echo ""
        echo -e "${YELLOW}  Option 3: 1Password:${NC}"
        echo '    source <(op read "op://Private/age-private-key/notesPlain" | age -d -i - ~/.claude/.env.age)'
        exit 1
    fi

    log "Building DS image..."
    podman build --platform linux/amd64 \
        --build-arg RHSM_USER="$RHSM_USERNAME" \
        --build-arg RHSM_PASS="$RHSM_PASSWORD" \
        -t dogtag-ds -f "$SCRIPT_DIR/containers/ds/Containerfile" "$SCRIPT_DIR"

    log "Building CA + ACME image..."
    podman build --platform linux/amd64 \
        --build-arg RHSM_USER="$RHSM_USERNAME" \
        --build-arg RHSM_PASS="$RHSM_PASSWORD" \
        -t dogtag-ca -f "$SCRIPT_DIR/containers/ca/Containerfile" "$SCRIPT_DIR"

    log "Images built:"
    podman images --filter "reference=dogtag*" --format "  {{.Repository}}:{{.Tag}}  {{.Size}}"
    echo ""
    log "Run: bash $0"
}

# ── Up ────────────────────────────────────────────────────────────────────────
do_up() {
    for img in dogtag-ds dogtag-ca; do
        if ! podman image exists "localhost/$img:latest" 2>/dev/null; then
            fail "Image $img not found. Run: bash $0 --build"
            exit 1
        fi
    done

    podman kube down "$POD_YAML" 2>/dev/null || true
    podman pod rm -f dogtag-pki 2>/dev/null || true

    log "Launching Dogtag PKI pod..."
    podman kube play "$POD_YAML"

    echo ""
    log "Pod started. First-boot deployment in progress (~4 min)..."
    log "Watch progress: podman pod logs -f dogtag-pki"
    echo ""
    log "Endpoints (available after first-boot):"
    echo "  DS:   ldap://localhost:3389"
    echo "  CA:   https://localhost:8443/ca/admin/ca/getStatus"
    echo "  ACME: https://localhost:8443/acme/directory"
    echo ""
    log "Podman Desktop: open the 'Pods' tab to see dogtag-pki"
}

# ── Down ──────────────────────────────────────────────────────────────────────
do_down() {
    log "Tearing down Dogtag PKI pod..."
    podman kube down "$POD_YAML" 2>/dev/null || true
    podman pod rm -f dogtag-pki 2>/dev/null || true
    ok "Pod removed"
}

# ── Status ────────────────────────────────────────────────────────────────────
do_status() {
    log "Pod status:"
    podman pod ps --format "table {{.Name}}\t{{.Status}}\t{{.Containers}}" 2>&1 | grep -E "NAME|dogtag"
    echo ""
    log "Containers:"
    podman ps --filter "pod=dogtag-pki" --format "table {{.Names}}\t{{.Status}}"
    echo ""
    log "Endpoints:"

    CA=$(curl -sk https://localhost:8443/ca/admin/ca/getStatus 2>/dev/null)
    if echo "$CA" | grep -q "running"; then
        ok "CA: $(echo "$CA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Response']['Status'], 'v'+d['Response']['Version'])" 2>/dev/null)"
    else
        echo -e "${YELLOW}  CA: not ready${NC}"
    fi

    ACME=$(curl -sk https://localhost:8443/acme/directory 2>/dev/null)
    if echo "$ACME" | grep -q "newNonce"; then
        ok "ACME: $(echo "$ACME" | python3 -c "import sys,json; print(len(json.load(sys.stdin)), 'endpoints')" 2>/dev/null)"
    else
        echo -e "${YELLOW}  ACME: not ready${NC}"
    fi

    DS=$(ldapsearch -x -H ldap://localhost:3389 -b "" -s base 2>&1)
    if echo "$DS" | grep -q "LDAPv3"; then
        ok "DS: responding"
    else
        echo -e "${YELLOW}  DS: not ready${NC}"
    fi
}

# ── Test ──────────────────────────────────────────────────────────────────────
do_test() {
    log "Setting up pki CLI..."
    podman exec dogtag-pki-ca bash -c '
        certutil -L -d /etc/pki/pki-tomcat/alias -n "caSigningCert cert-pki-tomcat CA" -a > /tmp/ca.crt
        pki -d /root/.dogtag/nssdb -c Secret.123 client-init --force 2>/dev/null
        echo "Secret.123" > /root/.dogtag/nssdb/password.txt && chmod 600 /root/.dogtag/nssdb/password.txt
        certutil -A -d /root/.dogtag/nssdb -n "CA Signing Certificate" -t "CT,C,C" -a -i /tmp/ca.crt -f /root/.dogtag/nssdb/password.txt
        pki -d /root/.dogtag/nssdb -c Secret.123 pkcs12-import --pkcs12 /root/.dogtag/pki-tomcat/ca_admin_cert.p12 --password Secret.123 2>/dev/null
        echo "CLI ready"
    ' 2>&1 | tail -1

    echo ""
    log "Running basic tests (7 tests)..."
    podman exec dogtag-pki-ca bash /usr/local/bin/test-acme-issue.sh

    echo ""
    log "Running comprehensive tests (11 tests)..."
    podman exec dogtag-pki-ca bash /usr/local/bin/test-comprehensive.sh
}

# ── Logs ──────────────────────────────────────────────────────────────────────
do_logs() {
    log "Following pod logs (Ctrl+C to stop)..."
    podman pod logs -f dogtag-pki
}

# ── Main ──────────────────────────────────────────────────────────────────────
check_podman

case "${1:-up}" in
    --build|build)   do_build ;;
    --down|down)     do_down ;;
    --status|status) do_status ;;
    --test|test)     do_test ;;
    --logs|logs)     do_logs ;;
    --up|up|"")      do_up ;;
    *)
        echo "Usage: bash $0 [--build|--up|--down|--status|--test|--logs]"
        exit 1
        ;;
esac
