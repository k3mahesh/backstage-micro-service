#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# teardown-k8s.sh
#
# Deletes all Backstage POC resources from EKS — in the correct reverse order.
# Safe to run — does not touch the shared NLB (owned by ingress-nginx controller).
#
# Usage:
#   ./scripts/teardown-k8s.sh                    # delete everything (prompts for confirmation)
#   ./scripts/teardown-k8s.sh --yes              # skip confirmation prompt
#   ./scripts/teardown-k8s.sh --namespace myns   # override namespace (default: backstage-poc)
#   ./scripts/teardown-k8s.sh --dry-run          # print what would be deleted, delete nothing
#   ./scripts/teardown-k8s.sh --keep-pvcs        # delete workloads but keep EBS volumes
#
# What gets deleted:
#   - All Deployments, StatefulSets, Services in the namespace
#   - All ConfigMaps and Secrets in the namespace
#   - PersistentVolumeClaims (and therefore the EBS volumes) — unless --keep-pvcs
#   - The namespace itself
#   - The Ingress resource (backstage-poc-ingress)
#
# What is NOT deleted by this script:
#   - ECR repositories and images
#   - SSM parameters (/backstage/poc/*)
#   - The EKS cluster itself
#   - IAM roles / policies
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[teardown]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
NAMESPACE="backstage-poc"
AUTO_YES=false
DRY_RUN=false
KEEP_PVCS=false

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)        AUTO_YES=true;   shift ;;
    --dry-run)    DRY_RUN=true;    shift ;;
    --keep-pvcs)  KEEP_PVCS=true;  shift ;;
    --namespace)  NAMESPACE="$2";  shift 2 ;;
    -h|--help)
      sed -n '3,22p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) err "Unknown flag: $1. Run with --help for usage." ;;
  esac
done

# ── Validate prerequisites ────────────────────────────────────────────────────
command -v kubectl &>/dev/null || err "kubectl not found."
kubectl cluster-info &>/dev/null || \
  err "kubectl cannot reach the cluster. Run: aws eks update-kubeconfig --region <region> --name <cluster>"

# ── Check namespace exists ────────────────────────────────────────────────────
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  warn "Namespace '$NAMESPACE' does not exist — nothing to delete."
  exit 0
fi

# ── Confirmation prompt ───────────────────────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}⚠  WARNING: This will permanently delete all resources in namespace '$NAMESPACE'.${NC}"
echo -e "${RED}   This includes all pods, services, secrets, configmaps, and EBS volumes.${NC}"
echo ""

if [[ $DRY_RUN == true ]]; then
  warn "(dry-run mode — nothing will actually be deleted)"
elif [[ $AUTO_YES == false ]]; then
  read -r -p "Type the namespace name to confirm deletion: " CONFIRM
  if [[ "$CONFIRM" != "$NAMESPACE" ]]; then
    warn "Input did not match '$NAMESPACE'. Aborting."
    exit 1
  fi
fi

K="kubectl --namespace $NAMESPACE"
[[ $DRY_RUN == true ]] && K="$K --dry-run=client"

# ── 1. Delete Ingress first — removes the nginx routing rule for the POC ──────
step "1/6  Removing Ingress and Envoy"
log "Deleting Ingress (removes nginx routing rule for backstage-poc-aws.opstree.dev)..."
if [[ $DRY_RUN == false ]]; then
  kubectl delete ingress backstage-poc-ingress --namespace "$NAMESPACE" --ignore-not-found
  kubectl delete service envoy --namespace "$NAMESPACE" --ignore-not-found
  kubectl delete deployment envoy --namespace "$NAMESPACE" --ignore-not-found
  kubectl delete service envoy-admin --namespace "$NAMESPACE" --ignore-not-found
else
  log "  (dry-run) would delete: ingress/backstage-poc-ingress, service/envoy, deployment/envoy, service/envoy-admin"
fi
ok "Ingress and Envoy deleted"
warn "The shared NLB (ingress-nginx) is NOT affected — other apps (backstage, keycloak) remain running"

# ── 2. Delete application workloads ──────────────────────────────────────────
step "2/6  Removing application Deployments"
for dep in frontend backend-core backend-catalog backend-scaffolder backend-techdocs; do
  log "  Deleting deployment/$dep and its Service..."
  if [[ $DRY_RUN == false ]]; then
    kubectl delete deployment "$dep" --namespace "$NAMESPACE" --ignore-not-found
    kubectl delete service    "$dep" --namespace "$NAMESPACE" --ignore-not-found
  else
    log "  (dry-run) would delete: deployment/$dep, service/$dep"
  fi
