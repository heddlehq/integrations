defmodule HeddleIntegrations.FTP.MixProject do
  use Mix.Project

  def project do
    [
      app: :heddle_ftp,
      version: "1.0.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps()
    ]
  end

  # Heddle finds the nodes of every app in its build that lists them here.
  def application do
    [
      extra_applications: [:logger, :ftp],
      env: [
        bobbin_nodes: [
          HeddleIntegrations.Nodes.Ftp.CreateFolder,
          HeddleIntegrations.Nodes.Ftp.Delete,
          HeddleIntegrations.Nodes.Ftp.DeleteFolder,
          HeddleIntegrations.Nodes.Ftp.Download,
          HeddleIntegrations.Nodes.Ftp.List,
          HeddleIntegrations.Nodes.Ftp.Rename,
          HeddleIntegrations.Nodes.Ftp.Upload
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
