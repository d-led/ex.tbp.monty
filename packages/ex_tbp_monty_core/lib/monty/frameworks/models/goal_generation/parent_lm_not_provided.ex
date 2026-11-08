defmodule Monty.Frameworks.Models.GoalGeneration.ParentLMNotProvided do
  @moduledoc """
  A goal generator was asked about its learning module before one was provided.

  Mirrors `tbp/monty/frameworks/models/goal_generation.py::ParentLMNotProvided`.
  A generator belongs to a module and reads its hypotheses, its most likely
  object and its buffer; without the module there is nothing to answer with, and
  answering `nil` would only move the failure to whoever dereferences it next.
  """

  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}

  @impl true
  def exception(_opts), do: %__MODULE__{message: "parent learning module has not been provided"}
end
