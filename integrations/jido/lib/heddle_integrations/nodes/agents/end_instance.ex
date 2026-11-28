defmodule HeddleIntegrations.Nodes.Agents.EndInstance do
  @moduledoc """
  Ends this instance once its work is done, like a collection that was paid: its
  state, conversation and schedules are forgotten, once the run ends well. A new
  message to its key starts over.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.definition(
      "End Instance",
      "Ends this instance once its work is done: its state, conversation and schedules are forgotten.",
      []
    )
  end

  @impl true
  def handler(context, _input) do
    with {:ok, agent} <- Agents.agent(context),
         {:ok, ended} <- Agents.forget_instance(context, agent["name"], agent["key"]) do
      Service.success(context, %{
        "key" => agent["key"],
        "state" => ended["state"] || agent["state"]
      })
    else
      {:error, message} -> Service.failure(context, message)
    end
  end
end
