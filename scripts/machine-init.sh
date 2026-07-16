#!/usr/bin/env bash
# machine-init.sh -- Initialize a bare-metal machine for OSAC e2e CI.
#
# This script prepares the machine to serve as a self-hosted GitHub Actions
# runner that runs OSAC e2e tests using cluster-tool for on-demand OpenShift
# cluster provisioning and HashiCorp Vault for secret management.
#
# Usage:
#   sudo ./machine-init.sh [OPTIONS] [STEP ...]
#
# Steps (run all if none specified):
#   packages       Install system packages (libvirt, qemu-kvm, podman, etc.)
#   runner-user    Create github-runner user with libvirt group and sudo
#   services       Enable system services (libvirtd, haproxy, podman.socket)
#   oc             Install OpenShift CLI
#   osac           Install osac CLI (fulfillment-service)
#   cluster-tool   Install and configure cluster-tool for local CI mode
#   vault          Install Vault CLI
#   grpcurl        Install grpcurl
#   verify         Show installed versions and storage info
#
# Options:
#   --data-path PATH   Where cluster-tool stores disk images and overlays
#                      (auto-detects largest partition if omitted)
#   -h, --help         Show this help
#
# Examples:
#   sudo ./machine-init.sh                          # Run all steps
#   sudo ./machine-init.sh cluster-tool             # Only install/configure cluster-tool
#   sudo ./machine-init.sh packages services        # Only packages + services
#   sudo ./machine-init.sh --data-path /data/ct     # All steps, explicit storage path
set -euo pipefail

###############################################################################
# Constants
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_TOOL_DIR="/opt/cluster-tool"
CLUSTER_TOOL_BIN="/usr/local/bin/cluster-tool"
RUNNER_USER="github-runner"

