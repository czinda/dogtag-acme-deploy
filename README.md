# Dogtag PKI CA + ACME Responder Deployment

Deploy a standalone **Red Hat Certificate System (RHCS) v11.9** CA with an ACME responder on RHEL 8. Six deployment methods — from one-click Podman Desktop pods to bare-metal Ansible playbooks.

## What Gets Deployed

| Component | Package | Version |
|-----------|---------|---------|
| CA | `redhat-pki-ca` | 11.9.0 |
| ACME Responder | `redhat-pki-acme` | 11.9.0 |
| PKI Server | `redhat-pki-server` | 11.9.0 |
| Directory Server | `389-ds-base` | 1.4.x |

All container deployments include DISA STIG hardening (FIPS:STIG crypto policy, fapolicyd, gpgcheck).

## Deployment Methods

### 1. Podman Desktop Pod (Recommended)

Two containers in a Kubernetes pod — natively supported by Podman Desktop and portable to OpenShift.

```bash
# Build images (one-time, ~45 min on Apple Silicon):
export RHSM_USERNAME=your-user RHSM_PASSWORD=your-pass
bash launch-podman-desktop.sh --build

# Launch:
bash launch-podman-desktop.sh

# Or: Podman Desktop → Pods → Play Kubernetes YAML → dogtag-pki-pod.yaml

# Teardown:
bash launch-podman-desktop.sh --down
```

| Container | Service | Host Port |
|-----------|---------|-----------|
| `dogtag-pki-ds` | 389 Directory Server | 3389 |
| `dogtag-pki-ca` | Dogtag CA + ACME | 8443, 8080 |

### 2. Single Container (All-in-One)

Everything in one container with systemd.

```bash
# Build:
podman build --platform linux/amd64 \
  --build-arg RHSM_USER=$RHSM_USERNAME --build-arg RHSM_PASS=$RHSM_PASSWORD \
  -t dogtag-acme -f Containerfile .

# Run:
podman run -d --name dogtag-acme --privileged --systemd=true \
  -p 8443:8443 -p 8080:8080 -p 3389:3389 dogtag-acme:latest

# Or via compose:
podman compose -f compose.yaml up -d
```

### 3. Multi-Container (Separate Networks)

Three independent containers on a Podman network with compose healthchecks.

```bash
podman compose -f compose-split.yaml up -d
```

### 4. Shell Script (Bare Metal / VM)

Direct install on a RHEL 8 host.

```bash
scp deploy-dogtag-acme.sh root@pki.example.com:
ssh root@pki.example.com bash deploy-dogtag-acme.sh

# Options:
#   --acme-method=pkispawn    Use pkispawn instead of CLI method
#   --ds-password=X           Directory Manager password
#   --admin-password=X        CA admin password
```

### 5. Ansible Playbook (Remote Hosts)

```bash
cp inventory.example inventory
# Edit with your target hostname

ansible-playbook -i inventory deploy-dogtag-acme.yml \
  -e pki_admin_password=YourPassword \
  -e ds_password=YourDSPassword

# pkispawn method:
ansible-playbook -i inventory deploy-dogtag-acme.yml -e acme_method=pkispawn

# Run individual phases:
ansible-playbook -i inventory deploy-dogtag-acme.yml --tags acme
```

### 6. Pre-built Image Import

No build required, no RHSM credentials needed.

```bash
# Export (from a machine that has built the image):
podman save -o dogtag-acme-stig-hardened.tar dogtag-acme:stig-hardened

# Import on any machine:
podman load -i dogtag-acme-stig-hardened.tar
podman run -d --name dogtag-acme --privileged --systemd=true \
  -p 8443:8443 -p 8080:8080 dogtag-acme:stig-hardened
```

## Method Comparison

| Method | Containers | Build Time | RHSM Needed | STIG | Portable to k8s |
|--------|-----------|------------|-------------|------|-----------------|
| **Pod (recommended)** | 2 | ~45 min | Build only | Yes | Yes |
| Single container | 1 | ~45 min | Build only | Yes | No |
| Multi-container | 3 | ~45 min | Build only | Yes | No |
| Shell script | N/A | ~10 min | On host | Manual | No |
| Ansible | N/A | ~10 min | On host | Manual | No |
| Pre-built image | 1 | None | No | Yes | No |

## Prerequisites

**Container deployments:**
- Podman with `podman machine` running (macOS) or native Podman (Linux)
- `podman login registry.redhat.io` (Red Hat container registry access)
- RHSM credentials for image builds (stored in `~/.claude/.env.age` as `RHSM_USERNAME`/`RHSM_PASSWORD`)
- RHCS is **x86_64 only** — Apple Silicon uses `--platform linux/amd64` (QEMU emulation)

**Bare-metal deployments:**
- RHEL 8.x with root access
- Red Hat Certificate System subscription (`certsys-10.8-for-rhel-8-x86_64-rpms`)
- System registered with `subscription-manager`

## Endpoints After Deployment

| Service | URL |
|---------|-----|
| CA Status | `https://localhost:8443/ca/admin/ca/getStatus` |
| ACME Directory | `https://localhost:8443/acme/directory` |
| OCSP Responder | `http://localhost:8080/ca/ocsp` |
| Admin Console | `https://localhost:8443/ca/services` |

## Testing

All test scripts are baked into container images at `/usr/local/bin/`.

