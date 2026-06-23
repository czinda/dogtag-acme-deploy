<#
.SYNOPSIS
    Dogtag PKI CA + ACME — Windows Podman Desktop Launcher

.DESCRIPTION
    Builds container images and launches the Dogtag PKI pod on Windows
    via Podman Desktop / podman kube play.

.PARAMETER Action
    build  — Build all container images (requires RHSM credentials)
    up     — Launch the pod (default)
    down   — Tear down the pod
    status — Show pod and endpoint status
    test   — Run the test suites inside the CA container
    logs   — Follow container logs

.EXAMPLE
    # First time (builds images):
    $env:RHSM_USERNAME = "your-user"
    $env:RHSM_PASSWORD = "your-pass"
    .\launch.ps1 build

    # Launch:
    .\launch.ps1 up

    # Status:
    .\launch.ps1 status

    # Run tests:
    .\launch.ps1 test

    # Teardown:
    .\launch.ps1 down

.NOTES
    Generated-by: Claude Code (claude.ai/code)
#>

param(
    [Parameter(Position=0)]
    [ValidateSet("build", "up", "down", "status", "test", "logs")]
    [string]$Action = "up"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PodYaml = Join-Path $ScriptDir "dogtag-pki-pod.yaml"

function Write-Step($msg) { Write-Host "[dogtag] $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "  OK: $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "  FAIL: $msg" -ForegroundColor Red }

# ── Preflight checks ─────────────────────────────────────────────────────────
function Test-Podman {
    try {
        $ver = podman --version 2>&1
        if ($LASTEXITCODE -ne 0) { throw "podman not found" }
        Write-Step "Podman: $ver"
    } catch {
        Write-Fail "Podman is not installed or not in PATH."
        Write-Host "  Install from: https://podman-desktop.io/" -ForegroundColor Yellow
        exit 1
    }

    $machine = podman machine info 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Podman Machine not running. Start it with: podman machine start"
        exit 1
    }
}

# ── Build ─────────────────────────────────────────────────────────────────────
function Invoke-Build {
    if (-not $env:RHSM_USERNAME -or -not $env:RHSM_PASSWORD) {
        Write-Fail "RHSM_USERNAME and RHSM_PASSWORD environment variables required."
        Write-Host ""
        Write-Host '  $env:RHSM_USERNAME = "your-rhn-username"' -ForegroundColor Yellow
        Write-Host '  $env:RHSM_PASSWORD = "your-rhn-password"' -ForegroundColor Yellow
        Write-Host '  .\launch.ps1 build' -ForegroundColor Yellow
        exit 1
    }

    Write-Step "Building DS image..."
    podman build --platform linux/amd64 `
        --build-arg RHSM_USER="$env:RHSM_USERNAME" `
        --build-arg RHSM_PASS="$env:RHSM_PASSWORD" `
        -t dogtag-ds -f "$ScriptDir\containers\ds\Containerfile" $ScriptDir
    if ($LASTEXITCODE -ne 0) { Write-Fail "DS build failed"; exit 1 }

    Write-Step "Building CA + ACME image..."
    podman build --platform linux/amd64 `
        --build-arg RHSM_USER="$env:RHSM_USERNAME" `
        --build-arg RHSM_PASS="$env:RHSM_PASSWORD" `
        -t dogtag-ca -f "$ScriptDir\containers\ca\Containerfile" $ScriptDir
    if ($LASTEXITCODE -ne 0) { Write-Fail "CA build failed"; exit 1 }

    Write-Step "Images built:"
    podman images --filter "reference=dogtag*" --format "  {{.Repository}}:{{.Tag}}  {{.Size}}"
    Write-Host ""
    Write-Step "Run '.\launch.ps1 up' to start the pod."
}

