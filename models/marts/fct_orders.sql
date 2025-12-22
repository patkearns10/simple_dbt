with 

orders as (
    
    select * from {{ ref('stg_jaffle_shop__orders')}}

),

order_items as (
    
    select * from {{ ref('int_order_items')}}

),

order_items_summary as (

    select

        order_items.order_id,
        sum(supply_cost) as order_cost

    from order_items

    group by 1

),


compute_booleans as (
    select

        orders.*,
        order_items_summary.order_cost

    from orders
    
    left join order_items_summary on orders.order_id = order_items_summary.order_id
)

select * from compute_booleans