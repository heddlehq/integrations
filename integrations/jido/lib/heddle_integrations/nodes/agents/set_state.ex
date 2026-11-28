defmodule HeddleIntegrations.Nodes.Agents.SetState do
  @moduledoc """
  Changes what the agent keeps for its instance. Each field must be in the State of
  its Agent trigger, with the same type. It is kept once the run ends well, and the
  next message sees it.
  """

  use Bobbin.Node

  alias Bobbin.Service
  alias Bobbin.Template
  alias HeddleIntegrations.Services.Agents

  definition do
    Agents.definition(
      "Set State",
      "Changes what the agent keeps for this instance, like the stage of a deal.",
      [%{type: :json, name: :changes, label: "Changes", default: "{}"}]
    )
  end

  @impl true
  def handler(context, _input) do
    with {:ok, agent} <- Agents.agent(context),
         {:ok, changes} <- changes(context),
         {:ok, state} <- Agents.change_state(agent["state"], agent["declared"] || %{}, changes),
         {:ok, _instance} <- Agents.update_instance(context, agent, %{"state" => state}) do
      context
      |> Map.put("agent", Map.put(agent, "state", state))
      |> Service.success(state)
    else
      {:error, message} -> Service.failure(context, message)
    end
  end

  defp changes(context) do
    case context["changes"] do
      map when is_map(map) -> {:ok, map}
      text when text in [nil, ""] -> {:ok, %{}}
      text when is_binary(text) -> text |> Template.json(context) |> object()
      _other -> object(:error)
    end
  end

  defp object({:ok, map}) when is_map(map), do: {:ok, map}
  defp object({:error, message}) when is_binary(message), do: {:error, message}
  defp object(_other), do: {:error, "Changes must be a JSON object, like {\"stage\": \"won\"}."}
end
