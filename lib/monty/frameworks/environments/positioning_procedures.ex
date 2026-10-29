defmodule Monty.Frameworks.Environments.PositioningProcedures do
  @moduledoc """
  Where the agent stands before an episode starts, and how it gets there.

  Mirrors `tbp/monty/frameworks/environments/positioning_procedures.py`. Monty's
  evaluation episodes do not begin from wherever the simulation left the agent:
  they begin from a position a procedure chose, so that "the first view of the
  object" means the same thing in every episode and in every experiment. This
  module holds the two functions that read an observation for that purpose, and
  the module tree holds the procedures themselves.

  ## What counts as being on an object

  Both functions read the *semantic* channel — the ids the environment stamped on
  each pixel — and never the depth. A pixel that returned a depth but carries no
  semantic id is background, which is the same distinction the salience module
  makes (`OnObjectObservation`).
  """

  alias Monty.Frameworks.Environments.PositioningProcedures.PositioningProcedureResult

  @doc """
  How much of the view is on an object, as a fraction of its pixels.

  `:any` counts every pixel with a semantic id; an integer counts only the
  pixels of that object. Monty's `get_perc_on_obj_semantic`.
  """
  @spec get_perc_on_obj_semantic([[integer()]], integer() | :any) :: float()
  def get_perc_on_obj_semantic(image, semantic_id \\ :any) do
    pixels = image |> List.flatten() |> length()

    on_object =
      case semantic_id do
        :any -> image |> List.flatten() |> Enum.count(&(&1 >= 1))
        id -> image |> List.flatten() |> Enum.count(&(&1 == id))
      end

    on_object / pixels
  end

  @doc """
  The depth at the centre pixel of one sensor's view.

  Monty's `PositioningProcedure.depth_at_center`, a static method there; a
  function here because nothing about it depends on a procedure's state.
  """
  @spec depth_at_center(map(), atom() | String.t(), atom() | String.t()) :: float()
  def depth_at_center(observations, agent_id, sensor_id) do
    depth =
      observations
      |> Map.fetch!(agent_id)
      |> Map.fetch!(sensor_id)
      |> Map.fetch!("depth")

    rows = length(depth)
    columns = depth |> hd() |> length()

    depth
    |> Enum.at(div(rows, 2))
    |> Enum.at(div(columns, 2))
  end

  @doc "The result a procedure answers with when it has nothing else to say."
  @spec result(map()) :: PositioningProcedureResult.t()
  def result(fields \\ %{}), do: struct(PositioningProcedureResult, fields)
end