done
ok "Application workloads deleted"

# ── 3. Delete data layer ──────────────────────────────────────────────────────
step "3/6  Removing data layer (postgres + redis)"
for ss in postgres redis; do
  log "  Deleting statefulset/$ss and its Service..."
  if [[ $DRY_RUN == false ]]; then
    kubectl delete statefulset "$ss" --namespace "$NAMESPACE" --ignore-not-found
    kubectl delete service     "$ss" --namespace "$NAMESPACE" --ignore-not-found
  else
    log "  (dry-run) would delete: statefulset/$ss, service/$ss"
  fi
done
ok "Data layer deleted"

# ── 4. Delete ConfigMaps and Secrets ─────────────────────────────────────────
step "4/6  Removing ConfigMaps and Secrets"
if [[ $DRY_RUN == false ]]; then
  kubectl delete configmap app-config app-config-production envoy-config postgres-init \
    --namespace "$NAMESPACE" --ignore-not-found
  kubectl delete secret backstage-secrets \
    --namespace "$NAMESPACE" --ignore-not-found
else
  log "  (dry-run) would delete: configmaps (app-config, app-config-production, envoy-config, postgres-init)"
  log "  (dry-run) would delete: secret/backstage-secrets"
fi
ok "ConfigMaps and Secrets deleted"

# ── 5. Delete PVCs (EBS volumes) ─────────────────────────────────────────────
step "5/6  Removing PersistentVolumeClaims (EBS volumes)"
if [[ $KEEP_PVCS == true ]]; then
  warn "  --keep-pvcs set — skipping PVC deletion. EBS volumes will remain."
  warn "  Delete manually later: kubectl delete pvc --all -n $NAMESPACE"
else
  if [[ $DRY_RUN == false ]]; then
    kubectl delete pvc postgres-data redis-data techdocs-storage \
      --namespace "$NAMESPACE" --ignore-not-found
    log "  Waiting for EBS volumes to be released..."
    sleep 5
  else
    log "  (dry-run) would delete: pvc/postgres-data, pvc/redis-data, pvc/techdocs-storage"
  fi
  ok "PVCs deleted — EBS volumes will be deprovisioned by AWS"
fi

# ── 6. Delete namespace ───────────────────────────────────────────────────────
step "6/6  Deleting namespace '$NAMESPACE'"

if [[ $DRY_RUN == false ]]; then
  kubectl delete namespace "$NAMESPACE" --ignore-not-found

  log "Waiting for namespace to be fully deleted..."
  for i in $(seq 1 30); do
    if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
      ok "Namespace '$NAMESPACE' fully deleted"
      break
    fi
    log "  Still terminating... ($i/30)"
    sleep 5
  done

  if kubectl get namespace "$NAMESPACE" &>/dev/null; then
    warn "Namespace is stuck in Terminating state."
    warn "This usually means a resource finalizer is blocking deletion."
    warn "Check with: kubectl get all -n $NAMESPACE"
    warn "Force-remove finalizers: kubectl patch namespace $NAMESPACE -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge"
  fi
else
  log "  (dry-run) would delete: namespace/$NAMESPACE"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
step "Teardown complete"

if [[ $DRY_RUN == false ]]; then
  echo ""
  ok "All Backstage POC resources in '$NAMESPACE' have been deleted."
  echo ""
  echo -e "${BOLD}What was NOT deleted (requires manual cleanup if needed):${NC}"
  echo "  - ECR images:      aws ecr list-images --repository-name <name> --region ap-south-1"
  echo "  - ECR repos:       aws ecr delete-repository --repository-name <name> --force --region ap-south-1"
  echo "  - SSM parameters:  aws ssm delete-parameter --name /backstage/poc/BACKEND_SECRET --region ap-south-1"
  echo "                     aws ssm delete-parameter --name /backstage/poc/GITHUB_TOKEN --region ap-south-1"
  echo "                     aws ssm delete-parameter --name /backstage/poc/POSTGRES_PASSWORD --region ap-south-1"
else
  ok "(dry-run complete — nothing was deleted)"
fi
