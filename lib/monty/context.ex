defmodule Monty.Context do
  @moduledoc """
  What a module needs to know about the run it is part of.

  Mirrors `tbp/monty/context.py::RuntimeContext`. Python threads one mutable
  `RandomState` through every module; here `rng` is the handle of the episode's
  one stream (`Monty.Random.Stream`), and a module draws from it in the order it
  is stepped — so the draws are NumPy's, in Monty's order, and a run is still a
  function of its episode seed.

  `rng_for/2` is the older arrangement, kept for the sites that have not been
  moved onto the stream yet (the environment's noise transforms and the message
  noise of a camera, which draw per module per step). It is a different set of
  numbers by construction, and `docs/monty-bugs.md` §2.1 lists what is left.

  The step is advanced by the coordinator, never by a module.
  """

  @enforce_keys [:episode_seed]
  defstruct episode_seed: 0, step: 0, mode: :matching, suppress_runtime_errors: false, rng: nil

  @type mode :: :matching | :exploratory

  @type t :: %__MODULE__{
          episode_seed: non_neg_integer(),
          step: non_neg_integer(),
          mode: mode(),
          suppress_runtime_errors: boolean(),
          rng: GenServer.server() | nil
        }

  @doc "A context for the first step of an episode."
  @spec new(non_neg_integer(), keyword()) :: t()
  def new(episode_seed, opts \\ []) do
    %__MODULE__{
      episode_seed: episode_seed,
      mode: Keyword.get(opts, :mode, :matching),
      suppress_runtime_errors: Keyword.get(opts, :suppress_runtime_errors, false)
    }
  end

  @doc "The same context one step later."
  @spec next(t()) :: t()
  def next(%__MODULE__{} = ctx), do: %{ctx | step: ctx.step + 1}

  @doc """
  A deterministic random stream for one module at this step.

  Same episode seed, module id and step always give the same numbers; the
  stream is independent of which other modules drew before it.
  """
  @spec rng_for(t(), atom() | String.t()) :: :rand.state()
  def rng_for(%__MODULE__{episode_seed: seed, step: step}, module_id) do
    :rand.seed_s(:exsss, {seed, :erlang.phash2(module_id), step})
  end
end
