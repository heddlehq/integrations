defmodule HeddleIntegrations.CassandraTest do
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

  describe "Cassandra" do
    test "creates, writes and reads, with values as parameters" do
      query = fn cql, context ->
        node_run(Cassandra.RunQuery, "cassandra", %{"cql" => cql}, context)
      end

      table = "heddle_test.items_#{System.system_time(:microsecond)}"

      assert {:ok, _result} =
               query.(
                 "CREATE KEYSPACE IF NOT EXISTS heddle_test WITH replication = " <>
                   "{'class': 'SimpleStrategy', 'replication_factor': 1}",
                 %{}
               )

      assert {:ok, _result} =
               query.(
                 "CREATE TABLE #{table} (id int PRIMARY KEY, name text, price decimal, " <>
                   "at timestamp, active boolean, ref uuid, tags set<text>)",
                 %{}
               )

      assert {:ok, %{"count" => 0}} =
               query.(
                 "INSERT INTO #{table} (id, name, price, at, active, ref, tags) " <>
                   "VALUES ({{id}}, {{name}}, {{price}}, {{at}}, {{active}}, {{ref}}, {{tags}})",
                 %{
                   "id" => "7",
                   "name" => "o'brien",
                   "price" => "10.50",
                   "at" => "2026-11-07T10:00:00Z",
                   "active" => "true",
                   "ref" => "6f9619ff-8b86-d011-b42d-00c04fc964ff",
                   "tags" => ["a"]
                 }
               )

      assert {:ok, %{"count" => 1, "rows" => [row]}} =
               query.("SELECT * FROM #{table} WHERE id = {{id}}", %{"id" => 7})

      assert %{
               "id" => 7,
               "name" => "o'brien",
               "price" => "10.50",
               "active" => true,
               "ref" => "6f9619ff-8b86-d011-b42d-00c04fc964ff"
             } = row

      assert Jason.encode!(row)
    end

    test "reports what the server refuses" do
      assert {:error, _message} =
               node_run(Cassandra.RunQuery, "cassandra", %{"cql" => "SELECT * FROM nowhere.t"})
    end
  end
end
