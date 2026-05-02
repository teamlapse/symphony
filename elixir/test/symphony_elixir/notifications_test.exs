defmodule SymphonyElixir.NotificationsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Notifications

  test "sends configured desktop and Slack notifications through the sender" do
    previous_slack_url = System.get_env("SYMPHONY_TEST_SLACK_WEBHOOK_URL")
    System.put_env("SYMPHONY_TEST_SLACK_WEBHOOK_URL", "https://hooks.slack.test/services/unit")
    on_exit(fn -> restore_env("SYMPHONY_TEST_SLACK_WEBHOOK_URL", previous_slack_url) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      notifications_enabled: true,
      notifications_desktop: true,
      notifications_slack_webhook_url: "$SYMPHONY_TEST_SLACK_WEBHOOK_URL"
    )

    parent = self()

    Application.put_env(:symphony_elixir, :notification_sender, fn channel, notification ->
      send(parent, {:notification, channel, notification})
      :ok
    end)

    Notifications.human_review_required(
      %Issue{
        id: "issue-1",
        identifier: "YAP-1",
        title: "Add notifications",
        state: "Symphony Human Review",
        url: "https://linear.app/littleapps/issue/YAP-1"
      },
      "Symphony Fixing CI"
    )

    assert_receive {:notification, :desktop, desktop}
    assert_receive {:notification, :slack, slack}

    assert desktop.event == :human_review_required
    assert desktop.title == "Symphony ready: YAP-1"
    assert desktop.body == "Ready for human review | Symphony Fixing CI -> Symphony Human Review | Add notifications"
    assert desktop.url == "https://linear.app/littleapps/issue/YAP-1"
    assert slack == desktop
  end

  test "skips notifications when disabled" do
    parent = self()

    Application.put_env(:symphony_elixir, :notification_sender, fn channel, notification ->
      send(parent, {:notification, channel, notification})
      :ok
    end)

    Notifications.human_review_required(
      %Issue{
        id: "issue-2",
        identifier: "YAP-2",
        title: "No notification",
        state: "Todo"
      },
      nil
    )

    refute_receive {:notification, _channel, _notification}, 50
  end
end
