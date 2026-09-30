# Backstage Microservices — AWS EKS POC Deployment

> **Purpose:** Track every code change, AWS action, and decision made while deploying this POC.
> Every time something changes — in code or on AWS — a new entry goes in the [Change Log](#change-log).
>
> **Goal:** Deploy Backstage microservices on EKS securely, understand the end-to-end flow,
> and learn what each layer does. Single PostgreSQL and single Redis as containers inside the cluster.

---

## Mind Map — Full Picture

```mermaid
mindmap
  root((Backstage on EKS — POC))
    AWS Infrastructure
      EKS Cluster
        Namespace backstage
        Node Group
          t3.medium x2 minimum
      ECR
        backstage-frontend
        backstage-backend-core
        backstage-backend-catalog
        backstage-backend-scaffolder
        backstage-backend-techdocs
      IAM
        Node instance role
          ECR pull permission
          EBS CSI driver permission
        OIDC provider for IRSA
      EBS CSI Driver
        Provisions gp2 PVCs
        Postgres data 20Gi
        Redis data 2Gi
        TechDocs storage 5Gi
    Kubernetes Workloads
      namespace backstage
        Envoy LoadBalancer port 80
        frontend ClusterIP port 8080
        backend-core ClusterIP port 7007
        backend-catalog ClusterIP port 7008
        backend-scaffolder ClusterIP port 7009
        backend-techdocs ClusterIP port 7010
        postgres StatefulSet port 5432
        redis StatefulSet port 6379
    Configuration
      ConfigMaps
        app-config
        app-config-production
        envoy-config
        postgres-init
      Secrets
        backstage-secrets
          BACKEND_SECRET
          GITHUB_TOKEN
          POSTGRES_PASSWORD
    Deployment Workflow
      Local Machine
        Code changes
        Update deploy-on-aws.md
        git push origin main
      Bastion Host
        git pull
        Build images
        Push to ECR
        kubectl apply -f k8s/
```

---

## Architecture Diagram

```
           Internet / Your Browser
                    │
               port 80 (HTTP)
                    │
            ┌───────▼──────────────────────────────────────┐
            │              AWS EKS Cluster                  │
            │           Namespace: backstage                │
            │                                              │
            │  ┌─────────────────────────┐                 │
            │  │  Envoy — LoadBalancer   │◄── AWS ELB/NLB  │
            │  │  (envoy.yaml ConfigMap) │                 │
            │  └──┬──────┬──────┬───┬───┘                 │
            │     │      │      │   │                      │
            │  /api/  /api/  /api/ /*                      │
            │  cata  scaf   core                           │
            │  log   folder                                │
            │  search                                      │
            │  k8s                                         │
            │     │      │      │   │                      │
            │  ┌──▼─┐ ┌──▼──┐ ┌▼─┐ ┌▼──────────┐         │
            │  │cat │ │scaf │ │cor│ │ frontend  │         │
            │  │log │ │fold │ │e  │ │ nginx:8080│         │
            │  │7008│ │7009 │ │700│ └───────────┘         │
            │  └──┬─┘ └──┬──┘ └┬─┘                        │
            │  ┌──▼──────▼─────▼──────────────────────┐   │
            │  │        postgres:5432  redis:6379       │   │
            │  │        StatefulSet    StatefulSet      │   │
            │  └──────────────────────────────────────┘   │
            │                                              │
            │  ┌─────────────────────────────────────┐    │
            │  │     EBS Volumes (gp2 PVCs)           │    │
            │  │  postgres-data 20Gi                  │    │
            │  │  redis-data 2Gi                      │    │
            │  │  techdocs-storage 5Gi                │    │
            │  └─────────────────────────────────────┘    │
            └──────────────────────────────────────────────┘
```

---

## Directory Layout

```
k8s/
├── namespace.yaml                      ← create namespace first
├── configmaps/
│   ├── app-config.yaml                 ← base Backstage config (ConfigMap)
│   ├── app-config-production.yaml      ← production overrides (ConfigMap)
│   ├── envoy.yaml                      ← Envoy proxy routing rules (ConfigMap)
│   └── postgres-init.yaml              ← DB init script (ConfigMap)
├── secrets/
│   ├── backstage-secrets.template.yaml ← COMMIT: placeholder values
│   └── .gitignore                      ← ignores backstage-secrets.yaml
├── storage/
│   └── pvcs.yaml                       ← postgres, redis, techdocs PVCs
└── workloads/
    ├── postgres.yaml                   ← StatefulSet + headless Service
    ├── redis.yaml                      ← StatefulSet + headless Service
    ├── frontend.yaml                   ← Deployment + ClusterIP Service
    ├── backend-core.yaml               ← Deployment + ClusterIP Service
    ├── backend-catalog.yaml            ← Deployment + ClusterIP Service
    ├── backend-scaffolder.yaml         ← Deployment + ClusterIP Service
    ├── backend-techdocs.yaml           ← Deployment + ClusterIP Service
    └── envoy.yaml                      ← Deployment + LoadBalancer Service
```

---

## Pre-Flight Checklist — AWS Setup

### EKS Cluster

- [ ] EKS cluster exists (version 1.29+)
- [ ] `kubectl` configured: `aws eks update-kubeconfig --region ap-south-1 --name <cluster-name>`
- [ ] Node group has at least 2 × t3.medium nodes
- [ ] EBS CSI Driver add-on installed (needed for PVC provisioning)
  ```bash
  aws eks create-addon --cluster-name <name> --addon-name aws-ebs-csi-driver --region ap-south-1
  ```
- [ ] Node IAM role has `AmazonEBSCSIDriverPolicy` attached

### ECR Repositories

Create one repo per image:
```bash
for svc in frontend backend-core backend-catalog backend-scaffolder backend-techdocs; do
  aws ecr create-repository \
    --repository-name backstage-$svc \
    --region ap-south-1 \
    --image-scanning-configuration scanOnPush=true
done
```

- [ ] `backstage-frontend`
- [ ] `backstage-backend-core`
- [ ] `backstage-backend-catalog`
- [ ] `backstage-backend-scaffolder`
- [ ] `backstage-backend-techdocs`

### Node Group — ECR Pull Permission

- [ ] Node instance role has `AmazonEC2ContainerRegistryReadOnly` attached

---

## Deployment Workflow

Follow this exact order every time. Steps depend on each other.

### Step 1 — On Your Local Machine

```bash
# Make code changes, then:
# 1. Update the Change Log at the bottom of this file
# 2. Commit and push
git add .
git commit -m "your message"
git push origin main
```

### Step 2 — On the Bastion Host: Build & Push Images

```bash
# Authenticate with ECR
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=ap-south-1
ECR_REGISTRY=$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin $ECR_REGISTRY

# Pull latest code
cd backstage-micro-service
git pull origin main

# Build and push — do this for each service
for svc in frontend backend-core backend-catalog backend-scaffolder backend-techdocs; do
  docker build \
    --platform linux/amd64 \
    -t $ECR_REGISTRY/backstage-$svc:latest \
    -f packages/$svc/Dockerfile \
    .
  docker push $ECR_REGISTRY/backstage-$svc:latest
done
```

> **Note:** `packages/app/Dockerfile` is the `frontend` service.
> Rename it in the build command: `-f packages/app/Dockerfile` for `frontend`.

### Step 3 — On the Bastion Host: Update Image URIs in Manifests

Replace the `<ECR_REGISTRY>` placeholder in each workload manifest:

```bash
# One-liner to replace in all workload files
sed -i "s|<ECR_REGISTRY>|$ECR_REGISTRY|g" k8s/workloads/*.yaml
```

### Step 4 — On the Bastion Host: Create the Secret

```bash
# Never commit this — it is .gitignored
kubectl create secret generic backstage-secrets \
  --namespace backstage \
  --from-literal=BACKEND_SECRET=$(aws ssm get-parameter \
    --name /backstage/poc/BACKEND_SECRET --with-decryption \
    --query Parameter.Value --output text) \
  --from-literal=GITHUB_TOKEN=$(aws ssm get-parameter \
    --name /backstage/poc/GITHUB_TOKEN --with-decryption \
    --query Parameter.Value --output text) \
  --from-literal=POSTGRES_PASSWORD=$(aws ssm get-parameter \
    --name /backstage/poc/POSTGRES_PASSWORD --with-decryption \
    --query Parameter.Value --output text)
```

### Step 5 — Apply Manifests in Order

```bash
# 1. Namespace
kubectl apply -f k8s/namespace.yaml

# 2. ConfigMaps
kubectl apply -f k8s/configmaps/

# 3. Storage
kubectl apply -f k8s/storage/

# 4. Data layer — wait for postgres before starting backends
kubectl apply -f k8s/workloads/postgres.yaml
kubectl apply -f k8s/workloads/redis.yaml
kubectl rollout status statefulset/postgres -n backstage
kubectl rollout status statefulset/redis -n backstage

# 5. Application workloads
kubectl apply -f k8s/workloads/frontend.yaml
kubectl apply -f k8s/workloads/backend-core.yaml
kubectl apply -f k8s/workloads/backend-catalog.yaml
kubectl apply -f k8s/workloads/backend-scaffolder.yaml
kubectl apply -f k8s/workloads/backend-techdocs.yaml

# 6. Envoy ingress — creates the AWS ELB
kubectl apply -f k8s/workloads/envoy.yaml
```

### Step 6 — Get the Envoy LB DNS and Update APP_BASE_URL

```bash
# Wait for the ELB to be provisioned (can take 1-2 minutes)
kubectl get svc envoy -n backstage -w

# Get the DNS
LB_DNS=$(kubectl get svc envoy -n backstage \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $LB_DNS
```

Once you have `$LB_DNS`, update `APP_BASE_URL` and `CORS_ORIGIN` in every backend Deployment:

```bash
# Patch each backend deployment's APP_BASE_URL env var
for dep in backend-core backend-catalog backend-scaffolder backend-techdocs; do
  kubectl set env deployment/$dep \
    -n backstage \
    APP_BASE_URL=http://$LB_DNS \
    CORS_ORIGIN=http://$LB_DNS
done
```

Then open `http://$LB_DNS` in your browser.

---

## Useful kubectl Commands

```bash
# See all pods and their status
kubectl get pods -n backstage

# Watch pods come up live
kubectl get pods -n backstage -w

# Tail logs for a service
kubectl logs -f deployment/backend-catalog -n backstage

# Tail logs for postgres
kubectl logs -f statefulset/postgres -n backstage

# Shell into a running pod for debugging
kubectl exec -it deployment/backend-catalog -n backstage -- sh

# Check postgres databases are created
kubectl exec -it statefulset/postgres -n backstage -- \
  psql -U backstage -c '\l'

# Describe a pod to see events / errors
kubectl describe pod -l app=backend-core -n backstage

# Restart a deployment (e.g. after config change)
kubectl rollout restart deployment/backend-catalog -n backstage

# Force re-pull latest image
kubectl rollout restart deployment/frontend -n backstage

# Delete and re-apply everything (nuclear option)
kubectl delete namespace backstage
kubectl apply -f k8s/namespace.yaml
# ... re-run steps 2-6 above
```

---

## Health Check URLs

All traffic goes through the Envoy LB. Use `$LB_DNS` from Step 6.

| Check | URL |
|---|---|
| React SPA | `http://$LB_DNS/` |
| Envoy admin (internal only) | `kubectl port-forward svc/envoy-admin 9901:9901 -n backstage` then `http://localhost:9901` |
| Envoy cluster health | `http://localhost:9901/clusters` |
| Catalog API | `http://$LB_DNS/api/catalog/entities` |
| Scaffolder API | `http://$LB_DNS/api/scaffolder/v2/tasks` |
| TechDocs API | `http://$LB_DNS/api/techdocs/` |

---

## SSM Parameters to Create

```bash
# Generate BACKEND_SECRET
SECRET=$(node -e "console.log(require('crypto').randomBytes(24).toString('base64'))")

aws ssm put-parameter --name /backstage/poc/BACKEND_SECRET \
  --value "$SECRET" --type SecureString --region ap-south-1

aws ssm put-parameter --name /backstage/poc/GITHUB_TOKEN \
  --value "ghp_yourtoken" --type SecureString --region ap-south-1

aws ssm put-parameter --name /backstage/poc/POSTGRES_PASSWORD \
  --value "yourpassword" --type SecureString --region ap-south-1
```

---

## Change Log

---

### [2026-09-29] — Multi-platform Dockerfile fix

**Files changed:** All 5 Dockerfiles, `docker-compose.yaml`

**What changed:** Added `ARG TARGETPLATFORM=linux/amd64` and `FROM --platform=...`
to every image stage. Added `platform: linux/amd64` to docker-compose services.

**Why:** Prevents arm64/amd64 mismatch when building on Apple Silicon for EKS (amd64).

**AWS impact:** None — build-time fix. Images pushed to ECR will be correct amd64.

**Status:** ✅ Done

---

### [2026-09-29] — Replace nginx routing with Envoy proxy as ingress

**Files changed:** `envoy.yaml` (new), `nginx.conf`, `packages/app/Dockerfile`,
`docker-compose.yaml`

**What changed:** nginx now only serves static files on port 8080.
Envoy handles all routing on port 80 with per-route timeouts and WebSocket support.

**Why:** Envoy gives us better observability, per-service timeouts, and a clean
separation between ingress and static file serving.

**AWS impact:**
- In docker-compose: Envoy listens on port 80 of the host
- In EKS: Envoy Service type=LoadBalancer creates an AWS NLB

**Status:** ✅ Done

---

### [2026-09-29] — Move deployment target from docker-compose to EKS

**Files changed:**
- `k8s/` directory — all manifests (new)
- `app-config.production.yaml` — added `APP_BASE_URL` env var support
- `docker-compose.yaml` — added `APP_BASE_URL: http://localhost` to all backends
- `deploy-on-aws.md` — complete rewrite for EKS workflow

**What changed:**
Created a full `k8s/` directory with all Kubernetes manifests:
- `namespace.yaml` — `backstage` namespace
- `configmaps/` — app-config, envoy config, postgres init script as ConfigMaps
- `secrets/` — secret template (committed) + .gitignore
- `storage/` — PVCs for postgres (20Gi), redis (2Gi), techdocs (5Gi)
- `workloads/` — StatefulSets for postgres + redis, Deployments for all app services,
  Envoy as LoadBalancer exposing port 80 via AWS NLB

**Why:**
docker-compose is local dev only. EKS is the actual deployment target.
PostgreSQL and Redis run as single-replica containers inside the cluster (POC approach).

**AWS impact:**
- **EKS cluster** must exist with EBS CSI driver add-on installed
- **ECR repositories** must be created for each image (see pre-flight checklist)
- **Node IAM role** must have ECR pull + EBS CSI permissions
- **Envoy LoadBalancer Service** will create an AWS NLB — note the DNS after deploy
- **SSM parameters** must be created before creating the K8s secret

**Status:** ✅ Manifests committed — pending first EKS deployment

---

### [YYYY-MM-DD] — Template for future entries

**Files changed:**
- `file/path.ext`

**What changed:**
_Describe the change._

**Why:**
_Reason._

**AWS impact:**
_What needs to happen on AWS as a result.
e.g.: "kubectl rollout restart deployment/backend-catalog", "ECR image re-push",
"Update SSM parameter", "EKS node group scaling"._

**Status:** ⏳ Pending / ✅ Done / ❌ Blocked

---

## Open Items

- [ ] **EKS cluster** — create with EBS CSI driver add-on
- [ ] **ECR repos** — create 5 repos (see pre-flight checklist)
- [ ] **Node IAM role** — attach ECR + EBS CSI policies
- [ ] **SSM parameters** — create BACKEND_SECRET, GITHUB_TOKEN, POSTGRES_PASSWORD
- [ ] **Build images** — run the build+push script on bastion
- [ ] **Replace `<ECR_REGISTRY>`** in all `k8s/workloads/*.yaml` files
- [ ] **Get Envoy LB DNS** — update APP_BASE_URL in backend deployments after first apply
- [ ] **StorageClass** — verify cluster has `gp2` or change to `gp3` in `k8s/storage/pvcs.yaml`
- [ ] **Decide** — HTTPS via ACM + NLB or HTTP-only for POC
