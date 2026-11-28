defmodule HeddleIntegrations.Nodes.Agents.Event do
  @moduledoc """
  Starts a flow when an agent, or a flow, publishes an event with Agent: Publish Event.
  A blank Event takes every one. `result` has the `event`, its `data`, and the `agent`
  and `key` that published it.
  """

  use Bobbin.Node

  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.trigger_definition(
      Agents.event_trigger(),
      "Starts this flow when an agent publishes an event, like deal.won.",
      [%{type: :text, name: :event, label: "Event, blank for any", default: ""}]
    )
    |> Map.put(:title, "When an Agent Publishes")
  end

  @impl true
  def handler(context, _input) do
    data = if is_map(context["result"]), do: context["result"], else: %{}
    depth = if is_integer(data["depth"]), do: data["depth"], else: 0

    result = Map.take(data, ["event", "data", "agent", "key", "flow_id", "at"])
    {:ok, context |> Map.put("result", result) |> Map.put("agent_depth", depth), "exec"}
  end
end
