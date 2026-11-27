defmodule Monty.Frameworks.Experiments.ProfileTest do
  @moduledoc """
  Translations of `tests/unit/frameworks/experiments/profile_experiment_mixin_test.py`.

  Monty's four cases all ask about `ProfileExperimentMixin.__init_subclass__`: that
  the mixin may only be the leftmost base class, that it has to be mixed in with
  a `MontyExperiment`, and that a subclass of a subclass is detected. Python's
  base-class order is what they police, and Elixir composes by `use` rather than
  by a chain of base classes — there is no order to get wrong, so there is
  nothing to assert.

  The mixin's other job, wrapping a phase in `cProfile` and writing the profile as
  a pandas CSV, is excluded with the module: profiling here is `:eprof`/`:fprof`,
  and a step's timings are the run record's. A file with no tests is the honest
  shape of that.
  """

  use ExUnit.Case, async: true

  # excluded test_leftmost_subclassing_does_not_error: Python's base-class order; Elixir composes by `use`
  # excluded test_non_leftmost_subclassing_raises_error: Python's base-class order
  # excluded test_missing_experiment_base_raises_error: Python's base-class order
  # excluded test_experiment_subclasses_are_properly_detected: asserts nothing; it only builds two classes
end
