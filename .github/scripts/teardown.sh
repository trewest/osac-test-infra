#!/usr/bin/env bash
# Destroy the cluster clone, remove orphaned bridges, clean up temporary
# files, and remove the test container image.
#
# Required env: CLONE_NAME, E2E_IMAGE
set -euo pipefail

: "${CLONE_NAME:?CLONE_NAME is required}"
: "${E2E_IMAGE:?E2E_IMAGE is required}"

# --- Destroy agent VM (created by setup-caas-agents.sh) ---
AGENT_VM_NAME="agent-${CLONE_NAME}"
AGENT_VM_STORAGE_DIR="${AGENT_VM_STORAGE_DIR:-/data/osac-storage}"
echo "Destroying agent VM '${AGENT_VM_NAME}'..."
virsh destroy "${AGENT_VM_NAME}" 2>/dev/null || true
virsh undefine "${AGENT_VM_NAME}" 2>/dev/null || true
rm -f "${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}.qcow2" "${AGENT_VM_STORAGE_DIR}/${AGENT_VM_NAME}-discovery.iso"

# --- Destroy cluster clone ---
echo "Destroying clone '${CLONE_NAME}'..."
sudo python3 /usr/local/bin/cluster-tool destroy "${CLONE_NAME}" 2>&1 || true

# Remove orphaned bridges that survive virsh net-destroy
BRIDGE_PREFIX="br-${CLONE_NAME:0:8}"
for br in $(ip -o link show | grep -oP "${BRIDGE_PREFIX}[^ @]*"); do
  echo "Removing orphaned bridge ${br}..."
  sudo ip link set "${br}" down 2>/dev/null || true
  sudo ip link delete "${br}" 2>/dev/null || true
done

# --- Clean up temporary files ---
rm -f "$RUNNER_TEMP/pull-secret.json" "$RUNNER_TEMP/aap-license.zip" "$RUNNER_TEMP/kubeconfig"
rm -f "${REGISTRY_AUTH_FILE:-}" "$RUNNER_TEMP/auth.json"
rm -f "${HOME}/.config/containers/auth.json"
sudo rm -f /root/.config/containers/auth.json
rm -rf "$RUNNER_TEMP/osac-installer"

# Force-remove any container still referencing this run's test image before
# trying to remove the image itself. `podman run --rm` normally handles
# this, but if the container's process was killed abnormally (OOM, host
# reboot, a cancelled job) before --rm's own cleanup could run, podman's
# state store is left believing a now-dead container is still "running" --
# crun confirms there's no real process behind it, but podman never learns
# that. That permanently blocks `podman rmi` (which silently no-ops via
# `2>/dev/null || true` below, so this was invisible), leaking the image
# and its writable layer forever. Seen in production: 60+ such containers
# had accumulated undetected across the CI fleet, some for 3+ weeks,
# consuming the majority of disk on every affected host.
for c in $(podman ps -a --filter ancestor="${E2E_IMAGE}" --format "{{.ID}}" 2>/dev/null); do
  echo "Force-removing leftover container ${c} still referencing ${E2E_IMAGE}..."
  podman rm -f "${c}" 2>/dev/null || true
done
podman rmi "${E2E_IMAGE}" 2>/dev/null || true

# --- Clean up component image on runner ---
# Node-side cleanup is unnecessary: the clone is destroyed above.
if [[ -n "${COMPONENT_IMAGE:-}" ]]; then
  podman rmi "${COMPONENT_IMAGE}" 2>/dev/null || true
fi

