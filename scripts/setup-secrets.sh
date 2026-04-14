#!/usr/bin/env bash
# setup-secrets.sh - Create Kubernetes secrets for Direct File
# Generates cryptographically secure passwords for PostgreSQL, Redis, and builds
# the DATABASE_URL connection strings. Creates K8s secrets.
# Idempotent: uses dry-run + apply pattern.
#
# Usage:
#   bash scripts/setup-secrets.sh                  # Uses defaults
#   bash scripts/setup-secrets.sh --rotate         # Regenerate all passwords
#   bash scripts/setup-secrets.sh --show           # Show current secret values
#
# Retrieve passwords later:
#   kubectl get secret direct-file-postgres-secret -n direct-file -o jsonpath='{.data.postgres-password}' | base64 -d

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------
APP_NAME="${APP_NAME:-direct-file}"
NAMESPACE="${NAMESPACE:-direct-file}"
PASSWORD_LENGTH="${PASSWORD_LENGTH:-32}"

# Secret names
PG_SECRET="${PG_SECRET:-${APP_NAME}-postgres-secret}"
REDIS_SECRET="${REDIS_SECRET:-${APP_NAME}-redis-secret}"
DB_URL_SECRET="${DB_URL_SECRET:-${APP_NAME}-database-url-secret}"
APP_SECRET="${APP_SECRET:-${APP_NAME}-app-secret}"

# PostgreSQL connection parameters (k8s svc lookup)
PG_DATABASE="${PG_DATABASE:-directfile}"
PG_USERNAME="${PG_USERNAME:-postgres}"
PG_HOST="${PG_HOST:-${APP_NAME}-postgresql.${NAMESPACE}.svc.cluster.local}"
PG_PORT="${PG_PORT:-5432}"

# Redis connection parameters
REDIS_HOST="${REDIS_HOST:-${APP_NAME}-redis.${NAMESPACE}.svc.cluster.local}"
REDIS_PORT="${REDIS_PORT:-6379}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
generate_password() {
  openssl rand -base64 "$PASSWORD_LENGTH" | tr -d '/+=' | head -c "$PASSWORD_LENGTH"
}

generate_key() {
  openssl rand -base64 32
}

secret_exists() {
  kubectl get secret "$1" --namespace="$NAMESPACE" &>/dev/null
}

# ---------------------------------------------------------------------------
# Show mode
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--show" ]]; then
  echo "=== Direct File Secrets (namespace: ${NAMESPACE}) ==="
  echo ""
  echo "--- PostgreSQL ---"
  kubectl get secret "$PG_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d && echo "" || echo "(not found)"
  echo ""
  echo "--- Redis ---"
  kubectl get secret "$REDIS_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d && echo "" || echo "(not found)"
  echo ""
  echo "--- Database URL ---"
  kubectl get secret "$DB_URL_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.url}' 2>/dev/null | base64 -d && echo "" || echo "(not found)"
  echo ""
  echo "--- App Wrapping Key ---"
  kubectl get secret "$APP_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.wrapping-key}' 2>/dev/null | base64 -d && echo "" || echo "(not found)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Rotate mode - force regeneration
# ---------------------------------------------------------------------------
ROTATE=false
if [[ "${1:-}" == "--rotate" ]]; then
  ROTATE=true
  echo "[WARN] Rotating ALL secrets. Pods will need restart."
fi

# ---------------------------------------------------------------------------
# Ensure namespace exists
# ---------------------------------------------------------------------------
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

