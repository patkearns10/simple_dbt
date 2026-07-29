# Validating dbt-bouncer against this demo

This project replicates BHP's standardised-work-dev tagging pattern at a
small scale: `meta.database_tags` on some models/sources but not others,
applied via an `on-run-end` macro, validated pre-commit with dbt-bouncer.

What's already wired up:

- `dbt_project.yml` - tags the whole `marts/` folder (`fct_orders`,
  `dim_customers`, `small_incremental`); `staging/` and `intermediate/` are
  left untagged.
- `models/marts/_marts.yml` - an extra column-level tag on
  `dim_customers.CUSTOMER_NAME`.
- `models/staging/jaffle_shop/_src_jaffle_shop.yml` - only the `customers`
  source table is tagged; `orders`, `items`, `products`, `stores`, `supplies`
  are not.
- `macros/*.sql` - `apply_meta_as_tags` and its helpers, fixed to branch
  `ALTER VIEW` vs. `ALTER TABLE` by materialization and to auto-create
  missing tags (see the header comments in `macros/apply_meta_as_tags.sql`
  for what was fixed vs. the original BHP macro).
- `dbt-bouncer.yml` + `custom_checks/` - a custom check
  (`check_model_has_required_database_tags` /
  `check_source_has_required_database_tags`) since dbt-bouncer's built-in
  `check_model_has_meta_keys` only validates flat top-level keys, not the
  nested `database_tags` dict.
- `.pre-commit-config.yaml` - runs `dbt parse` then dbt-bouncer on commit.

## 0. Prerequisites

```bash
cd ~/git/simple_dbt
dbt debug          # confirm the `snowflake` profile can connect
pip install dbt-bouncer pre-commit --break-system-packages   # or pipx/virtualenv
```

Tags use BHP's real `MANAGEMENT.TAGS.<tag_name>` naming (not a demo-only
namespace), and `ensure_tag_exists` auto-creates the `MANAGEMENT` database,
`TAGS` schema, and each tag with `IF NOT EXISTS` - so nothing needs to be
pre-provisioned by hand. That does mean the role your `snowflake` profile
connects as needs `CREATE DATABASE` privilege the first time this runs. If
it doesn't, either grant it or have an admin create `MANAGEMENT.TAGS` once;
everything else below works unchanged either way.

## 1. Confirm the manifest reflects the new tags

```bash
dbt parse
```

No warehouse connection is used for this step - it just compiles the project
and writes `target/manifest.json`.

## 2. Run dbt-bouncer and confirm it catches the gap

```bash
dbt-bouncer --config-file dbt-bouncer.yml -v
```

Expected result the first time you run this: **5 failures**, one for each
untagged `jaffle_shop` source table (`orders`, `items`, `products`, `stores`,
`supplies`). `fct_orders`, `dim_customers`, `small_incremental`, and the
`customers` source should all pass, since they already carry the required
tags. This confirms the custom check is actually reading `meta.database_tags`
correctly and not just passing everything.

## 3. Confirm it catches a regression, not just the pre-existing gap

Temporarily remove the `MANAGEMENT.TAGS.SUPPORT_TEAM_NAME` line from the
`marts:` block in `dbt_project.yml`, then:

```bash
dbt parse && dbt-bouncer --config-file dbt-bouncer.yml -v
```

You should now see `fct_orders`, `dim_customers`, and `small_incremental`
fail too (in addition to the 5 source tables). Put the line back, re-run,
and confirm you're back to exactly 5 failures. This is the part worth
demoing live - it shows the check reacts to an actual code change, not just
a fixed pass/fail on this project.

## 4. Close the gap for one source table and confirm granularity

Add the same `config.meta.database_tags` block used for `customers` to the
`orders` table in `models/staging/jaffle_shop/_src_jaffle_shop.yml`, then
re-run step 2. You should go from 5 failures to 4 - confirming the check is
evaluating each source table independently rather than passing/failing the
whole file at once.

## 5. Run a real build and confirm tags land in Snowflake

```bash
dbt build --select marts
```

Watch the logs for `apply_meta_as_tags` / `Setting tag value for ...` lines.
Because `fct_orders` and `small_incremental` are tables and `dim_customers`
is a view, this single run exercises both branches of the `ALTER TABLE` /
`ALTER VIEW` fix - if that branching were wrong (as it was in the original
macro), the view tagging would fail here with a Snowflake compilation error.

Then verify in Snowflake directly, e.g.:

```sql
select * from table(
  information_schema.tag_references_all_columns('DIM_CUSTOMERS', 'view')
);

select * from table(
  information_schema.tag_references_all_columns('FCT_ORDERS', 'table')
);
```

You should see `MANAGEMENT.TAGS.DATA_DOMAIN`, `MANAGEMENT.TAGS.IPF_CLASSIFICATION`,
and `MANAGEMENT.TAGS.SUPPORT_TEAM_NAME` on both objects, plus
`MANAGEMENT.TAGS.PII` on `DIM_CUSTOMERS.CUSTOMER_NAME`. The `MANAGEMENT`
database, `TAGS` schema, and the tag objects themselves should have been
auto-created by `ensure_tag_exists` - nothing needs to be pre-provisioned by
hand for this demo (that's the auto-create-tags choice from the open
questions doc; BHP's real environment may decide differently, e.g. having
an admin create `MANAGEMENT.TAGS` once via IaC instead of letting dbt do it).

## 6. Wire up the pre-commit hook and confirm it blocks a bad commit

```bash
pre-commit install
```

Then repeat the "remove a tag" edit from step 3, stage it, and try to
commit:

```bash
git add dbt_project.yml
git commit -m "test: remove a required tag"
```

The commit should be rejected locally, before it reaches any CI system, with
the same dbt-bouncer failure output from step 3. Restore the tag, stage, and
commit again to confirm it goes through cleanly.

## What this does and doesn't prove

This validates the pre-commit mechanics end to end: dbt-bouncer reading a
real manifest, a custom check reaching into nested `meta.database_tags`, and
the failure surfacing at commit time via `.pre-commit-config.yaml`. It does
**not** by itself resolve the open questions from the review (package vs.
fork, auto-create vs. admin-provisioned tags, warn-vs-block rollout timing,
who owns the custom check going forward) - those are still worth a
team conversation, informed by seeing this actually run.
