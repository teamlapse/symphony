defmodule SymphonyElixir.Agent.Provider do
  @moduledoc """
  Dispatches agent session operations to the configured provider implementation.
  """

  alias SymphonyElixir.Agent.Provider.{CodexAppServer, Exec}

  @callback start_session(map(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(map()) :: :ok

  @spec start_session(map(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(%{kind: _kind} = profile, workspace, opts \\ []) do
    module = provider_module(profile)
    module.start_session(profile, workspace, opts)
  end

  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{provider: provider} = session, prompt, issue, opts \\ []) when is_atom(provider) do
    provider.run_turn(session, prompt, issue, opts)
  end

  @spec stop_session(map() | nil) :: :ok
  def stop_session(%{provider: provider} = session) when is_atom(provider) do
    provider.stop_session(session)
  end

  def stop_session(_session), do: :ok

  defp provider_module(%{kind: kind}) when kind in ["codex_app_server", "codex-app-server"] do
    CodexAppServer
  end

  defp provider_module(%{kind: kind}) when kind in ["exec", "cli", "generic_cli"] do
    Exec
  end

  defp provider_module(%{kind: kind}) do
    raise ArgumentError, message: "Unsupported agent provider kind #{inspect(kind)}"
  end
end
