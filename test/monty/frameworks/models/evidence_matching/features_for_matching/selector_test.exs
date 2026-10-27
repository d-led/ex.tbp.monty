defmodule Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.SelectorTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.AllSelector.AllFeaturesForMatchingSelector

  alias Monty.Frameworks.Models.EvidenceMatching.FeaturesForMatching.Selector.DefaultFeaturesForMatchingSelector

  @tolerances %{"patch" => %{"curvature" => 0.1}, "view_finder" => %{"rgba" => 0.1}}

  describe "DefaultFeaturesForMatchingSelector.select/3" do
    test "a channel weighted on a real feature is matched on its features" do
      weights = %{"patch" => %{"curvature" => 1}}
      tolerances = %{"patch" => %{}}

      assert DefaultFeaturesForMatchingSelector.select(1, weights, tolerances) == %{
               "patch" => true
             }
    end

    test "a channel weighted only on poses is matched by pose alone" do
      weights = %{"patch" => %{"pose_vectors" => [10, 10, 10], "pose_fully_defined" => 1}}
      tolerances = %{"patch" => %{}}

      assert DefaultFeaturesForMatchingSelector.select(1, weights, tolerances) == %{
               "patch" => false
             }
    end

    test "a channel the experiment never weighted is not matched" do
      assert DefaultFeaturesForMatchingSelector.select(1, %{}, @tolerances) == %{
               "patch" => false,
               "view_finder" => false
             }
    end

    test "feature evidence that counts for nothing switches features off everywhere" do
      weights = %{"patch" => %{"curvature" => 1}, "view_finder" => %{"rgba" => 1}}

      assert DefaultFeaturesForMatchingSelector.select(0, weights, @tolerances) == %{
               "patch" => false,
               "view_finder" => false
             }
    end

    test "every channel in the tolerances gets an answer" do
      weights = %{"patch" => %{"curvature" => 1}}

      assert DefaultFeaturesForMatchingSelector.select(1, weights, @tolerances) == %{
               "patch" => true,
               "view_finder" => false
             }
    end
  end

  describe "AllFeaturesForMatchingSelector.select/3" do
    test "a channel weighted only on poses is still matched on its features" do
      weights = %{"patch" => %{"pose_vectors" => [10, 10, 10]}}

      assert AllFeaturesForMatchingSelector.select(1, weights, @tolerances) == %{
               "patch" => true,
               "view_finder" => false
             }
    end

    test "feature evidence that counts for nothing still switches features off" do
      weights = %{"patch" => %{"curvature" => 1}, "view_finder" => %{"rgba" => 1}}

      assert AllFeaturesForMatchingSelector.select(0, weights, @tolerances) == %{
               "patch" => false,
               "view_finder" => false
             }
    end
  end
end
