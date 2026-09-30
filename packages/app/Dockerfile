# Frontend is pre-built on host (or CI) before docker compose build:
#   corepack yarn workspace app build
#
# This Dockerfile simply takes the pre-built static files from packages/app/dist/
# and serves them via Nginx, which also acts as the API gateway routing /api/*
# requests to the appropriate backend microservice.

# TARGETPLATFORM is injected by `docker buildx build --platform` or by the
# `platform:` key in docker-compose.yaml.  Defaults to linux/amd64 so the
# image is always EKS-compatible even when built on Apple Silicon (arm64).
ARG TARGETPLATFORM=linux/amd64
FROM --platform=${TARGETPLATFORM} nginx:1.27-alpine

RUN rm -rf /usr/share/nginx/html/*

# Copy pre-built React SPA (built on host before docker compose build)
COPY packages/app/dist /usr/share/nginx/html

# API gateway + SPA routing config
COPY nginx.conf /etc/nginx/nginx.conf

# Port 8080 — Envoy is the public ingress on :80; nginx only serves static files internally
EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
