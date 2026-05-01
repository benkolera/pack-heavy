# syntax=docker/dockerfile:1.7
#
# Multi-stage build for packheavy.
#
# Stage 1 (build) — compile Elixir release with assets digested.
# Stage 2 (runtime) — debian-slim with the OTP runtime libs the release
# needs. Final image is around 90 MB.

# Pin Elixir + OTP. Match these to the local toolchain (currently 1.19.5
# / OTP 28).
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.0.2

# hexpm/elixir only publishes snapshot tags, so the builder must point
# at one that actually exists on Docker Hub. Bump when stale; check
# https://hub.docker.com/r/hexpm/elixir/tags for the current list.
ARG BUILDER_DEBIAN=bookworm-20260421-slim
# Runner can roll — security patches land automatically and we rebuild
# every deploy.
ARG RUNNER_DEBIAN=bookworm-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${BUILDER_DEBIAN}"
ARG RUNNER_IMAGE="debian:${RUNNER_DEBIAN}"

# ---------- builder ----------
FROM ${BUILDER_IMAGE} AS builder

# Install build deps
RUN apt-get update -y && apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# RDS Postgres terminates connections with TLS using AWS's PKI. Pull
# the global cert bundle here in the builder so the runtime stage
# doesn't need curl.
RUN curl -fsSL -o /tmp/rds-global-bundle.pem \
      https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

# Prepare build dir
WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Build env
ENV MIX_ENV=prod

# Install mix deps first (cached unless mix.lock changes)
COPY mix.exs mix.lock ./
COPY config/config.exs config/prod.exs config/
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy assets sources required by the asset toolchain
COPY assets assets
COPY priv priv
COPY lib lib

# Build assets (tailwind + esbuild minified, then phx.digest)
RUN mix assets.deploy

# Compile + assemble release. config/runtime.exs is read at boot, not now.
COPY config/runtime.exs config/

# Release overlays (bin/migrate, bin/server)
COPY rel rel

RUN mix release

# ---------- runtime ----------
FROM ${RUNNER_IMAGE} AS runtime

RUN apt-get update -y && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# RDS Postgres CA bundle from the builder. runtime.exs points
# Postgrex's :cacertfile here.
COPY --from=builder /tmp/rds-global-bundle.pem /etc/ssl/certs/rds-global-bundle.pem

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Non-root runtime user
RUN groupadd --system --gid 1000 app && \
    useradd  --system --uid 1000 --gid 1000 --home /app app && \
    chown app:app /app
USER app:app

# Copy assembled release
COPY --from=builder --chown=app:app /app/_build/prod/rel/packheavy ./

ENV HOME=/app PHX_SERVER=true PORT=4000
EXPOSE 4000

# bin/server runs migrations then starts the endpoint
CMD ["/app/bin/server"]
