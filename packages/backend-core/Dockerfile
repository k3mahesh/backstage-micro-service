# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM node:22-bookworm-slim AS build

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

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM node:22-bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

USER node
WORKDIR /app

# Copy installed node_modules and built dist
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/packages/backend-core/dist ./packages/backend-core/dist
COPY --from=build --chown=node:node /app/packages/backend-core/package.json ./packages/backend-core/package.json
COPY --from=build --chown=node:node /app/packages/app/dist ./packages/app/dist
COPY --from=build --chown=node:node /app/packages/app/package.json ./packages/app/package.json

COPY --chown=node:node examples ./examples
COPY --chown=node:node app-config.yaml app-config.production.yaml ./

EXPOSE 7007

CMD ["node", "packages/backend-core", \
     "--config", "app-config.yaml", \
     "--config", "app-config.production.yaml"]
