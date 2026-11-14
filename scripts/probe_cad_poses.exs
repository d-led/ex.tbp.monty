# What a CAD run still considers possible at its last step: the objects, and
# the poses it thinks the one it likes can be in.
#
#   CAD_LIBRARY=/tmp/cad-experiment/blend \
#   MONTY_CAD_PART=$PWD/../ex.quiddity/test/fixtures/blend_r5.step \
#   mix run scripts/probe_cad_poses.exs [steps]
#
# A run concludes when one object is left *and* its pose has narrowed to one
# (`EvidenceGraphLM.check_terminal_condition/1`). A part with a symmetry keeps
# several, so it reports high evidence and no conclusion however long it looks:
# the answer is not "unrecognised" but "recognised, and this is how many ways
# round it could be". This prints which of the two happened.

alias Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer
alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
alias Monty.Geometry.SurfacePoseVectors
alias Monty.Studio.Run

# The two comparisons `feature_change_filter` makes on a surface that has not gone
# away: the normal's turn (`pose_vectors: [π/4, …]`) and the patch's travel
# (`distance: 0.01`).
angle_between = fn left, right ->
  dot = left |> Enum.zip(right) |> Enum.map(fn {a, b} -> a * b end) |> Enum.sum()
  :math.acos(Monty.Math.clip(dot, -1.0, 1.0)) * 180 / :math.pi()
end

distance = fn left, right ->
  left
  |> Enum.zip(right)
  |> Enum.map(fn {a, b} -> (a - b) * (a - b) end)
  |> Enum.sum()
  |> :math.sqrt()
end

# The geometry lives in the sibling builds: this application carries the
# framework, not CAD, and a probe is a script rather than a dependency
# (`scripts/cad_experiment.exs` says the same at more length).
for ebin <- [
      Path.expand("~/src/ex.monty.cad/_build/dev/lib/ex_monty_cad/ebin"),
      Path.expand("~/src/ex.monty.cad/_build/dev/lib/ex_quiddity/ebin"),
      Path.expand("~/src/ex.cadmpeg/_build/dev/lib/ex_cadmpeg/ebin")
    ] do
  Code.append_path(ebin) || :already_on_the_path
end

steps = System.argv() |> List.first() |> then(&(&1 && String.to_integer(&1))) || 500
library = System.get_env("CAD_LIBRARY") || Mix.raise("CAD_LIBRARY names the libraries root")

if System.get_env("MONTY_CAD_PART") in [nil, ""] do
  Mix.raise("MONTY_CAD_PART names the part the world steps")
end

Application.put_env(:ex_tbp_monty, :monty_libraries_dir, library)

# The config decides more than the policy: `camera_surf_delta` filters a patch
# that has not changed enough into a location-only message, and a location-only
# step is excluded from the symmetry count. `CAD_NO_DELTA` removes that filter and
# nothing else — a sensor without `delta_thresholds` is given `PassthroughPerceptFilter`,
# so deleting the key is the one-key comparison. Naming a config whose sensor does
# no delta filtering is not, because `camera_surf` differs in more than that: it
# also asks for four more curvature features and saves raw observations.
experiment =
  System.get_env("CAD_EXPERIMENT") || "base_config_10distinctobj_surf_agent"

{:ok, opened} =
  Monty.Studio.open(experiment, world_simulator: :cad)

# The seed is the exploration the policy draws — the world starts in the pose the
# *part* decides — so a probe of one seed says what that exploration did, and the
# same probe of another says whether the run's failure was the seed's.
seed = System.get_env("CAD_SEED")

setup =
  if seed in [nil, ""], do: opened.setup, else: %{opened.setup | seed: String.to_integer(seed)}

# `sensors` are descriptors, not modules: the module is built from `config` when
# the run starts, and the ported sensor is given `delta_thresholds` from the same
# place, so both have to lose it.
without_delta = fn sensor ->
  %{sensor | config: Map.delete(sensor.config, "delta_thresholds"), delta_thresholds: nil}
end

setup =
  if System.get_env("CAD_NO_DELTA") in [nil, ""],
    do: setup,
    else: %{setup | sensors: Enum.map(setup.sensors, without_delta)}

{:ok, run} = Run.start(setup, steps: steps, mode: :eval, episode: 0, epoch: 0)

