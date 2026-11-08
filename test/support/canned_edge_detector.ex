defmodule Monty.Test.CannedEdgeDetector do
  @moduledoc """
  A detector that reports one answer, whatever the observation.

  Monty's tests patch the edge detector with a mock returning fixed
  `EdgeFeatures`; this port injects a `{module, detector}` pair, and this is the
  module half of it. It exists so a case can say "there was an edge of strength
  2.5 at a right angle" without having to cut such an edge into a real patch.
  """

  alias Monty.Frameworks.Utils.EdgeDetection.EdgeFeatures

  @doc "The answer this detector was built with."
  def detect(%EdgeFeatures{} = features, _observation), do: features
end
