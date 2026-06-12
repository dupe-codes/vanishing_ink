# Multi-stage build for the Vanishing Ink single-origin BEAM server.
#
# The builder stage downloads deps for all three packages, builds the
# minified Lustre client bundle, and exports the server as a
# self-contained Erlang shipment. The runtime stage carries only the
# shipment plus the static client assets — no Gleam toolchain.
#
# The client build runs an embedded Bun runtime fetched by
# lustre_dev_tools. Bun is glibc-linked, so the builder uses the
# Debian-based Gleam image (not Alpine) to avoid musl incompatibility.
# The runtime stage stays on Alpine — it only runs the Erlang VM.
ARG GLEAM_VERSION=v1.16.0

# ---- builder ----
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang AS builder
COPY ./shared /build/shared
COPY ./client /build/client
COPY ./server /build/server
RUN cd /build/shared && gleam deps download
RUN cd /build/client && gleam deps download
RUN cd /build/server && gleam deps download
RUN cd /build/client && gleam run -m lustre/dev build --minify
RUN cd /build/server && gleam export erlang-shipment

# ---- runtime ----
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine
COPY --from=builder /build/server/build/erlang-shipment /app
COPY --from=builder /build/client/dist /app/static
WORKDIR /app
ENV HOST=0.0.0.0 PORT=8080 STATIC_DIR=/app/static DATABASE_PATH=/data/vanishing_ink.db
EXPOSE 8080
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]