# The config's own recognition policy is what ends an episode, so the probe
# asks it each step rather than counting to a number of its own.
#
# The belief and the pose set are read *during* the episode: an episode's
# modules stop with it, and the question is what the run knew while it was
# looking, not what survived it.
# The angle between two rotations, the way `unique_pose?/4` measures it: the
# turn each pose needs to become the most likely one.
turn_degrees = fn most_likely, pose ->
  product =
    Monty.Geometry.mul(
      Monty.Geometry.transpose(Monty.Geometry.Rotation.to_matrix(most_likely)),
      pose
    )

  diagonal = product |> Enum.with_index() |> Enum.map(fn {row, index} -> Enum.at(row, index) end)

  :math.acos(Monty.Math.clip((Enum.sum(diagonal) - 1) / 2, -1.0, 1.0)) * 180 / :math.pi()
end

# What a conclusion is waiting for, in the module's own terms.
#
# `unique_pose?/4` answers true only when every *possible* hypothesis agrees with
# the most likely rotation to within `pose_similarity_threshold` (0.35 rad, 20°
# by default), so the largest turn among them is the distance from settling — and
# the number of distinct rotations says how many ways round the part could be.
poses_of = fn
  %EvidenceGraphLM{} = module ->
    case EvidenceGraphLM.current_mlh(module) do
      nil ->
        %{}

      # Before the first percept the module answers a placeholder MLH rather than
      # nil, and there are no hypotheses to measure (`EvidenceGraphLM` names the
      # same two ids when it decides what to put in a report).
      %{graph_id: graph_id} when graph_id in ["no_observations_yet", "new_object0"] ->
        %{}

      %{graph_id: graph_id, rotation: most_likely} ->
        hypotheses = Map.fetch!(module.hypotheses, graph_id)
        possible = EvidenceGraphLM.get_possible_hypothesis_ids(module, graph_id)

        turns =
          for id <- possible,
              do: turn_degrees.(most_likely, Hypotheses.pose(hypotheses, id))

        %{
          graph_id => %{
            possible: length(possible),
            possible_ids: Enum.sort(possible),
            rotations:
              possible |> Enum.map(&Hypotheses.pose(hypotheses, &1)) |> Enum.uniq() |> length(),
            max_turn: turns |> Enum.max(fn -> 0.0 end) |> Float.round(1),
            # The counter that would let a symmetric part conclude anyway, and what
            # it is counting towards (`check_for_symmetry/4`).
            symmetry: module.symmetry_evidence,
            required: module.required_symmetry_evidence,
            # The gate on that counter: a step only counts as evidence of symmetry
            # when the buffer says this step's observation reached the module
            # (`add_lm_processing_to_buffer_stats/2`, which is false for a
            # location-only step).
            processed:
              Monty.Frameworks.Models.Buffer.FeatureAtLocationBuffer.get_last_obs_processed(
                module.buffer
              )
          }
        }
    end

  _not_an_evidence_module ->
    %{}
end

# What the sensor last had, from the filter's own memory: the percept that reached
# (or failed to reach) the module. A widening step is worth reading with it — an
# observation that adds alternatives because the patch left the part is a
# different event from one that adds them while still on it, and a surface normal
# that has turned past the config's 45° releases the great majority of them.
sensor_of = fn
  # A passthrough filter keeps no memory at all (`PassthroughPerceptFilter.reset/1`
  # is nil), so a run with `CAD_NO_DELTA` has nothing to say about the last
  # percept — which is the same fact as every percept being sent.
  nil ->
    %{}

  %{last_percept: nil} ->
    %{}

  %{last_percept: percept} ->
    morphology = percept.morphological_features || %{}

    %{
      on_object: morphology["on_object"],
      normal:
        case morphology["pose_vectors"] do
          nil -> nil
          pose_vectors -> SurfacePoseVectors.surface_normal(pose_vectors)
        end,
      location: percept.location
    }
end

# What the module was last handed, from its own buffer. A step that is not a new
# observation is one the delta filter withheld or one the sensor could not make a
# valid normal and curvature for (`process_features_in_lm: on_object? and
# valid_signals?`), and `on_object` and `pose_fully_defined` on the percept are
# what tells the two apart.
handed_of = fn module ->
  module.buffer
  |> FeatureAtLocationBuffer.get_all_input_percepts()
  |> List.last()
  |> case do
    nil ->
      %{}

    percept ->
      morphology = percept.morphological_features || %{}

      %{
        on_object: morphology["on_object"],
        pose_fully_defined: morphology["pose_fully_defined"]
      }
  end
