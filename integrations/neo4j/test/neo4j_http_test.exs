defmodule HeddleIntegrations.Neo4jHttpTest do
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

  describe "Neo4j" do
    test "sends values as parameters" do
      reply(202, %{"data" => %{"fields" => ["n"], "values" => [[1], [2]]}})

      assert {:ok, %{"count" => 2, "rows" => [%{"n" => 1}, %{"n" => 2}]}} =
               run(Neo4j.RunQuery, "neo", %{"cypher" => "RETURN {{a}} AS n"}, %{
                 "a" => "x' OR 1=1"
               })

      assert_received {:request, conn, raw}
      assert conn.request_path == "/db/neo4j/query/v2"

      assert Jason.decode!(raw) == %{
               "statement" => "RETURN $p1 AS n",
               "parameters" => %{"p1" => "x' OR 1=1"}
             }
    end

    test "says what the server refused" do
      reply(400, %{"errors" => [%{"message" => "bad query"}]})

      assert {:error, "Neo4j: bad query"} = run(Neo4j.RunQuery, "neo", %{"cypher" => "X"})
    end
  end
end
