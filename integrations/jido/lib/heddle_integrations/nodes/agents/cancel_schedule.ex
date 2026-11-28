defmodule HeddleIntegrations.Nodes.Agents.CancelSchedule do
  @moduledoc """
  Calls off what Agent: Schedule set for this instance: the one whose id it names, or
  every one when the id is blank, like when the customer already paid.
  `result.cancelled` lists their ids.
  """

  use Bobbin.Node

  alias Bobbin.Host
  alias Bobbin.Service
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.definition(
      "Cancel Schedule",
      "Calls off a message Agent: Schedule set for this instance, or all of them.",
      [%{type: :text, name: :id, label: "Schedule id, blank for all", default: ""}]
    )
  end

  @impl true
  def handler(context, _input) do
    with {:ok, agent} <- Agents.agent(context) do
      id = Agents.text(context, "id")
      schedules = Agents.instance(context, agent["name"], agent["key"])["schedules"] || []
      {cancelled, kept} = Enum.split_with(schedules, &(id == "" or &1["id"] == id))

      for schedule <- cancelled,
          run_id <- schedule["runs"] || [],
          do: Host.cancel_run(context["workspace_id"], run_id)

      case Agents.update_instance(context, agent, %{"schedules" => kept}) do
        {:ok, _instance} ->
          Service.success(context, %{"cancelled" => Enum.map(cancelled, & &1["id"])})

        {:error, message} ->
          Service.failure(context, message)
      end
    else
      {:error, message} -> Service.failure(context, message)
    end
  end
end