# ---------------------------------------------------------------------------
# Generate passwords (reuse existing if not rotating)
# ---------------------------------------------------------------------------
if [[ "$ROTATE" == "false" ]] && secret_exists "$PG_SECRET"; then
  echo "[INFO] $PG_SECRET exists, reusing passwords (use --rotate to regenerate)"
  PG_ADMIN_PASS=$(kubectl get secret "$PG_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.postgres-password}' | base64 -d)
else
  PG_ADMIN_PASS="$(generate_password)"
fi

if [[ "$ROTATE" == "false" ]] && secret_exists "$REDIS_SECRET"; then
  echo "[INFO] $REDIS_SECRET exists, reusing passwords (use --rotate to regenerate)"
  REDIS_PASS=$(kubectl get secret "$REDIS_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.redis-password}' | base64 -d)
else
  REDIS_PASS="$(generate_password)"
fi

if [[ "$ROTATE" == "false" ]] && secret_exists "$APP_SECRET"; then
  echo "[INFO] $APP_SECRET exists, reusing keys (use --rotate to regenerate)"
  WRAPPING_KEY=$(kubectl get secret "$APP_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.wrapping-key}' | base64 -d)
else
  WRAPPING_KEY="$(generate_key)"
fi

# ---------------------------------------------------------------------------
# Build connection strings using k8s svc name
# ---------------------------------------------------------------------------
DATABASE_URL="postgres://${PG_USERNAME}:${PG_ADMIN_PASS}@${PG_HOST}:${PG_PORT}/${PG_DATABASE}?sslmode=disable"
REDIS_URL="redis://:${REDIS_PASS}@${REDIS_HOST}:${REDIS_PORT}"

# ---------------------------------------------------------------------------
# Create secrets
# ---------------------------------------------------------------------------
echo "[INFO] Creating PostgreSQL secret: $PG_SECRET"
kubectl create secret generic "$PG_SECRET" \
  --namespace="$NAMESPACE" \
  --from-literal=postgres-password="$PG_ADMIN_PASS" \
  --from-literal=password="$PG_ADMIN_PASS" \
  --from-literal=database="$PG_DATABASE" \
  --from-literal=username="$PG_USERNAME" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret "$PG_SECRET" \
  --namespace="$NAMESPACE" \
  app.kubernetes.io/component=postgresql \
  app.kubernetes.io/part-of="$APP_NAME" \
  --overwrite

echo "[INFO] Creating Redis secret: $REDIS_SECRET"
kubectl create secret generic "$REDIS_SECRET" \
  --namespace="$NAMESPACE" \
  --from-literal=redis-password="$REDIS_PASS" \
  --from-literal=password="$REDIS_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret "$REDIS_SECRET" \
  --namespace="$NAMESPACE" \
  app.kubernetes.io/component=redis \
  app.kubernetes.io/part-of="$APP_NAME" \
  --overwrite

echo "[INFO] Creating database URL secret: $DB_URL_SECRET"
kubectl create secret generic "$DB_URL_SECRET" \
  --namespace="$NAMESPACE" \
  --from-literal=url="$DATABASE_URL" \
  --from-literal=database-url="$DATABASE_URL" \
  --from-literal=redis-url="$REDIS_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret "$DB_URL_SECRET" \
  --namespace="$NAMESPACE" \
  app.kubernetes.io/component=database-url \
  app.kubernetes.io/part-of="$APP_NAME" \
  --overwrite

echo "[INFO] Creating app secret: $APP_SECRET"
kubectl create secret generic "$APP_SECRET" \
  --namespace="$NAMESPACE" \
  --from-literal=wrapping-key="$WRAPPING_KEY" \
  --from-literal=LOCAL_WRAPPING_KEY="$WRAPPING_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl label secret "$APP_SECRET" \
  --namespace="$NAMESPACE" \
  app.kubernetes.io/component=app \
  app.kubernetes.io/part-of="$APP_NAME" \
  --overwrite

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo " Direct File secrets created in namespace: $NAMESPACE"
echo "============================================"
echo " PostgreSQL secret:   $PG_SECRET"
echo " Redis secret:        $REDIS_SECRET"
echo " Database URL secret: $DB_URL_SECRET"
echo " App secret:          $APP_SECRET"
echo ""
echo " PostgreSQL svc:      $PG_HOST:$PG_PORT"
echo " Redis svc:           $REDIS_HOST:$REDIS_PORT"
echo ""
echo " Run 'bash scripts/setup-secrets.sh --show' to view values"
echo "============================================"
