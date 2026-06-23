# Deployment Guide

Complete instructions for every deployment method. Pick the one that fits your environment.

---

## Method 1: Podman Desktop Pod (Recommended)

**Best for:** Local testing, demos, development. Portable to Kubernetes/OpenShift.
**Platform:** macOS, Windows, Linux
**Containers:** 2 (DS + CA/ACME in a shared-network pod)
**Security:** STIG-hardened (FIPS:STIG, fapolicyd, gpgcheck)

### Prerequisites

1. **Install Podman Desktop** — https://podman-desktop.io/
2. **Start Podman Machine:**
   ```bash
   # macOS / Windows (configures the Linux VM):
   podman machine init --cpus 4 --memory 4096 --disk-size 40
   podman machine start
   ```
3. **No registry login needed** — UBI base images are public on `registry.access.redhat.com`
4. **RHSM credentials** for image builds (Red Hat Subscription Manager — needed to install RHCS packages inside the image, not for pulling the base image)

### macOS / Linux

```bash
# Step 1: Set RHSM credentials
export RHSM_USERNAME=your-rhn-username
export RHSM_PASSWORD=your-rhn-password

# Step 2: Build images (one-time, ~45 min on Apple Silicon)
bash launch-podman-desktop.sh --build

# Step 3: Launch
bash launch-podman-desktop.sh

# Step 4: Check status (wait ~4 min for first-boot)
bash launch-podman-desktop.sh --status

# Step 5: Run tests
bash launch-podman-desktop.sh --test

# Step 6: Teardown
bash launch-podman-desktop.sh --down
```

### Windows (PowerShell)

```powershell
# Step 1: Set RHSM credentials
$env:RHSM_USERNAME = "your-rhn-username"
$env:RHSM_PASSWORD = "your-rhn-password"

# Step 2: Build images (one-time)
.\launch.ps1 build

# Step 3: Launch
.\launch.ps1 up

# Step 4: Check status (wait ~4 min for first-boot)
.\launch.ps1 status

# Step 5: Run tests
.\launch.ps1 test

# Step 6: Teardown
.\launch.ps1 down
```

### Podman Desktop GUI

1. Build images first using the CLI (`--build` step above)
2. Open **Podman Desktop**
3. Go to **Pods** tab
4. Click **Play Kubernetes YAML**
5. Select `dogtag-pki-pod.yaml`
6. Click **Play**
7. Wait ~4 minutes for first-boot deployment
8. Pod appears with 2 containers (DS + CA)

### Podman Machine Tuning

For best performance, configure the Podman Machine VM:

```bash
# Recommended settings (run before podman machine start):
podman machine stop
podman machine set --cpus 4 --memory 4096 --disk-size 40
podman machine start

# Verify:
podman machine info
```

| Setting | Minimum | Recommended | Why |
|---------|---------|-------------|-----|
| CPUs | 2 | 4 | pkispawn and QEMU emulation are CPU-intensive |
| Memory | 2 GB | 4 GB | Java (Tomcat) + 389 DS + NSS operations |
| Disk | 20 GB | 40 GB | Container images are ~800 MB each |

### Endpoints

| Service | URL |
|---------|-----|
| CA Status | https://localhost:8443/ca/admin/ca/getStatus |
| ACME Directory | https://localhost:8443/acme/directory |
| OCSP Responder | http://localhost:8080/ca/ocsp |
| DS (LDAP) | ldap://localhost:3389 |

---

## Method 2: Single Container (All-in-One)

**Best for:** Quickest setup, smallest footprint, simple testing.
**Platform:** macOS, Windows, Linux

### Build and Run

```bash
# Build (one-time):
podman build --platform linux/amd64 \
  --build-arg RHSM_USER=$RHSM_USERNAME \
  --build-arg RHSM_PASS=$RHSM_PASSWORD \
  -t dogtag-acme -f Containerfile .

# Run:
podman run -d --name dogtag-acme \
  --hostname dev-ca-1.localdomain \
  --privileged --systemd=true \
  -p 8443:8443 -p 8080:8080 -p 3389:3389 \
  dogtag-acme:latest

# Wait ~5 min for first-boot, then verify:
curl -sk https://localhost:8443/ca/admin/ca/getStatus
curl -sk https://localhost:8443/acme/directory
```

