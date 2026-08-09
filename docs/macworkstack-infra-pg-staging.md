# Handoff: codify `mwstack-pg-staging` in MacWorkStack-infra

The staging postgres cluster on the opi was stood up by hand on 2026-08-09
(`docker run … --name mwstack-pg-staging … postgres:17-alpine`) so hatchery's
cross-environment clones had a server to target. It works, and it will not survive a box
rebuild. The declaration belongs in MacWorkStack-infra's root compose — but that repo has
forking disabled and hatchery's operator holds read access, so this file is the patch,
ready to hand to whoever holds write.

Target branch: `feat/root-compose` (the version the opi runs; `master` predates the
profiles rework).

Insert into `compose.yaml` immediately above the `full-stack` profile stub:

```yaml
  pg-staging:
    # The staging cluster: what hatchery's cross-environment clones target
    # (mwstack-pg-dev -> mwstack-pg-staging by the per-environment naming rule).
    # Same image, same init matrix, its own data volume - the clone databases
    # themselves are created and filled by hatchery's provisioning; init only
    # pre-stages the DO-parity roles. Behind a profile so the daily db-only
    # loop never pays for it:  docker compose --profile staging up -d
    #
    # NB adopting this replaces any hand-run mwstack-pg-staging container (one
    # was stood up 2026-08-09); the compose volume has a different name, so
    # contents do not carry across - re-run the hatchery clones to refill,
    # which is what clones are for.
    <<: *pg-common
    profiles: ["staging"]
    container_name: mwstack-pg-staging
    environment: *init-env
    ports:
      - "${STAGING_PORT:-5434}:5432"
    volumes:
      - ./db/init:/docker-entrypoint-initdb.d:ro
      - pg-staging-data:/var/lib/postgresql/data
```

And add `pg-staging-data:` to the `volumes:` block at the foot.

Two more opi-host facts that belong wherever that repo keeps its runbook:

- The temporal namespace `mwserver-staging` was registered by hand the same day
  (`temporal operator namespace create --namespace mwserver-staging` inside the
  `mwserver-temporal` container) — staging mwservers poll it.
- Two root-owned wrappers from hatchery live at `/usr/local/bin/hatchery-expose` and
  `/usr/local/bin/hatchery-inspect` (sources: hatchery `Scripts/`), granted via
  `/etc/sudoers.d/hatchery-expose`. They are the whole of hatchery's root capability on
  the box: tunnel ingress add/remove/list, and read-only registry digest lookups.
