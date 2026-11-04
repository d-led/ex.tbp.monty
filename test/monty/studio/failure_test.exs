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
      assert explained.prerequisites
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

    test "an abandoned record points at nothing, because no file would have kept it running" do
      explained =
        Failure.explain("it stopped before it finished — nothing was working on it any more")

      refute explained.prerequisites
    end

    test "a memory that was never exported points at the page that exports it" do
      explained =
        Failure.explain(
          "No memory this application can read for pretrained_ycb_v14, and a run " <>
            "without one cannot recognise any object. Fetch it at /prerequisites."
        )

      assert explained.prerequisites
    end

    test "a run that stopped without a reason says so" do
      assert Failure.explain(nil).what == "It stopped without saying why."
    end

    # What an Oban job records for a process that was killed: the shape that used
    # to reach the page unchanged, `#PID` and all.
    test "a killed process is said as something outside the experiment" do
      explained = Failure.explain("** (EXIT from #PID<0.5994.0>) killed")

      assert explained.what == "The run's process was killed, so it stopped where it stood."
      assert explained.hint =~ "outside the experiment"
      assert explained.technical =~ "#PID<0.5994.0>"
    end

    test "a process that exited without being killed is said as an exit" do
      assert Failure.explain("** (exit) :shutdown").what ==
               "A process the run was waiting on exited, so the run stopped."
    end

    test "a term in the record is the detail, never the answer" do
      dump = ~s({:cannot_record, #Ecto.Changeset<action: :insert>})

      explained = Failure.explain(dump)

      assert explained.what == "The run stopped with an error this page cannot put in words."
      assert explained.technical == dump
    end

    test "a thrown value is the detail too, not a sentence to read" do
      explained = Failure.explain("** (throw) {:stop, :here}\n    (ex_tbp_monty 0.1.0) x.ex:1")

      assert explained.what == "The run stopped with an error this page cannot put in words."
      assert explained.technical =~ "** (throw)"
    end
  end

  describe "a reason as a record keeps it" do
    # A record now has two keys: a page shows one and unfolds the other. A crash
    # that arrives as the pair must never put the traceback in the sentence.
    test "a crash keeps its sentence and its traceback apart" do
      recorded = Failure.crashed(:exit, :killed, [])

      assert recorded["reason"] == "The run's process was killed, so it stopped where it stood."
      assert recorded["technical"] =~ "** (exit)"
    end

    test "an exception is the sentence, and the banner under it is the detail" do
      recorded = Failure.crashed(:error, %RuntimeError{message: "the object fell off"}, [])

      assert recorded["reason"] == "the object fell off"
      assert recorded["technical"] =~ "RuntimeError"
    end

    test "a sentence with a detail beside it keeps both" do
      explained = Failure.explain("The run could not start.", ~s({:no_such_run, "x"}))

      assert explained.what == "The run could not start."
      assert explained.technical == ~s({:no_such_run, "x"})
    end

    test "a record written before the split still has its traceback unfolded" do
      explained = Failure.explain(@crash, nil)

      assert explained.technical == @crash
    end
  end
end
