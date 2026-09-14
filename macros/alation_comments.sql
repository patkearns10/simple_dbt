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
  {% do run_query(sql) %}
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
         exist" — a query that fails for some other reason (e.g. a
         permission error on a share that does exist) isn't caught here,
         since Jinja has no try/except; that surfaces as an ordinary run
         failure, which is effectively this pattern's implicit "fail" mode
         for anything other than a missing relation.
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
      4. Resolve and apply the relation-level comment: tombstone clears it,
         a non-blank Alation value wins, otherwise fall back to YAML.
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
    {% do _apply_relation_comment(relation, final_relation_comment) %}
  {%- endif -%}

  {#- ---------------------------------------------------------------------
      5. Resolve column-level comments the same way, then write ONLY the
         columns a value was actually resolved for. Every other existing
         column comment on the relation is left completely untouched —
         this is deliberately not done by reusing dbt's built-in
         `alter_column_comment`, which writes a comment for every existing
         column, including a blank one for any column missing from the
         dict you pass it. Building the ALTER statement ourselves, listing
         only the columns we're touching, means partial documentation
         coverage (YAML, Alation, or both) never blanks anything else.
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


{#- Used when the Alation source is unreachable and on_unavailable = 'yaml':
    applies only the YAML descriptions, the same way stock persist_docs
    would, but still only touches columns that are actually documented. -#}
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
