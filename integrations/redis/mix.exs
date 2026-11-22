defmodule HeddleIntegrations.Redis.MixProject do
  use Mix.Project

  def project do
    [
      app: :heddle_redis,
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
          HeddleIntegrations.Nodes.Redis.DeleteKeys,
          HeddleIntegrations.Nodes.Redis.FindKeys,
          HeddleIntegrations.Nodes.Redis.GetValue,
          HeddleIntegrations.Nodes.Redis.Increment,
          HeddleIntegrations.Nodes.Redis.PublishMessage,
          HeddleIntegrations.Nodes.Redis.PushToList,
          HeddleIntegrations.Nodes.Redis.ReadHash,
          HeddleIntegrations.Nodes.Redis.ReadList,
          HeddleIntegrations.Nodes.Redis.RunCommand,
          HeddleIntegrations.Nodes.Redis.SetValue,
          HeddleIntegrations.Nodes.Redis.WriteHash
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
      {:redix, "~> 1.5"},
      {:jason, "~> 1.2"},
      {:plug, "~> 1.0", only: :test}
    ]
  end
end
