# Heddle integrations

Every integration of [Heddle](https://github.com/heddlehq/Heddle) with an outside
service lives here, so Heddle itself ships only its core. There are two kinds:

- **Manifests**: `integrations/<id>/integration.yaml`, a YAML file that describes a
  service's credential, its actions and its triggers as HTTP requests. Heddle
  downloads one when a workspace installs it. Anyone can add one; the ones Heddle pins
  by hash, like Notion, show as official.
- **Packages**: `integrations/<id>/` holding a Mix project, for what needs a driver or
  code, like SQL, MongoDB or email. They are written with
  [Bobbin](https://github.com/heddlehq/Bobbin) (`Bobbin.Service`) and enter Heddle when
  it is built, as git dependencies: list them in `HEDDLE_INTEGRATIONS`. A package
  names its nodes in its app env, `bobbin_nodes`, and documents them in
  `priv/docs.json`: for each node, an example of what it leaves in `result` and notes
  in English and Portuguese, which Heddle's documentation site shows.

Each action becomes a node, with a `success` and an `error` output.

Heddle reads the index at **https://heddlehq.github.io/integrations/index.json** and
lists these integrations on its Integrations page, marked as community integrations.
Only workspace admins can install them, and an installed integration keeps its
version until someone updates it.

## The catalog

[`catalog.yaml`](catalog.yaml) lists every integration Heddle plans to have, about 600,
with its status, how it authenticates and the Elixir library it builds on, if any.
Why and in what order: [docs/adr/0001](docs/adr/0001-five-hundred-integrations.md).
CI checks that every folder here is in it.

## Adding an integration

1. Write the manifest with [Bobbin](https://github.com/heddlehq/Bobbin):

   ```bash
   mix new tools && cd tools        # any Mix project with {:bobbin, "~> 0.5"} in deps
   mix deps.get
   mix bobbin.new acme_crm --path ../integrations/acme_crm/integration.yaml
   ```

2. Fill it in, and try each action against the real API:

   ```bash
   mix bobbin.validate integrations/acme_crm/integration.yaml
   mix bobbin.run integrations/acme_crm/integration.yaml "Get Item" \
     --field id=42 --credential api_key=$KEY
   ```

3. Open a pull request. CI checks the manifest, and a maintainer reviews what it sends
   and where.

The folder must be named after the integration's `id`. To change an integration,
raise its `version`: a change that breaks flows (a renamed action or field) raises
the major version.

## The format

See [`Bobbin.Integration`](https://hexdocs.pm/bobbin/Bobbin.Integration.html) and the
[JSON Schema](https://raw.githubusercontent.com/heddlehq/Bobbin/main/priv/integration.schema.json).
