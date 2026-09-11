# Alation write-back POC — for `simple_project`

Built against the manifest for your `simple_project` sandbox (jaffle-shop-derived,
target database `DEVELOPMENT`, schema `dbt_pkearns`, adapter `snowflake`,
`dbt_version: 2.0.0-preview.221` — i.e. Fusion). No Snowflake credentials were
available in this environment, so nothing here has actually been run yet —
treat this as a ready-to-run first pass, not a validated one. See "What still
needs a real run" at the bottom before showing this to Paul's team.

## What this replaces

Today, every model in `simple_project` has `persist_docs: {relation: true,
columns: true}` set project-wide (confirmed from your manifest). That means
every run pushes the YAML `description` straight to Snowflake as a `COMMENT`,
unconditionally.

This POC turns that off and replaces it with a post-hook that:
1. Looks up the object being built in two Alation-shaped tables (seeded here;
   a real Snowflake share view later) — one relation-scoped query for the
   table comment, one for all of that table's column comments.
2. Applies the Alation value if one exists and isn't blank; otherwise falls
   back to the YAML description; otherwise leaves the object alone.
3. Never touches a column it didn't resolve a value for.

No phase-toggling between "bootstrap" and "steady state" is needed — the same
merge logic handles a brand-new object (no Alation row yet → YAML wins) and an
enriched one (Alation row present → Alation wins) identically.

## Known landmine in stock `persist_docs` (found while researching this)

Snowflake's `persist_docs` implementation (`snowflake__alter_column_comment` in
`dbt-adapters`) builds one `ALTER TABLE ... ALTER col1 COMMENT ..., col2
COMMENT ...` statement covering *every existing column*, and emits `COMMENT
"$$$$"` (blank) for any column that isn't in your YAML `columns:` list. In other
words: today, with partial column documentation, every dbt run already blanks
the comment on any undocumented column. This is worth flagging to Paul
regardless of the Alation work — it's a separate, pre-existing risk in the
current setup. Our macro avoids it by only ever emitting ALTER clauses for
columns it has actually resolved a value for.

## Files

```
dbt_project_snippet.yml         merge into simple_project/dbt_project.yml
seeds/alation_table_comments.csv    table-level fixture (stand-in for the Alation share)
seeds/alation_column_comments.csv   column-level fixture
macros/alation_comments.sql         the actual lookup/merge/apply logic
models/marts/wide_events.sql        50-column synthetic fixture for the performance test
models/marts/_wide_events.yml       partial YAML coverage for wide_events
```

Copy `seeds/`, `macros/`, and `models/marts/wide_events.*` into the matching
folders in `simple_project`, then merge `dbt_project_snippet.yml`'s blocks into
your real `dbt_project.yml`. Run `dbt seed` once, then `dbt run`.

## Mapping to Paul's acceptance criteria

**Deterministic lookup.** The macro matches on `upper(schema_name) =
upper(...)` and `upper(table_name) = upper(...)` (mirroring Paul's own Alation
SQL, which already does `UPPER(...)` on both sides), plus an optional
`data_source_filter` var as a third key. If more than one row matches a table
or a given column, it raises a compiler error naming the object rather than
picking one silently (`fail_on_ambiguous_lookup: true`, on by default). **To
test:** append a second `DBT_PKEARNS,DIM_CUSTOMERS,...` row to
`alation_table_comments.csv` and rerun — the build for `dim_customers` should
fail with an explicit "must map to exactly one row" error.

**Null and deletion behaviour.** A blank `alation_table_description` /
`alation_column_description` (see the `FCT_ORDERS` and `TAX_PAID` rows) is
treated as "no opinion" and falls through to YAML — it never blanks an
existing comment. Deliberate removal requires the literal sentinel
`__REMOVE_COMMENT__` (see the `STG_JAFFLE_SHOP__STORES` / `TAX_RATE` rows) —
**to test:** compare `fct_orders`'s comment after a run (should show the YAML
description, not blank) against `stg_jaffle_shop__stores`'s (should be
explicitly blanked).

**Failure-safe deployment.** `adapter.get_relation()` checks that the
seed/share objects exist before querying them; if either is missing, behavior
follows `on_unavailable` (`keep_existing` by default, matching your stated
preference — plus `yaml` and `fail`). **To test:** temporarily rename one seed
table (or run `dbt run --exclude alation_table_comments alation_column_comments`
before ever seeding) and confirm existing comments survive a run. **Caveat:**
this only catches "the object doesn't exist." Jinja has no try/except, so a
query that fails for another reason (permission revoked on a share that still
exists, a transient network blip) is not caught here — it surfaces as an
ordinary run failure. If a softer landing is needed for that case too, it'd
need to move outside pure Jinja (e.g., a pre-flight check in an on-run-start
hook that sets a variable the post-hook can read) — worth a follow-up
conversation with Paul's team on whether that's necessary.

**Performance.** Both lookups are single queries scoped to `schema_name =
... and table_name = ...` — never a full-catalog diff. `wide_events` (50
columns, only 6 with any documentation at all) exercises this: confirm via
query history that building it issues exactly one query against
`alation_column_comments`, not 50.

