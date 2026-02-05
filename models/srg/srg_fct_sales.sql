with

customers as (
    select * from {{ ref('srg_dim_customers') }}
),

locations as (
    select * from {{ ref('srg_dim_locations') }}
),

orders as (
    select
        100 order_id,
        1 as customer_id,
        2 as location_id,
        '2025-01-12' as order_placed_at
    union all
    select
        101 order_id,
        1 as customer_id,
        2 as location_id,
        '2025-02-15' as order_placed_at
    union all
    select
        102 order_id,
        1 as customer_id,
        2 as location_id,
        '2025-03-22' as order_placed_at
)

select
    orders.*,
    coalesce(customers.customer_key, -1) as customer_key,
    coalesce(locations.location_key, -1) as location_key
from orders
left join customers
    on orders.customer_id = customers.id
    and orders.order_placed_at between customers.valid_from and customers.valid_to
left join locations
    on orders.location_id = locations.id
    and orders.order_placed_at between locations.valid_from and locations.valid_to