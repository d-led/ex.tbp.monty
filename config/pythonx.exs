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
    # MuJoCo is the physics engine a MuJoCo experiment's world steps, and this is
    # the interpreter this application owns: without it here, "is MuJoCo
    # available?" is a question about whatever `python3` happens to be on the
    # PATH rather than about the deployment. It is an ordinary wheel on every
    # platform this project runs on, so it costs a dependency line and nothing
    # else. Habitat-Sim has no wheel at all — it comes from conda, which is what
    # `environment.yml` in a Monty checkout is for.
    #
    # Pinned, and deliberately *not* to the release Monty's `uv.lock` names.
    # Monty runs 3.13.0 and `ex_mujoco` compiles 3.13.0, so 3.13.0 would be the
    # tidier pin — but its macOS wheel loads a bundled `libsdf_plugin.dylib`
    # that asks for `@rpath/mujoco.framework/Versions/A/libmujoco.3.13.0.dylib`,
    # and the interpreter this application embeds has no such rpath, so
    # `import mujoco` fails inside it (`no LC_RPATH's found`). What the pin is
    # for is agreement, not the number: measured on this Mac, 3.13.0 and 4.0.1
    # render the same scene to the same picture (mean
    # `[168.41, 151.68, 134.09]` each, identical pixel for pixel), which is why
    # `docs/monty-differences.md` §2.48 is closed with the two worlds at this
    # pair of versions. A release that changes the shading is a version to
    # re-measure, not to float onto.
    "mujoco==4.0.1",
    # What the world (`priv/monty_py/world.py`) is written against: the scene
    # and its images from `mujoco`, the arithmetic from `numpy`, and the `wxyz`
    # rotations an agent's state carries from `numpy-quaternion`. Nothing else,
    # because `world.py` imports nothing else.
    "numpy",
    "numpy-quaternion",
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