### With Compose

```bash
# Requires RHSM creds in environment for build:
RHSM_USER=$RHSM_USERNAME RHSM_PASS=$RHSM_PASSWORD \
  podman compose -f compose.yaml up -d
```

### Teardown

```bash
podman stop dogtag-acme && podman rm dogtag-acme
# Or: podman compose -f compose.yaml down
```

---

## Method 3: Multi-Container (Separate Networks)

**Best for:** Production-like separation, independent container lifecycle.
**Platform:** macOS, Windows, Linux

### Build and Run

```bash
# Build all 3 images:
for svc in ds ca acme; do
  podman build --platform linux/amd64 \
    --build-arg RHSM_USER=$RHSM_USERNAME \
    --build-arg RHSM_PASS=$RHSM_PASSWORD \
    -t dogtag-$svc -f containers/$svc/Containerfile .
done

# Launch:
podman compose -f compose-split.yaml up -d

# Watch:
podman compose -f compose-split.yaml logs -f
```

### Endpoints

| Service | URL | Note |
|---------|-----|------|
| CA | https://localhost:8443 | |
| ACME | https://localhost:8444 | Port offset |
| DS | ldap://localhost:3389 | |

### Teardown

```bash
podman compose -f compose-split.yaml down -v
```

---

## Method 4: Shell Script (Bare Metal / VM)

**Best for:** Customer environments, production RHEL 8 hosts.
**Platform:** RHEL 8.x with root access

### Prerequisites

- RHEL 8.x registered with `subscription-manager`
- Red Hat Certificate System subscription
- Root SSH access

### Deploy

```bash
# Copy to target:
scp deploy-dogtag-acme.sh root@pki.example.com:

# Default (pki-server CLI method):
ssh root@pki.example.com bash deploy-dogtag-acme.sh

# pkispawn method:
ssh root@pki.example.com bash deploy-dogtag-acme.sh --acme-method=pkispawn

# Custom passwords:
ssh root@pki.example.com bash deploy-dogtag-acme.sh \
  --ds-password=MyDSPass \
  --admin-password=MyAdminPass
```

### STIG Hardening (after deploy)

```bash
scp harden-stig.sh root@pki.example.com:
ssh root@pki.example.com bash harden-stig.sh
```

### Verify

```bash
ssh root@pki.example.com 'curl -sk https://localhost:8443/ca/admin/ca/getStatus'
ssh root@pki.example.com 'curl -sk https://localhost:8443/acme/directory'
```

---

## Method 5: Ansible Playbook (Remote Hosts)

**Best for:** Fleet deployment, CI/CD, infrastructure-as-code.
**Platform:** Any host with Ansible → RHEL 8 targets

### Prerequisites

- Ansible installed on control node
- SSH key access to target hosts
- Target hosts registered with `subscription-manager`

### Deploy

```bash
# 1. Create inventory:
cp inventory.example inventory
# Edit with your target hostnames:
#   [pki_servers]
#   pki1.example.com ansible_user=root
#   pki2.example.com ansible_user=root

# 2. Deploy (CLI method):
ansible-playbook -i inventory deploy-dogtag-acme.yml \
  -e pki_admin_password=YourPassword \
  -e ds_password=YourDSPassword

# 3. Or pkispawn method:
ansible-playbook -i inventory deploy-dogtag-acme.yml \
  -e acme_method=pkispawn

# 4. Run individual phases:
ansible-playbook -i inventory deploy-dogtag-acme.yml --tags packages
ansible-playbook -i inventory deploy-dogtag-acme.yml --tags ds
ansible-playbook -i inventory deploy-dogtag-acme.yml --tags ca
ansible-playbook -i inventory deploy-dogtag-acme.yml --tags acme
ansible-playbook -i inventory deploy-dogtag-acme.yml --tags verify
```

### Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `pki_instance_name` | `pki-tomcat` | PKI Tomcat instance name |
| `pki_https_port` | `8443` | HTTPS port |
| `pki_http_port` | `8080` | HTTP port |
| `pki_admin_password` | `Secret.123` | Admin password |
| `pki_admin_uid` | `caadmin` | Admin username |
| `ds_instance_name` | `pki-ds` | DS instance name |
| `ds_port` | `3389` | DS LDAP port |
| `ds_password` | `Secret.123` | Directory Manager password |
| `acme_method` | `cli` | `cli` or `pkispawn` |

---

## Method 6: Pre-built Image Import

**Best for:** Air-gapped environments, sharing with teammates, offline demos.
**Platform:** Any system with Podman

### Export (from a machine that has built the image)

```bash
# Single container image:
podman commit dogtag-acme dogtag-acme:stig-hardened
podman save -o dogtag-acme-stig-hardened.tar dogtag-acme:stig-hardened

# Pod images (DS + CA):
podman save -o dogtag-ds.tar dogtag-ds:latest
podman save -o dogtag-ca.tar dogtag-ca:latest
```

### Import and Run

```bash
# Single container:
podman load -i dogtag-acme-stig-hardened.tar
podman run -d --name dogtag-acme --privileged --systemd=true \
  -p 8443:8443 -p 8080:8080 -p 3389:3389 \
  dogtag-acme:stig-hardened

# Pod (import both images, then play YAML):
podman load -i dogtag-ds.tar
podman load -i dogtag-ca.tar
podman kube play dogtag-pki-pod.yaml
```

---

## Testing (All Methods)

### From Inside the Container

```bash
# Basic lifecycle (7 tests):
podman exec dogtag-pki-ca bash /usr/local/bin/test-acme-issue.sh

# Comprehensive (11 tests):
podman exec dogtag-pki-ca bash /usr/local/bin/test-comprehensive.sh

# STIG compliance scan:
podman exec dogtag-pki-ca bash /usr/local/bin/harden-stig.sh --scan-only
```

### From the Host

```bash
# CA status:
curl -sk https://localhost:8443/ca/admin/ca/getStatus | python3 -m json.tool

# ACME directory:
curl -sk https://localhost:8443/acme/directory | python3 -m json.tool

# OCSP check:
openssl ocsp -issuer ca.crt -serial 0x01 \
  -url http://localhost:8080/ca/ocsp -resp_text -noverify

# certbot:
certbot certonly --server https://localhost:8443/acme/directory \
  --standalone --no-verify-ssl -d test.example.com
```

### Using the Launcher

```bash
# macOS / Linux:
bash launch-podman-desktop.sh --test

# Windows:
.\launch.ps1 test
```

---

## Security

All container deployments include DISA STIG hardening:

| Control | Detail |
|---------|--------|
| Crypto policy | `FIPS:STIG` — TLS 1.2 min, SHA-1 disabled |
| fapolicyd | Application whitelisting (enforcing) |
| gpgcheck | All repos + local packages |
| STIG score | 100% (50/50 applicable rules) |
| Root file perms | 0740 on all init files |
| DNS | Multiple nameservers configured |

For bare-metal deployments, run `bash harden-stig.sh` after deployment.

---

## Troubleshooting

See [[Troubleshooting]] in the wiki, or the common issues:

| Issue | Fix |
|-------|-----|
| `Invalid database type: None` | Add `--type ds` to `acme-database-mod` |
| `hostname: command not found` | `dnf install -y hostname` |
| DNS fails in container | `echo "nameserver 8.8.8.8" > /etc/resolv.conf` |
| `BAD_CERT_DOMAIN` in pki CLI | Use `--ignore-cert-status BAD_CERT_DOMAIN` |
| RHCS packages not found (ARM) | Use `--platform linux/amd64` |
| 1Password GPG signing fails | Retry or use `git -c commit.gpgsign=false commit` |
