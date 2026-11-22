defmodule HeddleIntegrations.DynamoDBHttpTest do
  @moduledoc """
  What the stores reached over HTTP send and read. `stores_test.exs` runs them on real
  servers.
  """

  use ExUnit.Case, async: false

  alias HeddleIntegrations.Nodes.{DynamoDB, Elasticsearch, HttpRequest, Neo4j}

  defmodule Vault do
    # A run asks within its workspace, which these tests leave out.
    def fetch(_workspace_id, name, kind), do: fetch(name, kind)

    def fetch("es", "elasticsearch"), do: {:ok, %{"url" => "http://es:9200/", "api_key" => "k"}}

    def fetch("es-basic", "elasticsearch") do
      {:ok, %{"url" => "http://es:9200", "username" => "u", "password" => "p"}}
    end

    def fetch("neo", "neo4j") do
      {:ok, %{"url" => "http://neo:7474", "username" => "u", "password" => "p"}}
    end

    def fetch("aws", "dynamodb") do
      {:ok, %{"access_key_id" => "AK", "secret_access_key" => "SK", "region" => "sa-east-1"}}
    end
  end

  setup do
    previous = Application.get_env(:bobbin, :credentials_client)
    Application.put_env(:bobbin, :credentials_client, Vault)
    on_exit(fn -> Application.put_env(:bobbin, :credentials_client, previous) end)
  end

  defp reply(status, body) do
    test = self()

    Req.Test.stub(HttpRequest, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end)
  end

  defp run(module, credential, controls, context \\ %{}) do
    context = context |> Map.merge(controls) |> Map.put("credential", credential)

    case module.handler(context, nil) do
      {:ok, %{"result" => result}, "success"} -> {:ok, result}
      {:ok, %{"result" => %{"error" => message}}, "error"} -> {:error, message}
    end
  end

  describe "DynamoDB" do
    test "writes and reads the typed form" do
      reply(200, %{
        "Item" => %{
          "id" => %{"S" => "1"},
          "n" => %{"N" => "2"},
          "f" => %{"N" => "1.5"},
          "ok" => %{"BOOL" => true},
          "none" => %{"NULL" => true},
          "list" => %{"L" => [%{"S" => "a"}]},
          "map" => %{"M" => %{"a" => %{"N" => "1"}}},
          "set" => %{"SS" => ["x"]}
        }
      })

      assert {:ok, %{"found" => true, "item" => item}} =
               run(DynamoDB.GetItem, "aws", %{
                 "table" => "t",
                 "item_key" => ~s({"id": "1", "n": 2})
               })

      assert item == %{
               "id" => "1",
               "n" => 2,
               "f" => 1.5,
               "ok" => true,
               "none" => nil,
               "list" => ["a"],
               "map" => %{"a" => 1},
               "set" => ["x"]
             }

      assert_received {:request, conn, raw}
      assert conn.host == "dynamodb.sa-east-1.amazonaws.com"
      assert Plug.Conn.get_req_header(conn, "x-amz-target") == ["DynamoDB_20120810.GetItem"]
      assert ["AWS4-HMAC-SHA256" <> _rest] = Plug.Conn.get_req_header(conn, "authorization")

      assert Jason.decode!(raw) == %{
               "TableName" => "t",
               "Key" => %{"id" => %{"S" => "1"}, "n" => %{"N" => "2"}}
             }
    end

    test "updates through names and values, so a reserved word works" do
      reply(200, %{"Attributes" => %{"name" => %{"S" => "b"}}})

      assert {:ok, %{"item" => %{"name" => "b"}}} =
               run(DynamoDB.UpdateItem, "aws", %{
                 "table" => "t",
                 "item_key" => ~s({"id": "1"}),
                 "changes" => ~s({"name": "b"})
               })

      assert_received {:request, _conn, raw}

      assert %{
               "UpdateExpression" => "SET #n0 = :v0",
               "ExpressionAttributeNames" => %{"#n0" => "name"},
               "ExpressionAttributeValues" => %{":v0" => %{"S" => "b"}}
             } = Jason.decode!(raw)
    end

    test "says what the service refused" do
      reply(400, %{"message" => "Requested resource not found"})

      assert {:error, message} = run(DynamoDB.ScanItems, "aws", %{"table" => "t"})
      assert message =~ "not found"
    end
  end
end
