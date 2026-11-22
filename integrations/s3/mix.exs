defmodule HeddleIntegrations.S3.MixProject do
  use Mix.Project

  def project do
    [
      app: :heddle_s3,
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
          HeddleIntegrations.Nodes.S3.Copy,
          HeddleIntegrations.Nodes.S3.Delete,
          HeddleIntegrations.Nodes.S3.Download,
          HeddleIntegrations.Nodes.S3.Info,
          HeddleIntegrations.Nodes.S3.List,
          HeddleIntegrations.Nodes.S3.ShareLink,
          HeddleIntegrations.Nodes.S3.Upload
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
      {:jason, "~> 1.2"},
      {:plug, "~> 1.0", only: :test}
    ]
  end
end
