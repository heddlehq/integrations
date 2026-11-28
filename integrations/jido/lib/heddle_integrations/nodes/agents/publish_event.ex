defmodule HeddleIntegrations.Nodes.Agents.PublishEvent do
  @moduledoc """
  Tells the workspace something happened, like `deal.won`: every published flow that
  begins at When an Agent Publishes, for this event or for any, starts with it. In an
  agent's flow, the event says which agent and instance published it.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.definition(
      "Publish Event",
      "Tells the flows that wait for an event, like deal.won, that it happened.",
      [
        %{type: :text, name: :event, label: "Event", default: ""},
        %{type: :json, name: :data, label: "Data", default: "{}"}
      ]
    )
  end

  @impl true
  def handler(context, _input) do
    event = Agents.text(context, "event")

    with :ok <- if(event == "", do: {:error, "Name the event, like deal.won."}, else: :ok),
         {:ok, data} <- Service.json(context, "data"),
         {:ok, runs} <- Agents.publish_event(context, event, data || %{}) do
      Service.success(context, %{"event" => event, "runs" => runs})
    else
      {:error, message} -> Service.failure(context, message)
    end
  end
end
