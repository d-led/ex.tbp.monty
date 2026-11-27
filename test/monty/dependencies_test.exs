defmodule Monty.DependenciesTest do
  @moduledoc """
  Translations of `tests/unit/dependencies_test.py`.

  Monty's file holds one case and no module under test: it imports
  `torch_geometric` to prove the library is installed. A dependency here is a
  line in `mix.exs`, and a missing library is a build failure rather than a test
  failure — so there is nothing to translate, and the case is recorded as an
  exclusion rather than dropped.

  A file with no tests is the honest shape of that, and the map says so:
  `mix monty.test_map` counts this case as excluded, not as outstanding.
  """

  use ExUnit.Case, async: true

  # excluded test_torch_geometric: an import check for a Python library; a dependency here is a line in mix.exs
end
