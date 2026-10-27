defmodule Monty.Frameworks.Models.EvidenceMatching.ChannelsTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Models.EvidenceMatching.Channels

  describe "all_usable_input_channels/2" do
    test "keeps the channels that are both observed and stored in the graph" do
      features = %{"pose_vectors" => [[1.0, 0.0, 0.0]], "rgba" => [0.5, 0.5, 0.5]}
      all_input_channels = ["pose_vectors", "rgba", "curvature"]

      assert Channels.all_usable_input_channels(features, all_input_channels) ==
               ["pose_vectors", "rgba"]
    end

    test "a channel the sensor did not deliver cannot be matched" do
      assert Channels.all_usable_input_channels(%{"rgba" => [1.0]}, ["pose_vectors"]) == []
    end

    test "a channel the graph does not store is not matched either" do
      assert Channels.all_usable_input_channels(%{"depth" => [1.0]}, ["pose_vectors"]) == []
    end
  end
end
