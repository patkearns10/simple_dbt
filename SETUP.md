# Setup: Alation write-back

## Prerequisites

- dbt's role has `SELECT` on the real Alation share database/schema, plus
  the `COMMENT`/`ALTER` privileges it already needs for `persist_docs` today.
- Confirmed table/column names for the actual share (potentially different from
  the raw Alation-internal tables in the original SQL).

## Steps

1. **Declare the share as a source** (replaces the local seeds):

   ```yaml
   sources:
     - name: alation
       database: <shared database>
       schema: <shared schema>
       tables:
         - name: alation_table_comments
         - name: alation_column_comments
   ```

2. **Copy `macros/alation_comments.sql`** into the project, and swap
   `get_alation_relation()`'s one line from `ref(name)` to
   `source('alation', name)`.

3. **Merge `dbt_project_snippet.yml`** into `dbt_project.yml` — turns off
   native `persist_docs`, adds the post-hook, sets the `alation_comments`
   vars. Start with `on_unavailable: keep_existing`.

4. **Roll out staged**: a non-prod schema first → one enriched
   business area → full project. Re-check the acceptance-criteria mapping
   in `README.md` against real data at each stage, not just the fixtures.

5. **Rollback**: remove the `+post-hook`, restore the old `+persist_docs`
   value. Nothing else depends on this macro; already-written comments stay
   as-is.

## Can this be a shared package?

Yes: the package defines its **own** `sources:` YAML
declaring the Alation tables (in the package's own `models/` dir), and
`get_alation_relation()` keeps calling `source('alation', name)` unchanged.
That works because the macro and the source then live in the *same*
package — there's no cross-package `ref()`/`source()` resolution issue
(that issue only bites when the source is declared in the consumer's project
but the macro calling it lives in a separate package).

One thing packaging still can't do: the `dbt_project.yml` wiring
(`persist_docs: false` + the post-hook) — installing a package can't edit a
consumer's own project config, so every consuming project adds those few
lines itself.

**The `alation_comments` vars split the same way.** Policy-type settings
(`on_unavailable`, `tombstone_value`, `max_comment_length`,
`fail_on_ambiguous_lookup`) are the same reasonable choice for any consumer,
so the package declares defaults for these in its own `dbt_project.yml` — dbt
falls back to a package's own defaults for any var the root project doesn't
set. `data_source_filter` might not have a sensible universal default — that's 
inherently specific to each consumer's Alation setup — so those stay something 
each consuming project sets in its own `dbt_project.yml`, using the same 
`vars: alation_comments: {...}` block to override just that one key.
