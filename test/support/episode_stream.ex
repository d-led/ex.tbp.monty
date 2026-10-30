defmodule Monty.EpisodeStream do
  @moduledoc """
  An episode's random stream, for a test that steps a module which draws.

  A module that draws — the salience module's dither, the goal generator's coin
  flip — reads the stream off the context, because that is where Monty's one
  `rng` lives. A test that steps such a module therefore needs one, seeded and
  owned by the test, so the numbers depend on the seed and nothing else.

  Each context gets its own stream under its own registry name: tests run
  concurrently, and a shared name would make the draw order depend on which test
  drew first.
  """

  alias Monty.Context
  alias Monty.Random.Stream

  import ExUnit.Callbacks, only: [start_supervised!: 2]

  @doc "A context for `seed`, drawing from a stream of its own."
  @spec context(non_neg_integer()) :: Context.t()
  def context(seed \\ 0), do: %{Context.new(seed) | rng: start(seed)}

  @doc "A stream for `seed`, started under the calling test."
  @spec start(non_neg_integer()) :: GenServer.server()
  def start(seed \\ 0) do
    model_id = "episode-#{System.unique_integer([:positive])}"

    # By child id as well as by name: a test may want two streams, and
    # `start_supervised!` refuses two children with one id.
    start_supervised!({Stream, %{model_id: model_id, seed: seed}}, id: model_id)

    Stream.via(model_id)
  end
end
