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

# The sidecar has no console, and OTP's console handler writes to the `user`
# process (`logger_std_h:write_to_dev/2`). Without one, every line pays a failed
# write and OTP's apology on stderr — "Failed to write log message to stdout,
# trying stderr" — before arriving there anyway, so the window's console doubled
# every line and buried the real ones. The window drains both streams
# (`src-tauri/src/main.rs:388-453`), so the log goes to stderr directly and no
# write can fail that way.
config :logger, :default_handler, config: %{type: :standard_error}
