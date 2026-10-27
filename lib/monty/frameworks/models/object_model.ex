defmodule Monty.Frameworks.Models.ObjectModel do
  @moduledoc """
  How a learned object is stored — the object-model family.

  Mirrors `tbp/monty/frameworks/models/object_model.py`, which holds three
  things: the graph model, the grid model that oversamples a surface into
  voxels before thinning it into a graph, and the error the grid raises when it
  is asked to hold more space than it was given.

    * `Monty.Frameworks.Models.ObjectModel.GraphObjectModel` — **ported**: nodes,
      their features by column, and edges to the nearest neighbours;
    * `...ObjectModel.GridObjectModel` — the voxel grid; it arrives with the
      learning path, since recognition only ever reads a graph;
    * `...ObjectModel.GridTooSmallError` — the grid's "this object does not fit"
      answer.

  What Monty keeps in `abstract_monty_classes.ObjectModel` is an empty base
  class, so there is nothing to mirror for it here beyond this namespace.
  """
end
