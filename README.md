# Dogtag PKI CA + ACME Responder Deployment

Ansible playbook and shell script to deploy a standalone **Red Hat Certificate System (RHCS)** CA with an ACME responder on RHEL 8, using `redhat-pki` v11.9.

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

# 2. Deploy
ansible-playbook -i inventory deploy-dogtag-acme.yml \
  -e pki_admin_password=YourSecurePassword \
  -e ds_password=YourDSPassword
```

## Quick Start (Shell Script)

```bash
scp deploy-dogtag-acme.sh root@pki.example.com:
ssh root@pki.example.com bash deploy-dogtag-acme.sh
```

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
| `rhcs_repo` | `certsys-10.8-for-rhel-8-x86_64-rpms` | RHCS repo ID |

## Endpoints After Deployment

| Service | URL |
|---------|-----|
| CA | `https://<hostname>:8443/ca` |
| ACME Directory | `https://<hostname>:8443/acme/directory` |
| Admin Console | `https://<hostname>:8443/ca/services` |

## Testing ACME

```bash
certbot certonly \
  --server https://pki.example.com:8443/acme/directory \
  --standalone --no-verify-ssl \
  -d test.example.com
```

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
| `deploy-dogtag-acme.yml` | Ansible playbook (recommended) |
| `deploy-dogtag-acme.sh` | Standalone shell script (alternative) |
| `inventory.example` | Sample Ansible inventory |

## License

GPL-2.0-only (matches Red Hat Certificate System licensing)
