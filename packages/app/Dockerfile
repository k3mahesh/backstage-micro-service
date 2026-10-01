ARG TARGETPLATFORM=linux/amd64

# ── Stage 1: Build React SPA ──────────────────────────────────────────────────
FROM --platform=${TARGETPLATFORM} node:22-bookworm-slim AS build

WORKDIR /app

# Copy workspace definition files first (better layer caching)
COPY package.json yarn.lock .yarnrc.yml ./
COPY packages/app/package.json ./packages/app/
COPY packages/backend-core/package.json ./packages/backend-core/
COPY packages/backend-catalog/package.json ./packages/backend-catalog/
COPY packages/backend-scaffolder/package.json ./packages/backend-scaffolder/
COPY packages/backend-techdocs/package.json ./packages/backend-techdocs/

RUN corepack enable && yarn install --frozen-lockfile

# Copy source and build
# app-config.yaml is required at build time so Backstage can bake app.title,
# app.baseUrl etc. into the JS bundle. Without it the app falls back to
# "mock-config" and throws "Missing required config value at 'app.title'".
COPY app-config.yaml ./
COPY packages/app ./packages/app
RUN yarn workspace app build

# ── Stage 2: Serve with nginx ─────────────────────────────────────────────────
FROM --platform=${TARGETPLATFORM} nginx:1.27-alpine

RUN rm -rf /usr/share/nginx/html/*

COPY --from=build /app/packages/app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf

# Port 8080 — Envoy is the public ingress on :80; nginx only serves static files internally
EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
