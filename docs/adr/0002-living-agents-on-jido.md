# 2. Agents: living agents on Jido

Date: 2026-11-28
Status: proposed

## Context

Heddle's AI Agent node already reasons with tools inside a single run: it calls a
model, the nodes linked to its `tools` output, and answers. When the run ends, the
agent ends. Nothing it learned is left for the next run, except what the flow writes
to a Memory key by hand.

What people build with n8n or Zapier on top of that is an agent that lives: a support
agent that remembers each customer, an SDR that follows up three days later, a
collections agent that knows what it promised. Today in Heddle each of those is a flow
that reads state, calls the AI Agent, writes state, schedules itself, and guards
against two messages at once. It's possible, and almost nobody gets it right.

[Jido](https://hex.pm/packages/jido) is an Elixir framework for agents with state:
an agent is a struct with a schema, it handles one message at a time, and Jido 3
ships a ReAct loop (Jido.AI) with a context window, cost limits and tool review. It
uses `req_llm`, as Heddle does.

Most people who use Heddle have never heard of Jido. Its words (Action, Signal,
Sensor, Directive) mean nothing to them, and they shouldn't have to learn them.

## Decision

### What an agent is

- **A living agent**: it has a name, lives in the workspace and keeps its state between
  runs. Heddle's flows are its hands. It isn't another way to reason in a single run:
  the AI Agent node stays for that.
- **Heddle's words**: Agent, Message, State, Event. Jido shows up only as "powered by
  Jido" in the docs. The palette category is "Agents" ("Agentes" in pt-BR); the
  package id is `jido`.
- **A package in this repository**, `integrations/jido` (the app `heddle_jido`),
  though Jido isn't an external service. It needs Heddle's core only through generic
  extension points of the Bobbin host (below), which other packages can use too.

### An agent is a flow

- **The flow-agent**: a flow that begins at the **Agent** trigger. The trigger holds
  the name, the instructions, the credential and model of the AI page, the state it
  keeps and a `tools` output. Publishing the flow creates the agent; each message is a
  run of it.
- **Instances by key**, as a Memory key: one instance per customer, each with its own
  state and conversation. A fixed key (`main`, the default) makes a single agent.
- **Declared state**: the trigger lists each field with its starting value, as JSON
  (`{"stage": "new", "attempts": 0}`). The starting value sets the field's type, and
  Set State refuses a field that isn't declared or a value of another type.
- **Its anatomy**: trigger → **Think** (optional) → **Reply**, **Set State**,
  **Schedule**, **Publish Event**. Think runs Jido's ReAct with the nodes linked to its
  `tools` output as tools. A flow-agent without Think is a state machine, which is
  fine.

### Durability

- The state and the conversation of each instance are kept in Heddle's store
  (Postgres), under the namespace `agents` as `name/key`. What a run changes is kept
  only if the run ends well (`with_run`).
- **One run per message, one at a time per instance**: each run goes in the lane
  `agents:name/key` (an Oban job each), so two messages never change an instance at
  once. The Jido process lives only during Think; the conversation goes to the store
  with `Jido.Session.encode/decode`.
- No Erlang cluster is needed.

### What wakes an agent (v1)

- A message from a flow: **Send Message** (fire and forget) and **Ask** (the run waits
  for the reply that Reply gives).
- Its schedule: **Schedule** and **Cancel Schedule**, on Oban.
- Events: **Publish Event**, and the trigger **When an agent publishes an event** for
  any flow.
- A person: a public chat page `/chat/:token`, and channels (WhatsApp, Slack) through
  flows that send their messages.

Agents work together by asking each other: **Ask an agent** as a tool of Think, plus
events.

### The nodes

16 nodes:

| Where | Nodes |
| --- | --- |
| Trigger | Agent |
| In the flow-agent | Think, Reply, Set State, Schedule, Cancel Schedule, Publish Event, End Instance |
| In any flow | Send Message, Ask, Read Agent, List Instances, Publish Event, Pause/Resume, Reset Instance |
| Trigger in any flow | When an agent publishes an event |

### Safety (v1)

- **No loops**: a chain of agents messaging each other stops at depth 5.
- **A budget per instance**: messages per hour and cost per day.
- **Approval** before the tools marked for it (Jido's `review_tools`).
- **Who may send**: a list of the flows and agents allowed to message an agent.

### Versions

An instance moves to the new version of its flow on its next message: a field it kept
stays when its type is the same, a new field starts at its value, a removed field
goes. Publishing warns when a field changes type, since its value is lost.

### Memory

The conversation keeps the last 20 messages (`context.max_messages`), a summary of the
older ones, and a **remember** tool that writes to a declared field.

### Jido 3, through a bridge

- **`jido` 3.0.0-beta.3**, a single package that includes Jido.AI. `jido_ai` 2.4
  doesn't resolve with the `req_llm` 1.30 that Heddle uses.
- Jido calls the model and the tools from processes of its own (Tasks). What Heddle
  tracks for a step lives in the node's process: its cost, the runs that led to it
  (for the loop check), and the API key. So Think runs Jido in a task, and the node's
  process answers each model call and each tool until it ends. Jido's processes find
  it among their `$callers`. The API key never reaches Jido, so it is never in what an
  agent keeps.
- The model comes from the AI page (`Bobbin.Host.ai_connection/2`), and each call's
  usage is charged to the step (`Bobbin.Host.record_usage/1`). Heddle keeps its own
  `req_llm` setup: Heddle's AI isn't moved to Jido.

### Heddle's side

Generic extension points of the Bobbin host, in Heddle's core:

- `run_tool`: a package's node calls the nodes linked to its `tools` output.
- `ai_connection` and `record_usage` (done).
- A package's node waits and resumes (`wait_for_call`), for Ask.
- A package registers a trigger that starts runs in a lane, and a schedule on Oban.
- The `/chat/:token` route.
- A panel in a node's drawer, filled by its package: for the Agent trigger, its
  instances, state, messages, schedule and runs, and a **Chat** button to try it.
- MCP: `list_nodes` with each node's docs, and `list_agents`, `read_agent`,
  `message_agent`.

### For those who don't know Jido

- Four templates: Support Agent, SDR Follow-up, Collections, Triage Team.
- A guide in English and Portuguese.
- The editor's copilot knows how to build a flow-agent.
- The Chat button in the trigger's panel, to talk to the agent before publishing it to
  anyone.

### Order

1. **Heddle's core**: the extension points above, and their tables.
2. **The minimal cycle**: Agent, Think, Reply, Set State, Send Message, Ask.
3. **Schedule, events and safety**.
4. **Chat, panel, templates and docs**.

## Consequences

- Heddle gets agents that live, and the AI Agent node keeps its place: one run, one
  task.
- Jido 3 is a beta. The package pins its exact version, and a Jido release can change
  the bridge or the ReAct options it uses.
- The package needs Bobbin 0.7 (`ai_connection`, `record_usage`, `wait_for_call`).
  Until it's released, it builds only with `BOBBIN_PATH` set to a checkout.
- An instance handles one message at a time. A busy agent (a public chat with many
  people on one key) queues; one key per person avoids that.
- Ask as a tool of Think needs a node that waits inside a tool, which Heddle doesn't
  support yet. Until it does, Think can't ask another agent; it can only send it a
  message.
- The extension points (run a tool, wait, a panel in the drawer, a trigger in a lane)
  are generic. The next packages that need them get them for free.
- Like every package, `jido` enters Heddle at build time (`HEDDLE_INTEGRATIONS`) and
  needs its logo, its `priv/docs.json` in English and Portuguese, and its line in
  `catalog.yaml`.
