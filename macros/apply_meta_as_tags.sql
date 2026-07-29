{#-
  Applies Snowflake object tags from each model's `meta.database_tags` config,
  called as an `on-run-end` hook (see dbt_project.yml).

  This replicates the pattern used in the BHP standardised-work-dev project
  (itself a fork of Montreal-Analytics' snowflake_utils.apply_meta_as_tags),
  with two fixes identified during that review:

  1. ALTER VIEW vs. ALTER TABLE: Snowflake requires `ALTER VIEW ... SET TAG`
     for view-backed objects; `ALTER TABLE` against a view errors out. This
     version branches on `res.node.config.materialized` and picks the right
     keyword, so it works whether a model is a view (dim_customers), a table
     (fct_orders), or incremental (small_incremental).
  2. Tag auto-creation with a real cache: unlike the fork (which dropped tag
     auto-creation and left an unused, never-populated cache dict), this
     version creates missing tag objects on first use via `ensure_tag_exists`
     and tracks what's already been created/confirmed in `created_tags` so we
     don't re-issue the same `CREATE SCHEMA` / `CREATE TAG` for every model in
     a single run.

  Tag names use a 3-part `<database>.<schema>.<tag_name>` convention. In this
  demo they live in the developer's own database, `DEVELOPMENT.TAGS.<tag_name>`
  (see meta.database_tags in dbt_project.yml, _marts.yml, _src_jaffle_shop.yml).
  `ensure_tag_exists` creates the schema and tag with `IF NOT EXISTS` but does
  NOT create the database, since the dev role (TRANSFORMER) can't CREATE DATABASE
  - the target database must already exist and be writable by the connecting role.
#}

{% macro apply_meta_as_tags(results) %}
  {#- Guard the log with `execute`: on-run-end macros are invoked once at parse
      time (execute == false) and again when the hook actually runs, so an
      unguarded log() prints twice. -#}
  {% if execute %}
    {{ log('$ Applying Meta as Tags', info=True) }}
    {%- set created_tags = [] -%}
    {% for res in results -%}
        {% if model_contains_tag_meta(res.node) %}

            {%- set model_database = res.node.database -%}
            {%- set model_schema = res.node.schema -%}
            {%- set model_alias = res.node.alias -%}
            {#- Fully-qualified name for DDL. `ensure_tag_exists` runs CREATE SCHEMA,
                which switches the session's active schema, so unqualified ALTERs
                would resolve against the wrong schema - always qualify. -#}
            {%- set qualified_object_name = model_database ~ '.' ~ model_schema ~ '.' ~ model_alias -%}
            {%- set materialization = res.node.config.materialized -%}
            {#- The core fix: pick the correct ALTER keyword for this object type. -#}
            {%- set object_type = 'VIEW' if materialization in ('view', 'ephemeral') else 'TABLE' -%}

            {%- call statement('set_database', fetch_result=True) -%}
                USE DATABASE {{ model_database }}
            {%- endcall -%}
            {%- call statement('set_schema', fetch_result=True) -%}
                USE SCHEMA {{ model_schema }}
            {%- endcall -%}

            {{ log("========== Processing tags for " ~ model_database ~ "." ~ model_schema ~ "." ~ model_alias ~ " (" ~ object_type ~ ") ==========", info=True) }}

            {% if res.node.meta %}
                {%- set model_meta = res.node.meta -%}
            {% else %}
                {%- set model_meta = res.node.config.meta -%}
            {% endif %}

            {#- Existing tags on this object, so we only ALTER when a value has changed.
                NOTE: tag_references_all_columns' object-domain argument must be 'table'
                for ALL table-like objects, including views - passing 'view' errors with
                "Invalid value VIEW for argument OBJECT_TYPE". This is separate from the
                ALTER keyword (object_type), which really is VIEW vs TABLE. -#}
            {%- call statement('main', fetch_result=True) -%}
                select LEVEL, OBJECT_NAME, COLUMN_NAME, UPPER(TAG_NAME) as TAG_NAME, TAG_VALUE
                from table(information_schema.tag_references_all_columns('{{ model_alias }}', 'table'))
            {%- endcall -%}
            {%- set existing_tags_for_object = load_result('main')['data'] -%}

            {#- The columns the relation actually has in the warehouse. A model's
                yml can document columns its SQL doesn't (yet) produce; we must not
                try to `ALTER ... MODIFY COLUMN` those, or Snowflake errors with
                "invalid identifier". Compare against this set, not the yml docs. -#}
            {%- set object_relation = api.Relation.create(database=model_database, schema=model_schema, identifier=model_alias) -%}
            {%- set actual_columns = [] -%}
            {% for col in adapter.get_columns_in_relation(object_relation) %}
                {%- do actual_columns.append(col.name | upper) -%}
            {% endfor %}

            {% for table_tag in model_meta.database_tags %}
                {% if table_tag not in created_tags %}
                    {{ ensure_tag_exists(table_tag) }}
                    {% do created_tags.append(table_tag) %}
                {% endif %}
                {% set desired_tag_value = model_meta.database_tags[table_tag] %}
                {{ set_object_tag_value_if_different(object_type, model_alias|upper, table_tag, desired_tag_value, existing_tags_for_object, qualified_object_name) }}
            {% endfor %}

            {% for column in res.node.columns %}
                {% if (column | upper) not in actual_columns %}
                    {{ log("⚠️  Skipping column tags for " ~ model_alias ~ "." ~ column ~ " - documented in yml but not present in the built relation", info=True) }}
                {% else %}
                    {% for column_tag in res.node.columns[column].meta.database_tags %}
                        {% if column_tag not in created_tags %}
                            {{ ensure_tag_exists(column_tag) }}
                            {% do created_tags.append(column_tag) %}
                        {% endif %}
                        {% set desired_tag_value = res.node.columns[column].meta.database_tags[column_tag] %}
                        {{ set_column_tag_value_if_different(object_type, model_alias|upper, column|upper, column_tag, desired_tag_value, existing_tags_for_object, qualified_object_name) }}
                    {% endfor %}
                {% endif %}
            {% endfor %}

            {{ log("========== Finished processing tags for " ~ model_alias ~ " ==========", info=True) }}
        {% endif %}
    {% endfor %}
  {% endif %}
  {#- dbt executes non-empty hook return values as SQL, so return an empty string. -#}
  {{ return('') }}
{% endmacro %}