# --- Clean up BMaaS virtual BMH resources ---
# All paths are derived from CLONE_NAME so teardown works even if setup
# failed before exporting state. When no matching resources exist, cleanup
# is a no-op (VMaaS teardown unaffected).
# NOTE: naming conventions here must match setup-virtual-bmh.sh.
VIRSH="virsh -c qemu:///system"
BMH_VM_PREFIX="virtual-bmh-${CLONE_NAME}-"
BMH_VM_NAMES=$(${VIRSH} list --all --name 2>/dev/null | grep "^${BMH_VM_PREFIX}" || true)
if [[ -n "${BMH_VM_NAMES}" ]]; then
  echo "Cleaning up virtual BMH VMs..."
  for VM_NAME in ${BMH_VM_NAMES}; do
    ${VIRSH} destroy "${VM_NAME}" 2>/dev/null || true
    ${VIRSH} undefine "${VM_NAME}" --nvram 2>/dev/null || true
    echo "  Removed VM: ${VM_NAME}"
  done
fi

BMH_POOL_NAME="bmh-${CLONE_NAME}"
if ${VIRSH} pool-info "${BMH_POOL_NAME}" &>/dev/null; then
  echo "Removing libvirt storage pool ${BMH_POOL_NAME}..."
  ${VIRSH} pool-destroy "${BMH_POOL_NAME}" 2>/dev/null || true
  ${VIRSH} pool-undefine "${BMH_POOL_NAME}" 2>/dev/null || true
fi

BMH_DISK_DIR="/tmp/virtual-bmh-disks-${CLONE_NAME}"
if [[ -d "${BMH_DISK_DIR}" ]]; then
  rm -rf "${BMH_DISK_DIR}"
fi

SUSHY_CONFIG_DIR="${HOME}/sushy-${CLONE_NAME}"
SUSHY_PID_FILE="${SUSHY_CONFIG_DIR}/sushy.pid"
SUSHY_PID=""
if [[ -f "${SUSHY_PID_FILE}" ]]; then
  SUSHY_PID=$(cat "${SUSHY_PID_FILE}")
  echo "Stopping sushy-emulator (PID ${SUSHY_PID})..."
  kill "${SUSHY_PID}" 2>/dev/null || true
  for i in $(seq 1 10); do
    if ! kill -0 "${SUSHY_PID}" 2>/dev/null; then
      break
    fi
    if [[ "${i}" -eq 10 ]]; then
      echo "  SIGTERM did not stop sushy-emulator, sending SIGKILL..."
      kill -9 "${SUSHY_PID}" 2>/dev/null || true
    fi
    sleep 1
  done
  rm -f "${SUSHY_PID_FILE}"
fi

if [[ -d "${SUSHY_CONFIG_DIR}" ]]; then
  rm -rf "${SUSHY_CONFIG_DIR}"
fi

# --- Verify BMaaS cleanup ---
# Fail the job if critical resources leaked so we're notified early.
BMH_LEAKED=false
REMAINING_VMS=$(${VIRSH} list --all --name 2>/dev/null | grep "^${BMH_VM_PREFIX}" || true)
if [[ -n "${REMAINING_VMS}" ]]; then
  echo "ERROR: VMs still present after cleanup:" >&2
  echo "${REMAINING_VMS}" >&2
  BMH_LEAKED=true
fi
if ${VIRSH} pool-info "${BMH_POOL_NAME}" &>/dev/null; then
  echo "ERROR: Storage pool '${BMH_POOL_NAME}' still present after cleanup" >&2
  BMH_LEAKED=true
fi
if [[ -n "${SUSHY_PID}" ]] && kill -0 "${SUSHY_PID}" 2>/dev/null; then
  echo "ERROR: sushy-emulator process still running (PID ${SUSHY_PID})" >&2
  BMH_LEAKED=true
fi
if [[ -d "${BMH_DISK_DIR}" ]]; then
  echo "ERROR: Disk directory '${BMH_DISK_DIR}' still present after cleanup" >&2
  BMH_LEAKED=true
fi
if [[ -d "${SUSHY_CONFIG_DIR}" ]]; then
  echo "ERROR: Sushy config directory '${SUSHY_CONFIG_DIR}' still present after cleanup" >&2
  BMH_LEAKED=true
fi
if [[ "${BMH_LEAKED}" == "true" ]]; then
  exit 1
fi
