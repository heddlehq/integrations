defmodule HeddleIntegrations.ElasticsearchHttpTest do
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

  describe "Elasticsearch" do
    test "searches with the query of the node" do
      reply(200, %{
        "hits" => %{
          "total" => %{"value" => 1},
          "hits" => [%{"_id" => "1", "_score" => 1.5, "_source" => %{"title" => "a"}}]
        }
      })

      assert {:ok, %{"total" => 1, "documents" => [document]}} =
               run(
                 Elasticsearch.Search,
                 "es",
                 %{"index_name" => "a b", "search" => ~s({"match": {"title": "{{term}}"}})},
                 %{"term" => ~s(say "hi")}
               )

      assert document == %{"_id" => "1", "_score" => 1.5, "title" => "a"}

      assert_received {:request, conn, raw}
      assert conn.request_path == "/a%20b/_search"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["ApiKey k"]
      assert %{"query" => %{"match" => %{"title" => ~s(say "hi")}}} = Jason.decode!(raw)
    end

    test "logs in with a username when there's no API key" do
      reply(200, %{"_id" => "1", "_source" => %{}})

      assert {:ok, _document} =
               run(Elasticsearch.GetDocument, "es-basic", %{
                 "index_name" => "i",
                 "document_id" => "1"
               })

      assert_received {:request, conn, _raw}
      assert ["Basic " <> _rest] = Plug.Conn.get_req_header(conn, "authorization")
    end

    test "says what the server refused" do
      reply(404, %{"error" => %{"reason" => "no such index"}})

      assert {:error, message} =
               run(Elasticsearch.GetDocument, "es", %{"index_name" => "i", "document_id" => "1"})

      assert message =~ "no such index"
    end

    test "asks for what's missing" do
      assert {:error, _message} = run(Elasticsearch.Search, "es", %{"index_name" => " "})
    end
  end
end
