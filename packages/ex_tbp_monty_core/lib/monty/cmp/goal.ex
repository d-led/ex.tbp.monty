defmodule Monty.Cmp.Goal do
  @moduledoc """
  A target state on the cortical messaging protocol.

  Mirrors `tbp/monty/cmp.py::Goal`. A goal is a `Message` whose location and
  features are the values the receiver should achieve; `confidence` is the
  conviction with which the goal generator believes it should be acted upon,
  and `goal_tolerances` says how closely each element has to match before the
  goal counts as achieved.

  Unlike a message, every state field may be `nil`: "go to that object" does not
  specify a location, and "move that way" does not specify an object.
  """

  @enforce_keys [:sender_id, :sender_type]
  defstruct location: nil,
            morphological_features: nil,
            non_morphological_features: nil,
            confidence: 0.0,
            pass_message: true,
            process_features_in_lm: false,
            sender_id: nil,
            sender_type: nil,
            goal_tolerances: nil,
            info: %{}

  @type t :: %__MODULE__{
          location: [float()] | nil,
          morphological_features: map() | nil,
          non_morphological_features: map() | nil,
          confidence: float(),
          pass_message: boolean(),
          process_features_in_lm: boolean(),
          sender_id: String.t(),
          sender_type: :sm | :lm | :gsg,
          goal_tolerances: map() | nil,
          info: map()
        }

  @allowed_sender_types [:sm, :lm, :gsg]

  alias Monty.Cmp.Message

  @doc """
  Builds a goal. Fields a goal generator did not decide are simply absent.

  The pose features it carries, if it carries any, are checked as `Message`'s
  are — Monty asserts the same two keys on a goal — with the one allowance a goal
  gets: its `pose_fully_defined` may be `nil`, because a goal handed to a motor
  system does not know how completely the pose it came from was seen. A goal with
  no morphological features at all claims nothing and is accepted, which is how a
  salience module's "look there" goal is built.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    goal = struct(__MODULE__, attrs)

    with :ok <- validate_sender_type(goal),
         :ok <- validate_confidence(goal),
         :ok <- validate_location(goal),
         :ok <- validate_features(goal) do
      {:ok, goal}
    end
  end

  defp validate_features(%__MODULE__{morphological_features: nil}), do: :ok

  defp validate_features(%__MODULE__{morphological_features: features}),
    do: Message.validate_pose_features(features, allow_nil_flag?: true)

  defp validate_sender_type(%__MODULE__{sender_type: type}) when type in @allowed_sender_types,
    do: :ok

  defp validate_sender_type(%__MODULE__{sender_type: type}),
    do: {:error, {:invalid_sender_type, type, @allowed_sender_types}}

  defp validate_confidence(%__MODULE__{confidence: confidence})
       when is_number(confidence) and confidence >= 0 and confidence <= 1,
       do: :ok

  defp validate_confidence(%__MODULE__{confidence: confidence}),
    do: {:error, {:confidence_out_of_range, confidence}}

  defp validate_location(%__MODULE__{location: nil}), do: :ok

  defp validate_location(%__MODULE__{location: [_, _, _] = location}) do
    if Enum.all?(location, &is_number/1), do: :ok, else: {:error, {:invalid_location, location}}
  end

  defp validate_location(%__MODULE__{location: location}),
    do: {:error, {:invalid_location, location}}
end
