defmodule Monty.Frameworks.Loggers.WandbHandlers.PythonxClient do
  @moduledoc """
  The `wandb` client Monty's handlers call, reached through an embedded interpreter.

  Not a Monty class: Monty's `WandbWrapper` calls the `wandb` module directly, and
  this is that call, made from the BEAM. `pythonx` runs Python in-process, so a run
  is not a port to keep alive but a map of Python globals that Elixir threads from
  one call to the next — `init/2` answers it, `log/2` and `finish/1` take it back.

  ## Why the payloads are JSON

  `pythonx` encodes Elixir values into Python ones, and how it maps an atom, a
  struct or a tuple is its business rather than Monty's. Everything here crosses as
  JSON text and is `json.loads`ed on the other side, so what wandb receives is the
  same data whatever shape the logger happened to build it in — and a value that
  cannot be JSON is a value that would not have reached wandb anyway.

  ## Where a run goes

  Nothing here decides: wandb reads `WANDB_MODE` and `WANDB_DIR` from the
  environment, so a test can point a run at a temporary directory in offline mode
  and a deployment can sync it later, without this module knowing either.
  """

  @init_code """
  import json
  import os

  # The interpreter is started once, at boot, and inherits the environment then;
  # `System.put_env/2` afterwards never reaches it. So the BEAM's view of the
  # `WANDB_*` variables is handed over on every `init`, and both sides agree about
  # where a run goes and whether it syncs.
  os.environ.update(json.loads(environment))

  import wandb

  run = wandb.init(**json.loads(options))
  """

  @doc """
  Opens a run and answers the interpreter's globals, which are the run's handle.

  `name`, `group`, `resume`, `id` and `tags` are Monty's own arguments to
  `wandb.init`; `config` is the experiment's, sent whole.
  """
  @spec init(map()) :: {:ok, map()} | {:error, term()}
  def init(attributes) do
    variables = %{
      "options" => attributes |> options() |> Jason.encode!(),
      "environment" => environment() |> Jason.encode!()
    }

    run(@init_code, variables)
  end

  # `id`, `group` and `tags` are only passed when they have a value: Monty passes
  # `id=self.wandb_id or ""`, and this wandb refuses an empty run id outright. A
  # config that names none gets a run wandb names, which is what Monty's own
  # default (`wandb.util.generate_id`) does on the Python side.
  defp options(attributes) do
    [
      {"name", attributes["name"]},
      {"project", "Monty"},
      {"config", Map.get(attributes, "config", %{})},
      {"resume", attributes["resume"]},
      {"group", attributes["group"]},
      {"id", attributes["id"]},
      {"tags", attributes["tags"]}
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  @doc "Reports one payload — a table, a number, whatever a handler built."
  @spec log(map(), term()) :: {:ok, map()} | {:error, term()}
  def log(globals, payload) do
    run(
      "import json\nrun.log(json.loads(payload))",
      Map.put(globals, "payload", Jason.encode!(payload))
    )
  end

  @doc "Finishes the run the globals belong to."
  @spec finish(map()) :: :ok | {:error, term()}
  def finish(globals) do
    case run("run.finish()", globals) do
      {:ok, _globals} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp environment do
    for {key, value} <- System.get_env(), String.starts_with?(key, "WANDB_"), into: %{} do
      {key, value}
    end
  end

  # A Python exception is a failed call and not a crashed application: a logger
  # that cannot reach wandb says so and the run carries on, which is the rule this
  # port's handlers already follow.
  defp run(code, variables) do
    {_result, globals} = Pythonx.eval(code, variables)
    {:ok, globals}
  rescue
    exception -> {:error, {:wandb, Exception.message(exception)}}
  end
end
