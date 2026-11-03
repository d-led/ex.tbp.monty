defmodule Monty.Test.PrerequisiteRoots do
  @moduledoc """
  Monty's three data roots, pointed at a directory of the test's own.

  The prerequisites are addressed by `MONTY_DATA`, `MONTY_MODELS` and
  `MONTY_LOGS`, which are the machine's — so a test that asks what is missing
  has to own them while it runs, and hand them back afterwards.
  """

  alias Monty.Prerequisites

  @doc """
  Runs `fun` with the roots inside `root`.

  The previous values go back afterwards, including the ones that were not set,
  because a run in another test must not read this one's tree.
  """
  def with_roots(root, fun) do
    variables = [
      {"MONTY_DATA", Path.join(root, "data")},
      {"MONTY_MODELS", Path.join(root, "models")},
      {"MONTY_LOGS", Path.join(root, "logs")}
    ]

    previous = Enum.map(variables, fn {name, _} -> {name, System.get_env(name)} end)

    Enum.each(variables, fn {name, value} ->
      File.mkdir_p!(value)
      System.put_env(name, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  @doc """
  One prerequisite as it looks after a fetch: where the manifest says it belongs.

  An archive is a directory, anything else is a file, which is how
  `Prerequisites.present?/1` answers.
  """
  def plant(prerequisite) do
    if prerequisite[:extract] do
      File.mkdir_p!(Prerequisites.where_it_lands(prerequisite))
    else
      path = Prerequisites.target_path(prerequisite)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")
    end
  end
end
