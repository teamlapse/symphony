defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with configured coding agents.
  """

  require Logger
  alias SymphonyElixir.Agent.Provider
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp agent_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    executor_profile = Config.agent_profile!(:executor)

    with {:ok, session} <- Provider.start_session(executor_profile, workspace, worker_host: worker_host) do
      try do
        do_run_agent_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns)
      after
        Provider.stop_session(session)
      end
    end
  end

  defp do_run_agent_turns(agent_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           Provider.run_turn(
             agent_session,
             prompt,
             issue,
             on_message: agent_message_handler(codex_update_recipient, issue)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      with {:ok, turn_number} <-
             maybe_run_agent_review_loop(
               agent_session,
               workspace,
               issue,
               codex_update_recipient,
               turn_number,
               max_turns,
               worker_host_from_session(agent_session)
             ) do
        continue_agent_turns(
          agent_session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          turn_number,
          max_turns
        )
      end
    end
  end

  defp continue_agent_turns(agent_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    case continue_with_issue?(issue, issue_state_fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_agent_turns(
          agent_session,
          workspace,
          refreshed_issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          turn_number + 1,
          max_turns
        )

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous executor turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp maybe_run_agent_review_loop(agent_session, workspace, issue, codex_update_recipient, turn_number, max_turns, worker_host) do
    review = Config.settings!().review

    if review.enabled do
      reviewer_profile = Config.agent_profile!(:reviewer)

      with {:ok, reviewer_session} <- Provider.start_session(reviewer_profile, workspace, worker_host: worker_host) do
        try do
          run_agent_review_loop(
            agent_session,
            reviewer_session,
            workspace,
            issue,
            codex_update_recipient,
            turn_number,
            max_turns,
            1
          )
        after
          Provider.stop_session(reviewer_session)
        end
      end
    else
      {:ok, turn_number}
    end
  end

  defp run_agent_review_loop(
         agent_session,
         reviewer_session,
         workspace,
         issue,
         codex_update_recipient,
         turn_number,
         max_turns,
         review_round
       ) do
    review = Config.settings!().review

    if review_round > review.max_rounds do
      {:error, {:agent_review_max_rounds_reached, review.max_rounds}}
    else
      send_agent_runtime_event(
        codex_update_recipient,
        issue,
        :agent_review_started,
        %{round: review_round, max_rounds: review.max_rounds},
        "Agent Review"
      )

      with {:ok, report_path} <- prepare_review_report_path(workspace, review.findings_path),
           review_prompt <- build_review_prompt(issue, workspace, report_path, review_round),
           {:ok, review_turn} <-
             Provider.run_turn(
               reviewer_session,
               review_prompt,
               issue,
               on_message: agent_message_handler(codex_update_recipient, issue)
             ),
           {:ok, review_result} <- read_review_report(report_path, review) do
        send_agent_runtime_event(
          codex_update_recipient,
          issue,
          :agent_review_completed,
          %{
            round: review_round,
            max_rounds: review.max_rounds,
            status: review_result_status(review_result)
          },
          nil
        )

        Logger.info(
          "Completed agent review for #{issue_context(issue)} session_id=#{review_turn[:session_id]} workspace=#{workspace} round=#{review_round}/#{review.max_rounds} status=#{review_result_status(review_result)}"
        )

        handle_review_result(review_result, %{
          agent_session: agent_session,
          reviewer_session: reviewer_session,
          workspace: workspace,
          issue: issue,
          codex_update_recipient: codex_update_recipient,
          turn_number: turn_number,
          max_turns: max_turns,
          review_round: review_round
        })
      end
    end
  end

  defp handle_review_result(:pass, %{turn_number: turn_number}), do: {:ok, turn_number}

  defp handle_review_result(
         {:changes_requested, feedback},
         %{
           agent_session: agent_session,
           reviewer_session: reviewer_session,
           workspace: workspace,
           issue: issue,
           codex_update_recipient: codex_update_recipient,
           turn_number: turn_number,
           max_turns: max_turns,
           review_round: review_round
         }
       ) do
    if turn_number >= max_turns do
      {:error, {:agent_review_feedback_remaining_after_max_turns, max_turns}}
    else
      next_turn_number = turn_number + 1

      send_agent_runtime_event(
        codex_update_recipient,
        issue,
        :agent_review_feedback_started,
        %{turn: next_turn_number, max_turns: max_turns, review_round: review_round},
        "Address Feedback"
      )

      with {:ok, feedback_turn} <-
             Provider.run_turn(
               agent_session,
               build_review_feedback_prompt(feedback, next_turn_number, max_turns),
               issue,
               on_message: agent_message_handler(codex_update_recipient, issue)
             ) do
        send_agent_runtime_event(
          codex_update_recipient,
          issue,
          :agent_review_feedback_completed,
          %{turn: next_turn_number, max_turns: max_turns, review_round: review_round},
          nil
        )

        Logger.info("Completed review-feedback executor turn for #{issue_context(issue)} session_id=#{feedback_turn[:session_id]} workspace=#{workspace} turn=#{next_turn_number}/#{max_turns}")

        run_agent_review_loop(
          agent_session,
          reviewer_session,
          workspace,
          issue,
          codex_update_recipient,
          next_turn_number,
          max_turns,
          review_round + 1
        )
      end
    end
  end

  defp prepare_review_report_path(workspace, findings_path) do
    report_path = Path.expand(findings_path, workspace)
    workspace_root = Path.expand(workspace)
    workspace_prefix = workspace_root <> "/"

    if String.starts_with?(report_path, workspace_prefix) do
      with :ok <- File.mkdir_p(Path.dirname(report_path)),
           :ok <- File.rm(report_path) |> ignore_missing_file() do
        {:ok, report_path}
      end
    else
      {:error, {:review_report_path_outside_workspace, report_path, workspace_root}}
    end
  end

  defp ignore_missing_file(:ok), do: :ok
  defp ignore_missing_file({:error, :enoent}), do: :ok
  defp ignore_missing_file({:error, reason}), do: {:error, reason}

  defp build_review_prompt(issue, workspace, report_path, review_round) do
    review = Config.settings!().review
    target_branch = review.target_branch
    report_relative_path = Path.relative_to(report_path, workspace)
    current_branch = git_output(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])
    head_sha = git_output(workspace, ["rev-parse", "--short", "HEAD"])
    diff_stat = git_output(workspace, ["diff", "--stat", "#{target_branch}...HEAD"])

    """
    Agent review job for Linear ticket #{issue.identifier}.

    Review round: #{review_round} of #{review.max_rounds}
    Workspace: #{workspace}
    Current branch: #{String.trim(current_branch)}
    Head: #{String.trim(head_sha)}
    Target branch: #{target_branch}
    Required report path: #{report_relative_path}

    Custom review prompt/rules:
    #{Config.review_prompt()}

    Diff stat against #{target_branch}:
    #{diff_stat}

    Instructions:

    - Review the branch against #{target_branch} from this workspace.
    - Do not modify source files. Only write the review report at #{report_relative_path}.
    - The first non-blank line of #{report_relative_path} must be exactly one of:
      - status: #{review.pass_status}
      - status: #{review.changes_requested_status}
    - If there are findings, use status: #{review.changes_requested_status} and include concise, actionable findings with file paths and reasons.
    - If there are no findings, use status: #{review.pass_status} and include a short validation note.
    - Finish after writing the report.
    """
  end

  defp build_review_feedback_prompt(feedback, turn_number, max_turns) do
    """
    Internal agent review requested changes.

    This is executor turn ##{turn_number} of #{max_turns}. Continue in the same workspace and same ticket context.
    Address the findings below incrementally in the existing branch and workpad. If you already moved the issue to Human Review, move it back to the active implementation state before addressing the findings, then only return it to Human Review after a later review pass.

    Reviewer findings:

    #{feedback}
    """
  end

  defp read_review_report(report_path, review) do
    with {:ok, content} <- File.read(report_path),
         {:ok, status} <- review_report_status(content) do
      cond do
        status == review.pass_status ->
          {:ok, :pass}

        status == review.changes_requested_status ->
          {:ok, {:changes_requested, content}}

        true ->
          {:error, {:unknown_review_status, status, report_path}}
      end
    else
      {:error, :enoent} -> {:error, {:missing_review_report, report_path}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp review_report_status(content) when is_binary(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.first()
    |> case do
      "status:" <> status -> {:ok, String.trim(status)}
      nil -> {:error, :empty_review_report}
      other -> {:error, {:missing_review_status, other}}
    end
  end

  defp review_result_status(:pass), do: "pass"
  defp review_result_status({:changes_requested, _feedback}), do: "changes_requested"

  defp send_agent_runtime_event(recipient, issue, event, payload, runtime_stage)
       when is_pid(recipient) and is_atom(event) and is_map(payload) do
    send_codex_update(recipient, issue, %{
      event: event,
      payload: payload,
      timestamp: DateTime.utc_now(),
      runtime_stage: runtime_stage
    })
  end

  defp send_agent_runtime_event(_recipient, _issue, _event, _payload, _runtime_stage), do: :ok

  defp git_output(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> "git #{Enum.join(args, " ")} exited #{status}:\n#{output}"
    end
  rescue
    error -> "git #{Enum.join(args, " ")} failed: #{Exception.message(error)}"
  end

  defp worker_host_from_session(%{worker_host: worker_host}), do: worker_host
  defp worker_host_from_session(_session), do: nil

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
