# =============================================================================
# Dogtag PKI CA + ACME Responder — STIG-Hardened Container
#
# Build:
#   podman build --platform linux/amd64 \
#     --build-arg RHSM_USER=<user> --build-arg RHSM_PASS=<pass> \
#     -t dogtag-acme .
#
# Run:
#   podman run -d --name dogtag-acme --privileged --systemd=true \
#     -p 8443:8443 -p 8080:8080 -p 3389:3389 dogtag-acme
#
# First boot takes ~60s for DS + CA + ACME to start via systemd.
#
# Generated-by: Claude Code (claude.ai/code)
# =============================================================================
FROM registry.redhat.io/ubi8/ubi-init

LABEL name="dogtag-acme" \
      summary="Dogtag PKI CA + ACME Responder (RHCS 11.9, STIG-hardened)" \
      description="RHEL 8 container with Dogtag PKI CA, ACME responder, \
FIPS:STIG crypto policy, and fapolicyd. Deploys on first boot." \
      maintainer="czinda@redhat.com"

ARG RHSM_USER
ARG RHSM_PASS

# --- Phase 1: Register and install packages ---
RUN echo "nameserver 8.8.8.8" > /etc/resolv.conf && \
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf && \
    subscription-manager register \
      --username="${RHSM_USER}" --password="${RHSM_PASS}" \
      --auto-attach || true && \
    subscription-manager repos \
      --enable=certsys-10.8-for-rhel-8-x86_64-rpms || true && \
    dnf module enable -y pki-deps:10.6 pki-core:10.6 389-ds:1.4 && \
    dnf install -y \
      redhat-pki-server redhat-pki-ca redhat-pki-acme \
      389-ds-base openldap-clients hostname iproute \
      scap-security-guide openscap-scanner \
      crypto-policies-scripts fapolicyd rootfiles && \
    dnf clean all && \
    subscription-manager unregister || true

# --- Phase 2: FIPS:STIG crypto policy ---
COPY harden-stig.sh /usr/local/bin/harden-stig.sh
RUN chmod +x /usr/local/bin/harden-stig.sh && \
    if [ ! -f /usr/share/crypto-policies/policies/modules/STIG.pmod ]; then \
      printf '%s\n' \
        '# DISA STIG subpolicy for FIPS' \
        'min_tls_version = TLS1.2' \
        'min_dtls_version = DTLS1.2' \
        'hash = -SHA1' \
        'sign = -RSA-PSS-SHA1 -RSA-SHA1 -ECDSA-SHA1' \
        > /usr/share/crypto-policies/policies/modules/STIG.pmod; \
    fi && \
    update-crypto-policies --set FIPS:STIG

# --- Phase 3: STIG remediations (non-service items) ---
RUN sed -i 's/gpgcheck\s*=\s*0/gpgcheck=1/g' /etc/yum.repos.d/*.repo 2>/dev/null || true && \
    echo "localpkg_gpgcheck=1" >> /etc/dnf/dnf.conf && \
    chmod 0740 /root/.bashrc /root/.bash_profile /root/.cshrc /root/.tcshrc /root/.bash_logout 2>/dev/null || true && \
    printf '%s\n' \
      'C /root/.bash_logout 600 root root - /usr/share/rootfiles/.bash_logout' \
      'C /root/.bash_profile 600 root root - /usr/share/rootfiles/.bash_profile' \
      'C /root/.bashrc 600 root root - /usr/share/rootfiles/.bashrc' \
      'C /root/.cshrc 600 root root - /usr/share/rootfiles/.cshrc' \
      'C /root/.tcshrc 600 root root - /usr/share/rootfiles/.tcshrc' \
      > /etc/tmpfiles.d/rootfiles.conf

# --- Phase 4: Copy deploy and test scripts ---
COPY deploy-dogtag-acme.sh /usr/local/bin/deploy-dogtag-acme.sh
COPY test-acme-issue.sh /usr/local/bin/test-acme-issue.sh
COPY test-comprehensive.sh /usr/local/bin/test-comprehensive.sh
RUN chmod +x /usr/local/bin/*.sh

# --- Phase 5: First-boot deploy script ---
COPY first-boot.sh /usr/local/bin/first-boot.sh
RUN chmod +x /usr/local/bin/first-boot.sh

# --- Phase 6: Systemd service for first boot ---
RUN printf '%s\n' \
      '[Unit]' \
      'Description=Dogtag PKI First-Boot Deployment' \
      'After=network.target' \
      'ConditionPathExists=!/var/lib/pki/.deployed' \
      '' \
      '[Service]' \
      'Type=oneshot' \
      'ExecStart=/usr/local/bin/first-boot.sh' \
      'RemainAfterExit=yes' \
      'StandardOutput=journal+console' \
      'StandardError=journal+console' \
      'TimeoutStartSec=900' \
      '' \
      '[Install]' \
      'WantedBy=multi-user.target' \
      > /etc/systemd/system/dogtag-deploy.service && \
    systemctl enable dogtag-deploy.service

EXPOSE 8443 8080 3389

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
