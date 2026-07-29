{#-
  Sets a table/view-level Snowflake tag if it's missing or has a different
  value than desired. `object_type` must be 'TABLE' or 'VIEW' - see
  apply_meta_as_tags.sql for how that's determined from the model's
  materialization.

  `existing_tags` is the result of querying
  information_schema.tag_references_all_columns: column 0 is 'TABLE' or
  'COLUMN' (the tag's scope, not the underlying object's type - this stays
  'TABLE' even when object_type is 'VIEW'), column 1 is the object name,
  column 3 is the tag name, column 4 is the tag value.
#}
{% macro set_object_tag_value_if_different(object_type, object_name, tag_name, desired_tag_value, existing_tags, qualified_object_name) %}
    {{ log('Ensuring tag ' ~ tag_name ~ ' has value ' ~ desired_tag_value ~ ' on ' ~ object_type ~ ' ' ~ object_name, info=True) }}
    {%- set existing_tag = existing_tags
        | selectattr('0', 'equalto', 'TABLE')
        | selectattr('1', 'equalto', object_name|upper)
        | selectattr('3', 'equalto', tag_name|upper)
        | list -%}
    {% if existing_tag|length > 0 and existing_tag[0][4] == desired_tag_value %}
        {{ log('Correct tag value already exists', info=True) }}
    {% else %}
        {{ log('Setting tag value for ' ~ tag_name ~ ' to value ' ~ desired_tag_value, info=True) }}
        {%- call statement('main', fetch_result=True) -%}
            alter {{ object_type }} {{ qualified_object_name }} set tag {{ tag_name }} = '{{ desired_tag_value }}'
        {%- endcall -%}
    {% endif %}
{% endmacro %}
