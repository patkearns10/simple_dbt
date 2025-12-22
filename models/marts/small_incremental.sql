{{
    config(
        materialized='incremental',
        unique_key='id'
    )
}}


select 
 1 as id,
 'something' as text

{% if is_incremental() %}

    union all
    
    select
        2 as id,
        'nothing' as text

{% endif %}