# Multi-stage build for the Vanishing Ink single-origin BEAM server.
#
# The builder stage downloads deps for all three packages, builds the
# minified Lustre client bundle, and exports the server as a
# self-contained Erlang shipment. The runtime stage carries the shipment
# plus the static client assets and runs the compiled BEAM bytecode — it
# needs Erlang, not Gleam. (The base image does still ship the Gleam
# compiler; we reuse it deliberately to keep the glibc/NIF ABI identical
# between stages, see below — but nothing in the runtime path invokes
# `gleam`.)
#
# Both stages use the Debian-based Gleam image (not Alpine), and they
# must match: the client build runs an embedded glibc-linked Bun runtime
# fetched by lustre_dev_tools (musl-incompatible), and — more subtly —
# the server shipment bundles esqlite's compiled NIF (`esqlite3_nif.so`).
# That NIF is built against the builder's libc; loading a glibc NIF on a
# musl runtime fails at boot with `fcntl64: symbol not found`. Keeping
# both stages on glibc Debian avoids both traps. (Verified: an Alpine
# runtime stage builds fine but crashes on first DB open.)
ARG GLEAM_VERSION=v1.16.0

# ---- builder ----
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang AS builder
# Copy only the manifests first and download deps in their own layer, so
# a source edit no longer invalidates the (slow) dependency fetch. All
# three manifests land before any download because client and server
# declare `shared = { path = "../shared" }`; the path dep resolves
# against shared/gleam.toml, which must already be present.
COPY ./shared/gleam.toml ./shared/manifest.toml /build/shared/
COPY ./client/gleam.toml ./client/manifest.toml /build/client/
COPY ./server/gleam.toml ./server/manifest.toml /build/server/
RUN cd /build/shared && gleam deps download
RUN cd /build/client && gleam deps download
RUN cd /build/server && gleam deps download
# Now copy full sources over the manifests and build. Editing source
# reuses the cached deps layer above.
COPY ./shared /build/shared
COPY ./client /build/client
COPY ./server /build/server
RUN cd /build/client && gleam run -m lustre/dev build --minify
RUN cd /build/server && gleam export erlang-shipment

# ---- runtime ----
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang
COPY --from=builder /build/server/build/erlang-shipment /app
COPY --from=builder /build/client/dist /app/static
WORKDIR /app
ENV HOST=0.0.0.0 PORT=8080 STATIC_DIR=/app/static DATABASE_PATH=/data/vanishing_ink.db
EXPOSE 8080
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
