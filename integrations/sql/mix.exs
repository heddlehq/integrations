defmodule HeddleIntegrations.SQL.MixProject do
  use Mix.Project

  def project do
    [
      app: :heddle_sql,
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
          HeddleIntegrations.Nodes.Sql.DeleteRows,
          HeddleIntegrations.Nodes.Sql.DescribeTable,
          HeddleIntegrations.Nodes.Sql.InsertRows,
          HeddleIntegrations.Nodes.Sql.ListTables,
          HeddleIntegrations.Nodes.Sql.RunQuery,
          HeddleIntegrations.Nodes.Sql.RunTransaction,
          HeddleIntegrations.Nodes.Sql.SelectRows,
          HeddleIntegrations.Nodes.Sql.UpdateRows,
          HeddleIntegrations.Nodes.Sql.UpsertRows
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
      {:postgrex, "~> 0.22"},
      {:myxql, "~> 0.8.0"},
      {:tds, "~> 2.3"},
      {:exqlite, "~> 0.43"},
      {:jamdb_oracle, "~> 0.5.12"},
      {:jason, "~> 1.2"},
      {:plug, "~> 1.0", only: :test}
    ]
  end
end
