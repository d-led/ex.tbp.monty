[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,mix_tasks,test}/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ]
]
