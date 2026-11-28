defmodule HeddleIntegrations.Jido.MixProject do
  use Mix.Project

  def project do
    [
      app: :heddle_jido,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps()
    ]
  end

  # Heddle finds the nodes of every app in its build that lists them here.
  def application do
    [
      mod: {HeddleIntegrations.Agents.Application, []},
      extra_applications: [:logger],
      env: [
        bobbin_nodes: [
          HeddleIntegrations.Nodes.Agents.Agent,
          HeddleIntegrations.Nodes.Agents.Think,
          HeddleIntegrations.Nodes.Agents.Reply,
          HeddleIntegrations.Nodes.Agents.SetState,
          HeddleIntegrations.Nodes.Agents.SendMessage,
          HeddleIntegrations.Nodes.Agents.Ask,
          HeddleIntegrations.Nodes.Agents.Schedule,
          HeddleIntegrations.Nodes.Agents.CancelSchedule,
          HeddleIntegrations.Nodes.Agents.PublishEvent,
          HeddleIntegrations.Nodes.Agents.EndInstance,
          HeddleIntegrations.Nodes.Agents.ReadAgent,
          HeddleIntegrations.Nodes.Agents.ListInstances,
          HeddleIntegrations.Nodes.Agents.Pause,
          HeddleIntegrations.Nodes.Agents.ResetInstance,
          HeddleIntegrations.Nodes.Agents.Event
        ],
        bobbin_templates: [
          "priv/templates/support-agent.json",
          "priv/templates/sdr-follow-up.json",
          "priv/templates/collections.json",
          "priv/templates/triage-team.json"
        ]
      ]
    ]
  end

  # BOBBIN_PATH points at a Bobbin checkout, to try a change in both at once.
  defp bobbin do
    case System.get_env("BOBBIN_PATH") do
      nil -> "~> 0.7"
      path -> [path: path, override: true]
    end
  end

  defp deps do
    [
      {:bobbin, bobbin()},
      {:jido, "3.0.0-beta.3"},
      {:req_llm, "~> 1.30"},
      {:jason, "~> 1.2"}
    ]
  end
end
