import { createBackend } from '@backstage/backend-defaults';

const backend = createBackend();

// Scaffolder — runs software templates (repo creation, PR raising, etc.)
backend.add(import('@backstage/plugin-scaffolder-backend'));

// GitHub actions: create repos, push code, open PRs, manage webhooks
backend.add(import('@backstage/plugin-scaffolder-backend-module-github'));

// Sends Backstage notifications when scaffold tasks complete/fail
backend.add(
  import('@backstage/plugin-scaffolder-backend-module-notifications'),
);

backend.start();
