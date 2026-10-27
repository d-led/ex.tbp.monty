defmodule Monty.Context do
  @moduledoc """
  What a module needs to know about the run it is part of.

  Mirrors `tbp/monty/context.py::RuntimeContext`, with one deliberate
  difference: Python threads a single mutable `RandomState` through every
  module, which serialises whichever module draws next. Here the context
  carries the episode seed and the step, and `rng_for/2` derives a stream for a
  named module. Two runs with the same seed therefore draw the same numbers
  whether the modules are stepped one at a time or side by side.

  The step is advanced by the coordinator, never by a module.
  """

  @enforce_keys [:episode_seed]
  defstruct episode_seed: 0, step: 0, mode: :matching, suppress_runtime_errors: false

  @type mode :: :matching | :exploratory

  @type t :: %__MODULE__{
          episode_seed: non_neg_integer(),
          step: non_neg_integer(),
          mode: mode(),
          suppress_runtime_errors: boolean()
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
