defmodule Monty.Studio.RunTargetsTest do
  @moduledoc """
  What a phase of episodes knows about its own graphs when it ends.

  A training episode builds one graph and names it, so a phase of five episodes
  has five names to write down. Only the last one reached the library, and a
  five-dog library was written with every graph called `new_object0` — a memory
  nothing can score, because a recognition that settles on it has no dog to name.
  """

  use ExUnit.Case, async: true

  alias Monty.Studio.Run

  describe "a phase's graph names" do
    test "every episode's graph is named, not only the last one's" do
      first_episode = %{learning_module_0: %{"new_object0" => ["milka"]}}
      second_episode = %{learning_module_0: %{"new_object1" => ["puppy"]}}

      assert %{learning_module_0: %{"new_object0" => ["milka"], "new_object1" => ["puppy"]}} =
               Run.merge_targets(first_episode, second_episode)
    end

    test "a graph both episodes met keeps both names, each once, in order" do
      learned_so_far = %{learning_module_0: %{"new_object0" => ["puppy", "milka"]}}
      this_episode = %{learning_module_0: %{"new_object0" => ["milka", "kinder_guard_dog"]}}

      assert %{learning_module_0: %{"new_object0" => ["kinder_guard_dog", "milka", "puppy"]}} =
               Run.merge_targets(learned_so_far, this_episode)
    end

    test "a module this episode says nothing about keeps what it had" do
      learned_so_far = %{learning_module_0: %{"new_object0" => ["milka"]}}
      this_episode = %{learning_module_0: %{}}

      assert Run.merge_targets(learned_so_far, this_episode) == learned_so_far
    end

    test "the first episode of a phase is its whole answer" do
      first_episode = %{learning_module_0: %{"new_object0" => ["milka"]}}

      assert Run.merge_targets(%{}, first_episode) == first_episode
    end
  end
end
