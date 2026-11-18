defmodule ExTbpMonty.SamplePlugins do
  @moduledoc """
  The two sample plugin nodes, as the page sees them.

  A studio does not start processes on the machine it runs on; a **window** does,
  and only where the two example plugin nodes are beside its release (`plugins/`
  beside the release, which in a checkout is `_build/desktop/plugins`). A packaged
  window has none — the two ship as applications beside it — so what a page can do
  here is a seam: this module names the implementation in configuration —
  `config/desktop.exs` points it at the desktop's own server — and every other
  build answers "this build carries none".
  `lib/` never names a `Desktop.*` module, which is the rule that keeps the
  server and the window one application.

  Three answers, because a control needs all three: whether the nodes are here at
  all, how to start them, and how to stop them again. `start/0` answers with the
  names it started rather than `:ok`, so a page can say what happened.
  """

  @doc "Whether this build ships the sample plugin nodes."
  @callback available?() :: boolean()

  @doc """
  Starts them, joined to this node.

  `{:ok, names}` for the nodes that are now running — already-running ones
  included, because a control that a person presses twice must not be an error.
  `{:error, sentence}` when it could not: no nodes here, or no node name to join.
  """
  @callback start() :: {:ok, [String.t()]} | {:error, String.t()}

  @doc "Stops whichever of them this node started, and is silent about the rest."
  @callback stop() :: :ok

  @doc "The implementation this build configured, or `nil`."
  @spec implementation() :: module() | nil
  def implementation, do: Application.get_env(:ex_tbp_monty, :sample_plugins)

  @doc "Whether this build ships the sample plugin nodes."
  @spec available?() :: boolean()
  def available?, do: answer(:available?, false) == true

  @doc "Starts them; see `c:start/0`."
  @spec start() :: {:ok, [String.t()]} | {:error, String.t()}
  def start, do: answer(:start, {:error, "this build carries no sample plugin nodes"})

  @doc "Stops them; see `c:stop/0`."
  @spec stop() :: :ok
  def stop, do: answer(:stop, :ok)

  defp answer(callback, nothing_here) do
    case implementation() do
      nil -> nothing_here
      module -> apply(module, callback, [])
    end
  end
end
