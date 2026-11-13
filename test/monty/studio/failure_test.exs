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

  describe "a crash that reached an outcome" do
    # What the episode loop puts in `{:crashed, step, reason}` is whatever
    # stopped it: the pair `crashed/3` builds when a step died, or a bare term
    # an episode that would not start answered with. Both are what the record
    # keeps, and neither may arrive as nothing.
    test "a crash written on a step is kept exactly as it was written" do
      recorded = Failure.crashed(:error, %RuntimeError{message: "the motor disagreed"}, [])

      assert Failure.stopped({:crashed, 7, recorded}) == recorded
    end

    test "an outcome that is not a failure has nothing to explain" do
      assert Failure.stopped(:finished) == nil
      assert Failure.stopped(:stopped) == nil
    end

    test "an exception that arrived on its own keeps its own sentence" do
      stored = Failure.stopped(%RuntimeError{message: "the motor disagreed"})

      assert stored["reason"] == "the motor disagreed"
      assert stored["technical"] =~ "RuntimeError"
    end

    test "a sentence the world answered with stays a sentence" do
      assert Failure.stopped("idx must satisfy 0 <= idx < 3")["reason"] ==
               "idx must satisfy 0 <= idx < 3"
    end

    # The one thing a record must never do with a term is pass it off as the
    # answer to "why did this stop".
    test "a term is the detail, and says so in a sentence" do
      stored = Failure.stopped({:positioning_did_not_finish, 5})

      assert stored["reason"] == "The run stopped with an error this page cannot put in words."
      assert stored["technical"] == "{:positioning_did_not_finish, 5}"
    end

    # "The object was not in view" is a run that could not start, not an
    # unreadable one: it is the commonest way an episode fails to begin.
    test "an object the world could not show is said plainly" do
      stored = Failure.stopped({:target_not_visible, 3})

      assert stored["reason"] == "The world could not put the object in front of the agent."
      assert stored["technical"] == "{:target_not_visible, 3}"
    end
  end

  # A call to another node's process exits with the request it was making, which
  # for a policy is the policy and the observations it was deciding on. A run's
  # page showed exactly that as the reason it failed, so the tag is asked for by
  # name and everything it carried is dropped.
  describe "why a call to another process did not come back" do
    test "a process that is gone is said as a process that is gone" do
      reason = {:noproc, {GenServer, :call, [self(), {:call, %{answer: 42}}, 5_000]}}

      assert Failure.lost(reason) ==
               "its process is gone: the node restarted, or the plugin stopped"
    end

    test "a node that left is said as a node that left" do
      assert Failure.lost({:nodedown, :"plugin@10.0.0.7"}) == "its node left the cluster"
    end

    test "a node that did not answer says so without the request it sat on" do
      reason = {:timeout, {GenServer, :call, [self(), {:call, %{answer: 42}}, 5_000]}}

      assert Failure.lost(reason) == "it did not answer in time"
    end

    test "an exception the call exited with keeps its own sentence, not its trace" do
      assert Failure.lost({%RuntimeError{message: "the policy refused"}, []}) ==
               "the policy refused"
    end

    test "a reason nothing here knows is still a sentence" do
      assert Failure.lost({:nonsense, [1, 2, 3]}) == "it stopped without saying why"
      assert Failure.lost(:killed) == "it was killed"
    end
  end

  describe "why a part could not be taken" do
    test "a part somebody is performing names whose it is and until when" do
      assert Failure.unclaimable({:held, "peer@10.0.0.7", ~U[2026-11-13 12:04:11Z]}) ==
               "in peer@10.0.0.7's hands until 12:04"
    end

    test "a holder whose lease end is not known is still named" do
      assert Failure.unclaimable({:held, "peer@10.0.0.7", nil}) == "in peer@10.0.0.7's hands"
    end

    test "a part that already ended says so, and how" do
      assert Failure.unclaimable({:settled, "finished"}) == "already ended (finished)"
    end

    test "a part the run does not have is said as a part the run does not have" do
      assert Failure.unclaimable(:not_planned) == "not part of this run"
    end

    test "a refusal nothing here knows is still words" do
      assert Failure.unclaimable({:nonsense, [1, 2, 3]}) == "somebody else's to take"
    end
  end

  # A part's answer is a tag and its arguments. The run wrote the tag, and a tag
  # with a node and a timestamp inside it says nothing a person can act on.
  describe "why a part did not finish" do
    test "a part another node was performing names that node" do
      assert Failure.part({:unclaimable, {:held, "peer@10.0.0.7", nil}}) ==
               "it is in peer@10.0.0.7's hands"
    end

    test "a division with nowhere to put a part says it had nowhere to put it" do
      assert Failure.part({:no_node_for_part, 2}) == "no node could take it"
    end

    test "a part whose node died keeps the reason the node died of" do
      reason = {:noproc, {GenServer, :call, [self(), :part, 5_000]}}

      assert Failure.part({:peer_failed, "peer@10.0.0.7", reason}) ==
               "peer@10.0.0.7 stopped performing it: its process is gone: " <>
                 "the node restarted, or the plugin stopped"
    end

    test "a part taken over mid-work says who took it" do
      assert Failure.part({:lease_lost, "peer@10.0.0.7"}) ==
               "peer@10.0.0.7 took it over while it was being performed"
    end

    test "a part a node could not speak to says which version it speaks" do
      assert Failure.part({:incompatible_peer, "monty-cluster/9", "monty-cluster/8"}) ==
               "the node that took it speaks monty-cluster/9, this run speaks monty-cluster/8"
    end

    test "a part that crashed keeps the sentence its crash was recorded as" do
      crashed = Failure.crashed(:error, %RuntimeError{message: "the world would not start"}, [])

      assert Failure.part(crashed) == "the world would not start"
    end

    test "a part that stopped for a reason with no words is still a sentence" do
      assert Failure.part(:unreadable) == "it stopped (unreadable)"
      assert Failure.part({:nonsense, [1, 2, 3]}) == "it stopped without saying why"
    end
  end

  # Every page that flashes "…: why" asks this — the world that would not open,
  # the runs that could not be deleted, the run that could not be queued — so the
  # colon is never followed by a tuple. The shapes here are the ones those
  # handlers are actually handed.
  describe "whatever arrived, in one sentence" do
    test "a reason a record wrote stays the sentence it is" do
      assert Failure.sentence("The world could not put the object in front of the agent.") ==
               "The world could not put the object in front of the agent."
    end

    test "text that is a dump is said plainly rather than shown" do
      assert Failure.sentence("{:positioning_did_not_finish, 5}") ==
               "The run stopped with an error this page cannot put in words."
    end

    test "a task that died with an exception keeps the exception's own words" do
      assert Failure.sentence({%RuntimeError{message: "no python in this image"}, []}) ==
               "no python in this image"
    end

    test "a task that stopped for a reason with no words is still a sentence" do
      assert Failure.sentence(:killed) == "it was killed"
    end

    test "nothing to say is still one sentence" do
      assert Failure.sentence(nil) == "It stopped without saying why."
    end
  end

  # A write that fails answers a POSIX atom, and the run's own log carried it as
  # `{:error, :enospc}`. The translation already exists in OTP; it just has to be
  # asked for.
  describe "a failed read or write" do
    test "a full disk says the disk is full" do
      assert Failure.file({:error, :enospc}) == "no space left on device"
    end

    test "a missing file says the file is missing, and a bare reason works too" do
      assert Failure.file(:enoent) == "no such file or directory"
    end

    test "a code OTP does not know is still named" do
      assert Failure.file(:not_a_posix_code) == "unknown POSIX error: not_a_posix_code"
    end

    test "a shape that is not an error at all is described, not pasted" do
      assert Failure.file({:something, :else}) ==
               "for a reason this page cannot read (something, else)"
    end
  end

  # A record that will not be written says so because a field is wrong, and the
  # keyword Ecto answers is not that sentence.
  describe "a changeset's refusals" do
    test "a field that is invalid is named with what is wrong with it" do
      assert Failure.complaints(steps: {"is invalid", [type: :integer]}) ==
               "steps is invalid"
    end

    test "several fields are one sentence" do
      assert Failure.complaints(steps: {"is invalid", []}, state: {"can't be blank", []}) ==
               "steps is invalid; state can't be blank"
    end

    test "a changeset that refused nothing is still a sentence" do
      assert Failure.complaints([]) == "it did not pass the record's own checks"
    end
  end

  describe "what an unexpected reply was" do
    test "a reply that carries something big is named by its tags" do
      assert Failure.reply({:ok, DateTime.utc_now()}) == "ok, a DateTime"
    end

    test "a reply of plain values keeps its values" do
      assert Failure.reply({:error, :busy}) == "error, busy"
      assert Failure.reply(:ok) == "ok"
      assert Failure.reply(%{"k" => "v"}) == "a map"
      assert Failure.reply([1, 2]) == "a list"
      assert Failure.reply("a sentence") == "text"
      assert Failure.reply(42) == "42"
      assert Failure.reply({:ok, self()}) == "ok, a value"
    end
  end
end
