defmodule Monty.Frameworks.Models.ObjectModel do
  @moduledoc """
  How a learned object is stored — the object-model family.

  Mirrors `tbp/monty/frameworks/models/object_model.py`, which holds three
  things: the graph model, the grid model that oversamples a surface into
  voxels before thinning it into a graph, and the error the grid raises when it
  is asked to hold more space than it was given.

    * `Monty.Frameworks.Models.ObjectModel.GraphObjectModel` — **ported**: nodes,
      their features by column, and edges to the nearest neighbours;
    * `...ObjectModel.GridObjectModel` — **ported**: the voxel grid that averages
      what was seen in each voxel and thins the busiest ones into a graph, so
      that one model is bounded in size and in resolution at once;
    * `...ObjectModel.GridTooSmallError` — **ported**: the grid's "this object
      does not fit" answer.

  What Monty keeps in `abstract_monty_classes.ObjectModel` is an empty base
  class, so there is nothing to mirror for it here beyond this namespace.

  ## What every object model answers

  `GridObjectModel` is a `GraphObjectModel` in Python — same interface, a grid
  in front of the graph. Memory only ever asks a model these questions, so in
  Elixir, where there is no inheritance to lean on, the same set is written out
  as a behaviour and both models implement it:

    * `new/2` — an empty model for an object id, told its options;
    * `build_model/3` and `update_model/6` — add an episode's observations, or
      extend what is there; both can refuse, because a grid can be too small;
    * `set_graph/2` — take a pretrained graph as it was stored;
    * `graph/1`, `positions/1`, `num_nodes/1`, `get_values_for_feature/2` — what
      matching reads.

  Refusals are `{:error, reason}` rather than exceptions, since "the object is
  bigger than this model" is an answer a caller acts on (learn it anyway, log
  it, model bigger next time) and not an accident.
  """

  alias Monty.Frameworks.Utils.SpatialArithmetics

  @type model :: struct()
  @type location :: SpatialArithmetics.vector()
  @type features :: %{optional(String.t()) => list()}
  @type graph :: map()

  @doc "An empty model for `object_id`."
  @callback new(object_id :: String.t(), options :: keyword()) :: model()

  @doc "The model built from one episode's observations."
  @callback build_model(model(), [location()], features()) ::
              {:ok, model()} | {:error, term()}

  @doc "The model extended with one episode's observations."
  @callback update_model(
              model(),
              [location()],
              features(),
              location(),
              location(),
              Monty.Geometry.Rotation.t()
            ) ::
              {:ok, model()} | {:error, term()}

  @doc "The model holding a graph that was stored rather than built."
  @callback set_graph(model(), graph()) :: {:ok, model()} | {:error, term()}

  @doc "The graph matching reads, or `nil` before there is one."
  @callback graph(model()) :: graph() | nil

  @doc "One `[x, y, z]` per node."
  @callback positions(model()) :: [location()]

  @doc "The number of nodes."
  @callback num_nodes(model()) :: non_neg_integer()

  @doc "The columns holding one feature, as one row per node."
  @callback get_values_for_feature(model(), String.t()) :: [[float()]]

  @doc """
  The ids of the `count` nodes nearest each of `locations`.

  Displacing asks this to find which stored nodes an unobserved pose would have
  produced evidence from. Monty queries a KD-tree built over the graph; a grid
  model's graph is a point cloud with no edges, so it answers the same question
  by comparing distances.
  """
  @callback find_nearest_neighbors(model(), [location()], pos_integer()) :: [
              [non_neg_integer()]
            ]
end
