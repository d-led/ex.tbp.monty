defmodule Monty.Studio.RunHistory.StalledTest do
  use ExTbpMonty.DataCase, async: false

  alias Monty.Studio.{RunHistory, Settings}

  setup do
    Settings.forget()
    on_exit(&Settings.forget/0)
    :ok
  end

  describe "a running record that has gone quiet" do
    test "is not progressing once it has been quiet for longer than the setting says" do
      quiet_for = fn seconds ->
        %RunHistory.Run{
          status: "running",
          updated_at: DateTime.add(DateTime.utc_now(), -seconds, :second)
        }
      end

      assert RunHistory.stalled?(quiet_for.(90))

      # The same silence, with a longer patience: the decision follows the
      # setting, which is the whole point of it being one.
      assert {:ok, 3600} = Settings.put("run_stale_after_s", 3600)
      refute RunHistory.stalled?(quiet_for.(90))
    end

    test "a run that has finished is never not progressing" do
      finished = %RunHistory.Run{
        status: "finished",
        updated_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      }

      refute RunHistory.stalled?(finished)
    end
  end
end
