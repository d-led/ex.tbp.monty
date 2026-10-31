defmodule Monty.Simulators.Synthetic.LearningModule do
  @moduledoc """
  A learning module that counts what it is shown, so the runtime can be
  exercised before evidence matching is ported.

  It keeps the same shape an `EvidenceGraphLM` will: percepts in a buffer, a
  vote out, votes in, a top-down output and a goal. When the real module lands,
  the coordinator does not change — only this stand-in goes away.
  """

  use Monty.Frameworks.Models.AbstractMontyClasses.LearningModule

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
    # A look-at goal, not a jump: a jump is how a module tests a *hypothesis*, and
    # it needs the pose the hypothesis says to look from. This module has no
    # hypotheses, so it can only say where it saw something — which is what a
    # salience module says too, and what `LookAtGoal` acts on.
    goal = %Goal{
      location: location,
      sender_id: to_string(state.id),
      sender_type: :sm,
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

  # A stand-in counts percepts and concludes nothing, so the model can run a
  # whole episode with it but never sees it finish.
  @impl true
  def add_lm_processing_to_buffer_stats(state, processed),
    do: Map.put(state, :processed, processed)

  @impl true
  def observation_processed?(state), do: Map.get(state, :processed, false)

  @impl true
  def update_terminal_condition(state), do: {state, nil}

  @impl true
  def set_terminal_state(state, terminal_state),
    do: Map.put(state, :terminal_state, terminal_state)

  @impl true
  def set_experiment_mode(state, mode), do: Map.put(state, :mode, mode)

  @impl true
  def update_ltm_from_stm(state), do: state

  @impl true
  def set_target(state, primary_target), do: Map.put(state, :primary_target, primary_target)

  # The stand-in keeps no stepwise targets: it has no buffer for an episode to
  # be read from, and inventing a list here would be a statistic about nothing.
  @impl true
  def set_stepwise_target(state, _label), do: state

  @impl true
  def fixme_update_ground_truth(state), do: state

  defp remember(state, percepts), do: %{state | percepts: state.percepts ++ percepts}
end
