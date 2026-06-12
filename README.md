# Vanishing Ink

A mobile-first eReader for OCD ERP (Exposure Response Prevention): text
disappears as you read. The aim is to remove the safety behaviour of
re-reading by making it physically impossible. Built in Gleam end to end
under Operation Luminous as the learning vehicle for the language.

## Repo layout

This repo is a Gleam monorepo. Gleam has no workspace concept, so each
sub-project is a standalone package with its own `gleam.toml` and
`manifest.toml`. The `shared` package is linked into the other two as a
local path dependency.

```
vanishing_ink/
├── shared/       # Common types, target-agnostic, used by both server and client
├── server/       # BEAM/Erlang HTTP server (Wisp + Mist), port 3000
├── client/       # Lustre SPA, compiles to JavaScript
└── Justfile      # Dev orchestration
```

## Prerequisites

- [Gleam](https://gleam.run) 1.16 or newer
- Erlang/OTP (for the BEAM server)
- [Node.js](https://nodejs.org) 20+ (gleeunit test runner for the client)
- [just](https://github.com/casey/just) (recipe runner)

The Lustre dev tools fetch their own bundled Bun runtime on first
client build — nothing else to install.

## Common tasks

| Command             | Effect                                                |
| ------------------- | ----------------------------------------------------- |
| `just dev`          | Start the BEAM server on `http://localhost:3000`      |
| `just build`        | Build the server and the client JS bundle             |
| `just server-build` | Build the BEAM server only                            |
| `just client-build` | Build the Lustre client bundle to `client/dist/`      |
| `just test`         | Run gleeunit suites across all three sub-projects     |
| `just format`       | Run `gleam format` over every source file             |
| `just clean`        | Wipe build artefacts and generated bundles            |

Run `just` with no arguments for the full recipe listing.

## Smoke check

```sh
just dev &
curl http://localhost:3000/
# => {"status":"ok"}
```

For the client, `just client-build` produces `client/dist/index.html`
mounting the Lustre app at `#app`. Serve `client/dist/` with any static
file server (or open `index.html` after adjusting the script path) to
see the bundled sample text rendered as per-word `<span>`s under
`#vi-shell` — a brief `Loading...` placeholder is replaced once the
hardcoded sample has been dispatched through the update loop.

## Deployment

The app deploys to [Fly.io](https://fly.io) as a single-origin BEAM
server. The `Dockerfile` builds the minified client bundle and the
server Erlang shipment into one image; `fly.toml` runs a single machine
with a SQLite volume and scale-to-zero. A push to `main` triggers
`.github/workflows/deploy.yml`, which deploys via Fly's remote builder
**only after** the `test` workflow passes for that commit.

### Configuration

The server reads its configuration from the environment, falling back to
the dev defaults baked in for `just run` (so local development needs no
env at all):

| Variable          | Default                  | Notes                                              |
| ----------------- | ------------------------ | -------------------------------------------------- |
| `PORT`            | `3000`                   | HTTP listen port (`8080` in the container). Must be a `1..65535` integer if set; an invalid value fails the boot rather than silently defaulting. |
| `HOST`            | `0.0.0.0`                | Bind address.                                      |
| `DATABASE_PATH`   | `./vanishing_ink.db`     | SQLite file; on Fly this lives on the volume.      |
| `STATIC_DIR`      | `../client/dist`         | Lustre bundle; `/app/static` in the container.     |
| `SECRET_KEY_BASE` | random per boot          | Signed-cookie key. **Must** be set in production.  |

`SECRET_KEY_BASE` defaults to a fresh random string each boot, which is
fine in dev but would invalidate every signed cookie on restart (and on
every scale-to-zero wake) in production. Set it once as a Fly secret so
it stays stable across machine restarts.

### First deploy (manual, one time)

```sh
# 1. Create the app without deploying (reads the committed fly.toml).
fly launch --no-deploy

# 2. Create the SQLite volume in the same region as primary_region.
fly volumes create vanishing_ink_data --region iad --size 1

# 3. Set a stable signed-cookie key (generate any 64+ char secret).
fly secrets set SECRET_KEY_BASE="$(openssl rand -hex 64)"

# 4. First deploy from your machine.
fly deploy

# 5. Mint a deploy token and add it to GitHub as the FLY_API_TOKEN
#    repository secret so CI can deploy on subsequent pushes to main.
fly tokens create deploy
```

After the one-time setup, every push to `main` that passes tests deploys
automatically.
