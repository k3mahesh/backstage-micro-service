# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM node:22-bookworm-slim AS build

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      python3 make g++ cmake libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

RUN corepack enable

WORKDIR /app

COPY package.json yarn.lock .yarnrc.yml tsconfig.json ./
COPY packages/ ./packages/

RUN yarn install --immutable

RUN yarn workspace backend-scaffolder build

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM node:22-bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends libsqlite3-dev && \
    rm -rf /var/lib/apt/lists/*

USER node
WORKDIR /app

COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/packages/backend-scaffolder/dist ./packages/backend-scaffolder/dist
COPY --from=build --chown=node:node /app/packages/backend-scaffolder/package.json ./packages/backend-scaffolder/package.json

COPY --chown=node:node app-config.yaml app-config.production.yaml ./

EXPOSE 7009

CMD ["node", "packages/backend-scaffolder", \
     "--config", "app-config.yaml", \
     "--config", "app-config.production.yaml"]
