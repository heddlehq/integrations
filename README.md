# Heddle integrations

Integrations for [Heddle](https://github.com/heddlehq/Heddle) written by the community,
as manifests: YAML files that describe a service's credential and its actions as HTTP
requests. Each action becomes a node, with a `success` and an `error` output.

Heddle reads the index at **https://heddlehq.github.io/integrations/index.json** and
lists these integrations on its Integrations page, marked as community integrations.
Only workspace admins can install them, and an installed integration keeps its
version until someone updates it.

## Adding an integration

1. Write the manifest with [Bobbin](https://github.com/heddlehq/Bobbin):

   ```bash
   mix new tools && cd tools        # any Mix project with {:bobbin, "~> 0.3"} in deps
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
