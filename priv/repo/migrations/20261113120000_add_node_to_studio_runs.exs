defmodule ExTbpMonty.Repo.Migrations.AddNodeToStudioRuns do
  use Ecto.Migration

  # Which node owns the run.
  #
  # A run's files are one node's — its database row, its log, its pictures, and
  # the folder they are in is that node's (`Monty.Paths.node_root/0`) — so a
  # cluster of several nodes has several run lists, and a row that does not say
  # whose it is cannot be told apart from one merged over them.
  #
  # `nil` on a node that runs alone, because there is no second node to tell it
  # apart from and a column saying "this one" on every row is a column nobody
  # reads. A run recorded before this column existed is `nil` as well: the
  # honest answer about a row whose files could be anywhere is that nobody
  # recorded it at the time.
  def change do
    alter table(:studio_runs) do
      add :node, :string
    end
  end
end
