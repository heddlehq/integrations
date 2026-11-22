defmodule HeddleIntegrations.Email.MixProject do
  use Mix.Project

  def project do
    [
      app: :heddle_email,
      version: "1.0.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps()
    ]
  end

  # Heddle finds the nodes of every app in its build that lists them here.
  def application do
    [
      extra_applications: [:logger],
      env: [
        bobbin_nodes: [
          HeddleIntegrations.Nodes.Email.Delete,
          HeddleIntegrations.Nodes.Email.Get,
          HeddleIntegrations.Nodes.Email.List,
          HeddleIntegrations.Nodes.Email.MarkRead,
          HeddleIntegrations.Nodes.Email.MarkUnread,
          HeddleIntegrations.Nodes.Email.Move,
          HeddleIntegrations.Nodes.Email.Send
        ]
      ]
    ]
  end

  # BOBBIN_PATH points at a Bobbin checkout, to try a change in both at once.
  defp bobbin do
    case System.get_env("BOBBIN_PATH") do
      nil -> "~> 0.5"
      path -> [path: path, override: true]
    end
  end

  defp deps do
    [
      {:bobbin, bobbin()},
      {:gen_smtp, "~> 1.3"},
      {:plug, "~> 1.0", only: :test}
    ]
  end
end
