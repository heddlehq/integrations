defmodule HeddleIntegrations.Nodes.Agents.Agent do
  @moduledoc """
  The start of an agent's flow. Each message to the agent starts a run here, with
  `agent` in the context: its `name`, the instance `key`, the `message`, who it is
  `from`, and its `state`, as this version of the flow keeps it.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.trigger_definition([
      %{type: :text, name: :name, label: "Name", default: ""},
      %{type: :textarea, name: :instructions, label: "Instructions", default: ""},
      Service.credential_field("ai"),
      %{type: :model, name: :model, label: "Model", capability: :text, default: ""},
      %{type: :json, name: :state, label: "State", default: "{}"}
    ])
  end

  @impl true
  def handler(context, _input) do
    data = if is_map(context["result"]), do: context["result"], else: %{}
    name = Agents.text(context, "name")
    key = Agents.key(data["key"])

    with :ok <- check_name(name),
         {:ok, declared} <- Agents.declared_state(context["state"]) do
      instance = Agents.instance(context, name, key)

      agent = %{
        "name" => name,
        "key" => key,
        "message" => message(data["message"]),
        "from" => data["from"] || %{"type" => "flow"},
        "state" => Agents.migrate(declared, instance["state"]),
        "declared" => declared,
        "instructions" => Agents.text(context, "instructions"),
        "credential" => context["credential"],
        "model" => context["model"],
        "reply_to" => data["reply_to"],
        "messages" => instance["messages"] || 0
      }

      result = Map.take(agent, ["name", "key", "message", "from", "state"])
      {:ok, context |> Map.put("agent", agent) |> Map.put("result", result), "exec"}
    end
  end

  defp check_name(""), do: {:error, "Give the agent a name."}

  defp check_name(name) do
    if String.contains?(name, "/"),
      do: {:error, "An agent's name can't have a /."},
      else: :ok
  end

  defp message(nil), do: ""
  defp message(text) when is_binary(text), do: text
  defp message(value), do: Jason.encode!(value)
end
