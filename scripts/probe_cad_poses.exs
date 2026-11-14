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

alias Monty.Frameworks.Models.EvidenceMatching.Hypotheses
alias Monty.Frameworks.Models.EvidenceMatching.LearningModule.EvidenceGraphLM
alias Monty.Studio.Run

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
# step is excluded from the symmetry count. Naming a config whose sensor does no
# delta filtering (`test/policy/base_surf`, whose `sensor_module` is
# `camera_surf`) is how that is compared rather than argued.
experiment = System.get_env("CAD_EXPERIMENT") || "base_config_10distinctobj_surf_agent"

{:ok, opened} =
  Monty.Studio.open(experiment, world_simulator: :cad)

# The seed is the exploration the policy draws — the world starts in the pose the
# *part* decides — so a probe of one seed says what that exploration did, and the
# same probe of another says whether the run's failure was the seed's.
seed = System.get_env("CAD_SEED")

setup =
  if seed in [nil, ""], do: opened.setup, else: %{opened.setup | seed: String.to_integer(seed)}

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

read = fn run ->
  try do
    belief = run |> Run.beliefs() |> Map.values() |> List.first()

    poses =
      run
      |> Run.statistics(fn
        %EvidenceGraphLM{} = module -> poses_of.(module)
        _not_an_evidence_module -> %{}
      end)
      |> then(fn state -> Map.new(state.learning_modules, &{&1.id, &1.state}) end)

    %{belief: belief, poses: poses}
  rescue
    _modules_stopped_with_the_episode -> nil
  end
end

# One row per step, for the symmetry question: how many hypotheses the module
# holds, what its symmetry counter says, and how much of the previous step's set
# survived — because `check_for_symmetry/4` only counts a step where more than
# 90 % of the possible hypotheses were possible the step before.
observe = fn
  %{poses: poses}, step, previous when map_size(poses) > 0 ->
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
    {module_id, Map.new(by_graph, fn {graph_id, pose} -> {graph_id, Map.delete(pose, :possible_ids)} end)}
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

  sampled = observed |> Enum.take_every(max(div(length(observed), 12), 1)) |> Enum.take(12)

  for row <- sampled do
    IO.puts(
      "  step #{String.pad_leading(to_string(row.step), 3)}  possible #{String.pad_leading(to_string(row.possible), 2)}" <>
        "  overlap #{Float.round(row.overlap, 2)}  processed #{row.processed}  symmetry #{row.symmetry}"
    )
  end
end

Run.stop_model(run)
