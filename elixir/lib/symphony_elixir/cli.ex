defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]
  @run_switches [
    repo_url: :string,
    linear_project_url: :string,
    linear_api_key: :string,
    target_branch: :string,
    buildbuddy_api_key: :string,
    port: :integer,
    help: :boolean
  ]
  @required_active_states [
    "Todo",
    "In Progress",
    "Human Review",
    "Symphony Todo",
    "Symphony In Progress",
    "Symphony Agent Review",
    "Symphony Address Feedback",
    "Symphony Fixing CI",
    "Symphony Human Review",
    "Symphony Merging",
    "Symphony Rework"
  ]
  @required_terminal_states [
    "Closed",
    "Cancelled",
    "Canceled",
    "Duplicate",
    "Done",
    "Merged",
    "Merged into Main",
    "Symphony Done",
    "Symphony Cancelled",
    "Symphony Canceled",
    "Symphony Duplicate"
  ]
  @required_hook_env [
    "BUILDBUDDY_API_KEY",
    "LINEAR_PROJECT_SLUG",
    "SYMPHONY_MANAGED_REPO_URL",
    "SYMPHONY_WORKSPACE_ROOT"
  ]
  @managed_run_env_names [
    "BUILDBUDDY_API_KEY",
    "LINEAR_API_KEY",
    "LINEAR_PROJECT_SLUG",
    "LINEAR_PROJECT_URL",
    "SYMPHONY_MANAGED_REPO_URL",
    "SYMPHONY_PORT",
    "SYMPHONY_TARGET_BRANCH",
    "SYMPHONY_WORKSPACE_ROOT"
  ]
  @dialyzer :no_match

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type result :: :ok | {:error, String.t()} | {:halt, String.t(), non_neg_integer()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:halt, message, status} ->
        IO.puts(message)
        System.halt(status)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: result()
  def evaluate(args, deps \\ runtime_deps()) do
    case args do
      ["run" | run_args] ->
        run_args
        |> configure_run(deps)
        |> start_after_configure(deps)

      _ ->
        evaluate_workflow(args, deps)
    end
  end

  @spec configure([String.t()], deps()) :: result()
  def configure(args, deps \\ runtime_deps()) do
    case args do
      ["run" | run_args] -> configure_run(run_args, deps)
      _ -> configure_workflow_args(args, deps)
    end
  end

  defp evaluate_workflow(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  defp configure_workflow_args(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          configure_workflow(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          configure_workflow(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    with :ok <- configure_workflow(workflow_path, deps) do
      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{Path.expand(workflow_path)}: #{inspect(reason)}"}
      end
    end
  end

  @spec configure_workflow(String.t(), deps()) :: :ok | {:error, String.t()}
  defp configure_workflow(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)
      :ok
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  defp configure_run(run_args, deps) do
    case OptionParser.parse(run_args, strict: @run_switches, aliases: [h: :help]) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false) do
          {:halt, run_usage_message(), 0}
        else
          do_configure_run(opts, deps)
        end

      _ ->
        {:error, run_usage_message()}
    end
  end

  defp start_after_configure(:ok, deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony: #{inspect(reason)}"}
    end
  end

  defp start_after_configure(other, _deps), do: other

  defp do_configure_run(opts, deps) do
    IO.puts("Symphony run")
    IO.puts("This run is ephemeral. Config, cloned source, logs, and workspaces are deleted when Symphony exits.")
    IO.puts("")

    with {:ok, answers} <- collect_run_answers(opts),
         {:ok, run_paths} <- prepare_run_paths(answers),
         :ok <- clone_workflow_repo(answers.repo_url, answers.target_branch, run_paths.repo_checkout),
         {:ok, workflow_path} <- prepare_run_workflow(run_paths.repo_checkout, run_paths, answers),
         :ok <- configure_run_environment(run_paths, answers, opts, deps),
         :ok <- configure_workflow(workflow_path, deps) do
      System.at_exit(fn _status -> File.rm_rf(run_paths.root) end)

      IO.puts("")
      IO.puts("Workflow: #{workflow_path}")
      IO.puts("Target branch: #{answers.target_branch} (review uses origin/#{answers.target_branch})")
      IO.puts("Workspace root: #{run_paths.workspace_root}")
      IO.puts("Dashboard: http://127.0.0.1:#{answers.port}/")
      IO.puts("")

      :ok
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    """
    Usage:
      symphony run
      symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md]
    """
    |> String.trim()
  end

  defp run_usage_message do
    """
    Usage: symphony run [options]

    Starts a fresh, ephemeral Symphony session and prompts for missing values.

    Options:
      --repo-url <url>              Repository to clone for WORKFLOW.md
      --linear-project-url <url>    Linear project URL
      --linear-api-key <key>        Linear API key
      --target-branch <branch>      Branch to fetch from origin (default: main)
      --buildbuddy-api-key <key>    Optional BuildBuddy API key for hooks
      --port <port>                 Dashboard port (default: 4000)
    """
    |> String.trim()
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp collect_run_answers(opts) do
    repo_url =
      opts
      |> Keyword.get(:repo_url)
      |> prompt_required("Repo URL")

    linear_project_url =
      opts
      |> Keyword.get(:linear_project_url)
      |> prompt_required("Linear project URL")

    linear_api_key =
      opts
      |> Keyword.get(:linear_api_key)
      |> prompt_secret_required("Linear API key")

    target_branch =
      opts
      |> Keyword.get(:target_branch)
      |> prompt_optional("Target branch", "main")
      |> normalize_target_branch()

    buildbuddy_api_key =
      opts
      |> Keyword.get(:buildbuddy_api_key)
      |> prompt_secret_optional("BuildBuddy API key", nil)

    port =
      opts
      |> Keyword.get(:port)
      |> prompt_port()

    with {:ok, project_slug} <- linear_project_slug(linear_project_url) do
      {:ok,
       %{
         repo_url: repo_url,
         linear_project_url: linear_project_url,
         linear_api_key: linear_api_key,
         linear_project_slug: project_slug,
         target_branch: target_branch,
         buildbuddy_api_key: buildbuddy_api_key,
         port: port
       }}
    end
  end

  defp prompt_required(value, label) do
    case prompt_optional(value, label, nil) |> String.trim() do
      "" ->
        IO.puts(:stderr, "#{label} is required.")
        prompt_required(nil, label)

      trimmed ->
        trimmed
    end
  end

  defp prompt_optional(value, _label, _default) when is_binary(value) and value != "" do
    String.trim(value)
  end

  defp prompt_optional(_value, label, default) do
    suffix = if default in [nil, ""], do: "", else: " [#{default}]"
    "#{label}#{suffix}: " |> read_prompt() |> value_or_default(default)
  end

  defp prompt_secret_required(value, label) do
    case prompt_secret_optional(value, label, nil) |> String.trim() do
      "" ->
        IO.puts(:stderr, "#{label} is required.")
        prompt_secret_required(nil, label)

      trimmed ->
        trimmed
    end
  end

  defp prompt_secret_optional(value, _label, _default) when is_binary(value) and value != "" do
    String.trim(value)
  end

  defp prompt_secret_optional(_value, label, default) do
    suffix = if default in [nil, ""], do: "", else: " [set, press return to keep]"
    IO.write("#{label}#{suffix}: ")

    answer =
      with_terminal_echo(false, fn ->
        read_prompt("")
      end)

    IO.puts("")
    value_or_default(answer, default)
  end

  defp read_prompt(prompt) do
    case IO.gets(prompt) do
      answer when is_binary(answer) -> String.trim(answer)
      _eof -> ""
    end
  end

  defp value_or_default("", default) when is_binary(default), do: default
  defp value_or_default(value, _default), do: value

  defp prompt_port(port) when is_integer(port) and port >= 0, do: port

  defp prompt_port(default) do
    default = default || 4000

    case prompt_optional(nil, "Dashboard port", to_string(default)) |> Integer.parse() do
      {port, ""} when port >= 0 -> port
      _ -> prompt_port(default)
    end
  end

  defp with_terminal_echo(enabled?, fun) when is_function(fun, 0) do
    set_terminal_echo(enabled?)

    try do
      fun.()
    after
      set_terminal_echo(true)
    end
  end

  defp set_terminal_echo(enabled?) do
    arg = if enabled?, do: "echo", else: "-echo"
    _ = System.cmd("stty", [arg], stderr_to_stdout: true)
    :ok
  rescue
    _error -> :ok
  end

  defp linear_project_slug(url) do
    normalized =
      url
      |> String.trim()
      |> String.split(["?", "#"], parts: 2)
      |> List.first()
      |> String.trim_trailing("/")

    segments = String.split(normalized, "/", trim: true)

    case Enum.split_while(segments, &(&1 != "project")) do
      {_before, ["project", slug | _after]} when slug != "" ->
        {:ok, slug}

      _ ->
        {:error, "Could not derive Linear project slug from URL: #{url}"}
    end
  end

  defp normalize_target_branch(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "main"
      "refs/heads/" <> branch -> branch
      "refs/remotes/origin/" <> branch -> branch
      "origin/" <> branch -> branch
      branch -> branch
    end
  end

  defp prepare_run_paths(answers) do
    suffix =
      :erlang.unique_integer([:positive])
      |> Integer.to_string(36)
      |> String.downcase()

    repo_name =
      answers.repo_url
      |> String.trim_trailing("/")
      |> Path.basename()
      |> String.replace_suffix(".git", "")
      |> String.replace(~r/[^A-Za-z0-9._-]/, "-")

    root = Path.join(System.tmp_dir!(), "symphony-#{repo_name}-#{suffix}")
    workspace_root = Path.join(root, "workspaces")
    repo_checkout = Path.join(root, "workflow-repo")
    logs_root = Path.join(root, "logs")

    with :ok <- File.mkdir_p(root),
         :ok <- File.mkdir_p(workspace_root),
         :ok <- File.mkdir_p(logs_root) do
      {:ok,
       %{
         root: root,
         repo_checkout: repo_checkout,
         workspace_root: workspace_root,
         logs_root: logs_root
       }}
    else
      {:error, reason} -> {:error, "Failed to prepare run directories: #{inspect(reason)}"}
    end
  end

  defp clone_workflow_repo(repo_url, target_branch, repo_checkout) do
    IO.puts("Fetching WORKFLOW.md from #{repo_url}##{target_branch}")

    with :ok <- run_command("git", ["clone", "--no-checkout", repo_url, repo_checkout], File.cwd!()),
         :ok <-
           run_command(
             "git",
             ["fetch", "--prune", "origin", "+refs/heads/#{target_branch}:refs/remotes/origin/#{target_branch}"],
             repo_checkout
           ) do
      run_command("git", ["checkout", "--detach", "origin/#{target_branch}"], repo_checkout)
    end
  end

  defp run_command(command, args, cwd) do
    case System.cmd(command, args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, "#{command} #{Enum.join(args, " ")} failed with exit #{status}:\n#{output}"}
    end
  rescue
    error -> {:error, "Failed to run #{command}: #{Exception.message(error)}"}
  end

  defp prepare_run_workflow(repo_checkout, run_paths, answers) do
    source_path = Path.join(repo_checkout, "WORKFLOW.md")

    if File.regular?(source_path) do
      build_run_workflow(source_path, run_paths, answers)
    else
      {:error, "WORKFLOW.md not found at repo root for #{answers.repo_url}"}
    end
  end

  defp build_run_workflow(source_path, run_paths, answers) do
    with {:ok, source} <- File.read(source_path),
         {:ok, front_matter, prompt} <- split_workflow(source),
         {:ok, merged_front_matter} <- merge_run_front_matter(front_matter, run_paths, answers, source_path),
         workflow <-
           ["---\n", yaml(merged_front_matter), "---\n", run_prompt_prelude(), "\n\n", String.trim_leading(prompt)]
           |> IO.iodata_to_binary(),
         output_path = Path.join(run_paths.root, "WORKFLOW.md"),
         :ok <- File.write(output_path, workflow) do
      {:ok, output_path}
    else
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp split_workflow(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    case lines do
      ["---" | rest] -> split_workflow_after_opening_delimiter(rest)
      _ -> {:error, "WORKFLOW.md must start with YAML front matter"}
    end
  end

  defp split_workflow_after_opening_delimiter(lines) do
    {front, tail} = Enum.split_while(lines, &(&1 != "---"))

    case tail do
      ["---" | prompt] -> decode_workflow_front_matter(front, prompt)
      _ -> {:error, "WORKFLOW.md must include closing front matter delimiter"}
    end
  end

  defp decode_workflow_front_matter(front, prompt) do
    yaml = Enum.join(front, "\n")

    case YamlElixir.read_from_string(yaml) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded, Enum.join(prompt, "\n")}
      {:ok, _} -> {:error, "WORKFLOW.md front matter must be a YAML map"}
      {:error, reason} -> {:error, "Failed to parse WORKFLOW.md front matter: #{inspect(reason)}"}
    end
  end

  defp merge_run_front_matter(front_matter, run_paths, answers, source_path) do
    with {:ok, review} <- merge_review(Map.get(front_matter, "review", %{}), answers, source_path) do
      {:ok,
       front_matter
       |> Map.put("tracker", merge_tracker(Map.get(front_matter, "tracker", %{}), answers))
       |> Map.put("workspace", merge_workspace(Map.get(front_matter, "workspace", %{}), run_paths))
       |> Map.put("hooks", merge_hooks(Map.get(front_matter, "hooks", %{}), answers))
       |> Map.put("review", review)}
    end
  end

  defp merge_tracker(tracker, answers) when is_map(tracker) do
    tracker
    |> Map.put("kind", "linear")
    |> Map.put("api_key", "$LINEAR_API_KEY")
    |> Map.put("project_slug", answers.linear_project_slug)
    |> Map.put("active_states", merge_list(Map.get(tracker, "active_states"), @required_active_states))
    |> Map.put("terminal_states", merge_list(Map.get(tracker, "terminal_states"), @required_terminal_states))
  end

  defp merge_workspace(workspace, run_paths) when is_map(workspace) do
    Map.put(workspace, "root", run_paths.workspace_root)
  end

  defp merge_hooks(hooks, answers) when is_map(hooks) do
    hooks
    |> Map.put("env_passthrough", merge_list(Map.get(hooks, "env_passthrough"), @required_hook_env))
    |> Map.put("after_create", default_after_create_hook(answers.target_branch))
    |> Map.put("before_remove", default_before_remove_hook())
  end

  defp merge_review(review, answers, source_path) when is_map(review) do
    review
    |> Map.put("target_branch", "origin/#{answers.target_branch}")
    |> rewrite_review_prompt_file(source_path)
  end

  defp rewrite_review_prompt_file(review, source_path) do
    case Map.get(review, "prompt_file") do
      prompt_file when is_binary(prompt_file) ->
        prompt_file = String.trim(prompt_file)

        if prompt_file == "" do
          {:ok, review}
        else
          rewrite_non_empty_review_prompt_file(review, prompt_file, source_path)
        end

      _prompt_file ->
        {:ok, review}
    end
  end

  defp rewrite_non_empty_review_prompt_file(review, prompt_file, source_path) do
    prompt_path =
      case Path.type(prompt_file) do
        :absolute -> Path.expand(prompt_file)
        :relative -> source_path |> Path.dirname() |> Path.join(prompt_file) |> Path.expand()
      end

    if File.regular?(prompt_path) do
      {:ok, Map.put(review, "prompt_file", prompt_path)}
    else
      {:error, "review.prompt_file not found: #{prompt_path}"}
    end
  end

  defp merge_list(values, required) when is_list(values) do
    Enum.uniq(values ++ required)
  end

  defp merge_list(_values, required), do: required

  defp default_after_create_hook(target_branch) do
    quoted_target_branch = shell_quote(target_branch)

    """
    set -euo pipefail

    repo_url="${SYMPHONY_MANAGED_REPO_URL:?SYMPHONY_MANAGED_REPO_URL is required}"
    target_branch=#{quoted_target_branch}
    target_branch="${target_branch#refs/remotes/origin/}"
    target_branch="${target_branch#refs/heads/}"
    target_branch="${target_branch#origin/}"

    git clone --no-checkout "$repo_url" .
    git fetch --prune origin "+refs/heads/${target_branch}:refs/remotes/origin/${target_branch}"

    safe_issue="$(printf '%s' "${SYMPHONY_ISSUE_IDENTIFIER:-issue}" | sed 's/[^A-Za-z0-9._-]/-/g')"
    git checkout -B "symphony/${safe_issue}" "origin/${target_branch}"

    if [ -f .forge/scripts/session.sh ]; then
      bash .forge/scripts/session.sh
    fi
    """
  end

  defp shell_quote(value) do
    "'#{String.replace(to_string(value), "'", "'\"'\"'")}'"
  end

  defp default_before_remove_hook do
    """
    if command -v bazelisk >/dev/null 2>&1; then
      bazelisk clean --expunge_async || true
    fi
    """
  end

  defp run_prompt_prelude do
    """
    ## Symphony run contract

    This issue is being handled by `symphony run`, an ephemeral orchestration session.

    - Treat plain Linear automation states as aliases, not stop states:
      - `Todo` -> move to `Symphony In Progress` before implementation.
      - `In Progress` -> move to `Symphony In Progress` and continue from the current PR/workpad state.
      - `Human Review` -> treat as `Symphony Human Review`.
    - Keep a single `## Codex Workpad` Linear comment current throughout the run.
    - After implementation and local validation, open or update a draft PR, attach it to the issue, move the issue to `Symphony Agent Review`, and leave the PR as draft so internal automated agent review can run.
    - Do not request external/human review while the issue is in `Symphony Agent Review`.
    - If internal agent review requests changes, move the issue to `Symphony Address Feedback`, address the findings on the same branch/draft PR, rerun validation, push, and return to `Symphony Agent Review`.
    - Once internal agent review passes and execution resumes, mark the same PR ready for review; do not open a duplicate PR.
    - Move the issue to `Symphony Address Feedback` when ready PR review, human review, or Greptile comments need code or a justified reply.
    - Move the issue to `Symphony Fixing CI` when PR checks fail.
    - Move the issue to `Symphony Human Review` only after the PR is ready for review, checks are green, and actionable PR comments are resolved.
    """
  end

  defp configure_run_environment(run_paths, answers, _opts, deps) do
    env =
      %{
        "LINEAR_API_KEY" => answers.linear_api_key,
        "LINEAR_PROJECT_URL" => answers.linear_project_url,
        "LINEAR_PROJECT_SLUG" => answers.linear_project_slug,
        "SYMPHONY_MANAGED_REPO_URL" => answers.repo_url,
        "SYMPHONY_WORKSPACE_ROOT" => run_paths.workspace_root
      }
      |> maybe_put_env("BUILDBUDDY_API_KEY", answers.buildbuddy_api_key)

    clear_managed_run_environment()
    System.put_env(env)

    with :ok <- deps.set_logs_root.(Path.expand(run_paths.logs_root)) do
      deps.set_server_port_override.(answers.port)
    end
  rescue
    error -> {:error, "Failed to configure run environment: #{Exception.message(error)}"}
  end

  defp maybe_put_env(env, _name, value) when value in [nil, ""], do: env
  defp maybe_put_env(env, name, value), do: Map.put(env, name, value)

  defp clear_managed_run_environment do
    Enum.each(@managed_run_env_names, &System.delete_env/1)
  end

  defp yaml(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(&yaml_pair(&1, 0))
  end

  defp yaml_pair({key, value}, indent) do
    prefix = String.duplicate(" ", indent)
    key = to_string(key)

    cond do
      is_map(value) ->
        [prefix, key, ":\n", yaml_map(value, indent + 2)]

      is_list(value) ->
        [prefix, key, ":\n", yaml_list(value, indent + 2)]

      is_binary(value) and String.contains?(value, "\n") ->
        [prefix, key, ": |\n", indent_multiline(value, indent + 2)]

      true ->
        [prefix, key, ": ", yaml_scalar(value), "\n"]
    end
  end

  defp yaml_map(map, indent) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(&yaml_pair(&1, indent))
  end

  defp yaml_list(values, indent) do
    prefix = String.duplicate(" ", indent)

    Enum.map(values, fn value ->
      cond do
        is_map(value) ->
          [prefix, "-\n", yaml_map(value, indent + 2)]

        is_list(value) ->
          [prefix, "-\n", yaml_list(value, indent + 2)]

        is_binary(value) and String.contains?(value, "\n") ->
          [prefix, "- |\n", indent_multiline(value, indent + 2)]

        true ->
          [prefix, "- ", yaml_scalar(value), "\n"]
      end
    end)
  end

  defp indent_multiline(value, indent) do
    prefix = String.duplicate(" ", indent)

    value
    |> String.trim_trailing()
    |> String.split("\n", trim: false)
    |> Enum.map(fn line -> [prefix, line, "\n"] end)
  end

  defp yaml_scalar(value) when is_binary(value), do: Jason.encode!(value)
  defp yaml_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_scalar(value) when is_float(value), do: Float.to_string(value)
  defp yaml_scalar(value) when is_boolean(value), do: to_string(value)
  defp yaml_scalar(nil), do: "null"
  defp yaml_scalar(value), do: Jason.encode!(to_string(value))

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
