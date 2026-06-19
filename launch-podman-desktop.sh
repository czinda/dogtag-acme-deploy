#!/bin/bash
# =============================================================================
# Dogtag PKI — Podman Desktop Launcher
#
# Builds all 3 images and launches the pod via podman kube play.
# Alternatively, open Podman Desktop → Pods → Play Kubernetes YAML
# and select dogtag-pki-pod.yaml.
#
# Usage:
#   # First time (builds images — requires RHSM creds):
#   bash launch-podman-desktop.sh --build
#
#   # Subsequent runs (images already built):
#   bash launch-podman-desktop.sh
#
#   # Teardown:
#   bash launch-podman-desktop.sh --down
#
# Generated-by: Claude Code (claude.ai/code)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GREEN='\033[0;32m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'
log() { echo -e "${CYAN}[dogtag]${NC} $*"; }

case "${1:-up}" in
    --build)
        log "Building all 3 images (x86_64, requires RHSM credentials)..."

        if [ -z "${RHSM_USERNAME:-}" ] || [ -z "${RHSM_PASSWORD:-}" ]; then
            echo "RHSM_USERNAME and RHSM_PASSWORD must be set."
            echo ""
            echo "Option 1: Export them:"
            echo "  export RHSM_USERNAME=your-user"
            echo "  export RHSM_PASSWORD=your-pass"
            echo ""
            echo "Option 2: Source from encrypted env:"
            echo "  source <(age -d -i ~/.config/age/keys.txt ~/.claude/.env.age)"
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
        log "Now run: bash $0"
        ;;

    --down)
        log "Tearing down Dogtag PKI pod..."
        podman kube down "$SCRIPT_DIR/dogtag-pki-pod.yaml" 2>/dev/null || true
        podman pod rm -f dogtag-pki 2>/dev/null || true
        log "Pod removed"
        ;;

    up|"")
        # Check images exist
        for img in dogtag-ds dogtag-ca; do
            if ! podman image exists "localhost/$img:latest" 2>/dev/null; then
                echo -e "${RED}Image $img not found. Run: bash $0 --build${NC}"
                exit 1
            fi
        done

        # Remove existing pod if any
        podman kube down "$SCRIPT_DIR/dogtag-pki-pod.yaml" 2>/dev/null || true
        podman pod rm -f dogtag-pki 2>/dev/null || true

        log "Launching Dogtag PKI pod..."
        podman kube play "$SCRIPT_DIR/dogtag-pki-pod.yaml" 2>&1

        echo ""
        log "Pod started. First-boot deployment in progress..."
        log "Watch progress: podman pod logs -f dogtag-pki"
        echo ""
        log "Endpoints (available after first-boot completes):"
        log "  DS:   ldap://localhost:3389"
        log "  CA:   https://localhost:8443/ca/admin/ca/getStatus"
        log "  ACME: https://localhost:8443/acme/directory"
        echo ""
        log "Podman Desktop: open the 'Pods' tab to see dogtag-pki"
        ;;

    *)
        echo "Usage: bash $0 [--build|--down]"
        exit 1
        ;;
esac
