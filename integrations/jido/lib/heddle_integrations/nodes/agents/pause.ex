defmodule HeddleIntegrations.Nodes.Agents.Pause do
  @moduledoc """
  Pauses an agent, or resumes it, from any flow: while paused, it takes no messages.
  Sending one says it is paused, and a schedule that comes meanwhile fails its run,
  saying so. With a key, only that instance.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.definition(
      "Pause or Resume",
      "Pauses an agent, or one of its instances, so it takes no messages, or resumes it.",
      [
        Agents.agent_field(),
        %{type: :text, name: :key, label: "Instance key, blank for the whole agent", default: ""},
        %{
          type: :select,
          name: :action,
          label: "Action",
          options: ["pause", "resume"],
          default: "pause"
        }
      ]
    )
  end

  @impl true
  def handler(context, _input) do
    name = Agents.text(context, "to")
    key = Agents.text(context, "key")
    pause? = Agents.text(context, "action") != "resume"

    with :ok <- if(name == "", do: {:error, "Name the agent."}, else: :ok),
         :ok <- Agents.set_paused(context["workspace_id"], name, key, pause?) do
      Service.success(context, %{
        "agent" => name,
        "key" => if(key == "", do: nil, else: key),
        "paused" => pause?
      })
    else
      {:error, message} -> Service.failure(context, message)
    end
  end
end
