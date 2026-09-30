#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# build-push-ecr.sh
#
# Builds all Backstage service images for linux/amd64 and pushes them to ECR.
# Must be run from the repository root.
#
# Usage:
#   ./scripts/build-push-ecr.sh                        # build + push all, tag=latest+git-sha
#   ./scripts/build-push-ecr.sh --tag v1.2.3           # custom tag (also tags latest)
#   ./scripts/build-push-ecr.sh --service frontend     # single service only
#   ./scripts/build-push-ecr.sh --build-only           # build images, skip push
#   ./scripts/build-push-ecr.sh --push-only            # push already-built images, skip build
#   ./scripts/build-push-ecr.sh --region eu-west-1     # override AWS region
#
# Required environment / prerequisites:
#   - AWS CLI configured with credentials that can push to ECR
#   - Docker running (BuildKit enabled)
#   - ECR repositories must exist — create them with the pre-flight commands in
#     deploy-on-aws.md, or run with --create-repos flag
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${CYAN}[build-push-ecr]${NC} $*"; }
ok()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-ap-south-1}"
TAG="${TAG:-}"             # empty = auto (latest + git sha)
ONLY=""                    # empty = all services
BUILD=true
PUSH=true
CREATE_REPOS=false

# ── Parse flags ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)          TAG="$2";        shift 2 ;;
    --service)      ONLY="$2";       shift 2 ;;
    --region)       AWS_REGION="$2"; shift 2 ;;
    --build-only)   PUSH=false;      shift   ;;
    --push-only)    BUILD=false;     shift   ;;
    --create-repos) CREATE_REPOS=true; shift ;;
    -h|--help)
      sed -n '3,20p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) err "Unknown flag: $1. Run with --help for usage." ;;
  esac
done

# ── Validate we are in the repo root ─────────────────────────────────────────
[[ -f "package.json" && -d "packages" ]] || \
  err "Run this script from the repository root (backstage-micro-service/)"

# ── Resolve AWS account and ECR registry ─────────────────────────────────────
step "Resolving AWS identity"
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || \
  err "AWS CLI not configured or no credentials. Run: aws configure"
ECR_REGISTRY="$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"
ok "Account : $AWS_ACCOUNT"
ok "Region  : $AWS_REGION"
ok "Registry: $ECR_REGISTRY"

# ── Resolve image tag ─────────────────────────────────────────────────────────
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "nogit")
if [[ -z "$TAG" ]]; then
  TAG="$GIT_SHA"
fi
log "Image tag: ${BOLD}$TAG${NC} (also tagged as ${BOLD}latest${NC})"

# ── Service definitions ───────────────────────────────────────────────────────
# Array of: "local-name|ecr-repo-name|dockerfile-path"
SERVICES=(
  "frontend|frontend|packages/app/Dockerfile"
  "backend-core|backend-core|packages/backend-core/Dockerfile"
  "backend-catalog|backend-catalog|packages/backend-catalog/Dockerfile"
  "backend-scaffolder|backend-scaffolder|packages/backend-scaffolder/Dockerfile"
  "backend-techdocs|backend-techdocs|packages/backend-techdocs/Dockerfile"
)

# Filter to single service if --service was passed
if [[ -n "$ONLY" ]]; then
  FILTERED=()
  for svc in "${SERVICES[@]}"; do
    local_name="${svc%%|*}"
    [[ "$local_name" == "$ONLY" ]] && FILTERED+=("$svc")
  done
  [[ ${#FILTERED[@]} -eq 0 ]] && \
    err "Unknown service '$ONLY'. Valid names: frontend, backend-core, backend-catalog, backend-scaffolder, backend-techdocs"
  SERVICES=("${FILTERED[@]}")
fi

# ── Optionally create ECR repos ───────────────────────────────────────────────
if $CREATE_REPOS; then
  step "Creating ECR repositories (skips existing ones)"
  for svc in "${SERVICES[@]}"; do
    repo="${svc#*|}"; repo="${repo%%|*}"   # extract ecr-repo-name
    if aws ecr describe-repositories --repository-names "$repo" \
         --region "$AWS_REGION" &>/dev/null; then
      warn "  $repo already exists — skipping"
    else
      aws ecr create-repository \
        --repository-name "$repo" \
        --region "$AWS_REGION" \
        --image-scanning-configuration scanOnPush=true \
        --query 'repository.repositoryUri' --output text
      ok "  Created: $repo"
    fi
  done
fi

# ── ECR login ─────────────────────────────────────────────────────────────────
step "Logging in to ECR"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
ok "ECR login successful"

# ── Build and push ────────────────────────────────────────────────────────────
# Note: frontend Dockerfile uses a multi-stage build — no pre-build step needed.
FAILED=()

for svc in "${SERVICES[@]}"; do
  IFS='|' read -r local_name ecr_repo dockerfile <<< "$svc"
  full_image="$ECR_REGISTRY/$ecr_repo"

  # ── Build ──────────────────────────────────────────────────────────────────
  if $BUILD; then
    step "Building: $local_name"
    log "  Dockerfile : $dockerfile"
    log "  Image      : $full_image:$TAG"

    if docker build \
      --platform linux/amd64 \
      --file "$dockerfile" \
      --tag "$full_image:$TAG" \
      --tag "$full_image:latest" \
      --progress plain \
      .; then
      ok "Built $local_name"
    else
      warn "Build failed for $local_name — continuing with remaining services"
      FAILED+=("$local_name (build)")
      continue
    fi
  fi

  # ── Push ──────────────────────────────────────────────────────────────────
  if $PUSH; then
    step "Pushing: $local_name"
    if docker push "$full_image:$TAG" && docker push "$full_image:latest"; then
      ok "Pushed $full_image:$TAG"
      ok "Pushed $full_image:latest"
    else
      warn "Push failed for $local_name"
      FAILED+=("$local_name (push)")
    fi
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
step "Summary"

if [[ ${#FAILED[@]} -eq 0 ]]; then
  ok "All services completed successfully"
else
  warn "The following services had errors:"
  for f in "${FAILED[@]}"; do
    echo -e "  ${RED}✗${NC} $f"
  done
  echo ""
  exit 1
fi

echo ""
log "Images pushed to ECR under registry: ${BOLD}$ECR_REGISTRY${NC}"
log "Tag used: ${BOLD}$TAG${NC} + ${BOLD}latest${NC}"
echo ""
log "Next steps:"
echo "  1. Replace <ECR_REGISTRY> in k8s/workloads/*.yaml:"
echo "     for f in frontend backend-core backend-catalog backend-scaffolder backend-techdocs; do"
echo "       python3 -c \""
echo "     content = open('k8s/workloads/\$f.yaml').read()"
echo "     open('k8s/workloads/\$f.yaml','w').write(content.replace('<ECR_REGISTRY>', '$ECR_REGISTRY'))"
echo "       \""
echo "     done"
echo ""
echo "  2. kubectl apply -f k8s/  (see deploy-on-aws.md for the full ordered sequence)"
