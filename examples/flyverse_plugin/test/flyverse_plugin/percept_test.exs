defmodule FlyversePlugin.PerceptTest do
  use ExUnit.Case, async: true

  alias FlyversePlugin.Percept

  describe "nearness" do
    test "a uniform view is equally near on both sides" do
      assert Percept.nearness([[0.5, 0.5, 0.5, 0.5], [0.5, 0.5, 0.5, 0.5]]) == {2.0, 2.0}
    end

    test "the half that holds the nearer surface is the nearer one" do
      assert Percept.nearness([[0.02, 0.02, 1.0, 1.0]]) == {50.0, 1.0}
    end

    test "a pixel that saw nothing contributes nothing" do
      assert Percept.nearness([[0.0, 0.0, 1.0, 1.0]]) == {0.0, 1.0}
    end

    test "an odd column goes to the right half" do
      # One column on the left at 0.5 m (2.0), two on the right at 0.25 and
      # 0.5 m (4.0 and 2.0): the odd column is counted with the right half, and a
      # side answers its nearest thing rather than its mean.
      assert Percept.nearness([[0.5, 0.25, 0.5]]) == {2.0, 4.0}
    end

    # A wide view is mostly room, and a mean over it answers the distance to the
    # room. One looming pixel is what a fly turns toward.
    test "one thing near on a side makes that side near" do
      mostly_far = [[799.0, 799.0, 0.3, 799.0]]

      assert {left, right} = Percept.nearness(mostly_far)
      assert left == 0.0
      assert right > left + 3.0, "the one near pixel is the whole of the right's nearness"
    end

    test "the far wall is not a destination" do
      assert Percept.nearness([[799.0, 799.0, 799.0, 799.0]]) == {0.0, 0.0}
    end
  end

  # A band is a run of columns and its own nearest thing, and two of them are the
  # two halves — which is why `nearness/1` is this function with `2`. The reason
  # the count is a parameter is the connectome's input: a pack names as many drive
  # groups as its sensory groups have, and a plan that names one index per group
  # is a retina, not a left and a right.
  describe "bands, one per drive group" do
    test "two bands are the two halves of the view" do
      rows = [[0.02, 0.02, 1.0, 1.0]]

      assert Percept.bands(rows, 2) == [50.0, 1.0]
      assert Percept.bands(rows, 2) == Tuple.to_list(Percept.nearness(rows))
    end

    test "a band per column, each its own nearest thing" do
      assert Percept.bands([[0.5, 0.25, 1.0, 2.0]], 4) == [2.0, 4.0, 1.0, 0.5]
    end

    # Columns do not divide evenly, and the remainder goes to a band that widens
    # rather than to a band that sees nothing.
    test "the bands cover the image when the columns do not divide evenly" do
      assert Percept.bands([[0.5, 0.25, 1.0, 2.0]], 3) == [2.0, 4.0, 1.0]
    end

    test "one band is the whole image, and a far one is nothing" do
      assert Percept.bands([[1.0, 0.5, 2.0]], 1) == [2.0]
      assert Percept.bands([[799.0, 799.0, 799.0]], 3) == [0.0, 0.0, 0.0]
    end
  end

  # A fly's eye reports light, not metres. The `rgba` a sensor records is the same
  # view a depth image is a rendering of, so the second channel is a colour per
  # pixel and a luminance per band — which is what a photoreceptor could answer and
  # a depth image cannot be asked for.
  describe "the colours to drive from" do
    test "a pixel is its luminance, with green weighing most" do
      assert {:ok, {"view_finder", [[white]]}} =
               Percept.luminance(
                 %{"agent_id_0" => %{"view_finder" => %{"rgba" => [[[255, 255, 255, 255]]]}}},
                 "agent_id_0",
                 nil
               )

      assert_in_delta white, 1.0, 1.0e-9

      assert {:ok, {"view_finder", [[black, red, green]]}} =
               Percept.luminance(
                 %{
                   "agent_id_0" => %{
                     "view_finder" => %{
                       "rgba" => [[[0, 0, 0, 255], [255, 0, 0, 255], [0, 255, 0, 255]]]
                     }
                   }
                 },
                 "agent_id_0",
                 nil
               )

      assert black == 0.0
      assert green > red
      assert red == Float.round(0.2126, 6) or abs(red - 0.2126) < 0.001
    end

    test "a channel that arrived as a float is taken at its word" do
      assert {:ok, {_sensor, [[white]]}} =
               Percept.luminance(
                 %{"agent_id_0" => %{"view_finder" => %{"rgba" => [[[1.0, 1.0, 1.0, 1.0]]]}}},
                 "agent_id_0",
                 nil
               )

      assert_in_delta white, 1.0, 1.0e-9
    end

    test "a world that renders no colours is refused, and the sentence says so" do
      assert {:error, sentence} =
               Percept.luminance(
                 %{"agent_id_0" => %{"view_finder" => %{"depth" => [[1.0]]}}},
                 "agent_id_0",
                 nil
               )

      assert sentence =~ "colours"
    end

    # A photoreceptor band can only report *change*, and the polarity is not the
    # detector's to choose: a surface growing in the view brightens or darkens its
    # band, and both loom.
    test "a band's change is its drive, whichever way it changed" do
      assert Percept.loom([1.0, 0.0], [0.0, 0.0], 20.0) == [20.0, 0.0]
      assert Percept.loom([0.0, 1.0], [1.0, 1.0], 20.0) == [20.0, 0.0]
      assert Percept.loom([0.5, 0.5], [0.5, 0.5], 20.0) == [0.0, 0.0]
    end

    test "a first step has nothing to be a change of" do
      assert Percept.loom([1.0, 0.0], nil, 20.0) == [0.0, 0.0]
    end

    test "a band's light is the mean of its columns" do
      rows = [[0.0, 0.0, 1.0, 1.0]]

      assert Percept.luminance_bands(rows, 2) == [0.0, 1.0]
      # The odd middle column goes to the right, as it does for the depth bands.
      assert Percept.luminance_bands([[0.2, 0.4, 0.8]], 2) == [0.2, 0.6000000000000001]
    end
  end

  describe "the image to drive from" do
    setup do
      observations = %{
        "agent_id_0" => %{
          "patch" => %{"depth" => [[0.1]]},
          "view_finder" => %{"depth" => [[0.2]]},
          "rgba" => %{"depth" => [[0.3]]}
        }
      }

      {:ok, observations: observations}
    end

    test "is the wide sensor when the policy names none", %{observations: observations} do
      assert Percept.image(observations, "agent_id_0", nil) == {:ok, {"view_finder", [[0.2]]}}
    end

    test "is the sensor the policy names", %{observations: observations} do
      assert Percept.image(observations, "agent_id_0", "patch") == {:ok, {"patch", [[0.1]]}}
    end

    test "is any sensor that saw something, when the ones Monty names did not", %{
      observations: observations
    } do
      observations = put_in(observations, ["agent_id_0"], %{"rgba" => %{"depth" => [[0.3]]}})

      assert Percept.image(observations, "agent_id_0", nil) == {:ok, {"rgba", [[0.3]]}}
    end

    test "is a sentence when no sensor saw anything" do
      assert {:error, sentence} = Percept.image(%{"agent_id_0" => %{}}, "agent_id_0", nil)
      assert sentence =~ "none of agent_id_0's sensors recorded a depth image"
    end

    test "is a sentence when the agent is not in the observations" do
      assert {:error, sentence} = Percept.image(%{}, "agent_id_0", nil)
      assert sentence =~ "recorded a depth image"
    end

    test "is a sentence when the step carried no observations" do
      assert {:error, sentence} = Percept.image(nil, "agent_id_0", nil)
      assert sentence =~ "recorded a depth image"
    end

    test "refuses a named sensor that recorded no depth", %{observations: observations} do
      assert {:error, sentence} = Percept.image(observations, "agent_id_0", "missing")
      assert sentence =~ "carry no depth for missing"
    end
  end
end
