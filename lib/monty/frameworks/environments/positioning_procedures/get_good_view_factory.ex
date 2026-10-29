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

  @doc """
  A procedure for `target_semantic_id`, as the module and state a behaviour is
  called through.

  `{module, state}` is how this port carries every behaviour implementation: a
  struct says what a procedure is, and the module named after it is what knows how
  to run it.
  """
  @impl true
  def create(%__MODULE__{} = factory, target_semantic_id) do
    {GetGoodView,
     GetGoodView.new(
       agent_id: factory.agent_id,
       sensor_id: factory.sensor_id,
       target_semantic_id: target_semantic_id,
       allow_translation: factory.allow_translation,
       good_view_distance: factory.good_view_distance,
       good_view_percentage: factory.good_view_percentage,
       max_orientation_attempts: factory.max_orientation_attempts,
       multiple_objects_present: factory.multiple_objects_present
     )}
  end

  @target "tbp.monty.frameworks.environments.positioning_procedures.GetGoodViewFactory"

  @doc """
  The factory a composed config entry describes, or why it is not one this port
  can build.

  Every shipped evaluation config lists two of these: a view finder allowed to
  walk towards the object, and a patch camera that may only turn —
  `allow_translation: false` — because by then the body is where it should be and
  only the aim is wrong.
  """
  @spec from_config(map()) :: {:ok, t()} | {:error, term()}
  def from_config(%{"_target_" => @target} = config) do
    with {:ok, agent_id} <- fetch(config, "agent_id"),
         {:ok, sensor_id} <- fetch(config, "sensor_id") do
      {:ok,
       new(
         agent_id: agent_id,
         sensor_id: sensor_id,
         allow_translation: Map.get(config, "allow_translation", true),
         good_view_distance:
           Map.get(config, "good_view_distance", GetGoodView.good_view_distance_default()),
         good_view_percentage:
           Map.get(config, "good_view_percentage", GetGoodView.good_view_percentage_default()),
         max_orientation_attempts: Map.get(config, "max_orientation_attempts", 1),
         multiple_objects_present: Map.get(config, "multiple_objects_present", false)
       )}
    end
  end

  def from_config(%{"_target_" => target}), do: {:error, {:unsupported_procedure, target}}

  defp fetch(config, key) do
    case Map.fetch(config, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing, key}}
    end
  end
end
