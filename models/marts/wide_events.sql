-- Synthetic fixture, not real data. Exists purely to test that the Alation
-- lookup stays a single query per relation regardless of column count, and
-- that comment precedence (Alation > YAML > untouched) resolves correctly
-- across many undocumented columns.
{{ config(materialized='view') }}

select
  {% for i in range(1, 51) -%}
    {{ i }} as col_{{ '%03d' % i }}{{ "," if not loop.last }}
  {% endfor %}
