# Vanishing Ink

A mobile-first eReader where text disappears as you read — making it
physically impossible to go back and re-read. Built in Gleam end to end
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
client build. Set `AUTH_PASSWORD_HASH` before starting the server. See
the authentication section below.

## Common tasks

| Command             | Effect                                                |
| ------------------- | ----------------------------------------------------- |
| `just run`          | Build the client and start the server on `http://localhost:3000` |
| `just build`        | Build the server and the client JS bundle             |
| `just server-build` | Build the BEAM server only                            |
| `just client-build` | Build the Lustre client bundle to `client/dist/`      |
| `just test`         | Run gleeunit suites across all three sub-projects     |
| `just format`       | Run `gleam format` over every source file             |
| `just clean`        | Wipe build artefacts and generated bundles            |

Run `just` with no arguments for the full recipe listing.

## Smoke check

```sh
just run &
curl http://localhost:3000/api/status
# => {"status":"ok"}
```

Open `http://localhost:3000/` and sign in to use the library and reader.
The BEAM server serves the client bundle and API from the same origin.

## Authentication

The app uses one shared password. It has no users table or separate
libraries. The server protects the API, static assets, and app pages.
Only `/login` and the GET/HEAD health probe at `/api/status` are public.
Unauthenticated API requests receive `401`. Page requests redirect to
`/login` with `303`.

The middleware checks CSRF headers and authentication before serving
static files or routing requests. Scripted POST, PUT, PATCH, and DELETE
requests must send the session cookie and a matching `Origin` or `Referer`.
Without either header, CSRF protection removes the cookie and authentication
returns `401`. For local scripts, use `Origin: http://localhost:3000`.
For production scripts, use the actual HTTPS origin, including any port.

Generate a salted PBKDF2-HMAC-SHA256 verifier with Python 3:

```sh
export AUTH_PASSWORD_HASH="$(python3 - <<'PY'
import base64
import getpass
import hashlib
import secrets

password = getpass.getpass("New Vanishing Ink password: ").encode("utf-8")
if not 1 <= len(password) <= 1024:
    raise SystemExit("Password must contain 1 to 1024 UTF-8 bytes")
salt = secrets.token_bytes(16)
digest = hashlib.pbkdf2_hmac("sha256", password, salt, 600000, 32)
print("pbkdf2-sha256$600000$" + base64.b64encode(salt).decode()
      + "$" + base64.b64encode(digest).decode())
PY
)"
just run
```

Missing or invalid `AUTH_PASSWORD_HASH` prevents startup. Use a long,
unique password. Do not store the password or verifier in the repository.
The fixed verifier format uses a 16-byte salt, 600,000 iterations, and
a 32-byte digest. The login endpoint accepts URL-encoded forms only.
It limits the body to 4 KB and the password to 1,024 UTF-8 bytes.

An atomic, app-wide throttle permits at most one password attempt every
two seconds. It counts successful, unsuccessful, and malformed attempts.
Other attempts receive `429` with `Retry-After: 2`. The throttle uses
constant memory and resets on restart. An attacker can occupy the login
slots and delay legitimate login. Password derivation also permits only
one concurrent operation, including requests with delayed bodies. Existing
authenticated sessions and health probes do not consume slots. This is
not a distributed rate limiter.

Signed cookies expire after 60 days. The server checks the issue time
and rejects expired or future-issued cookies. Cookies use HttpOnly,
SameSite=Lax, and Secure, except for local HTTP development. Changing
the verifier or signing key invalidates existing sessions. There is no
individual session revocation. The server sends `Cache-Control: private,
no-store` for protected responses. Offline support remains future work.

There is no clock-skew tolerance. If the server clock moves backward,
cookies issued after the new time fail authentication until the clock
catches up. Sign in again to obtain a cookie with the current issue time.

## Deployment

The app deploys to [Fly.io](https://fly.io) as a single-origin BEAM
server. The `Dockerfile` builds the minified client bundle and the
server Erlang shipment into one image; `fly.toml` runs a single machine
with a SQLite volume and scale-to-zero. A push to `main` triggers
`.github/workflows/deploy.yml`, which deploys via Fly's remote builder
**only after** the `test` workflow passes for that commit.

### Configuration

The server reads its configuration from the environment. Most variables
have development defaults. The password verifier is always required:

| Variable          | Default                  | Notes                                              |
| ----------------- | ------------------------ | -------------------------------------------------- |
| `PORT`            | `3000`                   | HTTP listen port (`8080` in the container). Must be a `1..65535` integer if set; an invalid value fails the boot rather than silently defaulting. |
| `HOST`            | `0.0.0.0`                | Bind address.                                      |
| `DATABASE_PATH`   | `./vanishing_ink.db`     | SQLite file; on Fly this lives on the volume.      |
| `STATIC_DIR`      | `../client/dist`         | Lustre bundle; `/app/static` in the container.     |
| `SECRET_KEY_BASE` | random per boot          | Signed-cookie key, at least 64 bytes. **Must** be set in production. |
| `AUTH_PASSWORD_HASH` | none                  | Required PBKDF2 verifier. Missing or malformed values prevent startup. |

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

# 4. Set the password verifier generated above before deploying.
fly secrets set AUTH_PASSWORD_HASH="$AUTH_PASSWORD_HASH"

# 5. First deploy from your machine.
fly deploy

# 6. Mint a deploy token and add it to GitHub as the FLY_API_TOKEN
#    repository secret so CI can deploy on subsequent pushes to main.
fly tokens create deploy
```

After the one-time setup, every push to `main` that passes tests deploys
automatically.

For an existing deployment, set `AUTH_PASSWORD_HASH` before deploying
this version. Otherwise the new server refuses to start. A push to
`main` can trigger deployment automatically, so set the secret before
merging the authentication change.
