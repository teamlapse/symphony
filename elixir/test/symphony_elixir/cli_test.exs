defmodule SymphonyElixir.CLITest do
  use ExUnit.Case

  alias SymphonyElixir.CLI
  import ExUnit.CaptureIO

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
  @run_env_names [
    "BUILDBUDDY_API_KEY",
    "LINEAR_API_KEY",
    "LINEAR_PROJECT_SLUG",
    "LINEAR_PROJECT_URL",
    "SYMPHONY_SLACK_WEBHOOK_URL",
    "SYMPHONY_MANAGED_REPO_URL",
    "SYMPHONY_TARGET_BRANCH",
    "SYMPHONY_PORT",
    "SYMPHONY_WORKSPACE_ROOT"
  ]

  setup do
    original_env = Map.new(@run_env_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps = %{
      file_regular?: fn _path ->
        send(parent, :file_checked)
        true
      end,
      set_workflow_file_path: fn _path ->
        send(parent, :workflow_set)
        :ok
      end,
      set_logs_root: fn _path ->
        send(parent, :logs_root_set)
        :ok
      end,
      set_server_port_override: fn _port ->
        send(parent, :port_set)
        :ok
      end,
      ensure_all_started: fn ->
        send(parent, :started)
        {:ok, [:symphony_elixir]}
      end
    }

    assert {:error, banner} = CLI.evaluate(["WORKFLOW.md"], deps)
    assert banner =~ "This Symphony implementation is a low key engineering preview."
    assert banner =~ "Codex will run without any guardrails."
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :workflow_set
    refute_received :logs_root_set
    refute_received :port_set
    refute_received :started
  end

  test "defaults to WORKFLOW.md when workflow path is missing" do
    deps = %{
      file_regular?: fn path -> Path.basename(path) == "WORKFLOW.md" end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag], deps)
  end

  test "uses an explicit workflow path override when provided" do
    parent = self()
    workflow_path = "tmp/custom/WORKFLOW.md"
    expanded_path = Path.expand(workflow_path)

    deps = %{
      file_regular?: fn path ->
        send(parent, {:workflow_checked, path})
        path == expanded_path
      end,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_set, path})
        :ok
      end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, workflow_path], deps)
    assert_received {:workflow_checked, ^expanded_path}
    assert_received {:workflow_set, ^expanded_path}
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs", "WORKFLOW.md"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "returns not found when workflow file does not exist" do
    deps = %{
      file_regular?: fn _path -> false end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Workflow file not found:"
  end

  test "returns startup error when app cannot start" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:error, :boom} end
    }

    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
    assert message =~ "Failed to start Symphony with workflow"
    assert message =~ ":boom"
  end

  test "returns ok when workflow exists and app starts" do
    deps = %{
      file_regular?: fn _path -> true end,
      set_workflow_file_path: fn _path -> :ok end,
      set_logs_root: fn _path -> :ok end,
      set_server_port_override: fn _port -> :ok end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    assert :ok = CLI.evaluate([@ack_flag, "WORKFLOW.md"], deps)
  end

  test "run configures an ephemeral workflow from a managed repo and target branch" do
    parent = self()
    repo = create_workflow_repo!("release/2026")

    deps = %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_path, path})
        :ok
      end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn port ->
        send(parent, {:port, port})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    args = [
      "run",
      "--repo-url",
      repo,
      "--linear-project-url",
      "https://linear.app/project/littleapps-ui-framework-6609e93fb3b8/issues",
      "--linear-api-key",
      "lin_test",
      "--target-branch",
      "release/2026",
      "--buildbuddy-api-key",
      "bb_test",
      "--slack-webhook-url",
      "https://hooks.slack.test/services/test",
      "--port",
      "4123"
    ]

    assert capture_io(fn ->
             assert :ok = CLI.configure(args, deps)
           end) =~ "Target branch: release/2026"

    assert_received {:workflow_path, workflow_path}
    assert_received {:logs_root, logs_root}
    assert_received {:port, 4123}

    workflow = File.read!(workflow_path)
    run_root = Path.dirname(workflow_path)

    assert workflow =~ "## Symphony run contract"
    assert workflow =~ ~s(project_slug: "littleapps-ui-framework-6609e93fb3b8")
    assert workflow =~ ~s(target_branch: "origin/release/2026")
    assert workflow =~ ~s(prompt_file: "#{Path.join([run_root, "workflow-repo", "REVIEW_PROMPT.md"])}")
    assert workflow =~ "target_branch='release/2026'"
    refute workflow =~ "SYMPHONY_TARGET_BRANCH"
    assert workflow =~ ~s(root: "#{Path.join(run_root, "workspaces")}")
    assert workflow =~ "git clone --no-checkout \"$repo_url\" ."
    assert workflow =~ "bash .forge/scripts/session.sh"
    assert workflow =~ "bazelisk clean --expunge_async || true"
    assert workflow =~ "Symphony Address Feedback"
    assert workflow =~ "Symphony Fixing CI"
    assert workflow =~ "open or update a draft PR"
    assert workflow =~ "mark the same PR ready for review"
    assert workflow =~ "notifications:"
    assert workflow =~ "desktop: true"
    assert workflow =~ ~s(slack_webhook_url: "$SYMPHONY_SLACK_WEBHOOK_URL")

    assert logs_root == Path.join(run_root, "logs")
    assert System.get_env("LINEAR_API_KEY") == "lin_test"
    assert System.get_env("LINEAR_PROJECT_SLUG") == "littleapps-ui-framework-6609e93fb3b8"
    assert System.get_env("SYMPHONY_MANAGED_REPO_URL") == repo
    assert System.get_env("BUILDBUDDY_API_KEY") == "bb_test"
    assert System.get_env("SYMPHONY_SLACK_WEBHOOK_URL") == "https://hooks.slack.test/services/test"
    refute System.get_env("SYMPHONY_TARGET_BRANCH")
  end

  test "run prompts explicitly instead of defaulting from environment" do
    System.put_env("BUILDBUDDY_API_KEY", "bb_env")
    System.put_env("LINEAR_API_KEY", "lin_env")
    System.put_env("LINEAR_PROJECT_URL", "https://linear.app/project/env-project/issues")
    System.put_env("SYMPHONY_MANAGED_REPO_URL", "/tmp/env-repo")
    System.put_env("SYMPHONY_TARGET_BRANCH", "env-branch")
    System.put_env("SYMPHONY_PORT", "4999")

    parent = self()
    repo = create_workflow_repo!("release/2026")

    deps = %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: fn path ->
        send(parent, {:workflow_path, path})
        :ok
      end,
      set_logs_root: fn path ->
        send(parent, {:logs_root, path})
        :ok
      end,
      set_server_port_override: fn port ->
        send(parent, {:port, port})
        :ok
      end,
      ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
    }

    input =
      [
        repo,
        "https://linear.app/project/littleapps-ui-framework-6609e93fb3b8/issues",
        "lin_prompt",
        "release/2026",
        "bb_prompt",
        "",
        "4124"
      ]
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    output =
      capture_io(input, fn ->
        assert :ok = CLI.configure(["run"], deps)
      end)

    assert output =~ "Repo URL:"
    assert output =~ "Linear project URL:"
    assert output =~ "Linear API key:"
    assert output =~ "Target branch [main]:"
    assert output =~ "BuildBuddy API key:"
    assert output =~ "Slack webhook URL:"
    assert output =~ "Dashboard port [4000]:"
    assert output =~ "Target branch: release/2026"

    assert_received {:workflow_path, workflow_path}
    assert_received {:logs_root, logs_root}
    assert_received {:port, 4124}

    workflow = File.read!(workflow_path)
    run_root = Path.dirname(workflow_path)

    assert workflow =~ ~s(project_slug: "littleapps-ui-framework-6609e93fb3b8")
    assert workflow =~ ~s(target_branch: "origin/release/2026")
    assert workflow =~ ~s(prompt_file: "#{Path.join([run_root, "workflow-repo", "REVIEW_PROMPT.md"])}")
    assert workflow =~ "target_branch='release/2026'"
    assert logs_root == Path.join(run_root, "logs")
    assert System.get_env("LINEAR_API_KEY") == "lin_prompt"
    assert System.get_env("LINEAR_PROJECT_SLUG") == "littleapps-ui-framework-6609e93fb3b8"
    assert System.get_env("LINEAR_PROJECT_URL") == "https://linear.app/project/littleapps-ui-framework-6609e93fb3b8/issues"
    assert System.get_env("SYMPHONY_MANAGED_REPO_URL") == repo
    assert System.get_env("BUILDBUDDY_API_KEY") == "bb_prompt"
    refute System.get_env("SYMPHONY_SLACK_WEBHOOK_URL")
    refute System.get_env("SYMPHONY_TARGET_BRANCH")
  end

  test "run rejects old persistent setup flags" do
    assert {:error, message} = CLI.configure(["run", "--keep-run-root"])
    assert message =~ "Usage: symphony run"

    assert {:error, message} = CLI.configure(["run", "--logs-root", "tmp/logs"])
    assert message =~ "Usage: symphony run"
  end

  test "run help returns a successful halt result" do
    assert {:halt, message, 0} = CLI.configure(["run", "--help"])
    assert message =~ "Usage: symphony run"
  end

  defp create_workflow_repo!(branch) do
    root = Path.join(System.tmp_dir!(), "symphony-cli-test-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)

    git!(["init", "-b", branch], repo)
    git!(["config", "user.email", "test@example.com"], repo)
    git!(["config", "user.name", "Test"], repo)

    workflow = """
    ---
    tracker:
      kind: linear
      active_states:
        - Todo
    workspace:
      root: old-root
    hooks:
      after_create: old hook
      before_remove: old cleanup
    review:
      enabled: true
      prompt_file: REVIEW_PROMPT.md
    ---

    Original prompt.
    """

    File.write!(Path.join(repo, "WORKFLOW.md"), workflow)
    File.write!(Path.join(repo, "REVIEW_PROMPT.md"), "Review from the repo prompt file.\n")
    git!(["add", "WORKFLOW.md", "REVIEW_PROMPT.md"], repo)
    git!(["commit", "-m", "Add workflow"], repo)

    on_exit(fn -> File.rm_rf(root) end)

    repo
  end

  defp git!(args, cwd) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
