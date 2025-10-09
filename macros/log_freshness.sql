{% macro log_freshness(results) %}
{% set freshness_keywords = ['freshness', 'build_after', 'count', 'period', 'updates_on'] %}
{% set rows = [] %}

{% for r in results %}
    {% set node = r.node %}
    {{ log("NODE: " ~ node | tojson(indent=4), info=True)}}

    {% set raw_code = node.get('raw_code','') %}
    {{ log("DEBUG: " ~ node.name, raw_code, info=True)}}

    {% set cfg = node.get('config',{}) %}
    {% set freshness_cfg = cfg.get('freshness') %}

    {% set found_in_sql = [] %}
    {% for kw in freshness_keywords %}
        {% if kw in raw_code %}
            {% do found_in_sql.append(kw) %}
        {% endif %}
    {% endfor %}

    {% if freshness_cfg %}
        {% if found_in_sql | length > 0 %}
            {% set source_class = "sql_config" %}
        {% else %}
            {% set source_class = "yml_config" %}
        {% endif %}
    {% else %}
        {% set source_class = "not_set" %}
    {% endif %}

    {% do rows.append({
        "unique_id": node['unique_id'],
        "resource_type": node['resource_type'],
        "name": node['name'],
        "freshness_source": source_class,
        "freshness_keywords": found_in_sql,
        "freshness_config": freshness_cfg
    }) %}
{% endfor %}

{% if execute %}
    {% set create_sql %}
    create table if not exists development.dbt_pkearns.debug_freshness_log (
        "unique_id" string,
        "resource_type" string,
        "name" string,
        "freshness_source" string,
        "freshness_keywords" string,
        "freshness_config" string,
        "logged_at" timestamp
    );
    {% endset %}
    {% do run_query(create_sql) %}

    {% if rows | length > 0 %}
        {% set insert_sql %}
        insert into development.dbt_pkearns.debug_freshness_log
        ("unique_id","resource_type","name","freshness_source","freshness_keywords","freshness_config","logged_at")
        values
        {% for r in rows %}
        (
            '{{ r["unique_id"] | replace("'", "''") }}',
            '{{ r["resource_type"] | replace("'", "''") }}',
            '{{ r["name"] | replace("'", "''") }}',
            '{{ r["freshness_source"] | replace("'", "''") }}',
            '{{ r["freshness_keywords"] | join(",") | replace("'", "''") }}',
            '{{ r["freshness_config"] | tojson | replace("'", "''") }}',
            current_timestamp()
        ){% if not loop.last %},{% endif %}
        {% endfor %}
        ;
        {% endset %}
        {% do run_query(insert_sql) %}
    {% endif %}
{% endif %}

{% endmacro %}