```bash
# Basic issuance lifecycle (7 tests: issue → OCSP → revoke):
podman exec dogtag-pki-ca bash /usr/local/bin/test-acme-issue.sh

# Comprehensive suite (11 tests: RSA, ECC, SAN, FIPS, CRL, bulk, OCSP bug):
podman exec dogtag-pki-ca bash /usr/local/bin/test-comprehensive.sh

# STIG compliance scan (100% on 50 applicable rules):
podman exec dogtag-pki-ca bash /usr/local/bin/harden-stig.sh --scan-only

# Test with certbot:
certbot certonly --server https://localhost:8443/acme/directory \
  --standalone --no-verify-ssl -d test.example.com
```

## ACME Deployment Methods

The CA supports two methods for adding the ACME responder:

**pki-server CLI (default):** Five discrete commands — `acme-create`, `acme-database-mod --type ds`, `acme-issuer-mod --type pki`, `acme-realm-mod --type ds`, `acme-deploy`. Full control, step-by-step visibility.

**pkispawn:** Single `pkispawn -s ACME` command. Simpler but all-or-nothing.

## Ansible Tags

| Tag | Phase |
|-----|-------|
| `packages` | Enable RHCS repo, install packages |
| `ds` | Create 389 Directory Server instance |
| `ca` | Deploy CA subsystem via pkispawn |
| `acme` | Configure and deploy ACME responder |
| `verify` | Print status, certificates, and endpoints |

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `pki_instance_name` | `pki-tomcat` | PKI Tomcat instance name |
| `pki_https_port` | `8443` | HTTPS port |
| `pki_http_port` | `8080` | HTTP port |
| `pki_admin_password` | `Secret.123` | Admin and PKCS#12 password |
| `pki_admin_uid` | `caadmin` | Admin username |
| `ds_instance_name` | `pki-ds` | Directory Server instance name |
| `ds_port` | `3389` | DS LDAP port |
| `ds_password` | `Secret.123` | Directory Manager password |
| `acme_method` | `cli` | ACME method (`cli` or `pkispawn`) |
| `rhcs_repo` | `certsys-10.8-for-rhel-8-x86_64-rpms` | RHCS repo ID |

## Security

Container deployments are STIG-hardened with:

| Control | Detail |
|---------|--------|
| Crypto policy | `FIPS:STIG` — TLS 1.2 minimum, SHA-1 disabled for signatures |
| fapolicyd | Application whitelisting (enforcing mode) |
| gpgcheck | Enabled for all repos and local packages |
| STIG score | 100% (50/50 applicable rules) |

Run `harden-stig.sh` on bare-metal deployments to apply the same hardening.

## Architecture

### Pod (Recommended)

```
┌──────────── dogtag-pki pod ─────────────┐
│  Shared network namespace (localhost)   │
│                                         │
│  ┌──────────┐   ┌───────────────────┐   │
│  │    DS     │   │     CA + ACME     │   │
│  │  389 DS   │   │  pki-tomcat       │   │
│  │  :3389    │◄──│  :8443 /ca        │   │
│  │           │   │  :8443 /acme      │   │
│  │  dc=ca    │   │  :8080 /ca/ocsp   │   │
│  │  dc=acme  │   │                   │   │
│  └──────────┘   └───────────────────┘   │
└─────────────────────────────────────────┘
```

### Bare Metal

```
┌─────────────────────────────────────────┐
│              RHEL 8 Host                │
│                                         │
│  ┌─────────────────────────────────┐    │
│  │     PKI Tomcat (pki-tomcat)     │    │
│  │  ┌───────────┐  ┌───────────┐  │    │
│  │  │    CA      │  │   ACME    │  │    │
│  │  │ (signing,  │  │ (RFC 8555 │  │    │
│  │  │  OCSP,     │◄─┤  auto     │  │    │
│  │  │  CRL)      │  │  certs)   │  │    │
│  │  └─────┬──────┘  └─────┬─────┘  │    │
│  │        │               │        │    │
│  └────────┼───────────────┼────────┘    │
│           │               │             │
│  ┌────────▼───────────────▼────────┐    │
│  │    389 Directory Server (DS)    │    │
│  │  ┌──────────┐  ┌────────────┐  │    │
│  │  │ CA Data  │  │ ACME Data  │  │    │
│  │  │ (certs,  │  │ (accounts, │  │    │
│  │  │  CRLs)   │  │  orders)   │  │    │
│  │  └──────────┘  └────────────┘  │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| **Podman Desktop** | |
| `dogtag-pki-pod.yaml` | Kubernetes pod YAML (recommended) |
| `launch-podman-desktop.sh` | Build + launch + teardown helper |
| **Container** | |
| `Containerfile` | Single all-in-one container image |
| `compose.yaml` | Single-container compose |
| `compose-split.yaml` | Multi-container compose (DS + CA + ACME separate) |
| `containers/{ds,ca,acme}/` | Per-service Containerfiles and setup scripts |
| **Bare Metal** | |
| `deploy-dogtag-acme.sh` | Shell script (6 phases) |
| `deploy-dogtag-acme.yml` | Ansible playbook |
| `deploy-dogtag-est.sh` | EST responder deployment |
| `inventory.example` | Sample Ansible inventory |
| **Testing & Security** | |
| `test-acme-issue.sh` | Certificate lifecycle test (7 tests) |
| `test-comprehensive.sh` | Full test suite (11 tests) |
| `harden-stig.sh` | DISA STIG hardening + compliance scan |

## Known Issues

- [DOGTAG-4465](https://redhat.atlassian.net/browse/DOGTAG-4465): pki CLI reports cert as revoked while OCSP returns good — divergent NSS (AIA-based) vs LDAP validation paths

## License

GPL-2.0-only (matches Red Hat Certificate System licensing)
