defmodule HeddleIntegrations.MongoDBTest do
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

  describe "MongoDB" do
    setup do
      collection = "items_#{System.system_time(:microsecond)}"

      {:ok, %{"count" => 3}} =
        node_run(MongoDB.InsertDocuments, "mongo", %{
          "collection" => collection,
          "documents" =>
            ~s([{"name": "a", "n": 1}, {"name": "b", "n": 2}, {"name": "c", "n": 3, "at": {"$date": "2026-11-07T10:00:00Z"}}])
        })

      %{collection: collection}
    end

    test "finds with a filter, fields, sort, limit and skip", %{collection: collection} do
      assert {:ok, %{"documents" => [%{"name" => "b"} = document], "count" => 1}} =
               node_run(
                 MongoDB.FindDocuments,
                 "mongo",
                 %{
                   "collection" => collection,
                   "filter" => ~s({"n": {"$gte": {{min}}}}),
                   "fields" => ~s({"name": 1}),
                   "sort" => ~s({"n": -1}),
                   "limit" => "1",
                   "offset" => "1"
                 },
                 %{"min" => 2}
               )

      assert is_binary(document["_id"])
      refute Map.has_key?(document, "n")
    end

    test "returns dates and ids a run can keep", %{collection: collection} do
      assert {:ok, %{"documents" => [document]}} =
               node_run(MongoDB.FindDocuments, "mongo", %{
                 "collection" => collection,
                 "filter" => ~s({"name": "c"})
               })

      assert document["at"] == "2026-11-07T10:00:00.000Z"
      assert Jason.encode!(document)

      assert {:ok, %{"documents" => [%{"name" => "c"}]}} =
               node_run(
                 MongoDB.FindDocuments,
                 "mongo",
                 %{"collection" => collection, "filter" => ~s({"_id": "{{id}}"})},
                 %{"id" => document["_id"]}
               )
    end

    test "a value from a run can't become an operator", %{collection: collection} do
      assert {:error, message} =
               node_run(
                 MongoDB.FindDocuments,
                 "mongo",
                 %{"collection" => collection, "filter" => ~s({"name": {{name}}})},
                 %{"name" => %{"$ne" => nil}}
               )

      assert message =~ "operator"
    end

    test "updates what matches, and refuses an empty filter", %{collection: collection} do
      assert {:ok, %{"matched" => 2, "modified" => 2}} =
               node_run(MongoDB.UpdateDocuments, "mongo", %{
                 "collection" => collection,
                 "filter" => ~s({"n": {"$gt": 1}}),
                 "update" => ~s({"$set": {"seen": true}})
               })

      assert {:ok, %{"matched" => 1, "modified" => 1}} =
               node_run(MongoDB.UpdateDocuments, "mongo", %{
                 "collection" => collection,
                 "filter" => ~s({"n": {"$gt": 1}}),
                 "update" => ~s({"$set": {"seen": false}}),
                 "which" => "first"
               })

      assert {:ok, %{"upserted_ids" => [_id]}} =
               node_run(MongoDB.UpdateDocuments, "mongo", %{
                 "collection" => collection,
                 "filter" => ~s({"name": "new"}),
                 "update" => ~s({"$set": {"n": 9}}),
                 "upsert" => "yes"
               })

      assert {:error, _message} =
               node_run(MongoDB.UpdateDocuments, "mongo", %{
                 "collection" => collection,
                 "filter" => "",
                 "update" => ~s({"$set": {"n": 0}})
               })
    end

    test "counts, aggregates, lists and deletes", %{collection: collection} do
      assert {:ok, %{"count" => 2}} =
               node_run(MongoDB.CountDocuments, "mongo", %{
                 "collection" => collection,
                 "filter" => ~s({"n": {"$lt": 3}})
               })

      assert {:ok, %{"documents" => [%{"_id" => nil, "total" => 6}]}} =
               node_run(MongoDB.Aggregate, "mongo", %{
                 "collection" => collection,
                 "pipeline" => ~s([{"$group": {"_id": null, "total": {"$sum": "$n"}}}])
               })

      assert {:ok, %{"collections" => collections}} =
               node_run(MongoDB.ListCollections, "mongo", %{})

      assert collection in collections

      assert {:error, _message} =
               node_run(MongoDB.DeleteDocuments, "mongo", %{
                 "collection" => collection,
                 "filter" => ""
               })

      assert {:ok, %{"count" => 1}} =
               node_run(MongoDB.DeleteDocuments, "mongo", %{
                 "collection" => collection,
                 "filter" => ~s({"name": "a"})
               })
    end
  end
end
