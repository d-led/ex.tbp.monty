import Config

# Monty's wandb loggers call the Python `wandb` client, and this is the interpreter
# they get: one the application manages itself — downloaded and built by uv at
# compile time, initialised on boot — rather than one somebody has to install and
# keep in step on each machine.
# The pin moves with the `wandb-core` binary the wheel carries. It is a Go
# program built with whatever toolchain the release used, and 0.19.1's was built
# with go1.22 — sixty known vulnerabilities in the Go standard library and its
# dependencies, in a binary the image scan sees. The calls below (`wandb.init`,
# `run.log`, `run.finish`) have been the same for years; the toolchain has not.
config :pythonx, :uv_init,
  pyproject_toml: """
  [project]
  name = "ex_tbp_monty"
  version = "0.0.0"
  requires-python = "==3.13.*"
  dependencies = [
    "wandb==0.31.0",
    # Floors, not pins: these arrive as wandb's own dependencies, and the version
    # that lands is the one a scanner reads. `wandb==0.31.0` pulls urllib3 2.7.0
    # and msgpack 1.1.2, each with a fix above it — a TLS-interception and a
    # denial-of-service in a client this application does start, so raising them
    # is a real fix and not a quieter report. The pins we mean stay pinned; these
    # are the ones we do not.
    "setuptools>=84.2.1",
    "urllib3>=2.8.0",
    "msgpack>=1.2.4"
  ]
  """
