{#-
  Auto-creates a Snowflake tag object the first time it's referenced.

  This is the fix for the second issue flagged in the standardised-work-dev
  review: that fork dropped the upstream package's tag-auto-creation step, so
  every referenced tag has to already exist in Snowflake or the `ALTER ...
  SET TAG` fails. Whether auto-creation is the right call for BHP's real
  environment (vs. requiring tags to be provisioned up front by an admin/IaC
  process) is one of the open questions for the team - this macro shows what
  the "let dbt create it" option looks like.

  Expects `qualified_tag_name` as a fully qualified 3-part
  `<database>.<schema>.<tag_name>` name. In this demo the tags live in the
  developer's own database, in a TAGS schema (`DEVELOPMENT.TAGS.<tag_name>`, see
  meta.database_tags in dbt_project.yml, _marts.yml, _src_jaffle_shop.yml).
  The schema and tag are created with `IF NOT EXISTS`.

  Prerequisite: the target database (DEVELOPMENT) must already exist and the
  connecting role must own / have USAGE + CREATE SCHEMA on it. We do NOT
  attempt `create database` here, because the dev role (TRANSFORMER) does not
  have CREATE DATABASE on the account. If you point the tags at a database the
  role can't write to, have an admin create the schema/tags once instead.
#}
{% macro ensure_tag_exists(qualified_tag_name) %}
    {%- set parts = qualified_tag_name.split('.') -%}
    {%- set tag_database = parts[0] -%}
    {%- set tag_schema = parts[1] -%}
    {%- set tag_name = parts[2] -%}
    {{ log('Ensuring tag ' ~ qualified_tag_name ~ ' exists', info=True) }}
    {#- Tags live in a TAGS schema in the developer's own database (DEVELOPMENT.TAGS),
        so we only need to ensure the schema and the tag. We deliberately do NOT `create database`
        here: the dev role (TRANSFORMER) lacks CREATE DATABASE on the account, and
        the target database is expected to already exist. -#}
    {%- call statement('ensure_tag_schema', fetch_result=True) -%}
        create schema if not exists {{ tag_database }}.{{ tag_schema }}
    {%- endcall -%}
    {%- call statement('ensure_tag', fetch_result=True) -%}
        create tag if not exists {{ qualified_tag_name }}
    {%- endcall -%}
{% endmacro %}
