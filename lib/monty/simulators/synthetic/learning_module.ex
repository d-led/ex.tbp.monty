defmodule Monty.Simulators.Synthetic.LearningModule do
  @moduledoc """
  A learning module that counts what it is shown, so the runtime can be
  exercised before evidence matching is ported.

  It keeps the same shape an `EvidenceGraphLM` will: percepts in a buffer, a
  vote out, votes in, a top-down output and a goal. When the real module lands,
  the coordinator does not change — only this stand-in goes away.
  """

  @behaviour Monty.Frameworks.Models.AbstractMontyClasses.LearningModule

  alias Monty.Cmp.{Goal, Message}
  alias Monty.Geometry.OrientationMatrix

  @type state :: %{
          id: atom() | String.t(),
          percepts: [Message.t()],
          votes_received: [term()],
          output: Message.t() | nil
        }

  @spec new(atom() | String.t()) :: state()
  def new(id), do: %{id: id, percepts: [], votes_received: [], output: nil}

  @impl true
  def matching_step(percepts, _ctx, state) do
    {:ok, remember(state, percepts)}
  end

  @impl true
  def exploratory_step(percepts, _ctx, state) do
    {:ok, remember(state, percepts)}
  end

  @impl true
  def send_out_vote(state) do
    {[count: length(state.percepts), id: state.id], state}
  end

  @impl true
  def receive_votes(votes, state), do: {:ok, %{state | votes_received: votes}}

  @impl true
  def propose_goals(%{percepts: [%Message{location: location} | _]} = state) do
    goal = %Goal{
      location: location,
      sender_id: to_string(state.id),
      sender_type: :gsg,
      confidence: 0.5,
      goal_tolerances: %{"location" => 0.015}
    }

    {[goal], state}
  end

  def propose_goals(state), do: {[], state}

  @impl true
  def get_output(%{percepts: []} = state), do: {nil, state}

  def get_output(%{percepts: [%Message{location: location} | _]} = state) do
    output = %Message{
      location: nil,
      morphological_features: %{
        "pose_vectors" => %OrientationMatrix{
          value: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
        },
        "pose_fully_defined" => true
      },
      non_morphological_features: %{"object_id" => "object_0", "last_location" => location},
      confidence: 0.5,
      pass_message: true,
      process_features_in_lm: true,
      sender_id: to_string(state.id),
      sender_type: :lm
    }

    {output, state}
  end

  @impl true
  def reset_stm(state), do: %{state | percepts: [], votes_received: [], output: nil}

  defp remember(state, percepts), do: %{state | percepts: state.percepts ++ percepts}
end
