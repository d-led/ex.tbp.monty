defmodule Monty.Frameworks.Environments.PositioningProcedures.ObjectNotVisibleError do
  @moduledoc """
  Raised when a single-object scene shows no object to position against.

  Mirrors
  `tbp/monty/frameworks/environments/positioning_procedures.py::ObjectNotVisibleError`.
  A multi-object scene treats "the target is not in view" as an answer — the
  procedure declines to move and the episode starts from where it is — but a
  single-object scene has nothing else to look at, so it is a fault in how the
  episode was set up.
  """

  defexception message: "May be initializing experiment with no visible target object"
end
