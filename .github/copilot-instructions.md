# SillyTavern Copilot Instructions

## Build, test, and lint commands

- Install dependencies from the repository root with `npm install`.
- Start the app from the repository root with `npm start`. This launches `server.js`, parses CLI/config settings, and compiles the frontend library bundle during startup.
- Alternate runtime entry points are defined in the root `package.json`: `npm run debug`, `npm run start:global`, `npm run start:electron`, `npm run start:deno`, `npm run start:bun`, and `npm run start:no-csrf`.
- There is no dedicated root `npm run build` script. Frontend library bundling is handled by `webpack.config.js` and is triggered from the server startup path (`src/server-main.js` via `webpack-serve.js`).
- Lint the main app from the repository root with `npm run lint` or autofix with `npm run lint:fix`.
- Tests live in the `tests/` subproject, so run them from `tests/`:
  - `cd tests && npm test` runs Jest unit tests and Playwright E2E tests.
  - `cd tests && npm run test:unit` runs the Jest suite.
  - `cd tests && npm run test:e2e` runs the Playwright suite.
  - Single Jest file: `cd tests && node --experimental-vm-modules node_modules/jest/bin/jest.js --config jest.config.json util.test.js`
  - Single Jest test by name: `cd tests && node --experimental-vm-modules node_modules/jest/bin/jest.js --config jest.config.json util.test.js -t "flattenSchema"`
  - Single Playwright file: `cd tests && npx playwright test sample.e2e.js`
  - Single Playwright test by name: `cd tests && npx playwright test sample.e2e.js -g "should be titled"`
- `tests/playwright.config.js` uses `http://127.0.0.1:8000` as `baseURL`, so E2E runs assume a local SillyTavern server is already running on port 8000.
- The tests subproject also has its own lint commands: `cd tests && npm run lint` and `cd tests && npm run lint:fix`.

## High-level architecture

- `server.js` is the only root entry point. It parses CLI/config values with `src/command-line.js`, sets `globalThis.DATA_ROOT` and `globalThis.COMMAND_LINE_ARGS`, switches into the server directory, and then imports `src/server-main.js`.
- `src/server-main.js` builds the Express app and owns the runtime boot order: security/compression/body parsing, optional auth and whitelist middleware, cookie-session and CSRF setup, static asset hosting, public routes, authenticated routes, upload handling, pre-start migrations, plugin loading, webpack compilation, and final listen/logging.
- Route mounting is centralized in `src/server-startup.js`. Public API access starts with `users-public.js`; almost everything else is mounted after `requireLoginMiddleware`, usually under `/api/...`.
- The backend is organized by endpoint domains under `src/endpoints/`. Large features such as characters, chats, world info, tokenizers, search, vectors, image generation, and provider-specific backends each expose an Express router that gets mounted centrally.
- The browser client is not a small SPA entry; `public/script.js` imports a large graph of feature modules from `public/scripts/` and coordinates most UI behavior there.
- Third-party browser libraries are bundled separately from application code: `public/lib.js` is the webpack entry, and `webpack.config.js` writes the bundle into either `dist/` or a data-root-specific cache/output directory depending on environment.
- User content is data-root driven rather than stored directly in `public/`. `src/constants.js` defines `USER_DIRECTORY_TEMPLATE`, and `src/users.js` resolves per-user directories for characters, chats, groups, assets, settings, vectors, backups, workflows, and uploads.
- The server can load optional server-side plugins from `plugins/` through `src/plugin-loader.js`. Plugins initialize against an Express router and are mounted under `/api/plugins/<plugin-id>`.

## Key conventions

- This repository is ESM-first (`"type": "module"` in the root package). Follow the existing import/export style and preserve the explicit `.js` module specifiers used in server code.
- Do not hardcode paths into `public/` or `data/` when working on user-facing content. Server code generally resolves paths from `globalThis.DATA_ROOT`, `req.user.directories`, and `USER_DIRECTORY_TEMPLATE` so features remain per-user and compatible with `--dataRoot` / `--global`.
- When adding or changing backend API behavior, preserve the router-per-domain pattern: define an Express router in `src/endpoints/...` and wire it through `src/server-startup.js` instead of mounting ad hoc routes in random files.
- The auth boundary matters: routes above `requireLoginMiddleware` are intentionally public, while most `/api/...` routes are private. Keep that split intact when adding new endpoints.
- Deprecated endpoints are still supported through redirects in `src/server-startup.js`. If an API path moves, update both the canonical route and the redirect table.
- Client-side work usually belongs in `public/scripts/` modules imported by `public/script.js`, not in inline HTML scripts or server-side files.
- Server plugins must expose `info.id`, `info.name`, `info.description`, and an `init(router)` function. Plugin IDs are restricted to lowercase alphanumeric characters, `_`, and `-`.
- Jest tests use Node ESM mode (`--experimental-vm-modules`) from the `tests/` package. If you add or run unit tests, use the `tests/jest.config.json` entry point rather than assuming a root-level Jest setup.
- Avoid AI-generated noise that the project explicitly calls out in `CONTRIBUTING.md`: do not add unrelated comments, excessive logging, or changes that ignore local conventions.
