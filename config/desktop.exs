import Config

# The desktop build: the window's sidecar.
#
# This file holds only what is a property of *the build*. Every path the
# application uses is decided at run time (`config/runtime.exs`, through
# `Monty.Paths`): `:filename.basedir(:user_data, …)` evaluated here would be the
# home directory of the machine that built the release, and a window shipped
# from one machine would then look for its data in another machine's folder.
#
# The screens are the server's and are not touched: the same LiveViews, the same
# routes, the same endpoint. What differs is where they read from, and that the
# only reader is the window — see `docs/desktop.md`.

# Which repo the desktop build has is a property of the build; *where its file
# is* is not (`ExTbpMonty.Repo.SQLite.init/2`). `mix ecto.*` reads this list
# before `runtime.exs` has run, which is why it is named here at all.
config :ex_tbp_monty, ecto_repos: [ExTbpMonty.Repo.SQLite]

config :logger, level: :info
