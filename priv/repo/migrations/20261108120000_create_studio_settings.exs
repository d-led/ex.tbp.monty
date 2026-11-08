defmodule ExTbpMonty.Repo.Migrations.CreateStudioSettings do
  use Ecto.Migration

  # What an operator changes while the application is running, as opposed to what
  # is fixed when it boots (`config/config.exs`, a restart). A key/value table
  # rather than a column per knob: the set of knobs changes with the features,
  # and a migration per knob is a migration nobody wants to review.
  def change do
    create table(:studio_settings, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :string, null: false

      timestamps()
    end
  end
end
