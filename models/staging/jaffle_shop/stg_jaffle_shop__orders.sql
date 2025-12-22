with 

source as (

    select * from {{ source('jaffle_shop', 'orders') }}

),

renamed as (

    select
        id as order_id,
        customer as customer_id,
        ordered_at,
        store_id,
        subtotal,
        tax_paid,
        order_total,
        -- 'jaffle_shop' as column_to_be_deleted,
        current_timestamp as updated_at

    from source

)

select * from renamed