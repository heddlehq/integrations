defmodule HeddleIntegrations.Nodes.Agents.ResetInstance do
  @moduledoc """
  Starts an instance of an agent over, from any flow: its state, conversation and
  schedules are forgotten. `result.existed` says whether there was one.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.definition(
      "Reset Instance",
      "Starts an instance of an agent over: its state, conversation and schedules are forgotten.",
      [Agents.agent_field(), Agents.key_field()]
    )
  end

  @impl true
  def handler(context, _input) do
    name = Agents.text(context, "to")
    key = Agents.key(Agents.text(context, "key"))

    with :ok <- if(name == "", do: {:error, "Name the agent."}, else: :ok),
         existed = Agents.instance?(context, name, key),
         {:ok, _ended} <- Agents.forget_instance(context, name, key) do
      Service.success(context, %{"agent" => name, "key" => key, "existed" => existed})
    else
      {:error, message} -> Service.failure(context, message)
    end
  end
end
