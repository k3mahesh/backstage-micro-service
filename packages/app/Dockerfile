ARG TARGETPLATFORM=linux/amd64

# ── Stage 1: Build React SPA ──────────────────────────────────────────────────
FROM --platform=${TARGETPLATFORM} node:22-bookworm-slim AS build

# Build-time variables — passed via --build-arg when building this image.
# The Backstage CLI substitutes ${APP_BASE_URL} and ${BACKEND_BASE_URL}
# references in packages/app/app-config.yaml into the compiled JS bundle.
# Values are set in scripts/build-push-ecr.sh from host environment variables.
ARG APP_BASE_URL
ARG BACKEND_BASE_URL
ENV APP_BASE_URL=${APP_BASE_URL} \
    BACKEND_BASE_URL=${BACKEND_BASE_URL}

WORKDIR /app

# Copy workspace definition files first (better layer caching)
COPY package.json yarn.lock .yarnrc.yml ./
COPY packages/app/package.json ./packages/app/
COPY packages/backend-core/package.json ./packages/backend-core/
COPY packages/backend-catalog/package.json ./packages/backend-catalog/
COPY packages/backend-scaffolder/package.json ./packages/backend-scaffolder/
COPY packages/backend-techdocs/package.json ./packages/backend-techdocs/

RUN corepack enable && yarn install --frozen-lockfile

# Use the frontend-specific app-config (packages/app/app-config.yaml).
# It uses ${APP_BASE_URL} and ${BACKEND_BASE_URL} references which the
# Backstage CLI substitutes from ENV above during `yarn workspace app build`.
COPY packages/app ./packages/app
RUN cp packages/app/app-config.yaml app-config.yaml && \
    yarn workspace app build

# ── Stage 2: Serve with nginx ─────────────────────────────────────────────────
FROM --platform=${TARGETPLATFORM} nginx:1.27-alpine

RUN rm -rf /usr/share/nginx/html/*

COPY --from=build /app/packages/app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/nginx.conf

# Port 8080 — Envoy is the public ingress on :80; nginx only serves static files internally
EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
