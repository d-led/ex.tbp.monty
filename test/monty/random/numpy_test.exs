defmodule Monty.Random.NumpyTest do
  use ExUnit.Case, async: true

  alias Monty.Random.Numpy

  # An episode's seed from Monty's own `eval_stats.csv` — the first episode of
  # `base_config_10distinctobj_dist_agent`.
  @episode_seed 1_170_100_843

  # Every number in this file was printed by numpy 1.23.5 in Monty's own
  # environment. They are the specification: a generator that agrees with NumPy on
  # these agrees with it on what Monty draws, and one that does not is a different
  # experiment however plausible its statistics look.
  defmodule Fixtures do
    @moduledoc false

    def samples, do: [0.20329638816634776, 0.29085086873618826, 0.5237705430136725]
    def more_samples, do: [0.2641547205501692, 0.5900611060504631]

    def uniform_degrees, do: [-106.8133002601148, -75.29368725497223, 8.557395484922125]

    def normals, do: [-0.03260111614826397, -0.046248668844803296, -0.08595771088332692]

    def later_normals, do: [0.00866356735515495, -0.007990449831047498]

    def standard_normals, do: [-0.6520223229652794, -0.9249733768960658, -1.7191542176665382]

    def spare_normal, do: 0.173271347103099
  end

  describe "new/1" do
    # `RandomState(42).get_state()[1][:4]`, which is the seeded array itself.
    test "seeds the Mersenne Twister as NumPy seeds it" do
      state = Numpy.new(42)

      assert Tuple.to_list(state.key) |> Enum.take(4) == [
               42,
               3_107_752_595,
               1_895_908_407,
               3_900_362_577
             ]

      assert tuple_size(state.key) == 624
    end

    test "refuses a seed that is not one word, because NumPy would not seed it either" do
      assert_raise FunctionClauseError, fn -> Numpy.new(4_294_967_296) end
    end
  end

  describe "random_sample/1" do
    test "is NumPy's first draws" do
      {draws, _state} = draw(5, &Numpy.random_sample/1)

      assert draws ==
               Fixtures.samples() ++ Fixtures.more_samples()
    end

    test "gives the same numbers again from the same seed, which is the whole point" do
      {first, _state} = draw(5, &Numpy.random_sample/1)
      {second, _state} = draw(5, &Numpy.random_sample/1)

      assert first == second
    end
  end

  describe "uniform/3" do
    test "spreads NumPy's draw across the interval" do
      {draws, _state} = draw(3, &Numpy.uniform(&1, -180.0, 180.0))

      assert draws == Fixtures.uniform_degrees()
    end
  end

  describe "normal/3" do
    test "is NumPy's normals, scaled by the standard deviation" do
      {draws, _state} = draw(3, &Numpy.normal(&1, 0.0, 0.05))

      assert draws == Fixtures.normals()
    end

    test "keeps NumPy's spare draw, so what follows is its next normal and not another pair" do
      {first, state} = Numpy.normals(Numpy.new(@episode_seed), 3, 0.0, 0.05)
      {rest, _state} = Numpy.normals(state, 2, 0.0, 0.05)

      assert first == Fixtures.normals()
      assert rest == Fixtures.later_normals()
    end

    test "hands its spare to the next call, as NumPy does across an odd length" do
      {odd, state} = Numpy.normals(Numpy.new(@episode_seed), 3, 0.0, 1.0)
      {spare, _state} = Numpy.normal(state, 0.0, 1.0)

      assert odd == Fixtures.standard_normals()
      assert spare == Fixtures.spare_normal()
    end
  end

  defp draw(count, draw) do
    Enum.map_reduce(1..count, Numpy.new(@episode_seed), fn _draw, state -> draw.(state) end)
  end
end
