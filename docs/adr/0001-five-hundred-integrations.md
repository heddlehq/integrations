# 1. Five hundred integrations, complete, libraries first

Date: 2026-11-22
Status: proposed

## Context

Heddle competes with n8n, which ships about 300 services in its core nodes and more
through LangChain vendors. This repository holds 15 integrations. To compete, Heddle
needs the same breadth, and each integration needs the same depth: an integration with
three actions next to an n8n node with thirty doesn't win anyone over.

The manifest format (Bobbin 0.5) can't describe most of what those services need
yet: webhook triggers, files, optional fields, per-account hosts, signed requests.
Elixir already has active libraries for many of these services and protocols, and a
library that someone maintains beats a manifest we write from the API docs.

## Decision

### What to build

- **598 services**, listed in [`catalog.yaml`](../../catalog.yaml): the external
  services of n8n's core nodes, about 85 Brazilian services n8n doesn't cover
  (payments, banks with Pix, ERPs, NF-e, shipping, infoproducts, WhatsApp gateways),
  AI services (vector stores, search, speech, image) and the most used services
  outside n8n. LLM providers stay in Heddle's core.
- **Complete means at least n8n's parity**: every operation and trigger of the n8n
  node, plus the parts of the API it misses. For a service n8n doesn't have, the
  public API. The catalog points at the n8n node (`n8n:`) so its operations can be
  listed as the checklist.
- **One node per action**, grouped by `resource` (Contact, Deal, Ticket). The palette
  shows Integration › Resource › Action, and only what the workspace installed.

### How to build each one

1. **An active Elixir library first.** If Hex has a library for the service that is
   active (a release in the last 24 months, not retired, still downloaded), the
   integration is a package (`integrations/<id>/`, a Mix project) built on that
   library. The catalog records the library it checked in `lib:`. Protocols and
   drivers (SQL, Kafka, AMQP, MQTT, SSH, LDAP) are always packages.
2. **Otherwise a manifest**, drafted by `mix bobbin.import` from the service's
   OpenAPI or Postman collection when there is one, and finished by hand: names,
   descriptions, fields, `pick`, an `example` per action and the pt-BR texts.
3. Never by translating n8n's code: its license (Sustainable Use) doesn't allow it.

### Bobbin 0.6, before mass production

Without these, half the catalog comes out incomplete and has to be redone:

- **Webhook triggers**: a trigger declares how to register Heddle's URL with the
  service when a flow is activated and how to remove it, and how to check the
  signature (HMAC presets). This closes Heddle#83.
- **Richer fields**: `boolean`, `json`, `datetime`, `multiselect`, `file`, optional
  fields grouped as *additional fields* that are left out of the request when
  empty, and `resource` on each action.
- **Dynamic options**: a select whose options come from a request (pick the Slack
  channel or the spreadsheet by name instead of pasting an ID).
- **Files**: multipart uploads and downloads. A download stores the file (local disk
  when self-hosted, S3 in Heddle Cloud) and leaves `{file: {id, name, mime, size}}` in
  `result`. A `file` field takes that reference and streams it. Files expire with
  the execution.
- **More auth**: `aws_sigv4`, OAuth2 `client_credentials`, `login` (trade a user and
  password for a token), `jwt` (sign a token with a key: Ghost, Coinbase,
  Snowflake), `hmac` (sign each request: Binance, Shopee, Pusher), `oauth1`
  (NetSuite, Evernote), and client certificates (mTLS) for the Brazilian banks' Pix
  APIs.
- **Per-account hosts**: `base_url` takes templates of the credential
  (`https://{{credential.subdomain}}.zendesk.com/api/v2/`). About 125 services in the
  catalog need it (marked `host: true`).
- **i18n**: an optional `i18n.pt-BR` block with the names, descriptions and labels in
  Portuguese. Heddle shows the user's language.

Heddle implements each of these on its side (webhook registration on activation,
the options endpoint, file storage). The OAuth app of a service is created by the
workspace admin, who pastes its client ID and secret, and the manifest says where
to create it. Heddle Cloud registers its own apps for the ~30 most used services.

### Order

0. Bobbin 0.6, Heddle's side of it, and `mix bobbin.import`.
1. **Phase 1**: the 77 most used (Google, Microsoft, Slack, HubSpot, Stripe,
   Shopify…).
2. **Phase 2**: the 85 Brazilian services.
3. **Phase 3**: the other 436, a category at a time.

Within a phase, services with an active library go first: they take less work.

### Verification

- A new integration enters as `community`. CI checks the manifest against the schema,
  and against the service's OpenAPI when there is one (paths, methods, required
  fields), and each action's `example` against its `pick`.
- It becomes `official` (pinned by sha256 in Heddle, with the badge) only after
  someone runs every action against the real API with `mix bobbin.run`. Official
  integrations get smoke tests in CI with real credentials.

### Pull requests

One pull request per batch of 10 to 20 integrations of the same category.

## The catalog

`catalog.yaml` has one entry per service:

| Key | Meaning |
| --- | --- |
| `id` | The folder under `integrations/`, once built. |
| `name`, `category` | As shown on the Integrations page. |
| `phase` | 1, 2 or 3, above. |
| `origin` | `n8n` (a core node of n8n), `br` (Brazil), `ai` or `extra`. |
| `n8n` | The n8n node it matches, for the parity checklist. |
| `auth` | How it authenticates: `oauth2`, `oauth2_cc`, `bearer`, `header`, `query`, `basic`, `body`, `path`, `login`, `jwt`, `hmac`, `oauth1`, `aws`, `none`. |
| `mtls` | It needs a client certificate. |
| `host` | Its address depends on the account. |
| `kind` | `package` (Elixir) or `manifest` (YAML). |
| `via` | Covered by another package (CockroachDB through `sql`). |
| `lib` | The active Hex library it builds on, as checked. |
| `status` | `planned`, `draft`, `community` or `official`. |

`scripts/build.exs` checks that every folder under `integrations/` is in the catalog
and prints the progress.

## Consequences

- Nothing is mass produced before Bobbin 0.6. Phase 1 starts later, but no
  integration is written twice.
- Library-based packages enter Heddle at build time (`HEDDLE_INTEGRATIONS`) and don't
  install from the Integrations page as manifests do. Packages are the official
  part of the catalog; manifests remain the way the community adds integrations.
- 98 services have an active library today (checked on Hex on 2026-11-22: a release
  since 2024-11-22, not retired, 100+ recent downloads, and a name check by hand).
  The `google_api_*` clients last released in April 2025: if Google stops generating
  them, the Google integrations move to manifests.
- A library can stop being maintained. The catalog records its version and last
  release, and a yearly check moves an abandoned one to a manifest.
- The Brazilian banks need mTLS and the Pix rules of each bank: they are the costliest
  part of phase 2.
