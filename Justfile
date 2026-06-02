# Vanishing Ink — dev orchestration.
#
# Each sub-project (shared, server, client) is a standalone Gleam
# package with its own manifest. These recipes wrap the per-package
# commands so the root of the repo is a single entry point for the
# common dev loop. The `shared` package compiles on demand as a path
# dependency of server and client and has no recipe of its own.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Print the recipe list when run with no arguments.
default:
    @just --list --unsorted

# Build the client bundle, then start the BEAM server (port 3000).
run: client-build
    cd server && gleam run

# Build the server and the client bundle.
build: server-build client-build

# Build the Erlang/BEAM server.
server-build:
    cd server && gleam build

# Build the Lustre client to a static JS bundle in client/dist.
client-build:
    cd client && gleam run -m lustre/dev build

# Run gleeunit suites across shared, server, and client.
test:
    cd shared && gleam test
    cd server && gleam test
    cd client && gleam test

# Format every .gleam source file.
format:
    gleam format shared/src shared/test
    gleam format server/src server/test
    gleam format client/src client/test

# Wipe build artefacts and generated bundles.
clean:
    rm -rf shared/build server/build client/build
    rm -rf client/dist client/.lustre
