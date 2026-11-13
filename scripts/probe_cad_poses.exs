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

{:ok, opened} =
  Monty.Studio.open("base_config_10distinctobj_surf_agent", world_simulator: :cad)

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
            rotations:
              possible |> Enum.map(&Hypotheses.pose(hypotheses, &1)) |> Enum.uniq() |> length(),
            max_turn: turns |> Enum.max(fn -> 0.0 end) |> Float.round(1)
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

step_until_done = fn step_until_done, run, step, limit, last ->
  case Run.decision(run) do
    %{is_done: true} = decision ->
      {run, decision, last}

    _keep_going when step >= limit ->
      {run, %{is_done: false, timed_out?: false}, last}

    _keep_going ->
      {:ok, _info, _observations, run} = Run.step(run)
      step_until_done.(step_until_done, run, step + 1, limit, read.(run) || last)
  end
end

{run, decision, last} = step_until_done.(step_until_done, run, 0, steps, nil)
belief = last && last.belief

IO.puts("""
steps        #{run.step} of #{steps}
ended        #{if decision.is_done, do: "by the recognition policy", else: "at the probe's limit"}
terminal     #{inspect(Map.get(belief || %{}, :terminal_state))}
detected     #{inspect(Map.get(belief || %{}, :detected_object))}
possible     #{inspect(Map.get(belief || %{}, :possible_matches))}
poses        #{inspect(last && last.poses)}
""")

Run.stop_model(run)
