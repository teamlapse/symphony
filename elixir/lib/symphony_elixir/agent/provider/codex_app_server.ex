defmodule SymphonyElixir.Agent.Provider.CodexAppServer do
  @moduledoc """
  Agent provider backed by Codex app-server JSON-RPC over stdio.
  """

  @behaviour SymphonyElixir.Agent.Provider

  alias SymphonyElixir.Codex.AppServer

  @impl true
  def start_session(profile, workspace, opts) do
    opts = Keyword.put(opts, :profile, profile)

    with {:ok, session} <- AppServer.start_session(workspace, opts) do
      {:ok, Map.put(session, :provider, __MODULE__)}
    end
  end

  @impl true
  def run_turn(session, prompt, issue, opts) do
    AppServer.run_turn(session, prompt, issue, opts)
  end

  @impl true
  def stop_session(session) do
    AppServer.stop_session(session)
  end
end
