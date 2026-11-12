defmodule Monty.Runtime.Positioning do
  @moduledoc """
  Puts the agent in front of the object before an episode's first step.

  Mirrors the positioning half of `ExperimentEnvironment.pre_episode` in
  `tbp/monty/experiment/environment.py`: for each configured procedure, build it
  for the episode's target object, ask the world what is visible, and keep
  stepping the world with the actions the procedure answers until it is finished.
  Only the *last* procedure's verdict is kept — Monty's rule, because the
  procedures are a pipeline (walk towards the object, then aim at it), not
  alternatives.

  ## Pure, like the rest of the port

  Monty's loop mutates the environment and the procedure as it goes. Here the
  world is threaded through explicitly — `observe.(world, actions)` answers the
  observation, the agent's pose and the **next** world — and so is the procedure,
  so a caller can watch the whole prologue happen without a process.

  ## What a failed positioning means

  Monty raises when a single-object scene never gets the centre pixel onto the
  target: the episode was set up wrong, and a run that starts anyway measures
  nothing. This answers an error, so a job can report it rather than crash a
  supervisor.

  ## The step limit is the port's

  Monty's loop has no bound, and a procedure that never finishes hangs the
  experiment. This one stops after `:max_steps` — Monty's own procedures finish in
  a few dozen steps — and says so. The bound only fires where Monty would hang.
  """

  require Logger

  alias Monty.Frameworks.Environments.PositioningProcedures.GetGoodViewFactory

  @default_max_steps 100

  @typedoc "A world and actions in; the observation, the agent's pose and the next world out."
  @type observe :: (term(), [Monty.Frameworks.Actions.Action.t()] -> {map(), map(), term()})

  @typedoc """
  What positioning did: whether the last procedure ended in a good view, and how
  many steps it took.

  `steps` is `nil` when the world positioned the episode itself and did not
  report how much it moved — a world that ran Monty's `pre_episode` did the work,
  and inventing a number for it here would be worse than saying nothing.
  """
  @type outcome :: %{
          steps: non_neg_integer() | nil,
          success: boolean(),
          procedures: [String.t() | atom()]
        }

  @doc """
  Steps `world` until every procedure has finished.

  Options:

    * `:distractors` — how many other objects the scene has. A single-object scene
      the procedure never reaches the target in is an error; a cluttered one only
      needs the procedure to give up.
    * `:max_steps` — the bound described in the moduledoc.

  No procedures is Monty's "positioning is not configured": the world comes back
  untouched and nothing is stepped.
  """
  @spec prepare([GetGoodViewFactory.t()], integer(), term(), observe(), keyword()) ::
          {:ok, term(), outcome()} | {:error, term()}
  def prepare(factories, target_semantic_id, world, observe, options \\ [])

  def prepare([], _target_semantic_id, world, _observe, _options),
    do: {:ok, world, %{steps: 0, success: false, procedures: []}}

  def prepare(factories, target_semantic_id, world, observe, options) do
    max_steps = Keyword.get(options, :max_steps, @default_max_steps)

    case position(factories, target_semantic_id, world, observe, max_steps, 0, []) do
      {:ok, world, steps, answers} ->
        success = answers |> List.last() |> Map.fetch!(:success)

        if Keyword.get(options, :distractors, 0) == 0 and not success do
          {:error, {:target_not_visible, target_semantic_id}}
        else
          {:ok, world,
           %{steps: steps, success: success, procedures: Enum.map(answers, & &1.procedure)}}
        end

      {:error, :too_many_steps} ->
        {:error, {:positioning_did_not_finish, max_steps}}
    end
  end

  # Monty asks the world for a fresh look before each procedure, so a procedure
  # that may only turn starts from what the world shows now.
  defp position([], _target, world, _observe, _max_steps, steps, answers),
    do: {:ok, world, steps, Enum.reverse(answers)}

  defp position([factory | rest], target, world, observe, max_steps, steps, answers) do
    {module, procedure} = GetGoodViewFactory.create(factory, target)

    # A procedure reads one sensor's observation — the one it is positioning —
    # and the interface's transform computes every sensor's point cloud. An
    # episode spends seventeen world steps here, and half of each step's
    # transform is a cloud the procedure never looks at.
    #
    # Each procedure narrows from the world as it was handed in, and the
    # recursion carries that, not the narrowed look: one procedure's restore
    # would otherwise be the next one's starting point, and the second
    # procedure would compute both clouds again.
    look = narrow_to(observe, procedure.sensor_id)
    {observations, proprioceptive_state, world} = look.(world, [])

    case until_finished(
           module,
           procedure,
           observations,
           proprioceptive_state,
           world,
           look,
           max_steps,
           steps + 1
         ) do
      {:ok, result, world, steps} ->
        position(rest, target, world, observe, max_steps, steps, [
          %{procedure: name(factory), success: result.success} | answers
        ])

      {:error, :too_many_steps} = error ->
        error
    end
  end

  # One procedure's state machine: ask, act, look again — until it is terminated
  # or truncated. The world is carried along, because the step that produced the
  # last observation is the step the prologue keeps.
  defp until_finished(
         module,
         procedure,
         observations,
         proprioceptive_state,
         world,
         observe,
         max_steps,
         steps
       ) do
    if steps >= max_steps do
      Logger.warning("positioning gave up after #{steps} steps")
      {:error, :too_many_steps}
    else
      {result, procedure} = module.call(procedure, observations, proprioceptive_state)

      if result.terminated or result.truncated do
        {:ok, result, world, steps}
      else
        {observations, proprioceptive_state, world} = observe.(world, result.actions)

        until_finished(
          module,
          procedure,
          observations,
          proprioceptive_state,
          world,
          observe,
          max_steps,
          steps + 1
        )
      end
    end
  end

  defp name(%GetGoodViewFactory{agent_id: agent_id, sensor_id: sensor_id}),
    do: "#{sensor_id}@#{agent_id}"

  # The interface as the procedure needs it: stepped with only its own sensor's
  # cloud computed. What comes back carries the interface's own transform list,
  # because the steps after positioning are the model's and need every sensor's
  # cloud — a narrowed interface handed on would leave the model half blind.
  #
  # A world with no transforms (a test's, or one that positions itself) is
  # stepped exactly as it was.
  defp narrow_to(observe, sensor_id) do
    fn world, actions ->
      case world do
        %{transforms: [_ | _] = transforms} ->
          case narrow(transforms, sensor_id) do
            {:ok, narrowed} ->
              {observations, proprioceptive_state, stepped} =
                observe.(%{world | transforms: narrowed}, actions)

              {observations, proprioceptive_state, %{stepped | transforms: transforms}}

            :not_this_sensor ->
              observe.(world, actions)
          end

        _untransformed ->
          observe.(world, actions)
      end
    end
  end

  # The transforms with the sensor's own kept and the rest of the list narrowed
  # to it. `intrinsics` and `depth_clip_sensors` are indexed by place in
  # `sensor_ids`, so they have to move with it — narrow one without the other and
  # the wrong camera is unprojected.
  defp narrow(transforms, sensor_id) do
    transforms
    |> Enum.reduce_while({:ok, []}, fn transform, {:ok, kept} ->
      case one(transform, sensor_id) do
        :keep -> {:cont, {:ok, [transform | kept]}}
        {:narrow, narrowed} -> {:cont, {:ok, [narrowed | kept]}}
        :not_this_sensor -> {:halt, :not_this_sensor}
      end
    end)
    |> case do
      {:ok, kept} -> {:ok, Enum.reverse(kept)}
      :not_this_sensor -> :not_this_sensor
    end
  end

  defp one(%{sensor_ids: ids, intrinsics: intrinsics} = transform, sensor_id) do
    case Enum.find_index(ids, &(&1 == sensor_id)) do
      nil ->
        :not_this_sensor

      index ->
        {:narrow,
         %{
           transform
           | sensor_ids: [sensor_id],
             intrinsics: [Enum.at(intrinsics, index)],
             depth_clip_sensors:
               if(index in Map.get(transform, :depth_clip_sensors, []), do: [0], else: [])
         }}
    end
  end

  defp one(_transform, _sensor_id), do: :keep
end
