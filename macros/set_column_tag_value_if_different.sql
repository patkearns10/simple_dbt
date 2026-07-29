{#-
  Sets a column-level Snowflake tag if it's missing or has a different value
  than desired. `object_type` ('TABLE' or 'VIEW') selects the right ALTER
  keyword; the `MODIFY COLUMN ... SET TAG` clause itself is the same syntax
  for both object types.
#}
{% macro set_column_tag_value_if_different(object_type, object_name, column_name, tag_name, desired_tag_value, existing_tags, qualified_object_name) %}
    {{ log('Ensuring tag ' ~ tag_name ~ ' has value ' ~ desired_tag_value ~ ' on column ' ~ object_name ~ '.' ~ column_name, info=True) }}
    {%- set existing_tag_for_column = existing_tags
        | selectattr('0', 'equalto', 'COLUMN')
        | selectattr('1', 'equalto', object_name|upper)
        | selectattr('2', 'equalto', column_name|upper)
        | selectattr('3', 'equalto', tag_name|upper)
        | list -%}
    {% if existing_tag_for_column|length > 0 and existing_tag_for_column[0][4] == desired_tag_value %}
        {{ log('Correct tag value already exists', info=True) }}
    {% else %}
        {{ log('Setting tag value for ' ~ tag_name ~ ' to value ' ~ desired_tag_value, info=True) }}
        {%- call statement('main', fetch_result=True) -%}
            alter {{ object_type }} {{ qualified_object_name }} modify column {{ column_name }} set tag {{ tag_name }} = '{{ desired_tag_value }}'
        {%- endcall -%}
    {% endif %}
{% endmacro %}
