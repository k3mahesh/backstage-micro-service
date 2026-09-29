import { createBackend } from '@backstage/backend-defaults';

const backend = createBackend();

// TechDocs — generates, stores, and serves MkDocs-based documentation sites
// In production set techdocs.publisher.type to 'awsS3' or 'googleGcs'
backend.add(import('@backstage/plugin-techdocs-backend'));

backend.start();
