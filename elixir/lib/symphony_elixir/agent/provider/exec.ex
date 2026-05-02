defmodule SymphonyElixir.Agent.Provider.Exec do
  @moduledoc """
  Generic CLI provider for agents that can be driven by a shell command.

  The prompt is written to `.symphony/prompts/` and, by default, piped to the configured command.
  Commands can also read `SYMPHONY_PROMPT_FILE` directly by setting `prompt_mode: file`.
  """

  @behaviour SymphonyElixir.Agent.Provider

  require Logger

  alias SymphonyElixir.Agent.WorkspaceGuard

  @impl true
  def start_session(profile, workspace, opts) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- WorkspaceGuard.validate(workspace, worker_host),
         :ok <- reject_remote_worker(worker_host) do
      session_id = "exec-#{sanitize_session_part(profile.name)}-#{System.unique_integer([:positive])}"

      {:ok,
       %{
         provider: __MODULE__,
         profile: profile,
         session_id: session_id,
         workspace: expanded_workspace,
         worker_host: worker_host
       }}
    end
  end

  @impl true
  def run_turn(
        %{profile: profile, session_id: session_id, workspace: workspace} = session,
        prompt,
        _issue,
        opts
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = "turn-#{System.unique_integer([:positive])}"
    agent_session_id = "#{session_id}-#{turn_id}"

    emit_message(
      on_message,
      :session_started,
      %{session_id: agent_session_id, thread_id: session_id, turn_id: turn_id},
      session
    )

    with {:ok, prompt_file} <- write_prompt_file(workspace, agent_session_id, prompt),
         {:ok, output, status} <-
           run_shell_command(profile, workspace, prompt_file, session_id, turn_id, agent_session_id) do
      emit_output(on_message, output, session)

      if status == 0 do
        emit_message(on_message, :turn_completed, %{session_id: agent_session_id, exit_status: status}, session)

        {:ok,
         %{
           result: %{output: output, exit_status: status},
           session_id: agent_session_id,
           thread_id: session_id,
           turn_id: turn_id
         }}
      else
        emit_message(
          on_message,
          :turn_failed,
          %{session_id: agent_session_id, exit_status: status, output: output},
          session
        )

        {:error, {:exec_agent_failed, status, output}}
      end
    end
  end

  @impl true
  def stop_session(_session), do: :ok

  defp reject_remote_worker(nil), do: :ok
  defp reject_remote_worker(worker_host), do: {:error, {:unsupported_remote_exec_agent, worker_host}}

  defp write_prompt_file(workspace, session_id, prompt) do
    prompt_dir = Path.join([workspace, ".symphony", "prompts"])
    prompt_file = Path.join(prompt_dir, "#{session_id}.md")

    with :ok <- File.mkdir_p(prompt_dir),
         :ok <- File.write(prompt_file, prompt) do
      {:ok, prompt_file}
    end
  end

  defp run_shell_command(profile, workspace, prompt_file, session_id, turn_id, agent_session_id) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      command = command_for_prompt_mode(profile, prompt_file)

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            env: env_for_profile(profile, prompt_file, session_id, turn_id, agent_session_id)
          ]
        )

      await_port(port, profile.turn_timeout_ms, [])
    end
  end

  defp command_for_prompt_mode(%{prompt_mode: "file", command: command}, _prompt_file), do: command
  defp command_for_prompt_mode(%{prompt_mode: "none", command: command}, _prompt_file), do: command

  defp command_for_prompt_mode(%{command: command}, prompt_file) do
    "cat #{shell_escape(prompt_file)} | #{command}"
  end

  defp env_for_profile(%{env: env, name: profile_name}, prompt_file, session_id, turn_id, agent_session_id)
       when is_map(env) do
    env
    |> Map.put("SYMPHONY_PROMPT_FILE", prompt_file)
    |> Map.put("SYMPHONY_AGENT_PROFILE", profile_name)
    |> Map.put("SYMPHONY_AGENT_SESSION_ID", session_id)
    |> Map.put("SYMPHONY_AGENT_TURN_ID", turn_id)
    |> Map.put("SYMPHONY_AGENT_TURN_SESSION_ID", agent_session_id)
    |> Enum.map(fn {key, value} -> {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))} end)
  end

  defp await_port(port, timeout_ms, chunks) do
    receive do
      {^port, {:data, chunk}} ->
        await_port(port, timeout_ms, [to_string(chunk) | chunks])

      {^port, {:exit_status, status}} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), status}
    after
      timeout_ms ->
        Port.close(port)
        {:error, :turn_timeout}
    end
  end

  defp emit_output(_on_message, "", _session), do: :ok

  defp emit_output(on_message, output, session) do
    emit_message(on_message, :notification, %{payload: %{"output" => output}, raw: output}, session)
  end

  defp emit_message(on_message, event, payload, session) do
    metadata =
      case session.worker_host do
        host when is_binary(host) -> %{worker_host: host}
        _ -> %{}
      end

    message =
      metadata
      |> Map.merge(payload)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
    :ok
  rescue
    error ->
      Logger.debug("Exec agent update handler failed: #{inspect(error)}")
      :ok
  end

  defp default_on_message(_message), do: :ok

  defp sanitize_session_part(value) when is_binary(value) do
    Regex.replace(~r/[^A-Za-z0-9._-]/, value, "_")
  end

  defp sanitize_session_part(value), do: sanitize_session_part(to_string(value))

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
