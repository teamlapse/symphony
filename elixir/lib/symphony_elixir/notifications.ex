defmodule SymphonyElixir.Notifications do
  @moduledoc """
  Best-effort status notifications for local Symphony runs.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @max_notification_text 320
  @slack_timeout_ms 5_000

  @type channel :: :desktop | :slack
  @type notification :: %{
          required(:title) => String.t(),
          required(:body) => String.t(),
          optional(:event) => atom(),
          optional(:identifier) => String.t(),
          optional(:url) => String.t(),
          optional(:state) => String.t(),
          optional(:previous_state) => String.t(),
          optional(:runtime_stage) => String.t()
        }

  @spec human_review_required(Issue.t(), String.t() | nil) :: :ok
  def human_review_required(%Issue{} = issue, previous_state) do
    notify(%{
      event: :human_review_required,
      title: "Symphony ready: #{issue_identifier(issue)}",
      body: compact_join(["Ready for human review", state_transition(previous_state, issue.state), issue.title]),
      identifier: issue.identifier,
      url: issue.url,
      state: issue.state,
      previous_state: previous_state
    })
  end

  def human_review_required(_issue, _previous_state), do: :ok

  @spec notify(notification()) :: :ok
  def notify(notification) when is_map(notification) do
    case Config.settings() do
      {:ok, %{notifications: notifications}} ->
        deliver_enabled_notifications(notifications, normalize_notification(notification))

      {:error, reason} ->
        Logger.debug("Skipping notification because workflow config is unavailable: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("Skipping notification after error: #{Exception.message(error)}")
      :ok
  end

  defp deliver_enabled_notifications(%{enabled: true} = settings, notification) do
    settings
    |> enabled_channels()
    |> Enum.each(fn channel -> deliver(channel, notification, settings) end)

    :ok
  end

  defp deliver_enabled_notifications(_settings, _notification), do: :ok

  defp enabled_channels(settings) do
    []
    |> maybe_add_channel(settings.desktop == true, :desktop)
    |> maybe_add_channel(non_empty_string?(settings.slack_webhook_url), :slack)
  end

  defp maybe_add_channel(channels, true, channel), do: [channel | channels]
  defp maybe_add_channel(channels, _enabled, _channel), do: channels

  defp deliver(channel, notification, settings) do
    case Application.get_env(:symphony_elixir, :notification_sender) do
      sender when is_function(sender, 2) ->
        handle_delivery_result(channel, sender.(channel, notification))

      _ ->
        handle_delivery_result(channel, deliver_channel(channel, notification, settings))
    end
  rescue
    error ->
      Logger.warning("Failed to send #{channel} notification: #{Exception.message(error)}")
      :ok
  end

  defp handle_delivery_result(_channel, :ok), do: :ok

  defp handle_delivery_result(channel, {:error, reason}) do
    Logger.warning("Failed to send #{channel} notification: #{inspect(reason)}")
    :ok
  end

  defp handle_delivery_result(channel, other) do
    Logger.warning("Failed to send #{channel} notification: unexpected result #{inspect(other)}")
    :ok
  end

  defp deliver_channel(:desktop, notification, _settings) do
    case System.cmd("osascript", ["-e", apple_script(notification)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:osascript_failed, status, output}}
    end
  rescue
    error -> {:error, {:osascript_error, Exception.message(error)}}
  end

  defp deliver_channel(:slack, notification, %{slack_webhook_url: webhook_url}) do
    case Req.post(webhook_url,
           json: %{text: slack_text(notification)},
           connect_options: [timeout: @slack_timeout_ms],
           receive_timeout: @slack_timeout_ms
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:slack_status, status, body}}
      {:error, reason} -> {:error, {:slack_request_failed, reason}}
    end
  rescue
    error -> {:error, {:slack_error, Exception.message(error)}}
  end

  defp normalize_notification(notification) do
    %{
      event: Map.get(notification, :event),
      title: notification |> Map.get(:title, "Symphony") |> truncate(),
      body: notification |> Map.get(:body, "") |> truncate(),
      identifier: notification |> Map.get(:identifier) |> blank_to_nil(),
      url: notification |> Map.get(:url) |> blank_to_nil(),
      state: notification |> Map.get(:state) |> blank_to_nil(),
      previous_state: notification |> Map.get(:previous_state) |> blank_to_nil(),
      runtime_stage: notification |> Map.get(:runtime_stage) |> blank_to_nil()
    }
  end

  defp apple_script(notification) do
    [
      "display notification ",
      apple_string(notification.body),
      " with title ",
      apple_string(notification.title)
    ]
    |> IO.iodata_to_binary()
  end

  defp apple_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp slack_text(notification) do
    [
      "*#{notification.title}*",
      notification.body,
      notification.url
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n")
  end

  defp state_transition(previous_state, state) do
    case {blank_to_nil(previous_state), blank_to_nil(state)} do
      {nil, nil} -> nil
      {nil, current} -> current
      {previous, nil} -> previous
      {previous, current} -> "#{previous} -> #{current}"
    end
  end

  defp issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(%Issue{id: id}) when is_binary(id), do: id
  defp issue_identifier(_issue), do: "issue"

  defp compact_join(parts) do
    parts
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end

  defp blank_to_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp blank_to_nil(_value), do: nil

  defp truncate(nil), do: ""

  defp truncate(value) do
    value = to_string(value)

    if String.length(value) > @max_notification_text do
      String.slice(value, 0, @max_notification_text - 3) <> "..."
    else
      value
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
end
