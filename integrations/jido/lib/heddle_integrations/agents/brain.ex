defmodule HeddleIntegrations.Agents.Brain do
  @moduledoc """
  The Jido agent behind every agent of a workspace: it reasons with ReAct, calling the
  tools of its flow. Who it is, what it knows and what it said before come with each
  message, from the Agent trigger and the instance kept in Heddle.
  """

  use Jido.AI.Agent, name: "heddle_agent"

  ai do
    reasoning(Jido.AI.Reasoning.ReAct)
  end
end

defmodule HeddleIntegrations.Agents.Brain.Model do
  @moduledoc """
  The model calls of `HeddleIntegrations.Agents.Brain`, made by the node's process,
  see `HeddleIntegrations.Agents.Bridge`. Only text is supported.
  """

  @behaviour Jido.AI.InferenceClient

  alias HeddleIntegrations.Agents.Bridge

  @impl true
  def generate_text(_model, context, options) do
    Bridge.ask({:generate_text, context, Keyword.drop(options, [:telemetry])})
  end

  @impl true
  def evaluation_models, do: []

  for {name, arity} <- Jido.AI.InferenceClient.behaviour_info(:callbacks),
      {name, arity} not in [generate_text: 3, evaluation_models: 0] do
    @impl true
    def unquote(name)(unquote_splicing(Macro.generate_arguments(arity, __MODULE__))),
      do: {:error, :not_supported}
  end
end

defmodule HeddleIntegrations.Agents.Brain.Tools do
  @moduledoc """
  The nodes connected to the `tools` output of Agent: Think, as tools of
  `HeddleIntegrations.Agents.Brain`. The node's process runs them, see
  `HeddleIntegrations.Agents.Bridge`.
  """

  @behaviour Jido.AI.ToolSource

  alias HeddleIntegrations.Agents.Bridge

  @impl true
  def list_tools(%{tools: tools}, _context) do
    {:ok,
     Enum.map(tools, fn tool ->
       %{name: tool.name, description: tool.description, parameter_schema: tool.parameters}
     end)}
  end

  @impl true
  def run_tool(%{name: name, arguments: arguments}, _config, _context) do
    Bridge.ask({:tool, name, arguments})
  end
end
