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

## Known issue: Snowflake internal error on `ALTER VIEW ... COMMENT`

**Symptom.** A view model builds and is queryable, but the post-hook fails
with something like:

```
SQL execution internal error: Processing aborted due to error 300002:1914252441; incident 3954498.
```

The statement that fails is the `alter view ... alter <col> COMMENT $$...$$, ...`
the macro used to issue. It's a Snowflake bug (confirmed by Snowflake
support) triggered by some inline type conversions in the view definition,
e.g. `try_to_number(left(col, 1))` fails while `try_to_number(col)` works.
It isn't consistent across views, so refactoring SQL to avoid it isn't
practical.

**What the macro does now.** Two independent changes:

1. **Views don't use `ALTER VIEW ... ALTER` anymore** (`view_comment_strategy: recreate`,
   the default). After dbt builds the view, the macro re-issues it once with
   the comments inline:

   ```sql
   create or replace view <db>.<schema>.<view> (
     "ASA_SCORE" comment $$American Society of Anesthesiologists score$$,
     "NHI"       comment $$Unique 7-character national health index number$$,
     "OTHER_COL",
     ...
   )
   comment = $$<relation comment>$$
   copy grants
   as
   <compiled model SQL>;
   ```

   This is the same shape dbt's native `persist_docs` uses for views.
   `copy grants` keeps the view's grants, and `secure` views stay secure.
   Set `view_comment_strategy: alter` to go back to the old behaviour.

2. **Comment failures no longer fail the model** (`on_comment_error: warn`,
   the default). Every comment-writing statement runs inside a Snowflake
   Scripting block with an exception handler. If it errors, the model still
   succeeds, downstream models still run, and dbt logs a warning:

   ```
   [alation_comments] could not write column comments for <relation> — model left as built, comments skipped. Snowflake said: ERROR ...
   ```

   Set `on_comment_error: fail` to go back to failing the model.

**Applying it to an existing project.** Replace `macros/alation_comments.sql`
with the version in this PR (keep your `get_alation_relation()` line
pointing at `source('alation', name)`), and optionally add the two new vars.
Both default to the new behaviour, so no config change is required.

**Verify on the failing view first**, e.g.
`dbt run -s extract_rnda_theatre_event_data`, then:

```sql
select column_name, comment
from <db>.information_schema.columns
where table_schema = '<SCHEMA>' and table_name = '<VIEW>'
order by ordinal_position;
```

Things to check while testing (not yet verified on HNZ's account):

- Whether the `create or replace view ... (col comment ...)` path is clear
  of the bug. It's a different code path from `ALTER VIEW`, and it's what
  native `persist_docs` does, but it hasn't been run against the affected views.
- Whether Snowflake's exception handler catches this specific internal
  error. If it doesn't, the model will still fail; the recreate path is
  the main fix, and the wrapper is the safety net.
- Views with extra Snowflake view options set via config (other than
  `secure`, e.g. `change_tracking`) aren't re-applied by the recreate
  statement. Add them to `_recreate_view_with_comments` if you use them.

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
`fail_on_ambiguous_lookup`, `view_comment_strategy`, `on_comment_error`) are
the same reasonable choice for any consumer, so the package declares defaults
for these in its own `dbt_project.yml` — dbt falls back to a package's own
defaults for any var the root project doesn't set. `data_source_filter` might
not have a sensible universal default — that's inherently specific to each
consumer's Alation setup — so those stay something each consuming project
sets in its own `dbt_project.yml`, using the same
`vars: alation_comments: {...}` block to override just that one key.
