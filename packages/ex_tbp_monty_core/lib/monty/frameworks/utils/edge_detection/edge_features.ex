defmodule Monty.Frameworks.Utils.EdgeDetection.EdgeFeatures do
  @moduledoc """
  What one patch of an image says about the edge in it.

  Mirrors `tbp/monty/frameworks/utils/edge_detection.py::EdgeFeatures`.

  `angle` is `nil` when there is no edge — a uniform patch, or one whose edge
  does not pass through the middle — and `0.0` would be a lie in that case: zero
  radians is a direction, and no edge has none. `is_geometric_edge` says whether
  the edge is a crease in the world (depth changes across it) rather than a
  change in ink; a texture edge on a surface that is not behind anything is
  still an edge, but it is not a boundary.
  """

  @enforce_keys [:strength, :coherence, :is_geometric_edge, :has_edge]
  defstruct angle: nil,
            strength: 0.0,
            coherence: 0.0,
            is_geometric_edge: false,
            has_edge: false

  @type t :: %__MODULE__{
          angle: float() | nil,
          strength: float(),
          coherence: float(),
          is_geometric_edge: boolean(),
          has_edge: boolean()
        }

  @doc "The answer for a patch with no edge in it."
  @spec no_edge() :: t()
  def no_edge do
    %__MODULE__{strength: 0.0, coherence: 0.0, is_geometric_edge: false, has_edge: false}
  end
end
