defmodule ExTbpMonty.EmbeddedPython do
  @moduledoc """
  The Python this application carries, asked rather than guessed.

  Monty's loggers call the `wandb` client from inside the BEAM through
  `pythonx`, which loads a CPython into the running node. That interpreter is not
  something an operator installs or a page downloads: the environment is built
  when the release is *compiled* (uv fetches it then, which is why the image is
  large) and `pythonx` initialises it when the application boots. Nothing is
  fetched and nothing is written at run time.

  So the two things worth reporting are the ones that can be wrong at run time:

    * whether the interpreter answered at all — a page that says "prerequisites
      present" while the interpreter is missing would be lying about what a run
      with a wandb logger will do;
    * where a wandb run would go, which wandb decides from `WANDB_MODE` and
      which the container image sets to `disabled`.

  The answer cannot change while the node runs, so it is read once and kept in
  `:persistent_term` — the same shape `ExTbpMonty.BuildInfo` uses.
  """

  @term {__MODULE__, :version}
  @imports {__MODULE__, :imports}

  @doc """
  The interpreter's version, or why it could not be asked.

      iex> ExTbpMonty.EmbeddedPython.version()
      {:ok, "3.13.5"}
  """
  @spec version() :: {:ok, String.t()} | {:error, String.t()}
  def version do
    case :persistent_term.get(@term, :unloaded) do
      :unloaded -> ask() |> remember()
      version -> version
    end
  end

  @doc """
  What wandb will do with a run, from the environment the interpreter inherits.

  `online` is wandb's own default when nothing is set: a run then tries to sync,
  and says so if it cannot.
  """
  @spec wandb_mode() :: String.t()
  def wandb_mode do
    case System.get_env("WANDB_MODE") do
      nil -> "online"
      "" -> "online"
      mode -> mode
    end
  end

  @doc """
  Whether the interpreter this application carries can import a module.

  "Is MuJoCo here?" is a question about *this* interpreter: `config/pythonx.exs`
  is where the build installs packages into it, and the answer travels with the
  release. Asking `python3` on the PATH instead answers a question about the
  operator's machine — which is how a deployment with MuJoCo in it came to report
  that MuJoCo was missing.

  Asked once and kept, like the version: the environment cannot change while the
  node runs.
  """
  @spec imports?(String.t()) :: boolean()
  def imports?(module) when is_binary(module) do
    # Before the lookup, so a name that is not a module can never be cached and
    # can never reach the interpreter as anything but a lookup.
    unless Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_.]*\z/, module) do
      raise ArgumentError, "not a module name: #{inspect(module)}"
    end

    key = {@imports, module}

    case :persistent_term.get(key, :unloaded) do
      :unloaded ->
        answer = ask_import(module)

        # A no is not cached for the same reason a failed version is not: an
        # interpreter that could not answer at one moment is worth asking again.
        if answer, do: :persistent_term.put(key, true)

        answer

      true ->
        true
    end
  end

  @doc """
  Drops the cached version. The suite calls this: `:persistent_term` is not
  rolled back between tests.
  """
  @spec forget() :: :ok
  def forget do
    :persistent_term.erase(@term)
    :ok
  end

  defp ask do
    {code, _globals} = Pythonx.eval("import sys; sys.version.split()[0]", %{})
    {:ok, Pythonx.decode(code)}
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  # The name is passed as a global rather than interpolated into the source, so
  # this stays a lookup rather than a line of code.
  defp ask_import(module) do
    {code, _globals} =
      Pythonx.eval(
        "import importlib.util\nimportlib.util.find_spec(MODULE.decode()) is not None",
        %{"MODULE" => module}
      )

    Pythonx.decode(code) == true
  rescue
    _cannot_ask -> false
  end

  # A failure is not cached: an interpreter that did not answer at one moment is
  # worth asking again, and the success is the answer that cannot change.
  defp remember({:ok, _version} = ok) do
    :persistent_term.put(@term, ok)
    ok
  end

  defp remember(error), do: error
end
