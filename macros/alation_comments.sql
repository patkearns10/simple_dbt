{#
  Alation write-back POC
  ============================================================================
  Replaces dbt's native persist_docs auto-apply with an explicit,
  relation-scoped lookup against Alation's Snowflake-shared "enriched
  description" tables (mimicked here with seeds).

  Precedence per object (table and, independently, each column):
      1. explicit tombstone sentinel   -> comment is deliberately blanked
      2. non-blank Alation description -> business-mastered value wins
      3. YAML `description`            -> technical/bootstrap value
      4. none of the above             -> leave the existing comment alone

  Called from a project-wide post-hook (dbt_project_snippet.yml). Native
  persist_docs is turned OFF project-wide, so this macro is the only thing
  that ever writes a comment — there's no toggling between "bootstrap" and
  "steady state," the same merge logic naturally covers both.

  IMPORTANT — does NOT reuse dbt's built-in `alter_column_comment` macro.
  dbt-snowflake's default implementation writes a comment for *every*
  existing column on the relation, including `COMMENT $$$$` (blank) for any
  column missing from the dict you pass it. That means stock persist_docs
  silently blanks any column without a YAML description, every run. We
  build our own minimal ALTER statement instead, touching only the columns
  we've actually resolved a value for — every other column's comment is
  left completely untouched. See README "Known landmine in stock persist_docs".
#}

{% macro get_alation_relation(name) %}
  {#- Local stand-in via seeds today. Once pointed at the real
      Snowflake-to-Snowflake share, swap this one line for:
        {{ return(source('alation', name)) }}
      No other macro logic needs to change. -#}
  {{ return(ref(name)) }}
{% endmacro %}


{% macro _alation_cfg() %}
  {{ return(var('alation_comments', {})) }}
{% endmacro %}


{#- `relation.type` came back None when this macro chain ran under Fusion
    (2.0.0-preview.221) on a post-hook-supplied relation — producing SQL like
    `comment on NONE db.schema.table IS ...`, which Snowflake rejects with
    "Object type or Class 'NONE' does not exist or not authorized." Rather
    than trust `relation.type`, fall back to the model's own configured
    materialization, which is reliably available on `model.config`. -#}
{% macro _relation_ddl_type(relation) %}
  {%- if relation.type -%}
    {{ return(relation.type) }}
  {%- endif -%}
  {%- set materialized = model.config.materialized if (model is defined and model.config is defined) else none -%}
  {%- if materialized == 'view' -%}
    {{ return('view') }}
  {%- else -%}
    {#- table, incremental, seed, snapshot, dynamic materializations all
        take column/relation comments as ordinary tables in Snowflake. -#}
    {{ return('table') }}
  {%- endif -%}
{% endmacro %}


{#- Self-contained relation-comment DDL — deliberately does NOT call dbt's
    built-in `alter_relation_comment`/`snowflake__alter_relation_comment`.
    That macro has the same `relation.type` dependency described above, so
    reusing it would hit the identical "NONE" failure under the same
    conditions. -#}
{% macro _apply_relation_comment(relation, comment_text) %}
  {%- set ddl_type = _relation_ddl_type(relation) -%}
  {%- set safe_desc = comment_text | replace('$', '[$]') -%}
  {%- set sql -%}
    comment on {{ ddl_type }} {{ relation.render() }} IS $${{ safe_desc }}$$;
  {%- endset -%}
  {% do run_query(sql) %}
{% endmacro %}


{% macro apply_alation_comments(relation) %}
  {#- IMPORTANT: this macro is invoked from `+post-hook:` as `{{ apply_alation_comments(this) }}`.
      dbt takes whatever that expression renders to and runs it as a SQL
      statement. Every exit path below must therefore return an empty
      string, never `none` — `{{ return(none) }}` prints the literal text
      "None", which dbt then tries to execute as SQL (this is exactly the
      `unexpected 'None'` error seen when the Alation seeds weren't loaded
      yet). All work happens via `run_query()`/`do` internally; the macro
      itself must always evaluate to '' when called from the hook. -#}
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
      1. Failure-safe check: does the Alation metadata even exist right now?
         adapter.get_relation() is a metadata lookup that returns none
         instead of raising, so a missing share/seed is detectable. A query
         that fails for some *other* reason (e.g. a permission error on a
         share that does exist) is NOT caught here — Jinja has no
         try/except, so that scenario surfaces as a normal run failure.
         Treat that as this pattern's "fail" behavior by default; flag to
         Paul/team as an open question if a softer landing is required there.
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
      2. One targeted query for the relation-level comment, scoped to this
         object only (never a full-catalog scan).
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
      ~ " unambiguously — this must map to exactly one row. Narrow data_source_filter or fix the duplicate upstream."
    ) }}
  {%- endif -%}

  {#- ---------------------------------------------------------------------
      3. One targeted query for every column on this relation, in a single
         round trip regardless of how wide the model is.
     --------------------------------------------------------------------- #}
  {%- set column_query -%}
    select upper(column_name) as column_name, alation_column_description
    from {{ column_src }}
    where upper(schema_name) = upper('{{ relation.schema }}')
      and upper(table_name) = upper('{{ relation.identifier }}')
      {{ ds_predicate }}
  {%- endset -%}
  {%- set column_results = run_query(column_query) -%}

  {%- set seen_columns = [] -%}
  {%- for row in column_results.rows -%}
    {%- if row['column_name'] in seen_columns and fail_on_ambiguous -%}
      {{ exceptions.raise_compiler_error(
        "Ambiguous Alation column lookup: multiple rows for " ~ relation.schema ~ "." ~ relation.identifier ~ "." ~ row['column_name']
      ) }}
    {%- endif -%}
    {%- do seen_columns.append(row['column_name']) -%}
  {%- endfor -%}

  {#- ---------------------------------------------------------------------
      4. Resolve and apply the relation-level comment.
     --------------------------------------------------------------------- #}
  {%- set model_description = (model.description if model is defined else '') or '' -%}
  {%- set alation_table_desc = table_results.rows[0]['alation_table_description'] if (table_results.rows | length) == 1 else none -%}
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
    {% do _apply_relation_comment(relation, final_relation_comment) %}
  {%- endif -%}

  {#- ---------------------------------------------------------------------
      5. Resolve column-level comments: Alation > YAML, then write ONLY the
         columns we resolved a value for (never touch the rest).
     --------------------------------------------------------------------- #}
  {%- set yaml_columns = (model.columns if model is defined else {}) or {} -%}
  {%- set merged_columns = {} -%}

  {%- for col_name, col_meta in yaml_columns.items() -%}
    {%- if (col_meta.description | trim | length) > 0 -%}
      {%- do merged_columns.update({col_name | upper: _truncate(col_meta.description, max_len, relation)}) -%}
    {%- endif -%}
  {%- endfor -%}

  {%- for row in column_results.rows -%}
    {%- set col_name = row['column_name'] -%}
    {%- set desc = row['alation_column_description'] -%}
    {%- if desc == tombstone -%}
      {%- do merged_columns.update({col_name: ''}) -%}
    {%- elif desc is not none and (desc | trim | length) > 0 -%}
      {%- do merged_columns.update({col_name: _truncate(desc, max_len, relation)}) -%}
    {%- endif -%}
  {%- endfor -%}

  {%- if merged_columns | length > 0 -%}
    {%- set clauses = [] -%}
    {%- for col_name, description in merged_columns.items() -%}
      {%- set safe_desc = description | replace('$', '[$]') -%}
      {%- do clauses.append(col_name ~ " COMMENT $$" ~ safe_desc ~ "$$") -%}
    {%- endfor -%}
    {%- set alter_sql -%}
      alter {{ _relation_ddl_type(relation) }} {{ relation.render() }} alter {{ clauses | join(', ') }};
    {%- endset -%}
    {% do run_query(alter_sql) %}
  {%- endif -%}

  {{ return('') }}
{% endmacro %}


{#- Fallback path when the Alation source is unreachable and
    on_unavailable = 'yaml': behaves like stock persist_docs, but still
    avoids the blank-unlisted-columns landmine described above. -#}
{% macro _apply_yaml_only(relation, max_len) %}
  {%- set description = (model.description if model is defined else '') or '' -%}
  {%- if (description | trim | length) > 0 -%}
    {% do _apply_relation_comment(relation, _truncate(description, max_len, relation)) %}
  {%- endif -%}

  {%- set yaml_columns = (model.columns if model is defined else {}) or {} -%}
  {%- set clauses = [] -%}
  {%- for col_name, col_meta in yaml_columns.items() -%}
    {%- if (col_meta.description | trim | length) > 0 -%}
      {%- set safe_desc = _truncate(col_meta.description, max_len, relation) | replace('$', '[$]') -%}
      {%- do clauses.append((col_name | upper) ~ " COMMENT $$" ~ safe_desc ~ "$$") -%}
    {%- endif -%}
  {%- endfor -%}
  {%- if clauses | length > 0 -%}
    {%- set alter_sql -%}
      alter {{ _relation_ddl_type(relation) }} {{ relation.render() }} alter {{ clauses | join(', ') }};
    {%- endset -%}
    {% do run_query(alter_sql) %}
  {%- endif -%}
  {{ return('') }}
{% endmacro %}


{% macro _truncate(value, max_len, relation) %}
  {%- if (value | length) > max_len -%}
    {{ exceptions.warn("[alation_comments] description exceeds " ~ max_len ~ " characters and was truncated for " ~ relation ~ ".") }}
    {{ return(value[:max_len] ~ " …[truncated]") }}
  {%- else -%}
    {{ return(value) }}
  {%- endif -%}
{% endmacro %}
