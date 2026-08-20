# The second verse: the full provider pass for DigitalOcean App Platform

The roadmap (2026-08-09): dokku is the reference implementation of the complete story —
box init → stack new → clone (databases, keys) → exposure, every step a convergent,
narrated assertion — and each other provider earns the same complete pass. App Platform
goes second, and it is closer than it looks: MacWorkStack-infra documents an active DO
pipeline (DOCR `registry.digitalocean.com/macworkstack/*` with `:staging` retagged by CI
on every merge; prod on a shared DO Managed Postgres with the doadmin role matrix;
DockerHub frozen pending cutover). hatchery's job is to drive what already exists.

## The story, element by element

| dokku pass | App Platform equivalent | state |
|---|---|---|
| `box init` | No metal to prepare. The assertions become platform checks: `DIGITALOCEAN_TOKEN` present and answering, DOCR reachable, the managed-PG cluster visible. Same engine (`BoxAssertion`), check-only fixes, run locally: `hatchery box init --backend appPlatform [--cluster NAME]`. | shipped |
| `stack new` | Already authorable: `digitalocean_app` tofu resources. | shipped |
| clone: config/keys | Backend-agnostic already (contract, minting, rewrite). Live-config reads stay refused (`EV[…]` ciphertext) — clones plan from the declared sidecar, which the plan already says out loud. | shipped |
| clone: database | `ManagedPostgresProvisioner`: database + roles in the existing cluster via the DO API, ownership and grants as doadmin over local psql (reported as pending without psql), URLs with `sslmode=require` from the cluster's own endpoint. Copies (`full`/`schema`) run from the opi as the trusted source, the same dump-pipe the dokku path uses, into psql against the cluster. | shipped |
| exposure | `platform` provider already answers (default `ondigitalocean.app` domains); custom domains later via `cloudflare-api`. | shipped / queued |
| drift warning | `AppPlatformDrift`: the deployment's `source_image_digest` against the registry's tag digest, DOCR or Docker Hub, no wrappers, no root. | shipped |
| jobs / narration | Provider-agnostic already. | shipped |

## Prerequisites to gather (operator decisions, not code)

1. `DIGITALOCEAN_TOKEN` in the serve/CLI environment (the `doctor` check exists).
2. The managed cluster's ID + a decision on who may create databases in it.
3. DOCR read credentials for digest checks (`registry.digitalocean.com` token scope).
4. A cost line: App Platform apps bill per-app (~$5/mo each at the small tier). The clone
   plan screen should state the monthly cost of what it is about to create — money is a
   plan-visible consequence, exactly like an unreachable database server.

## Suggested slice order

1. ~~Platform checks as `box init --backend appPlatform` (pure engine reuse, no spend).~~ Shipped.
2. ~~DO managed-database provider: create/converge db + roles via API; URLs into the clone;
   refusal messages name the missing cluster/token.~~ Shipped: `stack clone --backend appPlatform --cluster NAME`, `ManagedPostgresProvisioner`. Copies stay in slice 5. The clone's addresses are platform-shaped too (`PlatformShape`): a sibling becomes its public domain (or its component on the private network, when the provider authors one app), a box-local host with no sibling behind it is refused by name, and box-local domains drop off.
3. ~~Cost lines on the plan screen for platform-billed backends.~~ Shipped: `PlatformCost`, `PlannedClone.costs`, printed by `stack clone`. The web plan view still has to show them.
4. ~~Digest-drift via the App Platform + DOCR APIs.~~ Shipped: `AppPlatformDrift`, reached through `ImageDrift.check` for an App Platform stack. DOCR through the DO API, Docker Hub through its tag API, other registries said to be not checkable.
5. ~~Copies through the trusted-source psql path~~ Shipped: a managed copy runs from the source box's `db_admin` channel, `docker exec … pg_dump --no-owner --no-acl | psql <cluster URL as the owner>`, schema reset before and grants after. The trusted source needs `postgresql-client` and its address allowed on the cluster, and the report says so when either is missing. Still queued: `cloudflare-api` custom domains.

## The third verse: Cloud Run

Started 2026-08-20, the same five slices in the same order, with Cloud SQL for the
managed database and Artifact Registry for digests. gcloud is the channel, because
Google signs its API calls in ways curl alone cannot, and a bearer token from
`gcloud auth print-access-token` is all the REST calls need.

1. ~~Platform checks as `box init --backend cloudRun [--project P] [--cluster INSTANCE]`.~~ Shipped.
2. Cloud SQL database provider: create and converge database and users through the admin API, URLs into the clone.
3. Cost lines for Cloud Run's per-request billing, said as a floor.
4. Digest drift through the Cloud Run service's image digest against Artifact Registry.
5. Copies through the trusted-source path, with the Cloud SQL Auth Proxy or an authorized network.
