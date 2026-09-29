# Frontend is pre-built on host (or CI) before docker compose build:
#   corepack yarn workspace app build
#
# This Dockerfile simply takes the pre-built static files from packages/app/dist/
# and serves them via Nginx, which also acts as the API gateway routing /api/*
# requests to the appropriate backend microservice.

FROM nginx:1.27-alpine

RUN rm -rf /usr/share/nginx/html/*

# Copy pre-built React SPA (built on host before docker compose build)
COPY packages/app/dist /usr/share/nginx/html

# API gateway + SPA routing config
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
