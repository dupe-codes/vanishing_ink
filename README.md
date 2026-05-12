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
see "Hello from Vanishing Ink" in the browser.
