defmodule SymphonyElixir.AgentProviderTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Provider
  alias SymphonyElixir.Agent.WorkspaceGuard

  test "exec provider runs stdin prompts through provider dispatch" do
    workspace = create_workspace!("MT-EXEC")
    profile = exec_profile(name: :default, command: "cat >/dev/null; printf 'ok\\n'")

    assert {:ok, session} = Provider.start_session(profile, workspace)
    assert {:ok, turn} = Provider.run_turn(session, "hello", %{})

    assert turn.result.output == "ok\n"
    assert turn.thread_id == session.session_id
    assert :ok = Provider.stop_session(session)
    assert :ok = Provider.stop_session(nil)
  end

  test "exec provider supports file prompt mode and survives noisy message handlers" do
    workspace = create_workspace!("MT-FILE")

    profile =
      exec_profile(
        command: "printf 'file:'; cat \"$SYMPHONY_PROMPT_FILE\"",
        prompt_mode: "file"
      )

    assert {:ok, session} = Provider.start_session(profile, workspace, [])

    assert {:ok, turn} =
             Provider.run_turn(session, "from-file", %{}, on_message: fn _message -> raise "handler failed" end)

    assert turn.result.output == "file:from-file"
    assert File.read!(Path.join([workspace, ".symphony", "prompts", "#{turn.session_id}.md"])) == "from-file"
  end

  test "exec provider supports no prompt input mode" do
    workspace = create_workspace!("MT-NONE")

    profile =
      exec_profile(
        command: "test -f \"$SYMPHONY_PROMPT_FILE\" && printf 'none'",
        prompt_mode: "none"
      )

    assert {:ok, session} = Provider.start_session(profile, workspace, [])
    assert {:ok, turn} = Provider.run_turn(session, "ignored", %{}, [])
    assert turn.result.output == "none"
  end

  test "exec provider exposes stable session metadata to command wrappers" do
    workspace = create_workspace!("MT-ENV")

    profile =
      exec_profile(
        name: "claude",
        command: "cat >/dev/null; printf '%s|%s|%s|%s' \"$SYMPHONY_AGENT_PROFILE\" \"$SYMPHONY_AGENT_SESSION_ID\" \"$SYMPHONY_AGENT_TURN_ID\" \"$SYMPHONY_AGENT_TURN_SESSION_ID\""
      )

    assert {:ok, session} = Provider.start_session(profile, workspace, [])
    assert {:ok, first_turn} = Provider.run_turn(session, "first", %{}, [])
    assert {:ok, second_turn} = Provider.run_turn(session, "second", %{}, [])

    assert first_turn.result.output =~ "claude|#{session.session_id}|turn-"
    assert first_turn.result.output =~ "|#{first_turn.session_id}"
    assert second_turn.result.output =~ "claude|#{session.session_id}|turn-"
    assert second_turn.result.output =~ "|#{second_turn.session_id}"
    refute first_turn.session_id == second_turn.session_id
  end

  test "exec provider reports failed turns" do
    workspace = create_workspace!("MT-FAIL")
    profile = exec_profile(command: "cat >/dev/null; printf 'failed\\n'; exit 7")

    assert {:ok, session} = Provider.start_session(profile, workspace, [])

    assert {:error, {:exec_agent_failed, 7, "failed\n"}} =
             Provider.run_turn(session, "hello", %{}, on_message: fn message -> send(self(), {:agent_message, message}) end)

    assert_received {:agent_message, %{event: :turn_failed, exit_status: 7, output: "failed\n"}}
  end

  test "exec provider reports turn timeouts" do
    workspace = create_workspace!("MT-TIMEOUT")
    profile = exec_profile(command: "sleep 1", turn_timeout_ms: 10)

    assert {:ok, session} = Provider.start_session(profile, workspace, [])
    assert {:error, :turn_timeout} = Provider.run_turn(session, "hello", %{}, [])
  end

  test "exec provider rejects remote worker sessions" do
    profile = exec_profile()

    assert {:error, {:unsupported_remote_exec_agent, "worker-a"}} =
             Provider.start_session(profile, "/workspace/MT-REMOTE", worker_host: "worker-a")
  end

  test "exec provider includes worker host metadata for existing sessions" do
    workspace = create_workspace!("MT-WORKER-METADATA")

    session = %{
      provider: SymphonyElixir.Agent.Provider.Exec,
      profile: exec_profile(command: "cat >/dev/null; printf 'ok\\n'"),
      session_id: "existing-session",
      workspace: workspace,
      worker_host: "worker-a"
    }

    assert {:ok, _turn} =
             Provider.run_turn(session, "hello", %{}, on_message: fn message -> send(self(), {:agent_message, message}) end)

    assert_received {:agent_message, %{event: :session_started, worker_host: "worker-a"}}
  end

  test "provider dispatch rejects unsupported agent kinds" do
    workspace = create_workspace!("MT-UNSUPPORTED")

    assert_raise ArgumentError, ~r/Unsupported agent provider kind/, fn ->
      Provider.start_session(%{kind: "unknown"}, workspace)
    end
  end

  test "workspace guard validates remote workspace paths" do
    assert {:error, {:invalid_workspace_cwd, :empty_remote_workspace, "worker-a"}} =
             WorkspaceGuard.validate("  ", "worker-a")

    assert {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, "worker-a", "bad\npath"}} =
             WorkspaceGuard.validate("bad\npath", "worker-a")

    assert {:ok, "/workspace/MT-REMOTE"} = WorkspaceGuard.validate("/workspace/MT-REMOTE", "worker-a")
  end

  test "workspace guard reports unreadable local workspace paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-provider-unreadable-#{System.unique_integer([:positive])}"
      )

    locked_dir = Path.join(test_root, "locked")

    try do
      File.mkdir_p!(locked_dir)
      File.chmod!(locked_dir, 0o000)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

      workspace = Path.join([locked_dir, "MT-LOCKED"])

      assert {:error, {:invalid_workspace_cwd, :path_unreadable, ^workspace, _reason}} =
               WorkspaceGuard.validate(workspace, nil)
    after
      File.chmod(locked_dir, 0o700)
      File.rm_rf(test_root)
    end
  end

  defp create_workspace!(issue_identifier) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-agent-provider-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, issue_identifier)

    File.mkdir_p!(workspace)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(test_root) end)

    workspace
  end

  defp exec_profile(overrides \\ []) do
    Map.merge(
      %{
        name: "exec",
        kind: "exec",
        command: "cat",
        prompt_mode: "stdin",
        env: %{},
        turn_timeout_ms: 1_000,
        read_timeout_ms: 100,
        stall_timeout_ms: 100
      },
      Map.new(overrides)
    )
  end
end
