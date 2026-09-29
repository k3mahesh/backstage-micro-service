import { createBackend } from '@backstage/backend-defaults';

const backend = createBackend();

// Software Catalog — the core registry of all components, services, APIs, etc.
backend.add(import('@backstage/plugin-catalog-backend'));
backend.add(
  import('@backstage/plugin-catalog-backend-module-scaffolder-entity-model'),
);
// Logs catalog errors to the backend log stream
backend.add(import('@backstage/plugin-catalog-backend-module-logs'));

// Search — indexes catalog + techdocs entities and exposes /api/search
backend.add(import('@backstage/plugin-search-backend'));
backend.add(import('@backstage/plugin-search-backend-module-catalog'));
backend.add(import('@backstage/plugin-search-backend-module-techdocs'));
// Use Postgres for search index in production; falls back to in-memory in dev
backend.add(import('@backstage/plugin-search-backend-module-pg'));

// Kubernetes — surfaces cluster info alongside catalog entities
backend.add(import('@backstage/plugin-kubernetes-backend'));

backend.start();
