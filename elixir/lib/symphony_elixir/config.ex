defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @default_review_prompt """
  You are a separate reviewer agent for the same Linear ticket.

  Review the current branch against the configured target branch. Focus on correctness,
  tests, regressions, security-sensitive behavior, and whether the implementation satisfies
  the ticket and workflow instructions. Do not request cosmetic-only changes.
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @type agent_profile :: %{
          name: String.t(),
          kind: String.t(),
          command: String.t(),
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map() | nil,
          turn_timeout_ms: pos_integer(),
          read_timeout_ms: pos_integer(),
          stall_timeout_ms: non_neg_integer(),
          prompt_mode: String.t(),
          env: map(),
          settings: map(),
          session_reuse: boolean()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec agent_profile!(String.t() | atom()) :: agent_profile()
  def agent_profile!(profile_or_role \\ :executor) do
    settings = settings!()
    profile_name = resolve_agent_profile_name(settings, profile_or_role)
    raw_profiles = settings.agents || %{}

    raw_profile =
      Map.get(raw_profiles, profile_name) ||
        legacy_profile_for_missing_name(settings, profile_name, profile_or_role)

    normalize_agent_profile(settings, profile_name, raw_profile)
  end

  @spec agent_runtime_settings(agent_profile(), Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def agent_runtime_settings(%{} = profile, workspace \\ nil, opts \\ []) do
    with {:ok, turn_sandbox_policy} <- agent_turn_sandbox_policy(profile, workspace, opts) do
      {:ok,
       %{
         approval_policy: profile.approval_policy,
         thread_sandbox: profile.thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  @spec review_prompt() :: String.t()
  def review_prompt do
    review = settings!().review

    cond do
      non_empty_string?(review.prompt_file) ->
        read_review_prompt_file!(review.prompt_file)

      non_empty_string?(review.prompt) ->
        review.prompt

      true ->
        @default_review_prompt
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  defp read_review_prompt_file!(prompt_file) when is_binary(prompt_file) do
    path = resolve_workflow_relative_path(prompt_file)

    case File.read(path) do
      {:ok, content} ->
        if String.trim(content) == "" do
          raise "review.prompt_file is empty: #{path}"
        else
          content
        end

      {:error, reason} ->
        raise "unable to read review.prompt_file #{path}: #{inspect(reason)}"
    end
  end

  defp resolve_workflow_relative_path(path) when is_binary(path) do
    case Path.type(path) do
      :absolute ->
        Path.expand(path)

      :relative ->
        Workflow.workflow_file_path()
        |> Path.dirname()
        |> Path.join(path)
        |> Path.expand()
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp resolve_agent_profile_name(settings, :executor), do: settings.agent.executor || "default"
  defp resolve_agent_profile_name(settings, :reviewer), do: settings.review.agent || "reviewer"
  defp resolve_agent_profile_name(_settings, profile_name) when is_atom(profile_name), do: Atom.to_string(profile_name)
  defp resolve_agent_profile_name(_settings, profile_name) when is_binary(profile_name), do: profile_name

  defp legacy_profile_for_missing_name(settings, "default", _role), do: legacy_codex_profile(settings)
  defp legacy_profile_for_missing_name(settings, "reviewer", :reviewer), do: legacy_codex_profile(settings)

  defp legacy_profile_for_missing_name(_settings, profile_name, _role) do
    raise ArgumentError, message: "Missing agent profile #{inspect(profile_name)} in WORKFLOW.md agents"
  end

  defp legacy_codex_profile(settings) do
    %{
      "kind" => "codex_app_server",
      "command" => settings.codex.command,
      "approval_policy" => settings.codex.approval_policy,
      "thread_sandbox" => settings.codex.thread_sandbox,
      "turn_sandbox_policy" => settings.codex.turn_sandbox_policy,
      "turn_timeout_ms" => settings.codex.turn_timeout_ms,
      "read_timeout_ms" => settings.codex.read_timeout_ms,
      "stall_timeout_ms" => settings.codex.stall_timeout_ms
    }
  end

  defp normalize_agent_profile(settings, profile_name, raw_profile) when is_map(raw_profile) do
    raw_profile = normalize_profile_keys(raw_profile)

    raw_profile
    |> base_agent_profile(settings, profile_name)
    |> Map.merge(policy_agent_profile(raw_profile, settings))
    |> Map.merge(timeout_agent_profile(raw_profile, settings))
    |> Map.merge(extra_agent_profile(raw_profile))
  end

  defp normalize_agent_profile(_settings, profile_name, _raw_profile) do
    raise ArgumentError, message: "Agent profile #{inspect(profile_name)} must be a map"
  end

  defp base_agent_profile(raw_profile, settings, profile_name) do
    %{
      name: profile_name,
      kind: profile_value(raw_profile, "kind") || profile_value(raw_profile, "type") || "exec",
      command: profile_value(raw_profile, "command") || settings.codex.command
    }
  end

  defp policy_agent_profile(raw_profile, settings) do
    %{
      approval_policy: profile_value(raw_profile, "approval_policy") || settings.codex.approval_policy,
      thread_sandbox: profile_value(raw_profile, "thread_sandbox") || settings.codex.thread_sandbox,
      turn_sandbox_policy:
        normalize_profile_map(profile_value(raw_profile, "turn_sandbox_policy")) ||
          settings.codex.turn_sandbox_policy
    }
  end

  defp timeout_agent_profile(raw_profile, settings) do
    %{
      turn_timeout_ms: profile_integer(raw_profile, "turn_timeout_ms", settings.codex.turn_timeout_ms),
      read_timeout_ms: profile_integer(raw_profile, "read_timeout_ms", settings.codex.read_timeout_ms),
      stall_timeout_ms: profile_integer(raw_profile, "stall_timeout_ms", settings.codex.stall_timeout_ms)
    }
  end

  defp extra_agent_profile(raw_profile) do
    %{
      prompt_mode: profile_value(raw_profile, "prompt_mode") || "stdin",
      env: normalize_profile_map(profile_value(raw_profile, "env")) || %{},
      settings: normalize_profile_map(profile_value(raw_profile, "settings")) || %{},
      session_reuse: profile_boolean(raw_profile, "session_reuse", true)
    }
  end

  defp agent_turn_sandbox_policy(%{turn_sandbox_policy: %{} = policy}, _workspace, _opts),
    do: {:ok, policy}

  defp agent_turn_sandbox_policy(_profile, workspace, opts) do
    with {:ok, settings} <- settings() do
      Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts)
    end
  end

  defp normalize_profile_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, acc ->
      Map.put(acc, to_string(key), normalize_profile_keys(raw_value))
    end)
  end

  defp normalize_profile_keys(value) when is_list(value), do: Enum.map(value, &normalize_profile_keys/1)
  defp normalize_profile_keys(value), do: value

  defp normalize_profile_map(value) when is_map(value), do: normalize_profile_keys(value)
  defp normalize_profile_map(_value), do: nil

  defp profile_value(profile, key), do: Map.get(profile, key)

  defp profile_integer(profile, key, default) do
    case profile_value(profile, key) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp profile_boolean(profile, key, default) do
    case profile_value(profile, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      settings.agent.executor == "" ->
        {:error, {:invalid_workflow_config, "agent.executor can't be blank"}}

      true ->
        :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
