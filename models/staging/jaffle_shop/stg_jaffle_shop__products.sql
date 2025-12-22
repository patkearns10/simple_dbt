with 

source as (

    select * from {{ source('jaffle_shop', 'products') }}

),

renamed as (

    select
        sku as product_id,
        name as product_name,
        type as product_type,
        price as product_price,
        description as product_description

    from source

)

select * from renamed