# backstage-micro-service

A [Backstage](https://backstage.io) instance scaffolded with `@backstage/create-app`.

## Prerequisites

- Node.js 22 or 24 (this project pins `"engines": { "node": "22 || 24" }` in `package.json`)
- Yarn (managed automatically via Corepack — no global install needed)
- Python 3 and standard build tools (needed to compile native deps like `better-sqlite3`)

Enable Corepack once per machine if you haven't already:

```sh
corepack enable
```

## Install

```sh
yarn install
```

> **Note:** This repo pins `"got": "npm:11.8.5"` in the root `package.json` `resolutions` field.
> Without it, `yarn install` fails with an `ENOENT` error trying to apply a patch
> (`got-npm-11.8.2-*.patch`) that a transitive dependency (`@yarnpkg/core`, pulled in by
> `@backstage/cli`) references but never ships. If you regenerate `yarn.lock` from scratch and
> hit that error again, keep this override in place.

## Run in development

```sh
yarn start
```

This starts both the frontend and backend in watch mode:

- Frontend: http://localhost:3000
- Backend API: http://localhost:7007

The default auth provider is "guest", so you can log in without configuring any identity
provider.

## Other useful commands

```sh
yarn build:all      # Build all packages
yarn build:backend   # Build only the backend package
yarn test            # Run unit tests
yarn test:e2e        # Run Playwright e2e tests
yarn lint:all        # Lint the whole repo
yarn tsc              # Type-check the whole repo
```

## Project structure

- `packages/app` — the Backstage frontend
- `packages/backend` — the Backstage backend
- `app-config.yaml` — local development configuration
- `app-config.production.yaml` — production configuration overrides
- `catalog-info.yaml` — this project's own Backstage catalog entity

## Next steps

- Configure a real auth provider in `app-config.yaml` (GitHub, Google, etc.) instead of `guest`.
- Point the catalog at real component/entity locations.
- Configure a Postgres database for production use (SQLite is used by default in development).

See the [official Backstage docs](https://backstage.io/docs) for more.
