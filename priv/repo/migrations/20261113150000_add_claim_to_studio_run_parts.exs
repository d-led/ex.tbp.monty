defmodule ExTbpMonty.Repo.Migrations.AddClaimToStudioRunParts do
  use Ecto.Migration

  # A part may be performed by any node that shares the run's directory, so "who
  # has this part" has to be a fact two nodes can agree on — and it has to survive
  # one of them dying silently (`Monty.Studio.Claim`).
  #
  # `claim` is the token of the node's claim: generated per claim, written before
  # the part is performed, and the thing every write about the part is checked
  # against. A node whose claim lapsed and was given to a peer still holds its
  # token; the row no longer does, so its write is refused rather than allowed to
  # overwrite the peer's.
  #
  # `claimed_until` is when the claim lapses if it is not renewed. A live part
  # renews as it steps; a part whose claim has passed is a part nobody is working
  # on any more, which is what makes it reassignable without a person unlocking
  # anything.
  def change do
    alter table(:studio_run_parts) do
      add :claim, :string
      add :claimed_until, :utc_datetime_usec
    end

    # The question the recovery path asks is "which parts of this run have a
    # lapsed claim" — one run's rows, read together.
    create index(:studio_run_parts, [:run_id, :claimed_until])
  end
end
