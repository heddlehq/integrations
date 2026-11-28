defmodule HeddleIntegrations.Nodes.Agents.ListInstances do
  @moduledoc """
  Lists the instances of an agent, from any flow, with their state: those whose key
  begins with Key starts with, up to Limit. `result.instances` is the list and
  `result.count` how many.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.definition(
      "List Instances",
      "Lists the instances of an agent, with their state.",
      [
        Agents.agent_field(),
        %{type: :text, name: :prefix, label: "Key starts with", default: ""},
        %{type: :text, name: :limit, label: "Limit", default: "100"}
      ]
    )
  end

  @impl true
  def handler(context, _input) do
    name = Agents.text(context, "to")
    limit = context |> Agents.number("limit") |> limit()

    if name == "" do
      Service.failure(context, "Name the agent.")
    else
      instances =
        context
        |> Agents.instances(name, Agents.text(context, "prefix"), limit)
        |> Enum.map(fn instance ->
          %{
            "key" => instance["key"],
            "state" => instance["state"] || %{},
            "messages" => instance["messages"] || 0,
            "schedules" => length(instance["schedules"] || []),
            "updated_at" => instance["updated_at"]
          }
        end)

      Service.success(context, %{"instances" => instances, "count" => length(instances)})
    end
  end

  defp limit(nil), do: 100
  defp limit(number), do: number |> trunc() |> max(1) |> min(1_000)
end