###############################################################################
# Parse arguments
###############################################################################
DATA_PATH=""
STEPS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-path)
            DATA_PATH="$2"
            shift 2
            ;;
        --data-path=*)
            DATA_PATH="${1#*=}"
            shift
            ;;
        -h|--help)
            sed -n '2,/^[^#]/{ /^#/s/^# \?//p }' "$0"
            exit 0
            ;;
        packages|runner-user|services|oc|osac|cluster-tool|vault|grpcurl|verify)
            STEPS+=("$1")
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# Default: run all steps
if [[ ${#STEPS[@]} -eq 0 ]]; then
    STEPS=(packages runner-user services oc osac cluster-tool vault grpcurl verify)
fi

###############################################################################
# Preflight checks
###############################################################################
if (( EUID != 0 )); then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

should_run() {
    local step="$1"
    for s in "${STEPS[@]}"; do
        [[ "$s" == "$step" ]] && return 0
    done
    return 1
}

echo "=========================================="
echo " OSAC CI Machine Initialization"
echo " Steps: ${STEPS[*]}"
echo "=========================================="
echo ""

###############################################################################
# Step: packages
###############################################################################
install_packages() {
    echo "==> Installing system packages..."

    if ! command -v dnf &>/dev/null; then
        echo "ERROR: dnf not found. This script requires RHEL/CentOS/Fedora." >&2
        exit 1
    fi

    dnf install -y \
        libvirt \
        qemu-kvm \
        podman \
        podman-docker \
        pigz \
        haproxy \
        skopeo \
        zstd \
        jq \
        git \
        dnf-plugins-core \
        dnsmasq \
        python3 \
        python3-pip \
        virt-install

    # ansible-builder is needed for building AAP execution-environment images
    python3 -m pip install --quiet ansible-builder

    # Agent VM storage directory for CaaS E2E
    AGENT_STORAGE="/data/osac-storage"
    if [[ ! -d "${AGENT_STORAGE}" ]]; then
        mkdir -p "${AGENT_STORAGE}"
        echo "    Created ${AGENT_STORAGE}"
    fi
    chown "${RUNNER_USER}:${RUNNER_USER}" "${AGENT_STORAGE}"

    # Install osac-hosts-entry helper for /etc/hosts management
    install -m 0755 "${SCRIPT_DIR}/osac-hosts-entry" /usr/local/sbin/osac-hosts-entry
    echo "    Installed /usr/local/sbin/osac-hosts-entry"

    echo "    Done."
}

###############################################################################
# Step: runner-user
###############################################################################
create_runner_user() {
    echo "==> Creating ${RUNNER_USER} user..."

    if id "${RUNNER_USER}" &>/dev/null; then
        echo "    User ${RUNNER_USER} already exists."
    else
        useradd -m -s /bin/bash "${RUNNER_USER}"
        echo "    User ${RUNNER_USER} created."
    fi

    # Add to libvirt group for VM management (group is created by libvirt package)
    if ! getent group libvirt &>/dev/null; then
        groupadd libvirt
        echo "    Created libvirt group."
    fi
    if ! id -nG "${RUNNER_USER}" | grep -qw libvirt; then
        usermod -aG libvirt "${RUNNER_USER}"
        echo "    Added to libvirt group."
    fi

    RUNNER_HOME=$(eval echo "~${RUNNER_USER}")

    # Scoped, declarative sudo policy -- covers exactly what e2e CI invokes
    # (cluster-tool, ip link on stale bridges, the auth.json/kubeconfig
    # plumbing), nothing more. Always regenerated (no "if not exists" guard)
    # so re-running this script on an already-provisioned host heals a
    # stale policy, consistent with how monitoring-setup.sh --update-central
    # treats config as declarative (vs. secrets, which are preserved).
    # Manual/admin operations (systemctl, journalctl, virsh, editing
    # /opt/cluster-tool, setup-runner-podman.sh) are intentionally NOT
    # covered -- see docs/new-ci-machine-setup.md, use root SSH for those.
    SUDOERS_FILE="/etc/sudoers.d/${RUNNER_USER}"
    SUDOERS_STAGING=$(mktemp /etc/sudoers.d/.github-runner.XXXXXX)
    RUNNER_UID=$(id -u "${RUNNER_USER}")
    RUNNER_GID=$(id -g "${RUNNER_USER}")
    # Number of registered runner instances on this host (each has its own
    # $RUNNER_TEMP, which the kubeconfig-copy/chown grants must enumerate
    # explicitly rather than wildcard). Matches osac-ci-1's topology today;
    # override via RUNNER_COUNT= if a future host differs.
    RUNNER_COUNT="${RUNNER_COUNT:-5}"

    KUBECONFIG_COPY_ALIAS="Cmnd_Alias KUBECONFIG_COPY ="
    KUBECONFIG_CHOWN_ALIAS="Cmnd_Alias KUBECONFIG_CHOWN ="
    for i in $(seq 1 "${RUNNER_COUNT}"); do
        RUNNER_TEMP_DIR="${RUNNER_HOME}/action-runners/runner-${i}/_work/_temp"
        if [[ "${i}" -eq 1 ]]; then
            KUBECONFIG_COPY_ALIAS+=" /usr/bin/cp ${RUNNER_HOME}/.kube/*.kubeconfig ${RUNNER_TEMP_DIR}/kubeconfig"
            KUBECONFIG_CHOWN_ALIAS+=" /usr/bin/chown ${RUNNER_UID}\:${RUNNER_GID} ${RUNNER_TEMP_DIR}/kubeconfig"
        else
            KUBECONFIG_COPY_ALIAS+=", \\"$'\n'"    /usr/bin/cp ${RUNNER_HOME}/.kube/*.kubeconfig ${RUNNER_TEMP_DIR}/kubeconfig"
            KUBECONFIG_CHOWN_ALIAS+=", \\"$'\n'"    /usr/bin/chown ${RUNNER_UID}\:${RUNNER_GID} ${RUNNER_TEMP_DIR}/kubeconfig"
        fi
    done

    cat > "${SUDOERS_STAGING}" <<EOF
# /etc/sudoers.d/${RUNNER_USER} -- generated by scripts/machine-init.sh
# (create_runner_user). Do not hand-edit; re-running machine-init.sh
# overwrites this file. See docs/new-ci-machine-setup.md.

Cmnd_Alias CLUSTER_TOOL_FLAVORS         = /usr/bin/python3 ${CLUSTER_TOOL_BIN} flavors
Cmnd_Alias CLUSTER_TOOL_FLAVORS_DELETE  = /usr/bin/python3 ${CLUSTER_TOOL_BIN} flavors --delete *
Cmnd_Alias CLUSTER_TOOL_PULL            = /usr/bin/python3 ${CLUSTER_TOOL_BIN} pull *
Cmnd_Alias CLUSTER_TOOL_DESTROY         = /usr/bin/python3 ${CLUSTER_TOOL_BIN} destroy *
Cmnd_Alias CLUSTER_TOOL_BOOT            = /usr/bin/python3 ${CLUSTER_TOOL_BIN} boot --flavor * --name *
Cmnd_Alias CLUSTER_TOOL_CLEANUP_HAPROXY = /usr/bin/python3 ${CLUSTER_TOOL_BIN} cleanup-haproxy

Cmnd_Alias BRIDGE_DOWN   = /usr/sbin/ip link set br-* down
Cmnd_Alias BRIDGE_DELETE = /usr/sbin/ip link delete br-*

Cmnd_Alias AUTH_JSON_MKDIR = /usr/bin/mkdir -p /root/.config/containers
Cmnd_Alias AUTH_JSON_COPY  = /usr/bin/cp ${RUNNER_HOME}/.config/containers/auth.json /root/.config/containers/auth.json
Cmnd_Alias AUTH_JSON_CHMOD = /usr/bin/chmod 600 /root/.config/containers/auth.json
Cmnd_Alias AUTH_JSON_RM    = /usr/bin/rm -f /root/.config/containers/auth.json

Cmnd_Alias HOSTS_ENTRY_ADD    = /usr/local/sbin/osac-hosts-entry add * *
Cmnd_Alias HOSTS_ENTRY_REMOVE = /usr/local/sbin/osac-hosts-entry remove *

${KUBECONFIG_COPY_ALIAS}

${KUBECONFIG_CHOWN_ALIAS}

${RUNNER_USER} ALL=(root) NOPASSWD: CLUSTER_TOOL_FLAVORS, CLUSTER_TOOL_FLAVORS_DELETE, \\
    CLUSTER_TOOL_PULL, CLUSTER_TOOL_DESTROY, CLUSTER_TOOL_BOOT, CLUSTER_TOOL_CLEANUP_HAPROXY, \\
    BRIDGE_DOWN, BRIDGE_DELETE, \\
    AUTH_JSON_MKDIR, AUTH_JSON_COPY, AUTH_JSON_CHMOD, AUTH_JSON_RM, \\
    HOSTS_ENTRY_ADD, HOSTS_ENTRY_REMOVE, \\
    KUBECONFIG_COPY, KUBECONFIG_CHOWN
EOF

    if ! visudo -c -f "${SUDOERS_STAGING}" >/dev/null; then
        echo "ERROR: generated sudoers policy failed visudo -c; leaving existing ${SUDOERS_FILE} untouched." >&2
        rm -f "${SUDOERS_STAGING}"
        exit 1
    fi
    chmod 0440 "${SUDOERS_STAGING}"
    chown root:root "${SUDOERS_STAGING}"
    mv -f "${SUDOERS_STAGING}" "${SUDOERS_FILE}"
    echo "    Scoped passwordless sudo policy installed/refreshed."

    # Copy SSH authorized_keys from the current user (if available)
    RUNNER_SSH_DIR="${RUNNER_HOME}/.ssh"
    mkdir -p "${RUNNER_SSH_DIR}"

    if [[ -f "${HOME}/.ssh/authorized_keys" ]]; then
        # Append keys, avoiding duplicates
        if [[ -f "${RUNNER_SSH_DIR}/authorized_keys" ]]; then
            # Only add keys not already present
            while IFS= read -r key; do
                grep -qxF "$key" "${RUNNER_SSH_DIR}/authorized_keys" 2>/dev/null \
                    || echo "$key" >> "${RUNNER_SSH_DIR}/authorized_keys"
            done < "${HOME}/.ssh/authorized_keys"
        else
            cp "${HOME}/.ssh/authorized_keys" "${RUNNER_SSH_DIR}/authorized_keys"
        fi
        echo "    SSH authorized_keys copied."
    fi

    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_SSH_DIR}"
    chmod 700 "${RUNNER_SSH_DIR}"
    chmod 600 "${RUNNER_SSH_DIR}/authorized_keys" 2>/dev/null || true

    echo "    Done."
}

###############################################################################
# Step: services
###############################################################################
enable_services() {
    echo "==> Enabling system services..."

    # libvirtd
    systemctl enable --now libvirtd

    # HAProxy -- only write base config if not already configured by cluster-tool
    if ! grep -q 'default_backend api-' /etc/haproxy/haproxy.cfg 2>/dev/null; then
        echo "    Writing HAProxy base config..."
        cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak 2>/dev/null || true
        cat > /etc/haproxy/haproxy.cfg <<'HAPROXY_EOF'
global
    log stdout local0
    maxconn 4096

defaults
    mode tcp
    log global
    timeout connect 10s
    timeout client 300s
    timeout server 300s

frontend api-frontend
    bind *:6443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    default_backend api-default

frontend ingress-https-frontend
    bind *:443
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
    default_backend ingress-https-default

frontend ingress-http-frontend
    bind *:80
    default_backend ingress-http-default

backend api-default
    server placeholder 127.0.0.1:16443 check

backend ingress-https-default
    server placeholder 127.0.0.1:1443 check

backend ingress-http-default
    server placeholder 127.0.0.1:1080 check
HAPROXY_EOF
    fi

    setsebool -P haproxy_connect_any 1 2>/dev/null || true

    # Open firewall ports if firewalld is active
    if systemctl is-active firewalld &>/dev/null; then
        echo "    Opening firewall ports (6443, 443, 80)..."
        firewall-cmd --permanent --add-port=6443/tcp --add-port=443/tcp --add-port=80/tcp
        firewall-cmd --reload
    fi

    systemctl enable --now haproxy
    systemctl restart haproxy

    # Protect sshd from OOM killer so the machine stays reachable
    # even when VMs or runners exhaust memory.
    mkdir -p /etc/systemd/system/sshd.service.d
    cat > /etc/systemd/system/sshd.service.d/oom-protect.conf <<'SSHD_OOM_EOF'
[Service]
OOMScoreAdjust=-1000
SSHD_OOM_EOF
    systemctl daemon-reload
    systemctl restart sshd
    echo "    sshd OOM protection enabled (OOMScoreAdjust=-1000)."

    # Podman socket for GitHub Actions (docker compatibility)
    systemctl enable --now podman.socket

    # Persistent journal (survives reboots for post-mortem debugging)
    mkdir -p /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    sed -i 's/^#\?Storage=.*/Storage=persistent/' /etc/systemd/journald.conf
    systemctl restart systemd-journald
    echo "    Persistent journal enabled."

    echo "    Done."
}

###############################################################################
# Step: oc
###############################################################################
install_oc() {
    echo "==> Installing OpenShift CLI..."

    if command -v oc &>/dev/null; then
        echo "    oc already installed: $(oc version --client 2>/dev/null | head -1)"
    else
        OC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz"
        echo "    Downloading from ${OC_URL}..."
        TMP_OC=$(mktemp -d)
        curl -sL "${OC_URL}" | tar xz -C "${TMP_OC}"
        install -m 0755 "${TMP_OC}/oc" /usr/local/bin/oc
        install -m 0755 "${TMP_OC}/kubectl" /usr/local/bin/kubectl 2>/dev/null || true
        rm -rf "${TMP_OC}"
        echo "    oc installed: $(oc version --client 2>/dev/null | head -1)"
    fi
}

###############################################################################
# Step: osac
###############################################################################
install_osac() {
    echo "==> Installing osac CLI..."

    local version="${OSAC_VERSION:-}"

    if command -v osac &>/dev/null && [[ -z "${version}" ]]; then
        echo "    osac already installed: $(osac version 2>/dev/null || echo 'unknown version')"
        return 0
    fi

    # Use env var if set, otherwise fetch latest release tag from GitHub
    if [[ -z "${version}" ]]; then
        echo "    Detecting latest release..."
        version=$(curl -sfL -o /dev/null -w '%{url_effective}' \
            "https://github.com/osac-project/fulfillment-service/releases/latest" \
            | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+$') \
            || { echo "ERROR: failed to detect latest osac version" >&2; exit 1; }
    fi

    local url="https://github.com/osac-project/fulfillment-service/releases/download/v${version}/osac_Linux_x86_64"
    echo "    Downloading osac v${version} from ${url}..."
    curl -fL -o /usr/local/bin/osac "${url}" \
        || { echo "ERROR: failed to download osac v${version}" >&2; exit 1; }
    chmod +x /usr/local/bin/osac
    echo "    osac v${version} installed at /usr/local/bin/osac"
}

###############################################################################
# Step: cluster-tool
###############################################################################
setup_cluster_tool() {
    echo "==> Installing cluster-tool..."

    # Ensure git is available (needed for clone)
    if ! command -v git &>/dev/null; then
        dnf install -y git
    fi

    # Install the binary
    if [[ -f "${CLUSTER_TOOL_BIN}" ]]; then
        echo "    cluster-tool already installed at ${CLUSTER_TOOL_BIN}"
        echo "    To update: git -C ${CLUSTER_TOOL_DIR} pull && cp ${CLUSTER_TOOL_DIR}/cluster-tool ${CLUSTER_TOOL_BIN}"
    else
        if [[ -d "${CLUSTER_TOOL_DIR}" ]]; then
            git -C "${CLUSTER_TOOL_DIR}" pull --ff-only
        else
            git clone https://github.com/osac-project/cluster-tool.git "${CLUSTER_TOOL_DIR}"
        fi
        install -m 0755 "${CLUSTER_TOOL_DIR}/cluster-tool" "${CLUSTER_TOOL_BIN}"
        echo "    cluster-tool installed at ${CLUSTER_TOOL_BIN}"
    fi

    echo "==> Configuring cluster-tool for local CI mode..."

    # Configure under the runner user's home, not root's.
    if ! id "${RUNNER_USER}" &>/dev/null; then
        echo "ERROR: User '${RUNNER_USER}' does not exist. Run the runner-user step first." >&2
        exit 1
    fi
    RUNNER_HOME=$(eval echo "~${RUNNER_USER}")
    CT_CONFIG_DIR="${RUNNER_HOME}/.config/cluster-tool"
    mkdir -p "${CT_CONFIG_DIR}"

    # Determine data path
    if [[ -z "${DATA_PATH}" ]] && [[ -f "${CT_CONFIG_DIR}/config" ]]; then
        EXISTING_DATA=$(grep '^CLUSTER_TOOL_DATA=' "${CT_CONFIG_DIR}/config" | cut -d= -f2)
        if [[ -n "${EXISTING_DATA}" ]]; then
            DATA_PATH="${EXISTING_DATA}"
            echo "    Using existing data path: ${DATA_PATH}"
        fi
    fi

    if [[ -z "${DATA_PATH}" ]]; then
        # Auto-detect: largest partition
        LARGEST=$(df --output=avail,target -x tmpfs -x devtmpfs | tail -n +2 | sort -rn | head -1 | awk '{print $2}')
        DATA_PATH="${LARGEST}/cluster-tool"
        echo "    Auto-detected data path: ${DATA_PATH}"
    fi

    # Write config (only if not already present)
    if [[ ! -f "${CT_CONFIG_DIR}/config" ]]; then
        echo "CLUSTER_TOOL_DATA=${DATA_PATH}" > "${CT_CONFIG_DIR}/config"
    fi

    # Create data directories and ensure runner user owns them
    mkdir -p "${DATA_PATH}/flavors" "${DATA_PATH}/overlays" "${DATA_PATH}/tmp" "${DATA_PATH}/containers/storage"
    chown "${RUNNER_USER}:${RUNNER_USER}" "${DATA_PATH}"
    chown "${RUNNER_USER}:${RUNNER_USER}" "${DATA_PATH}/flavors" "${DATA_PATH}/overlays" "${DATA_PATH}/tmp" "${DATA_PATH}/containers" "${DATA_PATH}/containers/storage"

    # Generate SSH keypair for cluster-tool (used for VM access)
    if [[ ! -f "${CT_CONFIG_DIR}/cluster-tool.key" ]]; then
        ssh-keygen -t ed25519 -f "${CT_CONFIG_DIR}/cluster-tool.key" -N '' -q
        echo "    SSH keypair generated."
    else
        echo "    SSH keypair already exists."
    fi

    # Configure podman parallel downloads (faster OCI image pulls)
    CONTAINERS_CONF="${RUNNER_HOME}/.config/containers/containers.conf"
    mkdir -p "$(dirname "${CONTAINERS_CONF}")"
    if [[ ! -f "${CONTAINERS_CONF}" ]]; then
        cat > "${CONTAINERS_CONF}" <<'EOF'
[engine]
image_parallel_copies = 20
EOF
        echo "    Podman parallel downloads configured."
    fi

    # Register as local server
    SERVERS_FILE="${CT_CONFIG_DIR}/servers.json"
    if [[ ! -f "${SERVERS_FILE}" ]]; then
        cat > "${SERVERS_FILE}" <<'EOF'
{"servers": {"local": {"host": "local"}}, "default": "local"}
EOF
        echo "    Registered as local server."
    else
        echo "    Server registry already exists."
    fi

    # Fix ownership of all config created under the runner user's home.
    # Chown ~/.config itself (not just subdirs) so rootless podman doesn't
    # complain about parent directory ownership.
    chown "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_HOME}/.config"
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${CT_CONFIG_DIR}"
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "$(dirname "${CONTAINERS_CONF}")"

    # Symlink root's cluster-tool config to the runner user's config.
    # The e2e workflow runs cluster-tool via sudo, which looks under /root/.
    ROOT_CT_DIR="/root/.config/cluster-tool"
    if [[ -L "${ROOT_CT_DIR}" ]]; then
        echo "    Symlink ${ROOT_CT_DIR} already exists."
    else
        # Remove any pre-existing directory so the symlink can be created
        rm -rf "${ROOT_CT_DIR}"
        mkdir -p /root/.config
        ln -sfn "${CT_CONFIG_DIR}" "${ROOT_CT_DIR}"
        echo "    Symlinked ${ROOT_CT_DIR} -> ${CT_CONFIG_DIR}"
    fi

    # DNS setup for local mode: cluster-tool creates dnsmasq entries
    # in /etc/NetworkManager/dnsmasq.d/ for cluster DNS resolution
    mkdir -p /etc/NetworkManager/dnsmasq.d
    if [[ ! -f /etc/NetworkManager/conf.d/cluster-tool-dns.conf ]]; then
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/cluster-tool-dns.conf <<'EOF'
[main]
dns=dnsmasq
EOF
        # Kill stale dnsmasq processes before restart
        pkill -x dnsmasq 2>/dev/null || true
        sleep 1
        systemctl restart NetworkManager

        # Verify resolv.conf points to localhost
        for _ in $(seq 1 30); do
            if grep -q '127.0.0.1' /etc/resolv.conf 2>/dev/null; then
                echo "    DNS configured (resolv.conf -> 127.0.0.1)"
                break
            fi
            sleep 0.5
        done
    fi

    echo "    Done."
}

###############################################################################
# Step: vault
###############################################################################
install_vault() {
    echo "==> Installing Vault CLI..."

    if command -v vault &>/dev/null; then
        echo "    vault already installed: $(vault --version)"
    else
        HASHICORP_REPO="/etc/yum.repos.d/hashicorp.repo"
        if [[ ! -f "${HASHICORP_REPO}" ]]; then
            dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
        fi
        dnf install -y vault
        echo "    vault installed: $(vault --version)"
    fi
}

###############################################################################
# Step: grpcurl
###############################################################################
install_grpcurl() {
    echo "==> Installing grpcurl..."

    local version="1.9.3"

    if command -v grpcurl &>/dev/null && [[ "$(grpcurl --version 2>&1)" == *"${version}"* ]]; then
        echo "    grpcurl already installed: $(grpcurl --version)"
        return 0
    fi

    local rpm="grpcurl_${version}_linux_amd64.rpm"
    local url="https://github.com/fullstorydev/grpcurl/releases/download/v${version}/${rpm}"
    local sha256="6315dff469ce9ba4aedb39f1b830bfdd276a155095d51129393579a62c8190ab"
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp}"' RETURN

    echo "    Downloading grpcurl v${version}..."
    curl -sL -o "${tmp}/${rpm}" "${url}"
    echo "${sha256}  ${tmp}/${rpm}" | sha256sum -c -
    dnf install -y "${tmp}/${rpm}"
    echo "    grpcurl installed: $(grpcurl --version)"
}

###############################################################################
# Step: verify
###############################################################################
run_verify() {
    local failures=0

    echo ""
    echo "=========================================="
    echo " Verification"
    echo "=========================================="

    _check() {
        local name="$1"
        local cmd="$2"
        local result
        if result=$(eval "$cmd" 2>&1); then
            result="${result%%$'\n'*}"
            printf "  %-20s %s\n" "${name}:" "${result}"
        else
            result="${result%%$'\n'*}"
            result="${result:-NOT FOUND}"
            printf "  %-20s FAILED — %s\n" "${name}:" "${result}"
            (( failures++ )) || true
        fi
    }

    _check "virsh"          "virsh version"
    _check "podman"         "podman --version"
    _check "oc"             "/usr/local/bin/oc version --client"
    _check "haproxy"        "haproxy -v"
    _check "pigz"           "pigz --version"
    _check "skopeo"         "skopeo --version"
    _check "vault"          "vault --version"
    _check "grpcurl"        "grpcurl --version"
    _check "jq"             "jq --version"
    _check "ansible-builder" "ansible-builder --version"

    if [[ -f "${CLUSTER_TOOL_BIN}" ]]; then
        printf "  %-20s %s\n" "cluster-tool:" "installed at ${CLUSTER_TOOL_BIN}"
    else
        printf "  %-20s FAILED — NOT FOUND\n" "cluster-tool:"
        (( failures++ )) || true
    fi

    if id "${RUNNER_USER}" &>/dev/null; then
        printf "  %-20s %s\n" "${RUNNER_USER}:" "exists (groups: $(id -nG "${RUNNER_USER}"))"
        if ! id -nG "${RUNNER_USER}" | grep -qw libvirt; then
            printf "  %-20s FAILED — not in libvirt group\n" "${RUNNER_USER}:"
            (( failures++ )) || true
        fi
        if [[ ! -f "/etc/sudoers.d/${RUNNER_USER}" ]]; then
            printf "  %-20s FAILED — sudoers file missing\n" "${RUNNER_USER}:"
            (( failures++ )) || true
        fi
    else
        printf "  %-20s FAILED — user not found\n" "${RUNNER_USER}:"
        (( failures++ )) || true
    fi

    if [[ -n "${DATA_PATH}" ]]; then
        echo ""
        AVAIL=$(df -h "${DATA_PATH}" 2>/dev/null | tail -1 | awk '{print $4}')
        echo "  Storage available:  ${AVAIL} at ${DATA_PATH}"
    fi

    if (( failures > 0 )); then
        echo ""
        echo "  ${failures} check(s) failed."
        return 1
    fi
}

###############################################################################
# Run selected steps
###############################################################################
should_run packages      && install_packages
should_run runner-user   && create_runner_user
should_run services      && enable_services
should_run oc            && install_oc
should_run osac          && install_osac
should_run cluster-tool  && setup_cluster_tool
should_run vault         && install_vault
should_run grpcurl       && install_grpcurl
should_run verify        && run_verify

echo ""
echo "=========================================="
echo " Done!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Set up Vault:     vault/scripts/vault-setup.sh"
echo "  2. Install runners:  scripts/runners/action-runners-setup.sh <TOKEN> [NUM_RUNNERS]"
echo "  3. Pull a flavor:    cluster-tool pull quay.io/osac-project/cluster-flavors:vmaas"
echo "  4. Test a boot:      cluster-tool boot --flavor vmaas-kustomize --name test-1"
echo "  5. Verify cluster:   KUBECONFIG=~/.kube/test-1.kubeconfig oc get nodes"
echo "  6. Clean up test:    cluster-tool destroy test-1"
