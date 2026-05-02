defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end

defmodule SymphonyElixir.StandaloneApplication do
  @moduledoc """
  OTP entrypoint for single-file release binaries.

  Escript builds call `SymphonyElixir.CLI.main/1` directly. Burrito releases start
  the OTP application instead, so this module configures Symphony from runtime CLI
  arguments before starting the normal supervision tree.
  """

  use Application

  alias Burrito.Util.Args, as: BurritoArgs

  @impl true
  def start(type, args) do
    case SymphonyElixir.CLI.configure(runtime_argv()) do
      :ok ->
        SymphonyElixir.Application.start(type, args)

      {:halt, message, status} ->
        IO.puts(message)
        {:ok, halt_soon(status)}

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @impl true
  def stop(state), do: SymphonyElixir.Application.stop(state)

  defp halt_soon(status) do
    spawn(fn ->
      Process.sleep(10)
      :init.stop(status)
    end)
  end

  defp runtime_argv do
    BurritoArgs.argv()
  rescue
    _error -> System.argv()
  end
end
