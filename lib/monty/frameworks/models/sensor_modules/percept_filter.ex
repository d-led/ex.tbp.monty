defmodule Monty.Frameworks.Models.SensorModules.PerceptFilter do
  @moduledoc """
  Something that decides whether a percept carries features or only a location.

  Mirrors `tbp/monty/frameworks/models/sensor_modules.py::PerceptFilter`, the
  protocol a sensor module's filter answers. `CameraSM` passes every percept
  through one: the default passes everything on, and `FeatureChangeFilter` sends
  a point to a learning module only when something about it changed enough to be
  worth learning.

  A filter is a value here, so what it remembers travels beside it rather than
  inside it: the callback takes the filter, the percept and that memory, and
  answers both the percept and the memory's next version.
  """

  alias Monty.Cmp.Message

  @type t :: struct()
  @type memory :: term()

  @doc "The percept, marked, and the filter's record of it."
  @callback call(t(), Message.t(), memory()) :: {Message.t(), memory()}

  @doc "The memory a new episode starts with, which is what `reset` answers."
  @callback reset(memory()) :: memory()
end
