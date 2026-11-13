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
