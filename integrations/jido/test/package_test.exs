defmodule HeddleIntegrations.Agents.PackageTest do
  use ExUnit.Case, async: true

  test "every node is documented, in English and Portuguese" do
    docs = "priv/docs.json" |> File.read!() |> Jason.decode!()
    nodes = Application.get_env(:heddle_jido, :bobbin_nodes)

    for module <- nodes do
      name = module.definition().name
      assert %{"notes" => %{"en" => en, "pt" => pt}} = docs[name], "#{name} has no docs"
      assert en != "" and pt != ""
    end

    assert map_size(docs) == length(nodes)
  end

  test "every template is a flow of nodes this package and Heddle have" do
    names = Enum.map(Application.get_env(:heddle_jido, :bobbin_nodes), & &1.definition().name)
    core = ~w(Logger Start Webhook)

    for path <- Application.get_env(:heddle_jido, :bobbin_templates) do
      template = path |> File.read!() |> Jason.decode!()
      assert template["name"] != "" and template["description"] != ""
      assert template["i18n"]["pt-BR"]["name"] != ""

      ids = MapSet.new(template["nodes"], & &1["id"])

      for node <- template["nodes"], do: assert(node["type"] in (names ++ core), node["type"])

      for wire <- template["connections"] do
        assert wire["source"] in ids and wire["target"] in ids
      end
    end
  end
end
