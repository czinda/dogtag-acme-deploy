# Dogtag PKI CA + ACME Responder Deployment

Ansible playbook and shell script to deploy a standalone **Red Hat Certificate System (RHCS)** CA with an ACME responder on RHEL 8, using `redhat-pki` v11.9.

Supports two ACME deployment methods:
- **`cli`** (default) — Step-by-step using the `pki-server acme` CLI. Recommended for production.
- **`pkispawn`** — Single-command deployment. Best for automation and lab environments.

## What Gets Deployed

| Component | Package | Version |
|-----------|---------|---------|
| CA | `redhat-pki-ca` | 11.9.0 |
| ACME Responder | `redhat-pki-acme` | 11.9.0 |
| PKI Server | `redhat-pki-server` | 11.9.0 |
| Directory Server | `389-ds-base` | 1.4.x |

## Prerequisites

- RHEL 8.x target host with root SSH access
- **Red Hat Certificate System** subscription (provides the `certsys-10.8-for-rhel-8-x86_64-rpms` repo)
- System registered with `subscription-manager`

## Quick Start (Ansible)

```bash
# 1. Create your inventory
cp inventory.example inventory
# Edit inventory with your target hostname

# 2. Deploy with pki-server CLI method (default)
ansible-playbook -i inventory deploy-dogtag-acme.yml \
  -e pki_admin_password=YourSecurePassword \
  -e ds_password=YourDSPassword

# 3. Or deploy with pkispawn method
ansible-playbook -i inventory deploy-dogtag-acme.yml \
  -e acme_method=pkispawn \
  -e pki_admin_password=YourSecurePassword \
  -e ds_password=YourDSPassword
```

## Quick Start (Shell Script)

```bash
# pki-server CLI method (default)
scp deploy-dogtag-acme.sh root@pki.example.com:
ssh root@pki.example.com bash deploy-dogtag-acme.sh

# pkispawn method
ssh root@pki.example.com bash deploy-dogtag-acme.sh --acme-method=pkispawn

# With custom passwords
ssh root@pki.example.com bash deploy-dogtag-acme.sh \
  --ds-password=MyDSPass --admin-password=MyAdminPass
```

## ACME Deployment Methods

### pki-server CLI (default)

Uses `pki-server acme-create`, `acme-database-mod`, `acme-issuer-mod`, `acme-realm-mod`, and `acme-deploy` — five discrete commands that configure each component individually.

**Advantages:** Full control, step-by-step visibility, supports shared CA/ACME configuration, easier to troubleshoot.

### pkispawn

Uses `pkispawn -s ACME` with a configuration file — deploys everything in one command.

**Advantages:** Simpler, fewer commands, good for automation and CI/CD.

**Trade-off:** All-or-nothing — if it fails, you remove and start over.

## Ansible Tags

Run individual phases with `--tags`:

| Tag | Phase |
|-----|-------|
| `packages` | Enable RHCS repo, install packages |
| `ds` | Create 389 Directory Server instance |
| `ca` | Deploy CA subsystem via pkispawn |
| `acme` | Configure and deploy ACME responder |
| `verify` | Print status, certificates, and endpoints |

```bash
# Just add ACME to an existing CA
ansible-playbook -i inventory deploy-dogtag-acme.yml --tags acme
```

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
| `acme_method` | `cli` | ACME deployment method (`cli` or `pkispawn`) |
| `rhcs_repo` | `certsys-10.8-for-rhel-8-x86_64-rpms` | RHCS repo ID |

## Endpoints After Deployment

| Service | URL |
|---------|-----|
| CA | `https://<hostname>:8443/ca` |
| ACME Directory | `https://<hostname>:8443/acme/directory` |
| Admin Console | `https://<hostname>:8443/ca/services` |

## Architecture

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
│  │  │  CRLs,   │  │  orders,   │  │    │
│  │  │  reqs)   │  │  authz)    │  │    │
│  │  └──────────┘  └────────────┘  │    │
│  └─────────────────────────────────┘    │
└─────────────────────────────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `deploy-dogtag-acme.yml` | Ansible playbook (supports `acme_method` variable) |
| `deploy-dogtag-acme.sh` | Shell script (supports `--acme-method` flag) |
| `inventory.example` | Sample Ansible inventory |

## License

GPL-2.0-only (matches Red Hat Certificate System licensing)