**Escaping and size limits.** `$` is escaped the same way dbt-snowflake's own
`alter_column_comment` does it (`replace('$', '[$]')`, since comments are
written as Snowflake dollar-quoted strings). The `CUSTOMER_TYPE` seed row
deliberately includes a `$`, a quoted phrase, an emoji, and an embedded line
break to exercise this. `max_comment_length` (default 8000 chars) truncates
with a `dbt` warning rather than erroring — Snowflake doesn't document a hard
COMMENT length limit, so this is a defensive guard, not an enforced platform
constraint; worth confirming the real practical ceiling against your Snowflake
account before relying on the default.

## Other things this incidentally tests

- **Tables vs. views vs. incremental vs. full-refresh:** the post-hook fires
  after every materialization type, so `dim_customers`/staging models
  (views), `small_incremental` (incremental — already a fixture in your
  project for exactly this), and any `--full-refresh` run all go through the
  same code path. One thing to specifically watch during the real run:
  Snowflake's support for altering a *column* comment on a **view** post-creation
  is unclear from public docs (table column comments are well-documented;
  view column comments may require `create or replace view` instead of
  `alter view ... alter column ... comment`). If that's the case, it's a
  limitation of Snowflake itself, not something specific to this pattern —
  but since most of `simple_project`'s models are views, it's worth checking
  first thing.

## Fixed since first draft

**Bug:** running `dbt run --exclude alation_table_comments alation_column_comments`
(seeds never loaded) failed every model with `SQL compilation error: syntax
error line 1 at position 0 unexpected 'None'`.

**Cause:** `+post-hook: "{{ apply_alation_comments(this) }}"` isn't a normal
macro call — dbt renders that Jinja expression to a string and executes the
*result* as a SQL statement. The macro's early-exit branches called `{{
return(none) }}`, and printing a macro's `return()` value through `{{ }}`
stringifies it — `None` becomes the literal text `"None"`, which dbt then
tried to run as SQL. This is exactly what fired: the seeds were excluded, so
`adapter.get_relation()` came back empty, hitting the `on_unavailable:
keep_existing` branch, which is the branch that used to say `return(none)`.

**Fix:** every exit path in `apply_alation_comments` (and `_apply_yaml_only`)
now returns `''` instead of `none`, including an explicit trailing
`{{ return('') }}` at the end of the "happy path" too, so nothing is left to
chance. An empty string is a no-op hook; dbt skips executing it. Re-pull
`macros/alation_comments.sql` and rerun the same command — all models should
now build cleanly and log the `keep_existing` message with no error.

**Bug 2:** with `on_unavailable: yaml` (seeds still not run), every model
failed instead with `SQL compilation error: Object type or Class 'NONE' does
not exist or not authorized`.

**Cause:** the `yaml` fallback path was the first one to actually reach the
DDL-writing code (`keep_existing` returns before ever writing anything).
That code used `relation.type` — and on your setup (Fusion,
`2.0.0-preview.221`), `relation.type` came back `None` for the relation
passed into a post-hook-invoked macro, on both our own hand-built column
ALTER *and* dbt's own `alter_relation_comment` macro (which has the identical
`relation.type` dependency internally). The rendered SQL was literally
`comment on NONE ... IS ...` / `alter NONE ... alter col ...` — Snowflake's
"Object type or Class 'NONE'" error is exactly what it says when the `COMMENT
ON`/`ALTER` object-type keyword is missing. This looks like a Fusion-specific
gap (plausibly related to the persist_docs rework in `dbt-fusion#1313`)
rather than anything wrong with the merge logic itself.

**Fix:** stopped trusting `relation.type` and stopped reusing dbt's built-in
`alter_relation_comment` (same dependency, same risk). Added
`_relation_ddl_type(relation)`, which falls back to `model.config.materialized`
(reliably present) to decide `view` vs `table`, and `_apply_relation_comment`,
a small self-contained `COMMENT ON ... IS ...` built the same way. Both DDL
paths (relation-level and column-level) now go through this helper instead of
`relation.type` directly. Re-pull `macros/alation_comments.sql` and rerun with
`on_unavailable: yaml` — `wide_events` (a view) should now get its YAML
description applied without error.

If this resurfaces on a different materialization, it's worth checking
whether `model.config.materialized` is populated the same way for that model
type (snapshots and dynamic tables weren't tested here) — that's the one
remaining assumption in the fix.

## What still needs a real run

- Nothing here has executed against Snowflake — only Jinja/YAML/CSV syntax
  was checked locally. Run it in your sandbox before drawing conclusions.
- You're on the Fusion engine (`2.0.0-preview.221`). Fusion has an open,
  actively-worked epic covering persist_docs/query-comments internals
  (`dbt-labs/dbt-fusion#1313`). This design deliberately avoids depending on
  *how* Fusion's native persist_docs applies comments — it turns that
  mechanism off and calls the plain `alter_relation_comment` / a hand-built
  `ALTER ... COMMENT` statement directly from a post-hook, which shouldn't be
  affected by that rework. Worth a quick smoke test on dbt Core 1.x too if
  you want a side-by-side baseline while Fusion's persist_docs work is in
  flight.
- The view-column-comment question above.
- Whether `data_source_filter` is the right third key once this points at the
  real HDP share, versus using actual database name — depends on how many
  Snowflake accounts/databases the real share spans.
