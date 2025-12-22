with 

order_items as (

    select * from {{ ref('stg_jaffle_shop__items') }}

),


orders as (
    
    select * from {{ ref('stg_jaffle_shop__orders')}}
),

products as (

    select * from {{ ref('stg_jaffle_shop__products') }}

),

supplies as (

  select * from {{ ref('stg_jaffle_shop__supplies') }}

),

order_supplies_summary as (

  select
    product_id,
    sum(supply_cost) as supply_cost

  from supplies

  group by 1
),

joined as (
    select
        order_items.*,
        products.product_price,
        order_supplies_summary.supply_cost,
        orders.ordered_at,
        orders.order_total

    from order_items

    left join orders on order_items.order_id  = orders.order_id
    
    left join products on order_items.product_id = products.product_id
    
    left join order_supplies_summary on order_items.product_id = order_supplies_summary.product_id
    
)

select * from joined

-- creating a dupe
-- this will fail a normal unique test
-- union all
-- select * from joined where order_item_id = '3f8b6d6a-c77a-46eb-8eb0-48f80acb9708'