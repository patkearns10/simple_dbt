{% macro log_sources(results) %}
--$----
  {%- for result in results if result.node.resource_type in ['models', 'sources'] -%}
    --$$----
        {{ log(result | tojson(indent=4), info=True) }}
    {% endfor %}
    
{% endmacro %}