defmodule Monty.Studio.Run do
  @moduledoc """
  A run of the experiment you just looked at.

  The setup decides the topology; this starts it as supervised processes and
  steps the clock, one timestep per call. It is deliberately not a GenServer:
  the caller owns the clock (a page, a test, an Oban job), and a run is a value
  you pass around rather than a process you have to ask.

  What comes back from `step/2` is the coordinator's report for one timestep —
  percepts, learning-module inputs, votes, goals, actions — and what a page
  shows while the run is happening. `Monty.Studio.Summary` turns the collected
  reports into what a page shows after it.
  """

  alias Monty.Experiment.Environment.Interface
  alias Monty.Experiment.RecognitionPolicy
  alias Monty.Experiment.RecognitionPolicy.{RecognitionCounter, RecognitionResult}
  alias Monty.Frameworks.Experiments.Seed
  alias Monty.Runtime.Positioning
  alias Monty.Studio.{Belief, Setup}

  @default_steps 12

  @enforce_keys [:model, :model_id, :setup, :interface, :episode_seed]
  defstruct [
    :model,
    :model_id,
    :setup,
    :interface,
    :episode_seed,
    :steps,
    step: 0,
    pending_actions: [],
    positioning: nil,
    policy: nil,
    counter: nil
  ]

  @type t :: %__MODULE__{
          model: module(),
          model_id: String.t(),
          setup: Setup.t(),
          interface: Interface.t(),
          episode_seed: non_neg_integer(),
          steps: pos_integer(),
          step: non_neg_integer(),
          pending_actions: [Monty.Frameworks.Actions.Action.t()],
          positioning: Monty.Runtime.Positioning.outcome() | nil,
          policy: Monty.Experiment.RecognitionPolicy.t() | nil,
          counter: Monty.Experiment.RecognitionPolicy.RecognitionCounter.t() | nil
        }

  @doc """
  Starts a model for an experiment.

  Options: `:steps` (how many timesteps this run is for, used for the
  controller's progress), `:model_id`, `:episode` (which episode of the epoch it
  is, counted from zero), and `:has_detailed_logger` (whether this run's logging
  wants the whole hypothesis space per step).

  The episode number is not bookkeeping: a run's random draws come from the
  seed its episode derives from the experiment's, so the same experiment and a
  different episode number are different draws — which is exactly what makes the
  second episode of an epoch a different object seen from a different angle.
  """
  @spec start(Setup.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(%Setup{} = setup, opts \\ []) do
    model_id =
      Keyword.get_lazy(opts, :model_id, fn -> "studio-#{System.unique_integer([:positive])}" end)

    episode = Keyword.get(opts, :episode, 0)

    spec =
      Setup.model_spec(setup, model_id,
        has_detailed_logger: Keyword.get(opts, :has_detailed_logger, false)
      )

    model = Setup.model_class(setup)

    with {:ok, factories} <- Setup.positioning_procedures(setup),
         {:ok, policy} <- Setup.recognition_policy(setup),
         {:ok, interface, positioning} <- position(setup, factories, episode) do
      case DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {model, spec}) do
        {:ok, _pid} ->
          # Monty's `pre_episode`: the experiment tells the model what the episode
          # is about, because only the world knows — a world that samples an object
          # says which one, and one that does not says nothing and the model keeps
          # what it knew.
          tell_target(model, model_id, interface)

          {:ok,
           %__MODULE__{
             model: model,
             model_id: model_id,
             setup: setup,
             episode_seed: Seed.episode_seed(seed(setup), :eval, episode),
             # The world starts where an episode starts, not where the last one
             # left it: a run is an episode — and where that is, the positioning
             # procedures have just decided.
             interface: interface,
             positioning: positioning,
             policy: policy,
             counter: RecognitionCounter.new(:eval),
             steps: Keyword.get(opts, :steps, @default_steps)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Monty's `MontyExperiment.pre_episode`: the experiment tells the model what the
  # episode is about, and the two halves of that arrive from the same place. The
  # world that chose the object also named the semantic ids in its scene, which
  # is what lets a step say *which* object was under the patch rather than only
  # that one was; Monty's own experiments pass both
  # (`object_recognition_experiments.py`).
  defp tell_target(model, model_id, interface) do
    world = interface.env

    target =
      if function_exported?(world.__struct__, :primary_target, 1),
        do: world.__struct__.primary_target(world)

    model.fixme_set_ground_truth(model_id, target, semantic_id_to_label: labels(world))

    :ok
  end

  # A world without semantics answers nothing, which is what an empty map says:
  # every step's stepwise target is then `no_label`, Monty's own word for a
  # sensor that cannot name what it is on.
  defp labels(world) do
    if function_exported?(world.__struct__, :semantic_id_to_label, 1),
      do: world.__struct__.semantic_id_to_label(world),
      else: %{}
  end

  # Monty's `pre_episode`: the world is reset, then looked at and stepped until
  # the agent is in front of the object, before the model sees anything. The
  # steps taken here are the environment's, not the episode's, so the run's step
  # counter starts at zero afterwards.
  #
  # The reset comes first because that is the order Monty's `Interface.pre_episode`
  # has, and because it is the only thing that starts an episode in a world that
  # lives in another process: `HabitatEnvironment.reset/1` is what runs Monty's own
  # `pre_episode` in the peer. Without it a run stepped a world that had never been
  # told an episode had begun.
  #
  # A world that positions the episode itself — Monty's own, behind the port — has
  # done the positioning inside that reset, with Monty's random stream; stepping
  # the procedures again would move an agent Monty had placed and make the episode
  # a different one.
  defp position(%Setup{} = setup, factories, episode) do
    world = Setup.world(setup)

    interface =
      Interface.new(
        env: world,
        # The next episode starts where Monty starts one: a new scene for a world
        # that is a value, and the peer's own reset for a world that is a process
        # — never a second peer.
        reset: fn -> world.__struct__.reset(world) end,
        transforms: Setup.built_transforms(setup),
        seed: seed(setup)
      )

    {_observations, _proprioceptive_state, interface} = Interface.pre_episode(interface)

    if Monty.Simulators.Environment.positions_itself?(world) do
      {:ok, interface, %{steps: nil, success: true, procedures: [:world]}}
    else
      observe = fn interface, actions -> Interface.step(interface, actions) end

      case Positioning.prepare(
             factories,
             Setup.target_semantic_id(setup, episode),
             interface,
             observe,
             distractors: Setup.distractors(setup)
           ) do
        {:ok, positioned, outcome} -> {:ok, positioned, outcome}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  What the world rendered this step, before the experiment's transforms ran.

  `step/1` answers the transformed observations, because that is what the model is
  given. A page showing the object wants the picture the world drew — a transform
  that clips depth to the patch's reach turns a surface into a flat slab — so this
  asks the world directly, and answers `nil` for a world that cannot say.
  """
  @spec rendered_observations(t()) :: map() | nil
  def rendered_observations(%__MODULE__{interface: interface}) do
    world = interface.env

    if function_exported?(world.__struct__, :observation, 1),
      do: world.__struct__.observation(world)
  end

  @doc """
  What each learning module believes after the run's last step, keyed by module id.

  The coordinator's report says what the modules *were given*; this says what they
  made of it, which is the other half of a step and the half a chart draws.
  """
  @spec beliefs(t()) :: %{optional(atom() | String.t()) => Belief.t()}
  def beliefs(%__MODULE__{model_id: model_id, setup: setup}) do
    Belief.all(model_id, Enum.map(setup.learning_modules, & &1.id))
  end

  @doc """
  The coordinator's state, which is what a logger reads an episode out of.

  Monty hands its logger the *model*, and the logger asks it for the episode
  number, the mode, the modules and their terminal states. The coordinator's
  state is this port's model: the same four answers, in one value.
  """
  @spec state(t()) :: Monty.Runtime.Step.State.t()
  def state(%__MODULE__{model: model, model_id: model_id}), do: model.state(model_id)

  @doc """
  What this episode is about: the object the world says it put in front of the
  agent, or `nil` for a world that does not ask the question.

  Monty's `logger_args` records a target only for a `OneObjectPerEpisodeInterface`;
  a world here answers it by exporting `primary_target/1`, which is the same
  distinction made the same way the episode's target is told to the model.
  """
  @spec target(t()) :: map() | nil
  def target(%__MODULE__{interface: interface}) do
    world = interface.env

    if function_exported?(world.__struct__, :primary_target, 1),
      do: world.__struct__.primary_target(world)
  end

  @doc """
  Monty's `logger_args`: the counters a handler keys an episode by.

  They are counters of the *run so far*, which is why they are zero here: a studio
  run is one episode and this is the first, and Monty's experiment increments them
  after the logger has been given the episode — the episode being logged is the one
  that has not been counted yet.
  """
  @spec logger_args(t()) :: map()
  def logger_args(%__MODULE__{episode_seed: seed} = run) do
    args = %{
      "total_train_steps" => 0,
      "train_episodes" => 0,
      "train_epochs" => 0,
      "total_eval_steps" => 0,
      "eval_episodes" => 0,
      "eval_epochs" => 0,
      "episode_seed" => seed
    }

    case target(run) do
      nil -> args
      target -> Map.put(args, "target", target)
    end
  end

  @doc """
  Runs one timestep, returning the report and the advanced run.

  The world is stepped with the actions the model chose on the *previous* step,
  and the report's observations come from *this* one: Monty's `Interface.step/1`
  hands the environment the actions it was given last time, and the first step
  of an episode is taken where the sensors already are.

  A failing module surfaces as an exit from the coordinator rather than a
  returned error: a step either produced a report or the run itself is broken,
  and pretending otherwise here would only move the decision.
  """
  @spec step(t()) :: {:ok, map(), map(), t()}
  def step(%__MODULE__{model: model, model_id: model_id, step: step} = run) do
    {observations, proprioceptive_state, interface} =
      Interface.step(run.interface, run.pending_actions)

    ctx = %{Monty.Context.new(run.episode_seed) | step: step}

    {:ok, actions, info} = model.step(model_id, observations, proprioceptive_state, ctx)

    # The observations come back with the report so a page can show what the
    # modules saw, not just what they did with it.
    run = %{
      run
      | step: step + 1,
        interface: interface,
        pending_actions: actions,
        counter:
          RecognitionCounter.count_step(
            run.counter,
            info.inputs != %{},
            info.step_type == :exploratory
          )
    }

    # Monty's `_recognition_complete` asks the policy and does what it asks for
    # before the loop decides whether to go on — which is what makes a stopping
    # decision's time-out reach the model, rather than being asked for and then
    # never applied.
    apply_reactions(run, decision(run))

    {:ok, info, observations, run}
  end

  @doc """
  What the experiment's recognition policy makes of the run so far.

  This is the question the experiment asks each step — `is_done` ends the run,
  `time_out_lms` and `start_exploring` are the two things it can ask for
  instead — and the answer is also what a run's summary can report.
  """
  @spec decision(t()) :: RecognitionResult.t()
  def decision(%__MODULE__{policy: nil}), do: %RecognitionResult{}

  def decision(%__MODULE__{policy: policy, counter: counter} = run) do
    RecognitionPolicy.call(policy, model_view(run), counter)
  end

  @doc """
  What the model concluded: each learning module's terminal state, if any.

  Read from the model rather than from the last step's report, because the
  ending an episode gets from a time-out happens after that report.
  """
  @spec conclusion(t()) :: %{optional(atom()) => term()}
  def conclusion(%__MODULE__{model: model, model_id: model_id}),
    do: model.state(model_id).terminal_states

  @doc """
  Whether the run is over: the experiment's policy, or this page's step budget.

  The policy is the experiment's answer and the budget is the page's, so a run
  that concludes early stops early, and one that never concludes still yields.
  """
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{step: step, steps: steps} = run),
    do: step >= steps or decision(run).is_done

  @doc "Stops the run's processes — the model and the world it steps; safe to call twice."
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{model: model, model_id: model_id, interface: interface}) do
    model.stop(model_id)
    Monty.Simulators.Environment.stop(interface.env)
  end

  @doc "How many steps a run of this experiment takes by default."
  @spec default_steps() :: pos_integer()
  def default_steps, do: @default_steps

  defp seed(%Setup{seed: seed}) when is_integer(seed), do: seed
  defp seed(_setup), do: 0

  # Monty's `_recognition_complete`: the two things a policy can ask for besides
  # stopping.
  defp apply_reactions(%__MODULE__{model: model, model_id: model_id}, decision) do
    if decision.start_exploring, do: :ok = model.switch_to_exploratory_step(model_id)
    if decision.time_out_lms, do: :ok = model.time_out(model_id)
  end

  # The four things a policy may read off the model (`docs/monty-bugs.md` §2.17).
  defp model_view(%__MODULE__{model: model, model_id: model_id}), do: model.status(model_id)
end
