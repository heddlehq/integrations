defmodule HeddleIntegrations.Nodes.Agents.ReadAgent do
  @moduledoc """
  Reads an instance of an agent, from any flow: its `state`, how many `messages` it
  handled, a `summary` of its older conversation, its `schedules`, whether it is
  `paused`, and what it spent today. `exists` is false for a key that never got a
  message, whose state is then empty.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.definition(
      "Read Agent",
      "Reads an instance of an agent: its state, messages and schedules.",
      [Agents.agent_field(), Agents.key_field()]
    )
  end

  @impl true
  def handler(context, _input) do
    name = Agents.text(context, "to")
    key = Agents.key(Agents.text(context, "key"))

    if name == "" do
      Service.failure(context, "Name the agent to read.")
    else
      instance = Agents.instance(context, name, key)
      budget = Agents.budget(context["workspace_id"], name, key)

      Service.success(context, %{
        "agent" => name,
        "key" => key,
        "exists" => instance != %{},
        "state" => instance["state"] || %{},
        "messages" => instance["messages"] || 0,
        "summary" => instance["summary"],
        "last_messages" => Enum.take(instance["transcript"] || [], -6),
        "schedules" => instance["schedules"] || [],
        "paused" => Agents.paused?(context["workspace_id"], name, key),
        "today" => %{"messages_this_hour" => budget["messages"], "cost" => budget["cost"]},
        "updated_at" => instance["updated_at"]
      })
    end
  end
end
