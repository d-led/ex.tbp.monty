defmodule Monty.Frameworks.Environments.PositioningProcedures.GetGoodViewFactory do
  @moduledoc """
  Builds a `GetGoodView` for whichever object an episode is about.

  Mirrors
  `tbp/monty/frameworks/environments/positioning_procedures.py::GetGoodViewFactory`.
  The target's semantic id is not known until the scene is built, so a config can
  only describe the procedure's settings here and ask for the procedure later.

  The defaults are Monty's own: half the view, or three centimetres away.
  """

  @behaviour Monty.Frameworks.Environments.PositioningProcedures.PositioningProcedureFactory

  alias Monty.Frameworks.Environments.PositioningProcedures.GetGoodView

  @enforce_keys [:agent_id, :sensor_id]
  defstruct agent_id: nil,
            sensor_id: nil,
            allow_translation: true,
            good_view_distance: nil,
            good_view_percentage: nil,
            max_orientation_attempts: 1,
            multiple_objects_present: false

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          sensor_id: atom() | String.t(),
          allow_translation: boolean(),
          good_view_distance: float(),
          good_view_percentage: float(),
          max_orientation_attempts: integer(),
          multiple_objects_present: boolean()
        }

  @doc "A factory for `:agent_id`'s procedure, with Monty's defaults for the rest."
  @spec new(keyword()) :: t()
  def new(options) do
    %__MODULE__{
      agent_id: Keyword.fetch!(options, :agent_id),
      sensor_id: Keyword.fetch!(options, :sensor_id),
      allow_translation: Keyword.get(options, :allow_translation, true),
      good_view_distance:
        Keyword.get(options, :good_view_distance, GetGoodView.good_view_distance_default()),
      good_view_percentage:
        Keyword.get(options, :good_view_percentage, GetGoodView.good_view_percentage_default()),
      max_orientation_attempts: Keyword.get(options, :max_orientation_attempts, 1),
      multiple_objects_present: Keyword.get(options, :multiple_objects_present, false)
    }
  end

  @impl true
  def create(%__MODULE__{} = factory, target_semantic_id) do
    GetGoodView.new(
      agent_id: factory.agent_id,
      sensor_id: factory.sensor_id,
      target_semantic_id: target_semantic_id,
      allow_translation: factory.allow_translation,
      good_view_distance: factory.good_view_distance,
      good_view_percentage: factory.good_view_percentage,
      max_orientation_attempts: factory.max_orientation_attempts,
      multiple_objects_present: factory.multiple_objects_present
    )
  end
end
