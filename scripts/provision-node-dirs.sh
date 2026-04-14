#!/usr/bin/env bash
# provision-node-dirs.sh - Provision local PV directories on Kubernetes nodes
# SSHs to target node(s) and creates directories for Direct File persistent volumes
# with proper ownership and permissions.
#
# Usage:
#   bash scripts/provision-node-dirs.sh                    # Default: 192.168.29.147
#   bash scripts/provision-node-dirs.sh 192.168.29.147     # Explicit node
#   bash scripts/provision-node-dirs.sh 192.168.29.147 192.168.29.148  # Multiple nodes

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------
APP_NAME="${APP_NAME:-direct-file}"
BASE_PATH="${BASE_PATH:-/opt/k8s-pers/vol1}"

# Directory paths
PSQL_DIR="${PSQL_DIR:-${BASE_PATH}/psql-${APP_NAME}}"
REDIS_DIR="${REDIS_DIR:-${BASE_PATH}/redis-${APP_NAME}}"

# Ownership: postgres=999:999, redis=999:0 (or 0:0 depending on chart)
PSQL_UID="${PSQL_UID:-999}"
PSQL_GID="${PSQL_GID:-999}"
REDIS_UID="${REDIS_UID:-999}"
REDIS_GID="${REDIS_GID:-0}"

SSH_USER="${SSH_USER:-$(whoami)}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i ${HOME}/.ssh/id_rsa_devops_ssh}"

# Default target node (IP instead of hostname per requirements)
DEFAULT_NODE="192.168.29.147"

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------
provision_node() {
  local node="$1"
  echo "[INFO] Provisioning directories on ${node}..."

  local remote_script
  remote_script=$(cat <<REMOTE_EOF
set -e

echo "  Creating ${PSQL_DIR}..."
sudo mkdir -p "${PSQL_DIR}"
sudo chown ${PSQL_UID}:${PSQL_GID} "${PSQL_DIR}"
sudo chmod 700 "${PSQL_DIR}"

echo "  Creating ${REDIS_DIR}..."
sudo mkdir -p "${REDIS_DIR}"
sudo chown ${REDIS_UID}:${REDIS_GID} "${REDIS_DIR}"
sudo chmod 700 "${REDIS_DIR}"

echo "  Verifying..."
ls -ld "${PSQL_DIR}"
ls -ld "${REDIS_DIR}"
REMOTE_EOF
)

  # shellcheck disable=SC2086
  ssh ${SSH_OPTS} "${SSH_USER}@${node}" bash -s <<< "$remote_script"
  echo "[OK]   Directories provisioned on ${node}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
NODES=("${@:-$DEFAULT_NODE}")

echo "============================================"
echo " Provisioning Direct File PV directories"
echo " App:   ${APP_NAME}"
echo " Base:  ${BASE_PATH}"
echo " Nodes: ${NODES[*]}"
echo "============================================"
echo ""

for node in "${NODES[@]}"; do
  provision_node "$node"
  echo ""
done

echo "============================================"
echo " Done. Directories created:"
echo "   ${PSQL_DIR}   (${PSQL_UID}:${PSQL_GID})"
echo "   ${REDIS_DIR}  (${REDIS_UID}:${REDIS_GID})"
echo "============================================"
