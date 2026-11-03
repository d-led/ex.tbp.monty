defmodule Monty.Simulators.Mujoco.AnswerTest do
  @moduledoc """
  The two halves of one format: `world.py` writes an answer, this reads it.

  Both sides are exercised for real — the Python helper out of the shipped
  `world.py` and the Elixir reader — because a format with one side tested
  against a copy of itself is two formats waiting to disagree. The expectation is
  always what `numpy.tolist()` would have produced, which is what the JSON these
  bytes replaced used to carry.
  """

  use ExUnit.Case, async: false

  alias Monty.Simulators.Mujoco.Answer

  @world_path :ex_tbp_monty |> :code.priv_dir() |> Path.join("monty_py") |> to_string()

  # The world's own answer, for a payload written as Python.
  defp decode(payload) do
    code = """
    import json
    import sys

    import numpy as np

    search_path = json.loads(search_path)

    if search_path not in sys.path:
        sys.path.insert(0, search_path)

    from world import _answer

    _answer(#{payload})
    """

    {result, _globals} = Pythonx.eval(code, %{"search_path" => Jason.encode!(@world_path)})

    result |> Pythonx.decode() |> Answer.decode()
  end

  # The transport this replaced: `json.dumps(payload, default=_json_default)`,
  # read back with Jason. Kept here as the referee for the format above.
  defp decode_as_json(payload) do
    code = """
    import json
    import sys

    import numpy as np

    search_path = json.loads(search_path)

    if search_path not in sys.path:
        sys.path.insert(0, search_path)

    from world import _json_default

    json.dumps(#{payload}, default=_json_default)
    """

    {result, _globals} = Pythonx.eval(code, %{"search_path" => Jason.encode!(@world_path)})

    result |> Pythonx.decode() |> Jason.decode!()
  end

  describe "an array" do
    test "comes back as the rows tolist would have nested it in" do
      answer = decode("{\"image\": np.arange(6, dtype=np.float64).reshape(2, 3)}")

      assert answer["image"] == [[0.0, 1.0, 2.0], [3.0, 4.0, 5.0]]
    end

    test "keeps three dimensions of a patch's rgba" do
      answer = decode("{\"rgba\": np.arange(8, dtype=np.uint8).reshape(2, 2, 2)}")

      assert answer["rgba"] == [[[0, 1], [2, 3]], [[4, 5], [6, 7]]]
    end

    test "carries a semantic mask as the integers it holds" do
      answer = decode("{\"semantic\": np.array([-1, 0, 3], dtype=np.int32)}")

      assert answer["semantic"] == [-1, 0, 3]
    end

    test "of one dimension comes back as one row" do
      answer = decode("{\"vector\": np.array([0.5, -1.25], dtype=np.float64)}")

      assert answer["vector"] == [0.5, -1.25]
    end

    test "of float32 keeps its own precision" do
      answer = decode("{\"values\": np.array([[0.5, 1.5]], dtype=np.float32)}")

      assert answer["values"] == [[0.5, 1.5]]
    end

    test "is read whatever dtype the world put in it" do
      answer =
        decode("""
        {
            "f8": np.array([1.5], dtype=np.float64),
            "f4": np.array([1.5], dtype=np.float32),
            "i8": np.array([-2], dtype=np.int64),
            "i4": np.array([-2], dtype=np.int32),
            "u4": np.array([2], dtype=np.uint32),
            "u1": np.array([2], dtype=np.uint8),
            "i1": np.array([-2], dtype=np.int8),
        }
        """)

      assert answer["f8"] == [1.5]
      assert answer["f4"] == [1.5]
      assert answer["i8"] == [-2]
      assert answer["i4"] == [-2]
      assert answer["u4"] == [2]
      assert answer["u1"] == [2]
      assert answer["i1"] == [-2]
    end

    test "of no dimensions comes back as the number itself" do
      assert decode(~s|{"scalar": np.array(3.5, dtype=np.float64)}|)["scalar"] == 3.5
    end
  end

  describe "the rest of the answer" do
    test "arrives untouched around the arrays" do
      answer =
        decode("""
        {
            "observations": {"agent_id_0": {"patch": {"depth": np.zeros((2, 2)), "range": 0.25}}},
            "primary_target": None,
            "semantic_id_to_label": {1: "mug"},
            "pass": True,
        }
        """)

      assert answer["observations"]["agent_id_0"]["patch"]["depth"] == [[0.0, 0.0], [0.0, 0.0]]
      assert answer["observations"]["agent_id_0"]["patch"]["range"] == 0.25
      assert answer["primary_target"] == nil
      assert answer["semantic_id_to_label"] == %{"1" => "mug"}
      assert answer["pass"] == true
    end

    test "is what the JSON transport decoded to, term for term" do
      # The whole reason this format is safe to change: the old path and the new
      # one are run over one payload, and the answer must be the same term.
      payload = """
      {
          "observations": {
              "agent_id_0": {
                  "patch": {
                      "depth": np.arange(6, dtype=np.float64).reshape(2, 3) / 7.0,
                      "rgba": np.arange(8, dtype=np.uint8).reshape(2, 2, 2),
                      "semantic": np.array([[-1, 0], [3, 3]], dtype=np.int32),
                      "cam_to_world": np.eye(4, dtype=np.float64),
                      "range": 0.25,
                  }
              }
          },
          "proprioceptive_state": {"agent_id_0": {"position": [0.0, 0.0, 0.1]}},
          "primary_target": None,
          "semantic_id_to_label": {1: "mug"},
      }
      """

      assert decode(payload) == decode_as_json(payload)
    end

    test "orders the arrays by the header, not by where they sit in the payload" do
      answer =
        decode("""
        {"second": np.array([[4, 5]], dtype=np.int32), "first": np.array([[1, 2, 3]], dtype=np.int32)}
        """)

      assert answer["first"] == [[1, 2, 3]]
      assert answer["second"] == [[4, 5]]
    end
  end

  describe "a value that cannot cross" do
    test "is refused rather than read as a shorter array" do
      # JSON could not have carried a NaN either — `json.dumps` writes `NaN`,
      # which is not JSON and which `Jason` refuses. The count is what notices.
      assert_raise ArgumentError, ~r/not finite cannot cross/, fn ->
        decode(~s|{"depth": np.array([1.0, float("nan")], dtype=np.float64)}|)
      end
    end

    test "is refused by name when the dtype has no reader" do
      assert_raise ArgumentError, ~r/an array of <c16 has no known width/, fn ->
        decode(~s|{"complex": np.array([1 + 2j], dtype=np.complex128)}|)
      end
    end
  end
end
