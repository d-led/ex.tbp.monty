defmodule Monty.Studio.Failure do
  @moduledoc """
  What stopped a run, said in words a person can act on.

  A record keeps two things: `reason`, which is always a sentence, and
  `technical` beside it when something crashed — the traceback, untouched, for
  whoever is debugging. `recorded/1` is the shape both arrive in, so the page
  shows the sentence plainly and keeps the traceback one fold away.

  Records written before that was true keep the traceback in `reason` itself, so
  `explain/1` reads those too: a banner becomes a sentence and the stacktrace
  beneath it becomes the fold. What it never does is hand a reader a dump of
  somebody's internals — an inspected tuple, a killed process — as the answer to
  "why did this stop". There is always a sentence; the detail is always kept.
  """

  @typedoc """
  A reason, explained.

  `technical` is `nil` when there was nothing to expand: a sentence we wrote, or
  a detail a newer record keeps in its own key instead. `prerequisites` says
  whether the prerequisites page is where a person would look next — a run that
  stopped because a file it reads is not here.
  """
  @type explained :: %{
          what: String.t(),
          hint: String.t() | nil,
          technical: String.t() | nil,
          prerequisites: boolean()
        }

  @simulator_hint "The simulator is the first thing to check: the run needs a world it can step."

  @killed "The run's process was killed, so it stopped where it stood."

  @killed_hint "Something outside the experiment ended it: a stop, a shutdown, or its code being rebuilt while it stepped. Start the run again."

  @exited "A process the run was waiting on exited, so the run stopped."

  @exited_hint "Nothing in the experiment raised. The run's own log says how far it got."

  @unreadable "The run stopped with an error this page cannot put in words."

  @unreadable_hint "The technical details hold what it was; the run's own log has the rest."

  @target_not_visible "The world could not put the object in front of the agent."

  @doc """
  Explains a reason a record keeps.

  A reason that is already a sentence stays one; a crash becomes a sentence
  about the run rather than about Elixir.
  """
  @spec explain(String.t() | nil) :: explained()
  def explain(nil),
    do: %{what: "It stopped without saying why.", hint: nil, technical: nil, prerequisites: false}

  def explain(reason) when is_binary(reason) do
    explained =
      case banner(reason) do
        {kind, message} -> translated(kind, message, reason)
        nil -> bare(reason)
      end

    # Where to look next is a property of the answer rather than of the branch
    # that produced it, so it is decided once, here.
    Map.put(explained, :prerequisites, points_at_prerequisites?(explained))
  end

  @doc """
  Explains a reason this application wrote, unfolding `technical` beside it.

  A record from before the two keys were split keeps its traceback in `reason`,
  and then the traceback it already had is the one to unfold — passing `nil`
  here must not drop it.
  """
  @spec explain(String.t() | nil, String.t() | nil) :: explained()
  def explain(reason, technical) do
    explained = explain(reason)
    %{explained | technical: technical || explained.technical}
  end

  @doc """
  A crash, as a record keeps it: the sentence under `reason`, the traceback
  under `technical`.

  `kind` is what `catch` was handed — `:error`, `:throw`, or `:exit` — and the
  last is how a process that was killed arrives: no experiment kills itself, so
  that one is explained as something outside it.
  """
  @spec crashed(atom(), term(), Exception.stacktrace()) :: %{String.t() => String.t() | nil}
  def crashed(kind, reason, stacktrace) do
    kind |> Exception.format(reason, stacktrace) |> explain() |> recorded()
  end

  @doc """
  A reason as a record keeps it: the sentence in `reason`, the detail beside it
  in `technical`, where the page looks for each.
  """
  @spec recorded(explained()) :: %{String.t() => String.t() | nil}
  def recorded(%{what: what, technical: technical}),
    do: %{"reason" => what, "technical" => technical}

  @doc """
  What stopped a run, however it reached us, in the shape a record keeps.

  An episode that died on a step carries the pair `crashed/3` built while the
  traceback still existed; an episode that would not start carries whatever the
  world or the config answered — an exception, a sentence, or a term. None of
  them may arrive as nothing: a record that says "failed" and stops there is the
  page this module exists to prevent.

  `nil` is the answer for an outcome that is not a failure at all — a run that
  finished, or one somebody stopped. The status says which; a reason beside it
  would read as something having gone wrong.
  """
  @spec stopped(term()) :: %{String.t() => String.t() | nil} | nil
  def stopped(outcome) when outcome in [:finished, :stopped], do: nil
  def stopped({:crashed, _step, reason}), do: stopped(reason)
  def stopped({:failed, sentence}) when is_binary(sentence), do: stopped(sentence)
  def stopped(%{"reason" => _} = recorded), do: recorded
  def stopped(%{__exception__: true} = exception), do: crashed(:error, exception, [])
  def stopped(sentence) when is_binary(sentence), do: sentence |> explain() |> recorded()

  # A scene that could not show the object is the commonest way an episode
  # fails to begin, and it deserves its own words rather than "unreadable".
  def stopped({:target_not_visible, _id} = reason),
    do: %{"reason" => @target_not_visible, "technical" => inspect(reason)}

  def stopped(term), do: term |> inspect() |> explain() |> recorded()

  # `Exception.format/3` opens with "** (Kind) message" and indents the stacktrace
  # beneath it. The kind is a module name for an error, a thrown value's own word
  # for a throw, and `EXIT`, sometimes with the process it came from, for a death.
  # Both halves are kept: the message is what we explain, the whole thing is what
  # "technical details" unfolds.
  defp banner(reason) do
    case Regex.run(~r/^\*\* \(([^)]*)\) ?(.*)$/m, reason) do
      [_all, kind, message] -> {kind(kind), String.trim(message)}
      nil -> nil
    end
  end

  # `EXIT from #PID<…>` and `exit` are the same thing to a reader, and the
  # process it came from is nobody's business on a page: the traceback keeps it.
  defp kind("EXIT" <> _from_a_process), do: "exit"
  defp kind(kind), do: kind

  # Not a banner: either one of our own sentences, or a value somebody inspected
  # into the record. A term is not an answer to "why did this stop", so it is
  # kept as the detail and answered with a sentence of ours.
  defp bare(reason) do
    case weak_tuple(reason) do
      nil -> if dump?(reason), do: unreadable(reason), else: plain(reason)
      text -> %{what: text, hint: @simulator_hint, technical: reason}
    end
  end

  # The page is offered where an explanation already says to look there: a
  # missing file's hint names it, and a setup finding that a model has no memory
  # says so in its own sentence. A killed process and an abandoned record say
  # nothing about files, and a link from every failure sent people to a page
  # with nothing on it for them.
  defp points_at_prerequisites?(%{what: what, hint: hint}),
    do: names_the_page?(what) or names_the_page?(hint)

  defp names_the_page?(nil), do: false
  defp names_the_page?(text), do: String.contains?(text, "prerequisites")
  # A sentence never opens the way a term does.
  defp dump?(text), do: String.match?(text, ~r/^\s*(#|%|\{|\[|:")/)

  defp unreadable(reason) do
    %{what: @unreadable, hint: @unreadable_hint, technical: reason}
  end

  # Already our own words — a stop, an end, an abandoned record. Nothing to
  # translate, nothing to unfold.
  defp plain(reason), do: %{what: reason, hint: nil, technical: nil}

  defp translated(kind, message, reason) do
    case about(kind, message, reason) do
      {what, hint} -> %{what: what, hint: hint, technical: reason}
      nil -> %{what: sentence(kind, message), hint: nil, technical: reason}
    end
  end

  # A process was killed. `Process.exit(pid, :kill)` cannot be trapped, so this
  # is never the experiment's own doing: a stop, a shutdown, or a rebuild that
  # purged the code the stepping process was running.
  defp about("exit", message, _reason), do: exit_words(message)

  # The ones worth a sentence of their own, because the exception's own words are
  # about machinery the reader has never seen. Matched on what was said rather
  # than on where it was raised, so a move of the code does not lose the message.
  defp about(_kind, message, reason) do
    cond do
      message =~ "sets a pose outright" or message =~ "stand-in world" ->
        {"This world cannot be posed directly, so the agent cannot be placed in it.",
         "Run it against a simulator — MuJoCo, in this application — or pick an experiment whose agent starts where the stand-in puts it."}

      reason =~ "Monty.Simulators.Mujoco.Host" and reason =~ "time out" ->
        {"The world stopped answering: MuJoCo did not return a step in two minutes.",
         "That is the simulator, not the model. Try the run again — and if it repeats, the stand-in scene is a way to check that the rest of the experiment still steps."}

      message =~ "no such file" or message =~ "enoent" ->
        {"A file the run needs is not there.",
         "The prerequisites page lists what an experiment expects to find on disk."}

      true ->
        nil
    end
  end

  defp exit_words(message) do
    if message =~ "kill",
      do: {@killed, @killed_hint},
      else: {@exited, @exited_hint}
  end

  defp weak_tuple(message) do
    case Regex.run(~r/^\{:simulator_exited, (\d+)\}$/, message) do
      [_, code] -> "The simulator stopped while the run was stepping (exit code #{code})."
      nil -> nil
    end
  end

  # Every other exception keeps its own sentence: the message is written by
  # whoever raised it, and it is usually the most useful thing there is — it just
  # does not need the stacktrace underneath it on a page meant to be read. A
  # thrown term is not that message, and gets one of ours.
  defp sentence(kind, ""), do: "The run stopped with an error (#{kind})."
  defp sentence(_kind, message) when is_binary(message), do: sayable(message)

  defp sayable(message) do
    if dump?(message), do: @unreadable, else: first_sentence(message)
  end

  defp first_sentence(message) do
    message
    |> String.split("\n")
    |> List.first()
    |> String.replace_prefix("** ", "")
    |> String.trim()
  end
end
