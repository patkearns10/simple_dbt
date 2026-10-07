{#
  Alation write-back
  ============================================================================
  Applies Snowflake table/column comments from three sources, in order of
  precedence, per object (a table's own comment, and independently, each of
  its columns):

      1. tombstone sentinel            -> comment is deliberately cleared
      2. non-blank Alation description -> business-mastered value wins
      3. YAML `description`            -> technical/bootstrap value
      4. none of the above              -> existing comment is left alone

  This replaces dbt's native `persist_docs`, which has no concept of an
  external source of truth: it always applies the YAML description,
  unconditionally, on every run. Here, native persist_docs is disabled
  project-wide (see dbt_project_snippet.yml) and this macro is called from a
  post-hook instead, so it's the only thing that ever writes a comment.

  There's no separate "bootstrap" mode vs. "steady state" mode. A model with
  no matching Alation row yet gets its YAML description (bootstrap); once
  Alation has enriched it, the same run picks up the Alation value instead
  (steady state). Nothing needs to be toggled between the two.

  Lookups are relation-scoped: building one model issues exactly one query
  against the table-level source and one against the column-level source,
  each filtered to that model's schema/table — never a catalog-wide scan,
  regardless of how many models are in the project or how wide any one of
  them is.

  Views and the Snowflake `ALTER VIEW ... ALTER <col> COMMENT` bug
  ----------------------------------------------------------------------------
  Snowflake has a known bug where `ALTER VIEW ... ALTER <col> COMMENT ...`
  fails with an internal error (e.g. `300002:...; incident ...`) for some
  views whose definitions contain inline conversions such as
  `try_to_number(left(col, 1))` — even though the view itself creates and
  queries fine. To avoid that code path entirely, views are handled
  differently from tables (see `view_comment_strategy`):

    - recreate (default): the view is re-issued once with the comments
      inline — `create or replace view x (col1 comment '...', ...) copy grants
      as <compiled model sql>` — the same shape dbt's native persist_docs
      uses for views. No `ALTER VIEW ... ALTER` is ever run.
    - alter: the original behaviour (one `ALTER VIEW ... ALTER` statement).

  Independently, every comment-writing statement runs inside a Snowflake
  Scripting block with an exception handler (see `on_comment_error`), so a
  failure to write a comment is logged as a warning instead of failing the
  model and skipping everything downstream of it.
#}

{% macro get_alation_relation(name) %}
  {#- Where the Alation-shaped data lives. Backed by seeds for local
      development; point this at the real Snowflake-to-Snowflake share by
      swapping the line below for `{{ return(source('alation', name)) }}` —
      nothing else in this file needs to change, since every caller only
      cares about the resulting relation's database/schema/identifier and
      how to select from it. -#}
  {{ return(ref(name)) }}
{% endmacro %}


{% macro _alation_cfg() %}
  {{ return(var('alation_comments', {})) }}
{% endmacro %}


{#- The DDL keyword Snowflake expects in `alter <keyword> ...` / `comment on
    <keyword> ...` — "table" or "view". Derived from the model's configured
    materialization (`model.config.materialized`) rather than the relation
    object's own `.type` attribute, because relation typing isn't guaranteed
    to be populated identically across every dbt engine at the point a
    post-hook runs; the model's own config is the one thing guaranteed to be
    present and correct. -#}
{% macro _relation_ddl_type(relation) %}
  {%- if relation.type -%}
    {{ return(relation.type) }}
  {%- endif -%}
  {%- set materialized = model.config.materialized if (model is defined and model.config is defined) else none -%}
  {%- if materialized == 'view' -%}
    {{ return('view') }}
  {%- else -%}
    {#- table, incremental, seed, snapshot, and dynamic-table materializations
        all take column/relation comments as ordinary tables in Snowflake. -#}
    {{ return('table') }}
  {%- endif -%}
{% endmacro %}


{#- Runs one comment-writing statement without letting it fail the model.

    Jinja has no try/except, so the error handling is pushed down into
    Snowflake: the statement is wrapped in an anonymous Snowflake Scripting
    block whose exception handler returns the error text instead of
    raising. The block itself always succeeds, so the post-hook (and the
    model) succeed too; a failed comment surfaces as a dbt warning.

    Anonymous blocks don't need `execute immediate` when sent through a
    driver (only SnowSQL / the classic UI need that), which matters here
    because the comment text inside is already `$$`-quoted.

    `on_comment_error: fail` skips the wrapper and runs the statement
    directly, restoring the old fail-the-model behaviour. -#}
{% macro _safe_run(sql, relation, label) %}
  {%- set cfg = _alation_cfg() -%}
  {%- if cfg.get('on_comment_error', 'warn') == 'fail' -%}
    {% do run_query(sql) %}
    {{ return(true) }}
  {%- endif -%}

  {%- set block -%}
begin
  {{ sql }}
  return 'OK';
exception
  when other then
    return 'ERROR ' || sqlcode || ': ' || sqlerrm;
end;
  {%- endset -%}
  {%- set res = run_query(block) -%}
  {%- set status = (res.rows[0][0] | string) if (res is not none and (res.rows | length) > 0) else 'OK' -%}
  {%- if status.startswith('ERROR') -%}
    {{ exceptions.warn(
      "[alation_comments] could not write " ~ label ~ " for " ~ relation
      ~ " — model left as built, comments skipped. Snowflake said: " ~ status
    ) }}
    {{ return(false) }}
  {%- endif -%}
  {{ return(true) }}
{% endmacro %}


{#- Writes a single relation-level comment. Deliberately self-contained
    rather than calling dbt's built-in `alter_relation_comment` — that macro
    also derives its DDL keyword from `relation.type`, so building our own
    keeps the type-resolution logic in one place (`_relation_ddl_type`) that
    we control. -#}
{% macro _apply_relation_comment(relation, comment_text) %}
  {%- set ddl_type = _relation_ddl_type(relation) -%}
  {%- set safe_desc = comment_text | replace('$', '[$]') -%}
  {%- set sql -%}
    comment on {{ ddl_type }} {{ relation.render() }} IS $${{ safe_desc }}$$;
  {%- endset -%}
  {% do _safe_run(sql, relation, 'relation comment') %}
{% endmacro %}


{#- Column comments for tables (and for views when
    view_comment_strategy = 'alter'): one ALTER listing ONLY the columns a
    value was resolved for, so nothing else is blanked. -#}
{% macro _alter_column_comments(relation, merged_columns) %}
  {%- set clauses = [] -%}
  {%- for col_name, description in merged_columns.items() -%}
    {%- set safe_desc = description | replace('$', '[$]') -%}
    {%- do clauses.append(col_name ~ " COMMENT $$" ~ safe_desc ~ "$$") -%}
  {%- endfor -%}
  {%- set alter_sql -%}
    alter {{ _relation_ddl_type(relation) }} {{ relation.render() }} alter {{ clauses | join(', ') }};
  {%- endset -%}
  {% do _safe_run(alter_sql, relation, 'column comments') %}
{% endmacro %}


{#- Column + relation comments for views, written without
    `ALTER VIEW ... ALTER` (see the header for why).

    Re-issues the view once, with the comments inline in the column list:

        create or replace [secure] view <rel> (
          "COL_A" comment $$...$$,
          "COL_B",
          ...
        ) comment = $$...$$ copy grants as <compiled model sql>

    Notes:
      - The column list must name every column, in order, so it's built from
        the live view (`adapter.get_columns_in_relation`). YAML/Alation
        entries for columns that don't exist on the view are simply ignored
        (an ALTER would have errored on them).
      - Columns with no resolved value get no comment. That loses nothing:
        dbt has just run `create or replace view` for this model, which
        already dropped any previous column comments.
      - `copy grants` keeps grants applied by dbt's own view build.
      - The relation comment is embedded here rather than written
        separately, because a separate `comment on view` issued before this
        statement would be wiped by the `create or replace`.
      - `create or replace` is atomic: if it fails, the view dbt just built
        stays exactly as it was. -#}
{% macro _recreate_view_with_comments(relation, merged_columns, relation_comment) %}
  {%- set view_sql = (model.compiled_code if (model is defined and model.compiled_code) else none) -%}
  {%- if not view_sql -%}
    {{ exceptions.warn("[alation_comments] compiled SQL not available for " ~ relation ~ " — skipping view comments.") }}
    {{ return(false) }}
  {%- endif -%}
  {%- set view_sql = view_sql | trim -%}
  {%- if view_sql.endswith(';') -%}
    {%- set view_sql = view_sql[:-1] -%}
  {%- endif -%}

  {%- set existing_columns = adapter.get_columns_in_relation(relation) -%}
  {%- if (existing_columns | length) == 0 -%}
    {{ exceptions.warn("[alation_comments] could not read columns for " ~ relation ~ " — skipping view comments.") }}
    {{ return(false) }}
  {%- endif -%}

  {%- set col_defs = [] -%}
  {%- for col in existing_columns -%}
    {%- set desc = merged_columns.get(col.name | upper) -%}
    {%- if desc is not none and (desc | length) > 0 -%}
      {%- do col_defs.append(adapter.quote(col.name) ~ " comment $$" ~ (desc | replace('$', '[$]')) ~ "$$") -%}
    {%- else -%}
      {%- do col_defs.append(adapter.quote(col.name)) -%}
    {%- endif -%}
  {%- endfor -%}

  {%- set is_secure = config.get('secure', false) -%}
  {%- set create_sql -%}
create or replace {% if is_secure %}secure {% endif %}view {{ relation.render() }} (
  {{ col_defs | join(',\n  ') }}
)
{%- if relation_comment is not none and (relation_comment | length) > 0 %}
comment = $${{ relation_comment | replace('$', '[$]') }}$$
{%- endif %}
copy grants
as
{{ view_sql }}
;
  {%- endset -%}
  {{ return(_safe_run(create_sql, relation, 'view comments (recreate)')) }}
{% endmacro %}


{#- Single place that decides HOW resolved comments get written.

    relation_comment: none = leave alone, '' = clear, text = set.
    merged_columns:   {UPPER_COL_NAME: text-or-''} for resolved columns only. -#}
{% macro _write_comments(relation, relation_comment, merged_columns) %}
  {%- set cfg = _alation_cfg() -%}
  {%- set strategy = cfg.get('view_comment_strategy', 'recreate') -%}
  {%- set is_view = (_relation_ddl_type(relation) | lower) == 'view' -%}

  {%- if is_view and strategy == 'recreate' and (merged_columns | length) > 0 -%}
    {#- One statement writes both the column and relation comments. -#}
    {% do _recreate_view_with_comments(relation, merged_columns, relation_comment) %}
  {%- else -%}
    {%- if relation_comment is not none -%}
      {% do _apply_relation_comment(relation, relation_comment) %}
    {%- endif -%}
    {%- if (merged_columns | length) > 0 -%}
      {% do _alter_column_comments(relation, merged_columns) %}
    {%- endif -%}
  {%- endif -%}
{% endmacro %}


{% macro apply_alation_comments(relation) %}
  {#- Entry point, called as `{{ apply_alation_comments(this) }}` from a
      project-wide post-hook. dbt executes whatever a post-hook expression
      renders to as a SQL statement — this macro does all of its work via
      `run_query()`/`do` internally and always renders to an empty string,
      which dbt treats as a no-op hook. -#}
  {%- set cfg = _alation_cfg() -%}
  {%- if not cfg.get('enabled', true) -%}
    {{ return('') }}
  {%- endif -%}
  {%- if not execute -%}
    {{ return('') }}
  {%- endif -%}

  {%- set on_unavailable = cfg.get('on_unavailable', 'keep_existing') -%}
  {%- set tombstone = cfg.get('tombstone_value', '__REMOVE_COMMENT__') -%}
  {%- set max_len = cfg.get('max_comment_length', 8000) -%}
  {%- set ds_filter = cfg.get('data_source_filter', '') -%}
  {%- set fail_on_ambiguous = cfg.get('fail_on_ambiguous_lookup', true) -%}

  {#- ---------------------------------------------------------------------
      1. Availability check. adapter.get_relation() is a metadata lookup
         that returns none instead of raising, so a missing share/seed is
         detectable up front and handled per `on_unavailable` rather than
         failing the run outright. This only catches "the object doesn't
         exist" — a lookup query that fails for some other reason (e.g. a
         permission error on a share that does exist) isn't caught here,
         since Jinja has no try/except; that surfaces as an ordinary run
         failure. (Comment WRITES are protected separately by `_safe_run`.)
     --------------------------------------------------------------------- #}
  {%- set table_src = get_alation_relation('alation_table_comments') -%}
  {%- set column_src = get_alation_relation('alation_column_comments') -%}
  {%- set table_src_check = adapter.get_relation(database=table_src.database, schema=table_src.schema, identifier=table_src.identifier) -%}
  {%- set column_src_check = adapter.get_relation(database=column_src.database, schema=column_src.schema, identifier=column_src.identifier) -%}

  {%- if table_src_check is none or column_src_check is none -%}
    {%- if on_unavailable == 'fail' -%}
      {{ exceptions.raise_compiler_error("Alation metadata source is unavailable (" ~ table_src ~ " / " ~ column_src ~ ") and on_unavailable=fail.") }}
    {%- elif on_unavailable == 'yaml' -%}
      {{ log("[alation_comments] source unavailable for " ~ relation ~ " — applying YAML descriptions only.", info=True) }}
      {% do _apply_yaml_only(relation, max_len) %}
      {{ return('') }}
    {%- else -%}
      {{ log("[alation_comments] source unavailable for " ~ relation ~ " — leaving existing comments untouched (on_unavailable=keep_existing).", info=True) }}
      {{ return('') }}
    {%- endif -%}
  {%- endif -%}

  {#- ---------------------------------------------------------------------
      2. Relation-level comment: one query, scoped to this object only.
     --------------------------------------------------------------------- #}
  {%- set ds_predicate = ("and upper(data_source) like upper('%" ~ ds_filter ~ "%')") if ds_filter else "" -%}
  {%- set table_query -%}
    select alation_table_description
    from {{ table_src }}
    where upper(schema_name) = upper('{{ relation.schema }}')
      and upper(table_name) = upper('{{ relation.identifier }}')
      {{ ds_predicate }}
  {%- endset -%}
  {%- set table_results = run_query(table_query) -%}

  {%- if (table_results.rows | length) > 1 and fail_on_ambiguous -%}
    {{ exceptions.raise_compiler_error(
      (table_results.rows | length) ~ " Alation rows matched " ~ relation.schema ~ "." ~ relation.identifier
      ~ " — a table must map to exactly one row. Narrow data_source_filter or fix the duplicate upstream."
    ) }}
  {%- endif -%}

  {#- ---------------------------------------------------------------------
      3. Column-level comments: one query for every column on this
         relation, in a single round trip regardless of how wide the model
         is — the cost of this pattern doesn't scale with column count.

         Row values are read positionally (row[0], row[1]) rather than by
         alias name. Column order in a `select` list is unambiguous; alias
         casing is not guaranteed to come back identically across every
         engine/driver combination, so positional access is the more
         portable choice here.
     --------------------------------------------------------------------- #}
  {%- set column_query -%}
    select upper(column_name) as column_name, alation_column_description
    from {{ column_src }}
    where upper(schema_name) = upper('{{ relation.schema }}')
      and upper(table_name) = upper('{{ relation.identifier }}')
      {{ ds_predicate }}
  {%- endset -%}
  {%- set raw_column_results = run_query(column_query) -%}

  {#- A row with a blank/null column name can't correspond to a real
      column — drop it with a warning rather than letting it flow into the
      ambiguity check or the merge below. -#}
  {%- set column_results_rows = [] -%}
  {%- for row in raw_column_results.rows -%}
    {%- set col_name = row[0] -%}
    {%- if col_name is none or (col_name | trim | length) == 0 -%}
      {{ exceptions.warn(
        "[alation_comments] dropped a row with a blank column_name for " ~ relation.schema ~ "." ~ relation.identifier
        ~ " — description was: " ~ (row[1] | string)
      ) }}
    {%- else -%}
      {%- do column_results_rows.append((col_name, row[1])) -%}
    {%- endif -%}
  {%- endfor -%}

  {#- Deterministic lookup: each column must map to exactly one row. -#}
  {%- set seen_columns = [] -%}
  {%- set duplicate_details = [] -%}
  {%- for col_name, description in column_results_rows -%}
    {%- if col_name in seen_columns -%}
      {%- do duplicate_details.append(col_name ~ "='" ~ (description | string) ~ "'") -%}
    {%- endif -%}
    {%- do seen_columns.append(col_name) -%}
  {%- endfor -%}
  {%- if (duplicate_details | length) > 0 and fail_on_ambiguous -%}
    {{ exceptions.raise_compiler_error(
      "Ambiguous Alation column lookup for " ~ relation.schema ~ "." ~ relation.identifier ~ ": " ~ (duplicate_details | join('; '))
      ~ ". Each column must map to exactly one row — narrow data_source_filter or fix the duplicate upstream."
    ) }}
  {%- endif -%}

  {#- ---------------------------------------------------------------------
      4. Resolve the relation-level comment: tombstone clears it, a
         non-blank Alation value wins, otherwise fall back to YAML.
     --------------------------------------------------------------------- #}
  {%- set model_description = (model.description if model is defined else '') or '' -%}
  {%- set alation_table_desc = table_results.rows[0][0] if (table_results.rows | length) == 1 else none -%}
  {%- set final_relation_comment = none -%}

  {%- if alation_table_desc == tombstone -%}
    {%- set final_relation_comment = '' -%}
  {%- elif alation_table_desc is not none and (alation_table_desc | trim | length) > 0 -%}
    {%- set final_relation_comment = alation_table_desc -%}
  {%- elif (model_description | trim | length) > 0 -%}
    {%- set final_relation_comment = model_description -%}
  {%- endif -%}

  {%- if final_relation_comment is not none -%}
    {%- set final_relation_comment = _truncate(final_relation_comment, max_len, relation) -%}
  {%- endif -%}

  {#- ---------------------------------------------------------------------
      5. Resolve column-level comments the same way. Only columns a value
         was actually resolved for end up in merged_columns, so on tables
         every other existing column comment is left completely untouched —
         this is deliberately not done by reusing dbt's built-in
         `alter_column_comment`, which writes a comment for every existing
         column, including a blank one for any column missing from the
         dict you pass it.
     --------------------------------------------------------------------- #}
  {%- set yaml_columns = (model.columns if model is defined else {}) or {} -%}
  {%- set merged_columns = {} -%}

  {%- for col_name, col_meta in yaml_columns.items() -%}
    {%- if (col_meta.description | trim | length) > 0 -%}
      {%- do merged_columns.update({col_name | upper: _truncate(col_meta.description, max_len, relation)}) -%}
    {%- endif -%}
  {%- endfor -%}

  {%- for col_name, desc in column_results_rows -%}
    {%- if desc == tombstone -%}
      {%- do merged_columns.update({col_name: ''}) -%}
    {%- elif desc is not none and (desc | trim | length) > 0 -%}
      {%- do merged_columns.update({col_name: _truncate(desc, max_len, relation)}) -%}
    {%- endif -%}
  {%- endfor -%}

  {#- 6. Write. Tables -> COMMENT ON + ALTER TABLE; views -> recreate with
         inline comments (default). All writes are failure-safe. -#}
  {% do _write_comments(relation, final_relation_comment, merged_columns) %}

  {{ return('') }}
{% endmacro %}


{#- Used when the Alation source is unreachable and on_unavailable = 'yaml':
    applies only the YAML descriptions, the same way stock persist_docs
    would, but still only touches columns that are actually documented. -#}
{% macro _apply_yaml_only(relation, max_len) %}
  {%- set description = (model.description if model is defined else '') or '' -%}
  {%- set relation_comment = _truncate(description, max_len, relation) if (description | trim | length) > 0 else none -%}

  {%- set yaml_columns = (model.columns if model is defined else {}) or {} -%}
  {%- set merged_columns = {} -%}
  {%- for col_name, col_meta in yaml_columns.items() -%}
    {%- if (col_meta.description | trim | length) > 0 -%}
      {%- do merged_columns.update({col_name | upper: _truncate(col_meta.description, max_len, relation)}) -%}
    {%- endif -%}
  {%- endfor -%}

  {% do _write_comments(relation, relation_comment, merged_columns) %}
  {{ return('') }}
{% endmacro %}


{#- Caps description length defensively and warns on truncation. Snowflake
    doesn't document a hard COMMENT length limit, so this is a guard against
    bloating DESCRIBE/SHOW output and IDE tooltips, not an enforced platform
    constraint — tune `max_comment_length` to whatever's sensible. -#}
{% macro _truncate(value, max_len, relation) %}
  {%- if (value | length) > max_len -%}
    {{ exceptions.warn("[alation_comments] description exceeds " ~ max_len ~ " characters and was truncated for " ~ relation ~ ".") }}
    {{ return(value[:max_len] ~ " …[truncated]") }}
  {%- else -%}
    {{ return(value) }}
  {%- endif -%}
{% endmacro %}
