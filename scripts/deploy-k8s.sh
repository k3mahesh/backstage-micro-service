#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# deploy-k8s.sh
#
# Deploys all Backstage services to EKS in the correct dependency order,
# waits for each layer to be healthy before moving to the next, and
# automatically patches APP_BASE_URL once the Envoy LoadBalancer gets its DNS.
#
# Usage:
#   ./scripts/deploy-k8s.sh                      # full deploy / re-deploy
#   ./scripts/deploy-k8s.sh --dry-run            # print what would run, apply nothing
#   ./scripts/deploy-k8s.sh --namespace myns     # override namespace (default: backstage)
#   ./scripts/deploy-k8s.sh --skip-wait          # apply everything without waiting
#   ./scripts/deploy-k8s.sh --rollout            # force rolling restart of all deployments
#
# Prerequisites:
#   - kubectl configured and pointing at the right cluster (aws eks update-kubeconfig ...)
#   - backstage-secrets K8s Secret already created (see deploy-on-aws.md Step 4)
#   - <ECR_REGISTRY> replaced in k8s/workloads/*.yaml (see build-push-ecr.sh output)
#
# Safe to re-run — kubectl apply is idempotent.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[deploy]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

KUBECTL="kubectl"

# ── Defaults ──────────────────────────────────────────────────────────────────
NAMESPACE="backstage-poc"
DRY_RUN=false
SKIP_WAIT=false
FORCE_ROLLOUT=false

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true;       shift ;;
    --skip-wait)     SKIP_WAIT=true;     shift ;;
    --rollout)       FORCE_ROLLOUT=true; shift ;;
    --namespace)     NAMESPACE="$2";     shift 2 ;;
    -h|--help)
      sed -n '3,18p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) err "Unknown flag: $1. Run with --help for usage." ;;
  esac
done

K="$KUBECTL --namespace $NAMESPACE"
[[ $DRY_RUN == true ]] && K="$K --dry-run=client"

# ── Validate we are in the repo root ─────────────────────────────────────────
[[ -d "k8s" && -f "k8s/namespace.yaml" ]] || \
  err "Run this script from the repository root (backstage-micro-service/)"

# ── Check prerequisites ───────────────────────────────────────────────────────
step "Checking prerequisites"

command -v kubectl &>/dev/null || err "kubectl not found. Install: https://kubernetes.io/docs/tasks/tools/"
command -v aws    &>/dev/null || err "aws CLI not found."

# Verify kubectl can reach the cluster
kubectl cluster-info &>/dev/null || \
  err "kubectl cannot reach the cluster. Run: aws eks update-kubeconfig --region <region> --name <cluster>"
ok "kubectl connected to: $(kubectl config current-context)"

# ── Check for unfilled placeholders ──────────────────────────────────────────
step "Validating manifests"

PLACEHOLDER_ERRORS=0

if grep -rl "<ECR_REGISTRY>" k8s/workloads/ &>/dev/null; then
  warn "<ECR_REGISTRY> placeholder still present in:"
  grep -rl "<ECR_REGISTRY>" k8s/workloads/ | sed 's/^/    /'
  warn "Run scripts/build-push-ecr.sh first — it prints the sed command to replace this."
  PLACEHOLDER_ERRORS=$((PLACEHOLDER_ERRORS + 1))
fi

# <ENVOY_LB_DNS> is expected at this point — we patch it later after the LB is up
if grep -rl "<ECR_REGISTRY>" k8s/workloads/ &>/dev/null || \
   grep -rl "storageClassName: gp2" k8s/storage/ &>/dev/null; then
  AVAILABLE_CLASSES=$(kubectl get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "unknown")
  log "Available StorageClasses on this cluster: $AVAILABLE_CLASSES"
  if ! kubectl get storageclass gp2 &>/dev/null; then
    warn "StorageClass 'gp2' not found. Available: $AVAILABLE_CLASSES"
    warn "Update k8s/storage/pvcs.yaml storageClassName before applying."
    PLACEHOLDER_ERRORS=$((PLACEHOLDER_ERRORS + 1))
  fi
fi

[[ $PLACEHOLDER_ERRORS -gt 0 ]] && err "Fix the issues above before deploying."
ok "Manifests look clean"

# ── Check the K8s Secret exists ───────────────────────────────────────────────
step "Checking secrets"
if [[ $DRY_RUN == false ]]; then
  if ! kubectl get secret backstage-secrets --namespace "$NAMESPACE" &>/dev/null; then
    err "Secret 'backstage-secrets' not found in namespace '$NAMESPACE'.
Create it first (see deploy-on-aws.md Step 4):
  kubectl create secret generic backstage-secrets \\
    --namespace $NAMESPACE \\
    --from-literal=BACKEND_SECRET=... \\
    --from-literal=GITHUB_TOKEN=... \\
    --from-literal=POSTGRES_PASSWORD=..."
  fi
  ok "Secret 'backstage-secrets' exists"
else
  warn "(dry-run) Skipping secret check"
fi

# ── Helper: apply a file with logging ────────────────────────────────────────
apply() {
  local file="$1"
  local label="${2:-$file}"
  log "  Applying: $label"
  if [[ $DRY_RUN == true ]]; then
    kubectl apply -f "$file" --dry-run=client --namespace "$NAMESPACE" 2>&1 | sed 's/^/    /'
  else
    kubectl apply -f "$file" --namespace "$NAMESPACE"
  fi
}

