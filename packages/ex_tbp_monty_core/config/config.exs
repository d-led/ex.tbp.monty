import Config

# The core is a package, so its own configuration is what a test run and a
# published build read; the application beside it configures the same keys for
# its own runs (`../../config/config.exs`), and Mix applies only the root
# project's config either way.

# A test that steps a world steps the stand-in scene unless it says otherwise:
# the core carries no Python and no MuJoCo, and a machine running its suite is
# not asked to have either.
config :ex_tbp_monty_core, world_simulator: :synthetic

# `Monty.Frameworks.Utils.KdTree` asks this once, when it builds an index: the
# native kernels are faster, the Elixir tree is the reference. A test that wants
# the reference on a machine that has the kernels flips this.
config :ex_tbp_monty_core, native_kernels?: true

config :logger, level: :warning
