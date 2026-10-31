# syntax=docker/dockerfile:1
#
# The studio as one OTP release, built once and shipped as an image:
#
#   docker build -t ex-tbp-monty \
#     --build-arg VERSION="$(git describe --tags --always)" .
#
#   docker run --rm -e DATABASE_URL=... -e SECRET_KEY_BASE=... ex-tbp-monty \
#     /app/bin/migrate            # once per deploy, before instances start
#   docker run -p 4000:4000 -e ... ex-tbp-monty
#                                # /app/bin/server, PHX_SERVER=true
#
# Three stages, because each needs a different toolchain and only the last one
# ships: a Node image supplies the npm that `mix assets.deploy` calls, the Elixir
# image compiles the release, and a Debian runtime carries the release plus the
# shared libraries BEAM needs — no compiler, no Node, no git, no Hex cache in
# the result.
#
# Base images are pinned to dated tags rather than to `latest`, so a rebuild of
# an old commit builds the same toolchain. Dependabot (.github/dependabot.yml)
# opens a pull request when a newer one appears, and CI scans the result.
#
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=trixie-20261020-slim
ARG NODE_VERSION=24.22.1-trixie-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# --- the Node distribution ---------------------------------------------------
# `mix assets.deploy` runs `npm ci` in assets/ before it bundles. There are no
# npm packages here — esbuild and tailwind come from Mix, daisyUI and heroicons
# from deps — so npm only has to exist and find nothing to do. It still has to
# exist: the builder image does not ship it, and `npm ci` with an empty
# package.json creates no `node_modules` at all, so there is nothing to copy
# from this stage but the interpreter itself.
FROM docker.io/node:${NODE_VERSION} AS node

# --- the release -------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