end

read = fn run ->
  belief = run |> Run.beliefs() |> Map.values() |> List.first()

  # `Run.statistics/2` hands the sensor modules over as the coordinator started
  # them — before step 1 — so the filter's memory read from it is empty however
  # long the run has been going. `detailed/2` asks each module for its own state
  # (`Monty.Runtime.Step.live_sensor_module/2`), which is where the percept the
  # patch last sent is.
  #
  # Nothing here is rescued: the closure used to swallow its own exceptions and
  # the probe then reported a tidy episode in which nothing had been observed,
  # which is the one failure a probe must not have.
  %{learning_modules: learning, sensor_modules: sensors} =
    Monty.Runtime.Model.detailed(run.model_id, fn
      %EvidenceGraphLM{} = module -> %{poses: poses_of.(module), handed: handed_of.(module)}
      _other -> %{}
    end)

  poses = Map.new(learning, &{&1.id, &1.state.poses})

  handed =
    learning
    |> List.first()
    |> then(&(&1 && &1.state.handed))

  sensor =
    sensors
    |> Enum.find(&Map.has_key?(&1.state, :filter_memory))
    |> then(&(&1 && sensor_of.(&1.state.filter_memory)))

  %{belief: belief, poses: poses, sensor: sensor || %{}, handed: handed || %{}}
end

# One row per step, for the symmetry question: how many hypotheses the module
# holds, what its symmetry counter says, and how much of the previous step's set
# survived — because `check_for_symmetry/4` only counts a step where more than
# 90 % of the possible hypotheses were possible the step before.
observe = fn
  %{poses: poses} = state, step, previous when map_size(poses) > 0 ->
    # `poses` is keyed by module, then by graph id — and a module with no
    # hypotheses yet reports `%{}` (`poses_of` says why), which is not a step the
    # counter can say anything about.
    by_graph = poses |> Map.values() |> List.first()
    pose = by_graph |> Map.values() |> List.first()

    case pose do
      %{possible_ids: ids, symmetry: symmetry, required: required, possible: possible} = pose ->
        before = previous && previous.possible_ids

        overlap =
          case {before, ids} do
            {[_ | _] = before, [_ | _] = now} ->
              MapSet.size(MapSet.intersection(MapSet.new(before), MapSet.new(now))) /
                length(now)

            _none_yet ->
              0.0
          end

        %{
          step: step,
          possible: possible,
          possible_ids: ids,
          symmetry: symmetry,
          required: required,
          processed: pose.processed,
          sensor: state.sensor,
          handed: state.handed,
          overlap: overlap
        }

      _no_hypotheses_yet ->
        nil
    end

  _no_state_yet, _step, _previous ->
    nil
end

step_until_done = fn step_until_done, run, step, limit, last, trace ->
  case Run.decision(run) do
    %{is_done: true} = decision ->
      {run, decision, last, Enum.reverse(trace)}

    _keep_going when step >= limit ->
      {run, %{is_done: false, timed_out?: false}, last, Enum.reverse(trace)}

    _keep_going ->
      {:ok, _info, _observations, run} = Run.step(run)
      state = read.(run)
      # A step with nothing to observe keeps the previous row rather than
      # replacing it with nothing: every overlap is measured against the last
      # step that had hypotheses.
      trace =
        case observe.(state, step + 1, List.first(trace)) do
          nil -> trace
          row -> [row | trace]
        end

      step_until_done.(step_until_done, run, step + 1, limit, state || last, trace)
  end
end

{run, decision, last, trace} = step_until_done.(step_until_done, run, 0, steps, nil, [])
belief = last && last.belief

# The ids are what the counter needs and what a reader does not: 120 of them in
# one line buries the four numbers that matter.
without_ids = fn poses ->
  Map.new(poses, fn {module_id, by_graph} ->
    {module_id,
     Map.new(by_graph, fn {graph_id, pose} -> {graph_id, Map.delete(pose, :possible_ids)} end)}
  end)
end

IO.puts("""
experiment   #{experiment}
steps        #{run.step} of #{steps}
ended        #{if decision.is_done, do: "by the recognition policy", else: "at the probe's limit"}
terminal     #{inspect(Map.get(belief || %{}, :terminal_state))}
detected     #{inspect(Map.get(belief || %{}, :detected_object))}
possible     #{inspect(Map.get(belief || %{}, :possible_matches))}
poses        #{inspect(last && without_ids.(last.poses))}
""")