# ── Up ────────────────────────────────────────────────────────────────────────
function Invoke-Up {
    foreach ($img in @("dogtag-ds", "dogtag-ca")) {
        $exists = podman image exists "localhost/${img}:latest" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Image $img not found. Run: .\launch.ps1 build"
            exit 1
        }
    }

    # Remove existing pod
    podman kube down $PodYaml 2>$null
    podman pod rm -f dogtag-pki 2>$null

    Write-Step "Launching Dogtag PKI pod..."
    podman kube play $PodYaml
    if ($LASTEXITCODE -ne 0) { Write-Fail "Pod launch failed"; exit 1 }

    Write-Host ""
    Write-Step "Pod started. First-boot deployment in progress (~4 min)..."
    Write-Step "Watch progress: podman pod logs -f dogtag-pki"
    Write-Host ""
    Write-Step "Endpoints (available after first-boot):"
    Write-Host "  DS:   ldap://localhost:3389" -ForegroundColor White
    Write-Host "  CA:   https://localhost:8443/ca/admin/ca/getStatus" -ForegroundColor White
    Write-Host "  ACME: https://localhost:8443/acme/directory" -ForegroundColor White
    Write-Host ""
    Write-Step "Open Podman Desktop -> Pods tab to see dogtag-pki"
}

# ── Down ──────────────────────────────────────────────────────────────────────
function Invoke-Down {
    Write-Step "Tearing down Dogtag PKI pod..."
    podman kube down $PodYaml 2>$null
    podman pod rm -f dogtag-pki 2>$null
    Write-Ok "Pod removed"
}

# ── Status ────────────────────────────────────────────────────────────────────
function Invoke-Status {
    Write-Step "Pod status:"
    podman pod ps --format "table {{.Name}} {{.Status}} {{.Containers}}" 2>&1 |
        Select-String "dogtag"

    Write-Host ""
    Write-Step "Containers:"
    podman ps --filter "pod=dogtag-pki" --format "table {{.Names}} {{.Status}}"

    Write-Host ""
    Write-Step "Endpoints:"
    try {
        $ca = Invoke-RestMethod -Uri "https://localhost:8443/ca/admin/ca/getStatus" `
            -SkipCertificateCheck -ErrorAction SilentlyContinue
        Write-Ok "CA: $($ca.Response.Status) v$($ca.Response.Version)"
    } catch { Write-Host "  CA: not ready" -ForegroundColor Yellow }

    try {
        $acme = Invoke-RestMethod -Uri "https://localhost:8443/acme/directory" `
            -SkipCertificateCheck -ErrorAction SilentlyContinue
        Write-Ok "ACME: $($acme.PSObject.Properties.Count) endpoints"
    } catch { Write-Host "  ACME: not ready" -ForegroundColor Yellow }
}

# ── Test ──────────────────────────────────────────────────────────────────────
function Invoke-Test {
    Write-Step "Setting up pki CLI..."
    podman exec dogtag-pki-ca bash -c @'
certutil -L -d /etc/pki/pki-tomcat/alias -n "caSigningCert cert-pki-tomcat CA" -a > /tmp/ca.crt
pki -d /root/.dogtag/nssdb -c Secret.123 client-init --force 2>/dev/null
echo "Secret.123" > /root/.dogtag/nssdb/password.txt && chmod 600 /root/.dogtag/nssdb/password.txt
certutil -A -d /root/.dogtag/nssdb -n "CA Signing Certificate" -t "CT,C,C" -a -i /tmp/ca.crt -f /root/.dogtag/nssdb/password.txt
pki -d /root/.dogtag/nssdb -c Secret.123 pkcs12-import --pkcs12 /root/.dogtag/pki-tomcat/ca_admin_cert.p12 --password Secret.123 2>/dev/null
echo "CLI ready"
'@

    Write-Host ""
    Write-Step "Running basic tests (7 tests)..."
    podman exec dogtag-pki-ca bash /usr/local/bin/test-acme-issue.sh

    Write-Host ""
    Write-Step "Running comprehensive tests (11 tests)..."
    podman exec dogtag-pki-ca bash /usr/local/bin/test-comprehensive.sh
}

# ── Logs ──────────────────────────────────────────────────────────────────────
function Invoke-Logs {
    Write-Step "Following pod logs (Ctrl+C to stop)..."
    podman pod logs -f dogtag-pki
}

# ── Main ──────────────────────────────────────────────────────────────────────
Test-Podman

switch ($Action) {
    "build"  { Invoke-Build }
    "up"     { Invoke-Up }
    "down"   { Invoke-Down }
    "status" { Invoke-Status }
    "test"   { Invoke-Test }
    "logs"   { Invoke-Logs }
}
