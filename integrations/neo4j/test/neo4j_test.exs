defmodule HeddleIntegrations.Neo4jTest do
  @moduledoc """
  Runs the nodes of each store on a real server, from `docker-compose.databases.yml`.
  """

  use ExUnit.Case, async: false

  alias HeddleIntegrations.Nodes.{Cassandra, DynamoDB, Elasticsearch, MongoDB, Neo4j, Redis}

  @moduletag :databases
  @moduletag timeout: 30_000

  defmodule Vault do
    # A run asks within its workspace, which these tests leave out.
    def fetch(_workspace_id, name, kind), do: fetch(name, kind)

    def fetch("mongo", "mongodb") do
      {:ok, %{"url" => "mongodb://127.0.0.1:15405/heddle_test", "database" => "heddle_test"}}
    end

    def fetch("redis", "redis"), do: {:ok, %{"url" => "redis://127.0.0.1:15406/1"}}
    def fetch("bad-redis", "redis"), do: {:ok, %{"url" => "redis://:wrong@127.0.0.1:1"}}
    def fetch("es", "elasticsearch"), do: {:ok, %{"url" => "http://127.0.0.1:15408"}}

    def fetch("dynamo", "dynamodb") do
      {:ok,
       %{
         "access_key_id" => "local",
         "secret_access_key" => "local",
         "region" => "us-east-1",
         "endpoint" => "http://127.0.0.1:15409"
       }}
    end

    def fetch("cassandra", "cassandra") do
      {:ok, %{"hosts" => "127.0.0.1:15407", "keyspace" => "", "username" => ""}}
    end

    def fetch("neo4j", "neo4j") do
      {:ok,
       %{"url" => "http://127.0.0.1:15410", "username" => "neo4j", "password" => "heddle-test"}}
    end

    def fetch(name, _kind), do: {:error, "no #{name}"}
  end

  setup do
    client = Application.get_env(:bobbin, :credentials_client)
    plug = Application.get_env(:bobbin, :req_plug)
    Application.put_env(:bobbin, :credentials_client, Vault)
    Application.put_env(:bobbin, :req_plug, nil)
    Application.put_env(:bobbin, :req_plug, nil)

    on_exit(fn ->
      Application.put_env(:bobbin, :credentials_client, client)
      Application.put_env(:bobbin, :req_plug, plug)
      Application.put_env(:bobbin, :req_plug, plug)
    end)
  end

  defp node_run(module, credential, controls, context \\ %{}) do
    context = context |> Map.merge(controls) |> Map.put("credential", credential)

    case module.handler(context, nil) do
      {:ok, %{"result" => %{"error" => message}}, "error"} -> {:error, message}
      {:ok, %{"result" => result}, "success"} -> {:ok, result}
    end
  end

  describe "Neo4j" do
    test "runs Cypher, with values as parameters" do
      label = "Item#{System.system_time(:microsecond)}"

      assert {:ok, %{"count" => 1, "rows" => [%{"name" => "o'brien"}]}} =
               node_run(
                 Neo4j.RunQuery,
                 "neo4j",
                 %{"cypher" => "CREATE (n:#{label} {name: {{name}}}) RETURN n.name AS name"},
                 %{"name" => "o'brien"}
               )

      assert {:ok, %{"count" => 1}} =
               node_run(
                 Neo4j.RunQuery,
                 "neo4j",
                 %{"cypher" => "MATCH (n:#{label}) WHERE n.name CONTAINS '{{part}}' RETURN n"},
                 %{"part" => "brien"}
               )

      assert {:error, message} = node_run(Neo4j.RunQuery, "neo4j", %{"cypher" => "NOT CYPHER"})
      assert message =~ "Neo4j"
    end
  end
end
