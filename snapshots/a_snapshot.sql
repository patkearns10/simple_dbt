{% snapshot a_snapshot %}

{{
    config(
      target_database='development',
      unique_key='id',
      strategy='timestamp',
      updated_at='updated_at',
      hard_deletes='invalidate'
    )
}}

select * from {{ ref('stg_jaffle_shop__orders') }}

{% endsnapshot %}