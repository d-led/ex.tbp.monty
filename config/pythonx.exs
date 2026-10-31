import Config

# Monty's wandb loggers call the Python `wandb` client, and this is the interpreter
# they get: one the application manages itself — downloaded and built by uv at
# compile time, initialised on boot — rather than one somebody has to install and
# keep in step on each machine.
config :pythonx, :uv_init,
  pyproject_toml: """
  [project]
  name = "ex_tbp_monty"
  version = "0.0.0"
  requires-python = "==3.13.*"
  dependencies = [
    "wandb==0.19.1"
  ]
  """
