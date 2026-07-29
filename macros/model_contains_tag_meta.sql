{#-
  Returns True if the model's meta (or any of its columns' meta) declares
  `database_tags`. Used by apply_meta_as_tags to skip models that have
  nothing to tag.
#}
{% macro model_contains_tag_meta(model_node) %}
    {% if model_node.meta.database_tags %}
        {{ return(True) }}
    {% endif %}
    {#- For compatibility with older manifest shapes where meta lives under config. -#}
    {% if model_node.config.meta.database_tags %}
        {{ return(True) }}
    {% endif %}
    {% for column in model_node.columns %}
        {% if model_node.columns[column].meta.database_tags %}
            {{ return(True) }}
        {% endif %}
    {% endfor %}
    {{ return(False) }}
{% endmacro %}