# The symmetry counter, which is the other way a part can conclude: the same
# alternatives surviving step after step, `required_symmetry_evidence` times.
# A counter that never climbs and one that climbs and resets are different
# failures, and only the second is the >90 % rule being strict.
observed = trace |> Enum.reject(&is_nil/1)

if observed != [] do
  pairs = observed |> Enum.chunk_every(2, 1, :discard)
  climbed = Enum.count(pairs, fn [a, b] -> b.symmetry == a.symmetry + 1 end)
  reset = Enum.count(pairs, fn [a, b] -> b.symmetry == 0 and a.symmetry > 0 end)
  highest = observed |> Enum.map(& &1.symmetry) |> Enum.max(fn -> 0 end)
  required = observed |> Enum.map(& &1.required) |> Enum.max(fn -> 0 end)
  overlaps = observed |> Enum.drop(1) |> Enum.map(& &1.overlap)
  passing = Enum.count(overlaps, &(&1 > 0.9))
  median = overlaps |> Enum.sort() |> then(&Enum.at(&1, div(length(&1), 2)))

  IO.puts("""
  symmetry     reached #{highest} of the #{required} it needs; climbed #{climbed} step(s), reset #{reset} time(s)
  overlap      median #{Float.round(median, 3)}, #{passing} of #{length(overlaps)} steps above the 0.9 the counter needs
  processed    #{Enum.count(observed, & &1.processed)} of #{length(observed)} steps counted as new observation
  """)

  # Why a step was not a new observation, which is a question of two gates: the
  # delta filter withholding a percept the sensor had made, or the sensor's own
  # `on_object? and valid_signals?` refusing it before any filter is asked.
  withheld = Enum.reject(observed, & &1.processed)
  off_part = Enum.count(withheld, &(&1.handed[:on_object] == 0.0))
  undefined_pose = Enum.count(withheld, &(&1.handed[:pose_fully_defined] == false))

  both =
    Enum.count(
      withheld,
      &(&1.handed[:on_object] == 0.0 and &1.handed[:pose_fully_defined] == false)
    )

  if withheld != [] do
    IO.puts(
      "  withheld     #{length(withheld)} were not new observations: #{off_part} off the part," <>
        " #{undefined_pose} without a definite pose, #{both} both," <>
        " #{length(withheld) - off_part - undefined_pose + both} neither"
    )
  end

  sampled = observed |> Enum.take_every(max(div(length(observed), 12), 1)) |> Enum.take(12)

  for row <- sampled do
    IO.puts(
      "  step #{String.pad_leading(to_string(row.step), 3)}  possible #{String.pad_leading(to_string(row.possible), 2)}" <>
        "  overlap #{Float.round(row.overlap, 2)}  processed #{row.processed}  symmetry #{row.symmetry}"
    )
  end

  # A set that narrows and then widens is a different failure from one that never
  # narrows, and only the step says which step did it.
  jumps =
    observed
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [before, now] -> now.possible - before.possible >= 10 end)

  if jumps != [] do
    IO.puts("\n  widening (a possible set that grew by ten or more):")

    # The comparisons `changed?/3` makes between the percept it last sent and this
    # one: the normal's turn (`pose_vectors: [π/4, …]`) and the patch's travel
    # (`distance: 0.01`). Nought for both means the step was released by the
    # `n_steps: 20` cadence instead — an unchanged patch read again.
    comparisons =
      observed
      |> Enum.filter(& &1.sensor[:normal])
      |> Enum.chunk_every(2, 1, :discard)
      |> Map.new(fn [before, now] ->
        {now.step,
         {Float.round(angle_between.(before.sensor.normal, now.sensor.normal), 1),
          Float.round(distance.(before.sensor.location, now.sensor.location), 3)}}
      end)

    for [before, now] <- Enum.take(jumps, 10) do
      IO.puts(
        "  step #{String.pad_leading(to_string(now.step), 3)}  #{before.possible} -> #{now.possible}" <>
          "  processed #{now.processed}  on_object #{inspect(now.sensor[:on_object])}" <>
          "  turned/moved #{inspect(Map.get(comparisons, now.step))}"
      )
    end
  end
end

Run.stop_model(run)