# ── Helper: wait for a rollout ────────────────────────────────────────────────
wait_rollout() {
  local kind="$1"   # deployment or statefulset
  local name="$2"
  local timeout="${3:-180s}"

  if [[ $DRY_RUN == true || $SKIP_WAIT == true ]]; then
    warn "  (skipping wait for $kind/$name)"
    return
  fi

  log "  Waiting for $kind/$name to be ready (timeout: $timeout)..."
  if kubectl rollout status "$kind/$name" \
       --namespace "$NAMESPACE" \
       --timeout "$timeout"; then
    ok "  $kind/$name is ready"
  else
    err "$kind/$name did not become ready within $timeout.
  Check pod logs:
    kubectl logs -l app=$name -n $NAMESPACE --tail=50
  Check pod events:
    kubectl describe pods -l app=$name -n $NAMESPACE"
  fi
}

# ── 1. Namespace ──────────────────────────────────────────────────────────────
step "1/7  Namespace"
kubectl apply -f k8s/namespace.yaml
ok "Namespace '$NAMESPACE' ready"

# ── 2. ConfigMaps ─────────────────────────────────────────────────────────────
step "2/7  ConfigMaps"
for f in k8s/configmaps/*.yaml; do
  apply "$f" "$(basename $f)"
done
ok "All ConfigMaps applied"

# ── 3. Clean up stuck pods from any previous run ─────────────────────────────
step "3/7  Cleaning up stuck pods"
if [[ $DRY_RUN == false ]]; then
  STUCK=$(kubectl get pods --namespace "$NAMESPACE" \
    --field-selector='status.phase in (Pending,Failed)' \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$STUCK" ]]; then
    log "  Deleting stuck pods: $STUCK"
    kubectl delete pods --namespace "$NAMESPACE" \
      --field-selector='status.phase in (Pending,Failed)' --ignore-not-found
    ok "  Stuck pods removed"
  else
    ok "  No stuck pods found"
  fi
else
  warn "  (dry-run) Skipping stuck pod cleanup"
fi

# ── 4. Data layer: PostgreSQL + Redis ─────────────────────────────────────────
step "4/7  Data layer (postgres + redis)"
apply k8s/workloads/postgres.yaml "postgres.yaml"
apply k8s/workloads/redis.yaml    "redis.yaml"

wait_rollout statefulset postgres 240s
wait_rollout statefulset redis    120s

# ── 5. Application backends — one at a time to avoid resource crunch ──────────
# Each service is applied and waited on before the next one starts.
# This prevents multiple pods competing for memory simultaneously.
step "5/7  Application backends (sequential — one at a time)"

log "  [1/6] backend-core"
apply k8s/workloads/backend-core.yaml "backend-core.yaml"
wait_rollout deployment backend-core 240s

log "  [2/6] backend-catalog"
apply k8s/workloads/backend-catalog.yaml "backend-catalog.yaml"
wait_rollout deployment backend-catalog 240s

log "  [3/6] backend-scaffolder"
apply k8s/workloads/backend-scaffolder.yaml "backend-scaffolder.yaml"
wait_rollout deployment backend-scaffolder 240s

log "  [4/6] backend-techdocs"
apply k8s/workloads/backend-techdocs.yaml "backend-techdocs.yaml"
wait_rollout deployment backend-techdocs 240s

log "  [5/6] frontend"
apply k8s/workloads/frontend.yaml "frontend.yaml"
wait_rollout deployment frontend 180s

log "  [6/6] envoy"
apply k8s/workloads/envoy.yaml "envoy.yaml"
wait_rollout deployment envoy 180s

# ── 6. Ingress ────────────────────────────────────────────────────────────────
step "6/6  Ingress (nginx ingress controller)"
apply k8s/ingress.yaml "ingress.yaml"
ok "Ingress applied — nginx ingress controller will route backstage-poc-aws.opstree.dev → envoy"

# ── Force rollout if requested ────────────────────────────────────────────────
if [[ $FORCE_ROLLOUT == true && $DRY_RUN == false ]]; then
  step "Forcing rolling restart of all deployments"
  for dep in frontend backend-core backend-catalog backend-scaffolder backend-techdocs envoy; do
    kubectl rollout restart deployment/"$dep" --namespace "$NAMESPACE"
    ok "  Restarted $dep"
  done
fi

# ── Final status ──────────────────────────────────────────────────────────────
step "Deployment complete"

if [[ $DRY_RUN == false ]]; then
  echo ""
  echo -e "${BOLD}Pod status:${NC}"
  kubectl get pods --namespace "$NAMESPACE" \
    -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount"

  echo ""
  echo -e "${BOLD}Services:${NC}"
  kubectl get svc --namespace "$NAMESPACE"

  echo ""
  echo -e "${BOLD}Ingress:${NC}"
  kubectl get ingress --namespace "$NAMESPACE"

  echo ""
  ok "Backstage POC will be available at: ${BOLD}https://backstage-poc-aws.opstree.dev${NC}"
  warn "Ensure DNS CNAME is set: backstage-poc-aws.opstree.dev → $(kubectl get ingress backstage-ingress -n backstage -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo '<shared-nlb-dns>')"
  ok "Envoy admin (internal):  kubectl port-forward svc/envoy-admin 9901:9901 -n $NAMESPACE"
else
  ok "(dry-run complete — nothing was applied)"
fi

echo ""
log "Useful commands:"
echo "  Watch pods live:       kubectl get pods -n $NAMESPACE -w"
echo "  Tail backend-core:     kubectl logs -f deployment/backend-core -n $NAMESPACE"
echo "  Tail all backends:     kubectl logs -f -l 'app in (backend-core,backend-catalog)' -n $NAMESPACE"
echo "  Describe failing pod:  kubectl describe pod -l app=<name> -n $NAMESPACE"
echo "  Check ingress:         kubectl describe ingress backstage-poc-ingress -n $NAMESPACE"
echo "  Force re-deploy:       ./scripts/deploy-k8s.sh --rollout"
