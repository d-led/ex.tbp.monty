defmodule Monty.Frameworks.RunParallelTest do
  @moduledoc """
  Translations of `tests/unit/frameworks/run_parallel_test.py`.

  Monty's one `PerLMStatsTest.test_reconstructs_named_metrics` is excluded below:
  it sums a pandas `DataFrame` into named metrics, and this port has no
  `per_lm_stats/1` — see `docs/monty-differences.md` §2.52.
  """

  use ExUnit.Case, async: true

  alias Monty.Frameworks.RunParallel

  # Monty's `PerLMStatsTest` sums a pandas `DataFrame` into named metrics, and
  # this port has no `per_lm_stats/1` — see §2.52.
  # excluded test_reconstructs_named_metrics: pandas only; the run page reads the run record

  # Monty's `ParseEpisodeSpecTest`, one case for one case.
  describe "parse_episode_spec/2" do
    # test_selects_all
    test "nothing, an empty string, a colon and \"all\" are every episode" do
      assert RunParallel.parse_episode_spec(nil, 5) == [0, 1, 2, 3, 4]
      assert RunParallel.parse_episode_spec("", 3) == [0, 1, 2]
      assert RunParallel.parse_episode_spec(":", 3) == [0, 1, 2]
      assert RunParallel.parse_episode_spec("all", 4) == [0, 1, 2, 3]
    end

    # test_single_index_valid
    test "a single index is that episode" do
      assert RunParallel.parse_episode_spec("3", 6) == [3]
    end

    # test_single_index_out_of_bounds_raises
    test "an index the list does not have is refused" do
      assert_raise ArgumentError, ~r/not a valid index/, fn ->
        RunParallel.parse_episode_spec("5", 5)
      end
    end

    # test_closed_range
    test "a closed range is half-open, so its end is not selected" do
      assert RunParallel.parse_episode_spec("2:5", 10) == [2, 3, 4]
    end

    # test_closed_range_equal_start_end_invalid
    test "a range that starts and ends in the same place names nothing and is refused" do
      assert_raise ArgumentError, ~r/not a valid range/, fn ->
        RunParallel.parse_episode_spec("3:3", 10)
      end
    end

    # test_closed_range_start_greater_than_end_invalid
    test "a range that runs backwards is refused" do
      assert_raise ArgumentError, ~r/not a valid range/, fn ->
        RunParallel.parse_episode_spec("5:3", 10)
      end
    end

    # test_closed_range_end_equals_total_ok
    test "a range may end exactly at the end of the list" do
      assert RunParallel.parse_episode_spec("0:4", 4) == [0, 1, 2, 3]
    end

    # test_closed_range_end_greater_than_total_raises
    test "a range may not end past the end of the list" do
      assert_raise ArgumentError, ~r/not a valid range/, fn ->
        RunParallel.parse_episode_spec("0:6", 5)
      end
    end

    # test_open_left
    test "an open-left range starts at the first episode" do
      assert RunParallel.parse_episode_spec(":3", 10) == [0, 1, 2]
    end

    # test_open_left_requires_positive_end
    test "an open-left range that ends before the first episode is refused" do
      assert_raise ArgumentError, ~r/not a valid range/, fn ->
        RunParallel.parse_episode_spec(":0", 10)
      end
    end

    # test_open_right
    test "an open-right range runs to the end of the list" do
      assert RunParallel.parse_episode_spec("7:", 10) == [7, 8, 9]
    end

    # test_open_right_start_zero_ok
    test "an open-right range may start at the first episode" do
      assert RunParallel.parse_episode_spec("0:", 3) == [0, 1, 2]
    end

    # test_open_right_start_equals_total_invalid
    test "an open-right range may not start at the end of the list" do
      assert_raise ArgumentError, ~r/not a valid range/, fn ->
        RunParallel.parse_episode_spec("5:", 5)
      end
    end

    # test_mixed_selection
    test "indices and ranges mix in one selection" do
      assert RunParallel.parse_episode_spec("0,3,5:8", 10) == [0, 3, 5, 6, 7]
    end

    # test_duplicates_eliminated_and_sorted
    test "a repeated episode is selected once, and the answer is in order" do
      assert RunParallel.parse_episode_spec("2,2,1:3,0,0", 5) == [0, 1, 2]
    end

    # test_whitespace_is_ignored
    test "whitespace around a part, and around a range's colon, is ignored" do
      assert RunParallel.parse_episode_spec("  0 ,  2 : 4 , 3  ", 10) == [0, 2, 3]
    end

    # test_letters_in_closed_range_invalid
    test "letters where a range should be are not a selection" do
      assert_raise ArgumentError, ~r/not a valid selection/, fn ->
        RunParallel.parse_episode_spec("a:b", 10)
      end
    end

    # test_double_colon_invalid
    test "two colons are not a range" do
      assert_raise ArgumentError, ~r/not a valid selection/, fn ->
        RunParallel.parse_episode_spec("3::5", 10)
      end
    end

    # test_word_in_list_invalid
    test "a word among the indices is not a selection" do
      assert_raise ArgumentError, ~r/not a valid selection/, fn ->
        RunParallel.parse_episode_spec("0,foo,2", 10)
      end
    end

    # test_total_zero_all_is_empty
    test "a list with no episodes selects nothing" do
      assert RunParallel.parse_episode_spec("all", 0) == []
    end

    # test_total_zero_none_is_empty
    test "a list with no episodes and no selection selects nothing" do
      assert RunParallel.parse_episode_spec(nil, 0) == []
    end

    # test_total_zero_any_specific_raises
    test "a list with no episodes cannot be asked for an episode" do
      for selection <- ["0", ":1", "0:"] do
        assert_raise ArgumentError, fn -> RunParallel.parse_episode_spec(selection, 0) end
      end
    end
  end

  describe "filter_episode_configs/2" do
    test "keeps the entries the selection names, in their own order" do
      entries = ["first", "second", "third", "fourth"]

      assert RunParallel.filter_episode_configs(entries, "3,1:3") == ["second", "third", "fourth"]
    end
  end
end
