defmodule HeddleIntegrations.Slack do
  @moduledoc """
  Slack's actions and triggers, written as a manifest in `priv/integration.yaml`. Upload
  File takes three calls, so it is a node in Elixir, `HeddleIntegrations.Nodes.Slack.UploadFile`.
  """

  use Bobbin.Integration.Nodes, manifest: "../../priv/integration.yaml"
end
