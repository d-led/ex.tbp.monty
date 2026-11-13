defmodule ExTbpMonty.Repo.Migrations.AddStartedOnToStudioRuns do
  use Ecto.Migration

  # Where the run was *asked for*, as against `node`, which is where it is
  # *running*.
  #
  # With one runs table for a cluster the two are different nodes: a run asked for
  # on node1 may be performed by node2, because that is the node that offers what
  # the run needs (`ExTbpMonty.Cluster.Placement`). A list that said only one of
  # the two hid the handover, and a reader looking at a run on a machine they did
  # not start it on had nothing to tell them why.
  #
  # `nil` on a node that runs alone, and on every row written before this column
  # existed — which is the same "one node, nothing to say" the `node` column uses.
  def change do
    alter table(:studio_runs) do
      add :started_on, :string
    end
  end
end