# build-essential for NIFs, git for the two GitHub dependencies (heroicons and
# daisyUI), unzip for the esbuild and tailwind binaries fetched by `mix
# assets.setup`.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       build-essential git ca-certificates unzip \
  && rm -rf /var/lib/apt/lists/*

# Node and npm from the stage above — the same distribution family (trixie),
# so the binaries link against the libc that is here. The npm and npx entry
# points are symlinks in the Node image, so they are recreated here rather than
# copied as files.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

WORKDIR /app

# What the admin footer reports about this build. The values are build
# arguments rather than runtime environment, because a release should know what
# it was built from even when it starts somewhere that sets nothing —
# `mix build.info` writes them into priv/, so they travel inside the image.
ARG VERSION=dev
ARG REVISION=
ARG CI_PROVIDER=
ARG CI_WORKFLOW=
ARG CI_RUN_NUMBER=
ARG CI_RUN_URL=
ENV BUILD_VERSION=${VERSION} \
    BUILD_REVISION=${REVISION} \
    BUILD_CI_PROVIDER=${CI_PROVIDER} \
    BUILD_CI_WORKFLOW=${CI_WORKFLOW} \
    BUILD_CI_RUN_NUMBER=${CI_RUN_NUMBER} \
    BUILD_CI_RUN_URL=${CI_RUN_URL}

RUN mix local.hex --force \
  && mix local.rebar --force

# Dependencies first: a source change does not re-resolve or re-fetch them.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Compile-time configuration decides how dependencies are compiled, so it has
# to be in place before deps.compile: config.exs, the file it imports and asks
# nothing of the environment (`pythonx.exs`), and prod.exs. runtime.exs
# deliberately is not copied yet — it is read when the release boots, not when
# it is built, so a deploy-time change does not recompile the dependencies.
# A new compile-time config file belongs in this list; `mix deps.compile` says
# so loudly, by name, when it is missing.
RUN mkdir config
COPY config/config.exs config/pythonx.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
# The project's own Mix tasks (`assets.install`, `build.info`): `elixirc_paths`
# compiles them outside `lib/`, and both are called later in this build.
COPY mix_tasks mix_tasks
COPY rel rel
COPY assets assets

# `assets.setup` fetches the standalone esbuild and tailwind binaries, so the
# image bundles with the same versions a developer has locally. esbuild's comes
# from the npm registry by its own Mix task; tailwind's from GitHub's releases,
# where a redirect header larger than `:httpc`'s 10 KiB cap made the download
# fail on a URL that was perfectly good. `mix assets.install` fetches that one
# with Req, which follows the redirect and retries a transient failure itself,
# so the build has no loop of its own to get stuck in.
#
# `mix compile` comes first because `assets.setup` is this project's own task
# (`mix_tasks/assets.install.ex`): before the project is compiled, Mix has never
# heard of it.
RUN mix compile \
  && mix assets.setup \
  && mix assets.deploy

COPY config/runtime.exs config/
RUN mix build.info \
  && mix release

# --- what ships --------------------------------------------------------------
FROM ${RUNNER_IMAGE} AS runtime

ARG VERSION=dev
ARG REVISION=unknown

LABEL org.opencontainers.image.title="Elixir TBP Monty" \
      org.opencontainers.image.description="TBP Monty in Elixir" \
      org.opencontainers.image.source="https://github.com/d-led/ex.tbp.monty" \
      org.opencontainers.image.licenses="MPL-2.0" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"

# Runtime libraries the release needs: openssl for crypto, libstdc++ for NIFs,
# ncurses for the shell, libsctp for distribution, locales so UTF-8 experiment
# names sort and log correctly, tzdata for how long ago a run finished.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       ca-certificates libstdc++6 openssl libncurses6 libsctp1 locales tzdata \
  && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod

# A fixed, unprivileged uid/gid: Kubernetes' runAsNonRoot and a volume's fsGroup
# need a number, and "app" then means the same thing in every deployment.
RUN groupadd --system --gid 10001 app \
  && useradd --system --uid 10001 --gid app --home-dir /app --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder --chown=10001:10001 /app/_build/prod/rel/ex_tbp_monty ./

# Everything a non-root container has to be able to write, in one directory:
#
#   * the studio's drafts and a run's files, which it resolves as `priv/...`
#     relative to the working directory — and the release's working directory
#     is `bin/`, inside a root-owned release tree. Hence the symlink: the same
#     relative path, landing on the volume.
#   * wandb's `root_dir` (`WANDB_DIR`) and, by default, everything that means
#     "the user's own directory" — Monty's downloads go to `~/tbp`, wandb reads
#     `~/.config`, Erlang writes `~/.erlang.cookie`. `HOME` was `/app`, owned by
#     root, so all of that failed for uid 10001.
#   * `WANDB_DIR` has to exist: handed a path it cannot write to — including one
#     that is not there yet — wandb warns once and uses the system temp
#     directory, which is outside the volume.
#
# Mount a volume here (a Fly volume, a Kubernetes PVC) to keep all of it across
# restarts. `-e HOME=...` and `-e WANDB_DIR=...` at run time still win.
RUN mkdir -p /app/priv/wandb \
  && ln -s /app/priv /app/bin/priv \
  && chown -R 10001:10001 /app/priv

# This image does not talk to wandb. Monty's configs name wandb loggers, and
# the `PythonxClient` would happily open a run — but a container that reports
# somewhere else needs a credential, a network and somebody to read the result,
# and the observability this image is built around is its own: the run record in
# Postgres, the log and artifacts a run leaves in /app/priv, the /runs pages and
# /health. `disabled` is wandb's own no-op mode, so a config naming those
# handlers still runs and nothing is uploaded or written.
#
# To send runs to wandb anyway, `-e WANDB_MODE=online -e WANDB_API_KEY=...`:
# the client forwards every WANDB_* variable into the interpreter on each init,
# and `WANDB_DIR` above is where it would write.
ENV WANDB_DIR=/app/priv/wandb \
    WANDB_MODE=disabled \
    HOME=/app/priv

USER 10001:10001

EXPOSE 4000

CMD ["/app/bin/server"]
