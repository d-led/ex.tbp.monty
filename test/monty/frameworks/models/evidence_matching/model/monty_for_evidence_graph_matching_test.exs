defmodule Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatchingTest do
  use ExUnit.Case, async: true

  alias Monty.Cmp.Message
  alias Monty.Frameworks.Models.EvidenceMatching.Model.MontyForEvidenceGraphMatching
  alias Monty.Geometry.{OrientationMatrix, SurfacePoseVectors}

  @identity [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
  # A quarter turn about z, as a frame of three rows.
  @quarter_turn [[0.0, -1.0, 0.0], [1.0, 0.0, 0.0], [0.0, 0.0, 1.0]]

  # A sensor whose pose vectors are `frame`, standing at `location` in the body.
  defp pose(location, frame \\ @identity), do: [location | frame]

  defp vote(states, sensed_pose),
    do: %{possible_states: states, sensed_pose_rel_body: sensed_pose}

  # What a learning module says it can see: a place on the object, the frame it
  # believes that place is seen from, and how strongly.
  defp vote_for(
         location,
         confidence,
         sensed_pose,
         pose_vectors \\ %OrientationMatrix{value: @identity}
       ) do
    {:ok, message} =
      Message.new(
        location: location,
        morphological_features: %{
          "pose_vectors" => pose_vectors,
          "pose_fully_defined" => true
        },
        non_morphological_features: %{},
        confidence: confidence,
        pass_message: true,
        process_features_in_lm: true,
        sender_id: "learning_module_1",
        sender_type: :lm
      )

    vote(%{"mug" => [message]}, sensed_pose)
  end

  describe "combine_votes/2" do
    test "moves a vote by the distance between the two sensors" do
      # Two sensors on the same body, one a hand's width to the right of the
      # other, both looking the same way: a place the sender points at is the
      # same place, described from the other sensor's position.
      sender = vote_for([0.0, 0.0, 0.5], 0.7, pose([0.0, 0.0, 0.0]))
      receiver = vote_for([0.0, 0.0, 0.0], 0.7, pose([0.1, 0.0, 0.0]))

      combined =
        MontyForEvidenceGraphMatching.combine_votes(
          %{sender: sender, receiver: receiver},
          %{receiver: [:sender]}
        )

      assert %{receiver: %{"mug" => [%Message{} = heard]}} = combined
      assert [x, y, z] = heard.location
      assert_in_delta x, 0.1, 1.0e-12
      assert_in_delta y, 0.0, 1.0e-12
      assert_in_delta z, 0.5, 1.0e-12
      assert heard.confidence == 0.7
    end

    test "turns the vote into the receiver's frame" do
      # The sending sensor is turned a quarter turn against the receiving one,
      # so the vote arrives turned the other way: what was the sender's
      # "forward" is the receiver's "right".
      sender = vote_for([0.0, 0.0, 0.0], 0.7, pose([0.0, 0.0, 0.0], @quarter_turn))
      receiver = vote_for([0.0, 0.0, 0.0], 0.7, pose([0.1, 0.0, 0.0]))

      combined =
        MontyForEvidenceGraphMatching.combine_votes(
          %{sender: sender, receiver: receiver},
          %{receiver: [:sender]}
        )

      assert %{receiver: %{"mug" => [%Message{morphological_features: features} = heard]}} =
               combined

      assert %OrientationMatrix{value: heard_frame} = features["pose_vectors"]
      assert heard_frame == [[0.0, 1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, 1.0]]
      assert [x, _y, _z] = heard.location
      assert_in_delta x, 0.1, 1.0e-12
    end

    test "one vote reaches each receiver in that receiver's own frame" do
      sender = vote_for([0.0, 0.0, 0.0], 0.7, pose([0.0, 0.0, 0.0]))
      left = vote_for([0.0, 0.0, 0.0], 0.7, pose([-0.2, 0.0, 0.0]))
      right = vote_for([0.0, 0.0, 0.0], 0.7, pose([0.2, 0.0, 0.0]))

      combined =
        MontyForEvidenceGraphMatching.combine_votes(
          %{sender: sender, left: left, right: right},
          %{left: [:sender], right: [:sender]}
        )

      assert %{
               left: %{"mug" => [%Message{location: [left_x, _, _]}]},
               right: %{"mug" => [%Message{location: [right_x, _, _]}]}
             } = combined

      assert_in_delta left_x, -0.2, 1.0e-12
      assert_in_delta right_x, 0.2, 1.0e-12
    end

    test "a source with nothing to say contributes nothing" do
      receiver = vote_for([0.0, 0.0, 0.0], 0.7, pose([0.0, 0.0, 0.0]))

      combined =
        MontyForEvidenceGraphMatching.combine_votes(
          %{silent: nil, receiver: receiver},
          %{receiver: [:silent]}
        )

      assert combined == %{receiver: %{}}
    end

    test "a module that has no opinion of its own hears nothing" do
      sender = vote_for([0.0, 0.0, 0.5], 0.7, pose([0.0, 0.0, 0.0]))

      combined =
        MontyForEvidenceGraphMatching.combine_votes(
          %{sender: sender, receiver: nil},
          %{receiver: [:sender]}
        )

      assert combined == %{receiver: %{}}
    end

    test "two sources voting for the same object are both heard" do
      first = vote_for([0.0, 0.0, 0.5], 0.7, pose([0.0, 0.0, 0.0]))
      second = vote_for([0.0, 0.0, 0.5], 0.5, pose([0.0, 0.0, 0.0]))
      receiver = vote_for([0.0, 0.0, 0.0], 0.9, pose([0.0, 0.0, 0.0]))

      combined =
        MontyForEvidenceGraphMatching.combine_votes(
          %{first: first, second: second, receiver: receiver},
          %{receiver: [:first, :second]}
        )

      assert %{receiver: %{"mug" => heard}} = combined
      assert Enum.map(heard, & &1.confidence) == [0.7, 0.5]
    end

    test "a vote that cannot be turned is refused rather than moved wrongly" do
      # Monty raises a `TypeError` here: only an `OrientationMatrix` describes a
      # frame that can be rotated, and a vote carrying surface pose vectors
      # would be moved in a guessed direction if it were not refused.
      surface_pose =
        SurfacePoseVectors.new([0.0, 0.0, 1.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0])

      sender = vote_for([0.0, 0.0, 0.0], 0.7, pose([0.0, 0.0, 0.0]), surface_pose)
      receiver = vote_for([0.0, 0.0, 0.0], 0.7, pose([0.1, 0.0, 0.0]))

      assert_raise MatchError, fn ->
        MontyForEvidenceGraphMatching.combine_votes(
          %{sender: sender, receiver: receiver},
          %{receiver: [:sender]}
        )
      end
    end
  end
end
