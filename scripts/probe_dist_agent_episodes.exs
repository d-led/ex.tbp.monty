# Monty's ten recorded episodes, replayed through the port — Monty beside us.
#
#   MIX_ENV=test mix run scripts/probe_dist_agent_episodes.exs
#
# `test/fixtures/monty_dist_agent_10episodes.jsonl` is one Monty evaluation of
# `base_config_10distinctobj_dist_agent` over the ten YCB objects, recorded step
# by step while Monty ran it (see `docs/validation.md`). This replays each
# episode through the port's own composition — the learning module the config
# describes, with the memory in `priv/monty/libraries/`, the recognition policy
# the config names, the real step coordinator — with the recording standing in
# for the world, and prints what each side concluded.
#
# It is a probe rather than a test because the two do not agree yet: the first
# episode uses all 43 of Monty's steps without recognising the mug. Chasing that
# difference is the work; asserting it as behaviour would be the opposite.

alias Monty.Experiment.RecognitionPolicy.{AnyPolicy, MaxTotalSteps}
alias Monty.Runtime.{Episode, LearningModuleServer, Model, Registry}
alias Monty.Simulators.Recording
alias Monty.Simulators.Synthetic.Environment
alias Monty.Studio.Setup
alias Monty.Test.MontyRecording

recording = "test/fixtures/monty_dist_agent_10episodes.jsonl"
experiment = "base_config_10distinctobj_dist_agent"
channel = "patch"

Code.require_file("probe_support.exs", __DIR__)
opened = ProbeSupport.setup(experiment)
setup = opened.setup
episodes = MontyRecording.episodes!(recording)
conclusions = MontyRecording.episode_conclusions!(recording)

{:ok, policy} = Setup.recognition_policy(setup)

replay = fn percepts ->
  id = "probe-#{System.unique_integer([:positive])}"

  spec = Setup.model_spec(setup, id)
  # Wiring the sensor to a module id the config did not build is a run where
  # nothing is ever perceived — which looks exactly like a model that cannot
  # recognise anything. Take the id the config gave the module.
  module_id = hd(spec.learning_modules).id

  spec =
    spec
    |> Map.merge(%{
      sensor_modules: [
        %{
          id: channel,
          agent_id: Environment.agent_id(),
          module: Recording.SensorModule,
          state:
            Recording.SensorModule.new(
              channel,
              Enum.map(percepts, fn
                [] -> nil
                [percept | _rest] -> percept
              end)
            )
        }
      ],
      sm_to_lm: %{module_id => [channel]},
      lm_to_lm_vote: %{module_id => []}
    })
    # No body: the recording holds what the sensors saw, not where the agent
    # stood, so Monty's own motor system has nothing here to plan a jump from.
    # Its actions drove the sensor in Monty; in the replay the recording is the
    # world, and the question under test is what the learning modules make of
    # the percepts.
    |> Map.drop([:motor])

  {:ok, _pid} = DynamicSupervisor.start_child(ExTbpMonty.ModelSupervisor, {Model, spec})

  # The experiment's policy, bounded by the recording's length: a port that does
  # not conclude stops where Monty did, and says so, rather than spinning to the
  # experiment's own 6000-step ceiling.
  {:ok, ceiling} = MaxTotalSteps.new(max_total_steps: length(percepts))
  {:ok, bounded} = AnyPolicy.new(policies: [policy, ceiling])

  result =
    Episode.run(
      id,
      fn _actions -> {%{Environment.agent_id() => %{}}, %{}} end,
      mode: :eval,
      policy: bounded
    )

  detected =
    LearningModuleServer.state(Registry.via({:learning_module, id, module_id})).detected_object

  Model.stop(id)

  {result.steps, Map.get(result.terminal_states, module_id), detected}
end

# How many episodes to replay: all ten take a quarter of an hour, so iterating
# starts with one.
wanted = System.argv() |> Enum.map(&String.to_integer/1) |> List.first(10)

results =
  episodes
  |> Enum.zip(conclusions)
  |> Enum.take(wanted)
  |> Enum.with_index(1)
  |> Enum.map(fn {{percepts, conclusion}, index} ->
    {steps, terminal_state, detected} = replay.(percepts)
    agrees = detected == conclusion["detected_object"] and terminal_state == :match

    IO.puts(
      "episode #{index}: Monty #{conclusion["detected_object"]} (#{length(percepts)} steps) · " <>
        "port #{inspect(detected)} (#{steps} steps, #{inspect(terminal_state)}) · " <>
        if(agrees, do: "agrees", else: "differs")
    )

    agrees
  end)

IO.puts("\n#{Enum.count(results, & &1)} of #{length(results)} episodes reach Monty's conclusion")
