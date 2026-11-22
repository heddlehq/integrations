defmodule HeddleIntegrations.DynamoDBTest do
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

  describe "DynamoDB" do
    setup do
      table = "items_#{System.system_time(:microsecond)}"

      {:ok, _response} =
        Req.post("http://127.0.0.1:15409/",
          headers: [
            {"x-amz-target", "DynamoDB_20120810.CreateTable"},
            {"content-type", "application/x-amz-json-1.0"}
          ],
          aws_sigv4: [
            access_key_id: "local",
            secret_access_key: "local",
            region: "us-east-1",
            service: :dynamodb
          ],
          body:
            Jason.encode!(%{
              TableName: table,
              BillingMode: "PAY_PER_REQUEST",
              AttributeDefinitions: [
                %{AttributeName: "pk", AttributeType: "S"},
                %{AttributeName: "sk", AttributeType: "N"}
              ],
              KeySchema: [
                %{AttributeName: "pk", KeyType: "HASH"},
                %{AttributeName: "sk", KeyType: "RANGE"}
              ]
            })
        )

      %{table: table}
    end

    test "puts, reads, updates, queries, scans and deletes", %{table: table} do
      item =
        ~s({"pk": "a", "sk": 1, "name": "x", "tags": ["t"], "more": {"ok": true}, "price": 1.5})

      key = ~s({"pk": "a", "sk": 1})

      assert {:ok, %{"saved" => true}} =
               node_run(DynamoDB.PutItem, "dynamo", %{"table" => table, "item_data" => item})

      assert {:ok, %{"found" => true, "item" => found}} =
               node_run(DynamoDB.GetItem, "dynamo", %{"table" => table, "item_key" => key})

      assert found == %{
               "pk" => "a",
               "sk" => 1,
               "name" => "x",
               "tags" => ["t"],
               "more" => %{"ok" => true},
               "price" => 1.5
             }

      assert {:ok, %{"item" => %{"name" => "y", "sk" => 1}}} =
               node_run(DynamoDB.UpdateItem, "dynamo", %{
                 "table" => table,
                 "item_key" => key,
                 "changes" => ~s({"name": "y"})
               })

      assert {:ok, %{"count" => 1, "items" => [%{"name" => "y"}]}} =
               node_run(
                 DynamoDB.QueryItems,
                 "dynamo",
                 %{
                   "table" => table,
                   "condition" => "pk = :pk",
                   "condition_values" => ~s({":pk": "{{id}}"})
                 },
                 %{"id" => "a"}
               )

      assert {:ok, %{"count" => 1}} = node_run(DynamoDB.ScanItems, "dynamo", %{"table" => table})

      assert {:ok, %{"tables" => tables}} = node_run(DynamoDB.ListTables, "dynamo", %{})
      assert table in tables

      assert {:ok, %{"deleted" => true}} =
               node_run(DynamoDB.DeleteItem, "dynamo", %{"table" => table, "item_key" => key})

      assert {:ok, %{"found" => false}} =
               node_run(DynamoDB.GetItem, "dynamo", %{"table" => table, "item_key" => key})
    end

    test "reports what the service refuses" do
      assert {:error, message} =
               node_run(DynamoDB.ScanItems, "dynamo", %{"table" => "nowhere"})

      assert message =~ "400"
    end
  end
end
