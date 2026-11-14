# One episode of a CAD part, steered by a policy another node offers.
#
#   MONTY_REMOTE_POLICY=monty_cad.feature_walk \
#   MONTY_SEEDS=cad@127.0.0.1 \
#   MONTY_CAD_PART=…/golden_simple_through_hole.step \
#   CAD_LIBRARY=/tmp/cad-experiment/plate \
#   elixir --name runner@127.0.0.1 -S mix run scripts/probe_remote_policy.exs [steps]
#
# The seam is `Monty.Studio.Setup`. It resolves `MONTY_REMOTE_POLICY` when the
# experiment is opened (`Monty.Studio.RemotePolicy.configured/0`, then `find/1`
# over the cluster), refuses a node whose policy nobody offers rather than
# quietly driving with the config's own, and builds the motor system from the
# policy it found. So this script opens, says where the policy came from, and
# steps the part — which is the whole of what the seam has to do.
#
# The cluster has to be up *before* the experiment is opened: the policy is
# resolved once, at open, and a node that has not joined yet would be told that
# nobody offers it.

alias Monty.Studio.RemotePolicy
alias Monty.Studio.Run

# The geometry lives in the sibling builds: this application carries the
# framework, not CAD (`scripts/cad_experiment.exs` says the same at more length).
for ebin <- [
      Path.expand("~/src/ex.monty.cad/_build/dev/lib/ex_monty_cad/ebin"),
      Path.expand("~/src/ex.monty.cad/_build/dev/lib/ex_quiddity/ebin"),
      Path.expand("~/src/ex.cadmpeg/_build/dev/lib/ex_cadmpeg/ebin")
    ] do
  Code.append_path(ebin) || :already_on_the_path
end

steps = System.argv() |> List.first() |> then(&(&1 && String.to_integer(&1))) || 200

library =
  System.get_env("CAD_LIBRARY") || Mix.raise("CAD_LIBRARY names the libraries root")

if System.get_env("MONTY_CAD_PART") in [nil, ""] do
  Mix.raise("MONTY_CAD_PART names the part the world steps")
end

Application.put_env(:ex_tbp_monty, :monty_libraries_dir, library)

unless Node.alive?() do
  Mix.raise(
    "this node is not distributed, so no policy can be reached: " <>
      "run it as `elixir --name runner@127.0.0.1 -S mix run #{__ENV__.file}`"
  )
end

experiment =
  System.get_env("CAD_EXPERIMENT") || "base_config_10distinctobj_surf_agent"

opened =
  case Monty.Studio.open(experiment, world_simulator: :cad) do
    {:ok, opened} -> opened
    {:error, why} -> Mix.raise("cannot open #{experiment}: #{inspect(why)}")
  end

# The seed is the exploration the policy draws, and the world starts in the pose
# the part decides, so a walk of one seed is comparable with a walk of the
# curvature policy on the same seed (`probe_cad_poses.exs` takes it the same way).
setup =
  case System.get_env("CAD_SEED") do
    nil -> opened.setup
    "" -> opened.setup
    seed -> %{opened.setup | seed: String.to_integer(seed)}
  end

policy =
  case opened.setup.remote_policy do
    nil -> "the config's own (MONTY_REMOTE_POLICY names none)"
    {:ok, remote} -> RemotePolicy.origin(remote)
    {:error, why} -> Mix.raise(why)
  end

IO.puts("""
node         #{node()}
peers        #{inspect(Node.list())}
policy       #{policy}
seed         #{setup.seed}
""")

{:ok, run} = Run.start(setup, steps: steps, mode: :eval, episode: 0, epoch: 0)

# Step until the config's own recognition policy ends the episode, the same way
# `probe_cad_poses.exs` does: the policy is what ends an episode, not a count.
step_until_done = fn step_until_done, run, step, limit ->
  case Run.decision(run) do
    %{is_done: true} = decision ->
      {run, decision}

    _keep_going when step >= limit ->
      {run, %{is_done: false, timed_out?: false}}

    _keep_going ->
      {:ok, _info, _observations, run} = Run.step(run)
      step_until_done.(step_until_done, run, step + 1, limit)
  end
end

{run, decision} = step_until_done.(step_until_done, run, 0, steps)
belief = run |> Run.beliefs() |> Map.values() |> List.first()

IO.puts("""
steps        #{run.step} of #{steps}
ended        #{if decision.is_done, do: "by the recognition policy", else: "at the probe's limit"}
terminal     #{inspect(Map.get(belief || %{}, :terminal_state))}
detected     #{inspect(Map.get(belief || %{}, :detected_object))}
possible     #{inspect(Map.get(belief || %{}, :possible_matches))}
""")
