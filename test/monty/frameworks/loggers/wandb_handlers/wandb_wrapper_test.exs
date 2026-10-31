defmodule Monty.Frameworks.Loggers.WandbHandlers.WandbWrapperTest do
  use ExUnit.Case, async: true

  alias Monty.Frameworks.Loggers.WandbHandlers.WandbWrapper

  # A wandb that answers instead of dialling, and leaves the order of the calls
  # readable in the test process's mailbox.
  defmodule Client do
    def init(attributes) do
      send(self(), {:init, attributes})
      {:ok, :run}
    end

    def log(:run, payload) do
      send(self(), {:log, payload})
      {:ok, :run}
    end

    def finish(:run) do
      send(self(), :finish)
      :ok
    end
  end

  defmodule Child do
    defstruct reports: []

    def from_config(_config), do: %__MODULE__{}

    def log_level, do: :basic

    def report_episode(%__MODULE__{reports: reports}, _data, _output_dir, episode, _mode, _totals) do
      send(self(), {:reported, episode})
      {:ok, %__MODULE__{reports: [episode | reports]}}
    end

    def close(%__MODULE__{}), do: :ok
  end

  defmodule Refuser do
    defstruct []

    def from_config(_config), do: %__MODULE__{}

    def log_level, do: :basic

    def report_episode(%__MODULE__{}, _data, _output_dir, _episode, _mode, _totals),
      do: {:error, :refused}

    def close(%__MODULE__{}), do: :ok
  end

  defp wrapper(handlers) do
    WandbWrapper.new(handlers, client: Client, run_name: "experiment", config: %{"seed" => 42})
  end

  test "every handler reports the episode before the run is committed" do
    {:ok, _wrapper} =
      WandbWrapper.report_episode(wrapper([%Child{}, %Child{}]), %{}, "/tmp", 3, :train, %{})

    assert_received {:reported, 3}
    assert_received {:reported, 3}
    assert_received {:log, %{}}
  end

  test "the run is opened once, however many episodes are reported" do
    {:ok, wrapper} = WandbWrapper.report_episode(wrapper([%Child{}]), %{}, "/tmp", 0, :train, %{})
    {:ok, _wrapper} = WandbWrapper.report_episode(wrapper, %{}, "/tmp", 1, :train, %{})

    assert_received {:init, _attributes}
    refute_received {:init, _attributes}
  end

  test "the run carries Monty's name, group and config" do
    {:ok, _wrapper} =
      WandbWrapper.report_episode(wrapper([%Child{}]), %{}, "/tmp", 0, :train, %{})

    assert_received {:init, attributes}
    assert attributes["name"] == "experiment_"
    assert attributes["config"] == %{"seed" => 42}
  end

  test "a refused episode is not committed" do
    assert {:error, :refused} =
             WandbWrapper.report_episode(wrapper([%Refuser{}]), %{}, "/tmp", 0, :train, %{})

    refute_received {:log, _payload}
  end

  test "closing finishes the open run, and says nothing when none was opened" do
    assert WandbWrapper.close(wrapper([%Child{}])) == :ok
    refute_received :finish

    {:ok, wrapper} = WandbWrapper.report_episode(wrapper([%Child{}]), %{}, "/tmp", 0, :train, %{})

    assert WandbWrapper.close(wrapper) == :ok
    assert_received :finish
  end
end
