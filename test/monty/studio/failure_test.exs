defmodule Monty.Studio.FailureTest do
  use ExUnit.Case, async: true

  alias Monty.Studio.Failure

  # What `Exception.format/3` writes into a record: the exception first, then the
  # stacktrace that makes a page unreadable.
  @crash """
  ** (ArgumentError) Monty.Frameworks.Actions.SetAgentPose sets a pose outright, which the stand-in world does not do; use a simulator behind Monty.Simulators.Port.Environment instead
      (ex_tbp_monty 0.1.0) lib/monty/simulators/synthetic/kinematics.ex:118: Monty.Simulators.Synthetic.Kinematics.act/2
      (elixir 1.20.4) lib/enum.ex:2622: Enum."-reduce/3-lists^foldl/2-0-"/3
  """

  describe "explaining why a run stopped" do
    test "a world that cannot be posed is said in the terms of the world" do
      explained = Failure.explain(@crash)

      assert explained.what ==
               "This world cannot be posed directly, so the agent cannot be placed in it."

      assert explained.hint =~ "simulator"
    end

    test "the original is kept whole, for whoever wants it" do
      assert Failure.explain(@crash).technical == @crash
    end

    test "a simulator that exited says which code it exited with" do
      explained = Failure.explain("{:simulator_exited, 1}")

      assert explained.what == "The simulator stopped while the run was stepping (exit code 1)."
      assert explained.hint =~ "world"
    end

    test "a missing file points at where such things are listed" do
      explained =
        Failure.explain("** (File.Error) could not read file \"priv/data.txt\": no such file")

      assert explained.what == "A file the run needs is not there."
      assert explained.hint =~ "prerequisites"
    end

    test "any other exception keeps its own first line, without the trace" do
      explained =
        Failure.explain(
          "** (RuntimeError) the object fell off the table\n    (stdlib) :erlang.error/1"
        )

      assert explained.what == "the object fell off the table"
      assert explained.technical =~ ":erlang.error/1"
    end

    test "an exception with nothing to say is named" do
      assert Failure.explain("** (ArgumentError)").what ==
               "The run stopped with an error (ArgumentError)."
    end

    test "a sentence we wrote is left as it is, with nothing to unfold" do
      explained = Failure.explain("it was stopped before it finished")

      assert explained.what == "it was stopped before it finished"
      assert explained.hint == nil
      assert explained.technical == nil
    end

    test "a run that stopped without a reason says so" do
      assert Failure.explain(nil).what == "It stopped without saying why."
    end
  end
end
