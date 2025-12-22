with 

source as (

    select * from {{ source('jaffle_shop', 'supplies') }}

),

renamed as (

    select
        id as product_id,
        name,
        cost as supply_cost,
        perishable,
        sku

    from source

)

select * from renamed