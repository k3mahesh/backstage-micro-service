# TARGETPLATFORM is injected by `docker buildx build --platform` or by the
# `platform:` key in docker-compose.yaml.  Defaults to linux/amd64 so that
# native modules (better-sqlite3, cpu-features, …) are always compiled for
# the same architecture as the runtime image — required for EKS (amd64) and
# avoids arm64/amd64 mismatch when building on Apple Silicon.
ARG TARGETPLATFORM=linux/amd64

# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM --platform=${TARGETPLATFORM} node:22-bookworm-slim AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      python3 make g++ cmake libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

RUN corepack enable

WORKDIR /app

# Copy entire monorepo — needed for yarn workspace resolution
COPY package.json yarn.lock .yarnrc.yml tsconfig.json ./
COPY packages/ ./packages/

# Install all dependencies (yarn.lock ensures reproducible install)
RUN yarn install --immutable

# Build only this backend service
RUN yarn workspace backend-core build

# Extract the bundle so dist/index.cjs.js is available as a plain file
RUN tar xzf packages/backend-core/dist/bundle.tar.gz

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
# Re-declare ARG so it is visible in this stage (ARG scope resets per stage).
ARG TARGETPLATFORM=linux/amd64
FROM --platform=${TARGETPLATFORM} node:22-bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

USER node
WORKDIR /app

# Copy installed node_modules and the extracted built files
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/package.json ./package.json
COPY --from=build --chown=node:node /app/packages/backend-core/dist/index.cjs.js ./packages/backend-core/dist/index.cjs.js
COPY --from=build --chown=node:node /app/packages/backend-core/dist/index.cjs.js.map ./packages/backend-core/dist/index.cjs.js.map
COPY --from=build --chown=node:node /app/packages/backend-core/package.json ./packages/backend-core/package.json
COPY --from=build --chown=node:node /app/packages/app/dist ./packages/app/dist
COPY --from=build --chown=node:node /app/packages/app/package.json ./packages/app/package.json

COPY --chown=node:node examples ./examples
COPY --chown=node:node app-config.yaml app-config.production.yaml ./

EXPOSE 7007

CMD ["node", "packages/backend-core", \
     "--config", "app-config.yaml", \
     "--config", "app-config.production.yaml"]
