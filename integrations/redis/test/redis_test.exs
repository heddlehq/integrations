defmodule HeddleIntegrations.RedisTest do
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

  describe "Redis" do
    setup do
      %{key: "heddle:test:#{System.system_time(:microsecond)}"}
    end

    test "sets, gets, expires and deletes", %{key: key} do
      assert {:ok, _result} =
               node_run(Redis.SetValue, "redis", %{"key" => key, "value" => "hello {{who}}"}, %{
                 "who" => "you"
               })

      assert {:ok, %{"value" => "hello you", "found" => true}} =
               node_run(Redis.GetValue, "redis", %{"key" => key})

      assert {:ok, %{"count" => 1}} = node_run(Redis.DeleteKeys, "redis", %{"keys" => key})
      assert {:ok, %{"found" => false}} = node_run(Redis.GetValue, "redis", %{"key" => key})

      assert {:ok, _result} =
               node_run(Redis.SetValue, "redis", %{
                 "key" => key,
                 "value" => "x",
                 "seconds" => "100"
               })

      assert {:ok, %{"reply" => ttl}} =
               node_run(Redis.RunCommand, "redis", %{"command" => ~s(["TTL", "#{key}"])})

      assert ttl in 90..100
    end

    test "increments", %{key: key} do
      assert {:ok, %{"value" => 1}} = node_run(Redis.Increment, "redis", %{"key" => key})

      assert {:ok, %{"value" => 6}} =
               node_run(Redis.Increment, "redis", %{"key" => key, "amount" => "5"})
    end

    test "finds keys", %{key: key} do
      node_run(Redis.SetValue, "redis", %{"key" => key, "value" => "x"})

      assert {:ok, %{"keys" => [^key]}} =
               node_run(Redis.FindKeys, "redis", %{"pattern" => key <> "*"})
    end

    test "writes and reads hashes and lists", %{key: key} do
      assert {:ok, %{"added" => 2}} =
               node_run(Redis.WriteHash, "redis", %{
                 "key" => key,
                 "fields" => ~s({"name": "a", "age": 30})
               })

      assert {:ok, %{"fields" => %{"name" => "a", "age" => "30"}}} =
               node_run(Redis.ReadHash, "redis", %{"key" => key})

      list = key <> ":list"
      node_run(Redis.PushToList, "redis", %{"key" => list, "value" => "b"})
      node_run(Redis.PushToList, "redis", %{"key" => list, "value" => "a", "side" => "start"})

      assert {:ok, %{"items" => ["a", "b"], "count" => 2}} =
               node_run(Redis.ReadList, "redis", %{"key" => list})
    end

    test "publishes" do
      assert {:ok, %{"subscribers" => 0}} =
               node_run(Redis.PublishMessage, "redis", %{"channel" => "c", "value" => "m"})
    end

    test "runs a command with values as arguments" do
      assert {:ok, %{"reply" => "a b"}} =
               node_run(Redis.RunCommand, "redis", %{"command" => ~s(["ECHO", {{text}}])}, %{
                 "text" => "a b"
               })

      assert {:error, message} =
               node_run(Redis.RunCommand, "redis", %{"command" => ~s(["NOPE"])})

      assert message =~ "unknown command"
    end

    test "says when it can't connect" do
      assert {:error, message} = node_run(Redis.GetValue, "bad-redis", %{"key" => "x"})
      assert message =~ "Could not connect"
      refute message =~ "wrong"
    end
  end
end
