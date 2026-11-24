defmodule Monty.Studio.EndlessTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Endless

  # A run's own id, unique per case so the shared table cannot make two tests
  # depend on each other.
  setup do
    %{run_id: "endless-test-#{System.unique_integer([:positive])}"}
  end

  describe "a run that did not ask to be open-ended" do
    test "has no switches, and nothing is created for it", %{run_id: run_id} do
      assert :ok = Endless.start(run_id, %{inputs: %{"episodes" => 3}})

      refute Endless.endless?(run_id)
      refute Endless.training?(run_id)
      assert Endless.settings(run_id) == nil
    end

    test "is not asked the model anything by a step", %{run_id: run_id} do
      # No row, so `sync/3` answers without touching a model that may not exist
      # — which is the promise that an ordinary run costs one absent lookup.
      assert :ok = Endless.sync(run_id, "no-such-model", :eval)
      assert Endless.settings(run_id) == nil
    end

    test "refuses a training switch", %{run_id: run_id} do
      assert {:error, :not_endless} = Endless.toggle_training(run_id)
      assert {:error, :not_endless} = Endless.set_training(run_id, true)
    end
  end

  describe "an open-ended run" do
    test "starts as its record asked it to", %{run_id: run_id} do
      assert :ok =
               Endless.start(run_id, %{inputs: %{"endless" => true, "training" => true}})

      assert Endless.endless?(run_id)
      assert Endless.training?(run_id)
      assert Endless.trained?(run_id)
    end

    test "starts not learning when the record asked for training but not for it", %{
      run_id: run_id
    } do
      assert :ok = Endless.start(run_id, %{inputs: %{"endless" => true}})

      assert Endless.endless?(run_id)
      refute Endless.training?(run_id)
      refute Endless.trained?(run_id)
    end

    test "can be switched while the run goes, and keeps that it learned", %{run_id: run_id} do
      :ok = Endless.start(run_id, %{inputs: %{"endless" => true}})

      assert {:ok, true} = Endless.toggle_training(run_id)
      assert Endless.training?(run_id)
      assert Endless.trained?(run_id)

      assert {:ok, false} = Endless.toggle_training(run_id)
      refute Endless.training?(run_id)
      assert Endless.trained?(run_id)
    end

    test "follows the episode's own mode when the record did not decide", %{run_id: run_id} do
      # An evaluation episode and no training asked for: the first step decides
      # "no" without telling the model anything, because it already holds that.
      :ok = Endless.start(run_id, %{inputs: %{"endless" => true}})

      assert :ok = Endless.sync(run_id, "no-such-model", :eval)

      settings = Endless.settings(run_id)
      assert settings.applied == :eval
      refute Endless.training?(run_id)
    end

    test "is forgotten when it closes", %{run_id: run_id} do
      :ok = Endless.start(run_id, %{inputs: %{"endless" => true}})

      assert :ok = Endless.clear(run_id)
      refute Endless.endless?(run_id)
    end
  end

  describe "what telling the model a mode costs" do
    test "nothing when it already holds it" do
      assert Endless.next_mode(:eval, :eval) == :same
      assert Endless.next_mode(:train, :train) == :same
    end

    test "the new mode when it does not" do
      assert Endless.next_mode(:eval, :train) == {:change, :train}
      assert Endless.next_mode(:train, :eval) == {:change, :eval}
    end
  end
end
