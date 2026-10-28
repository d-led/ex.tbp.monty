defmodule Monty.Frameworks.Models.MotorPolicies.PredefinedPolicy do
  @moduledoc """
  A policy that replays a written-down sequence of actions, for ever.

  Mirrors `tbp/monty/frameworks/models/motor_policies.py::PredefinedPolicy`.
  One action per line of a JSON file, read once at construction and then cycled:
  step `n` of the episode is action `n` of the file, wrapped round. It exits
  because unit tests and recorded-session experiments need a body that moves
  the same way twice, and no policy can promise that as simply as a list.

  The file is read with `ActionJSONDecoder`, the same decoder an action crosses
  a wire with, so a file is Monty's own action serialisation and nothing bespoke.

  Monty indexes with `bounding % len(action_list)`, so a file with no actions
  fails on the first step with a division by zero. This port refuses at
  construction instead — same failure, one step earlier, and a message that says
  which file.
  """

  @behaviour Monty.Frameworks.Models.MotorPolicies.MotorPolicy

  alias Monty.Frameworks.Actions.ActionJSONDecoder
  alias Monty.Frameworks.Models.MotorPolicies.MotorPolicyResult

  @enforce_keys [:agent_id, :action_list]
  defstruct agent_id: nil, action_list: [], episode_step: 0

  @type t :: %__MODULE__{
          agent_id: atom() | String.t(),
          action_list: [Monty.Frameworks.Actions.Action.t()],
          episode_step: non_neg_integer()
        }

  @doc """
  A replay for `:agent_id` from the actions written in `:file`.

  `:file` is a path with one JSON action per line, blank lines allowed.
  """
  @spec new(keyword()) :: t()
  def new(options) do
    agent_id = Keyword.fetch!(options, :agent_id)
    action_list = read_action_file(Keyword.fetch!(options, :file))

    %__MODULE__{agent_id: agent_id, action_list: action_list}
  end

  @doc """
  The actions in `file`, in the order they are written.

  A blank line is not an action. A line that is not an action is an error naming
  the line, because a replay that silently skipped one would be a different
  experiment.
  """
  # sobelow_skip ["Traversal.FileModule"] — the path is the experiment's own
  # `file_name`, from its config, exactly as Monty's `Path(file_name)` is.
  @spec read_action_file(Path.t()) :: [Monty.Frameworks.Actions.Action.t()]
  def read_action_file(file) do
    actions =
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.with_index(1)
      |> Enum.map(fn {line, number} -> decode_line!(line, file, number) end)

    if actions == [] do
      raise ArgumentError, "no actions in #{file}: a replay with nothing to replay"
    end

    actions
  end

  defp decode_line!(line, file, number) do
    with {:ok, object} <- Jason.decode(line),
         {:ok, action} <- ActionJSONDecoder.decode(object) do
      action
    else
      {:error, reason} ->
        raise ArgumentError,
              "line #{number} of #{file} is not an action: #{inspect(reason)}"
    end
  end

  @doc """
  The next action of the file, and the policy that has taken one more step.

  The percept, the state, the observations and the goal are all ignored: the
  sequence is the whole of what this policy knows.
  """
  @impl true
  @spec call(
          t(),
          Monty.Context.t(),
          map() | nil,
          Monty.Frameworks.Models.MotorSystemState.t(),
          Monty.Cmp.Message.t() | nil,
          Monty.Cmp.Goal.t() | nil
        ) :: {MotorPolicyResult.t(), t()}
  def call(%__MODULE__{} = policy, _ctx, _observations, _state, _percept, _goal) do
    {%MotorPolicyResult{actions: [Enum.at(policy.action_list, next_index(policy))]},
     %{policy | episode_step: policy.episode_step + 1}}
  end

  defp next_index(%__MODULE__{} = policy),
    do: rem(policy.episode_step, length(policy.action_list))

  @doc "Starts the next episode at the first action of the file."
  @impl true
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = policy), do: %{policy | episode_step: 0}

  @doc "How far into the file the replay has got."
  @impl true
  @spec state_dict(t()) :: map()
  def state_dict(%__MODULE__{} = policy), do: %{episode_step: policy.episode_step}
end
