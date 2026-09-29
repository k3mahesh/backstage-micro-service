import { createBackend } from '@backstage/backend-defaults';

const backend = createBackend();

// Serves the built React frontend as static files
backend.add(import('@backstage/plugin-app-backend'));

// Proxies external services on behalf of the frontend
backend.add(import('@backstage/plugin-proxy-backend'));

// Auth: guest provider for local dev — replace with OIDC/GitHub in production
backend.add(import('@backstage/plugin-auth-backend'));
backend.add(import('@backstage/plugin-auth-backend-module-guest-provider'));
backend.add(import('@backstage/plugin-auth-backend-module-github-provider'));

// Permissions / RBAC
backend.add(import('@backstage/plugin-permission-backend'));
backend.add(
  import('@backstage/plugin-permission-backend-module-allow-all-policy'),
);

// User settings (theme, starred entities, etc.)
backend.add(import('@backstage/plugin-user-settings-backend'));

// Notifications + real-time signals (WebSocket)
backend.add(import('@backstage/plugin-notifications-backend'));
backend.add(import('@backstage/plugin-signals-backend'));

// MCP Actions (AI tooling)
backend.add(import('@backstage/plugin-mcp-actions-backend'));

backend.start();
