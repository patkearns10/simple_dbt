select
    id,
    customer,
    ordered_at,
    store_id,
    subtotal,
    tax_paid,
    order_total,
    --
    column_to_be_deleted,
    --
    updated_at,
    dbt_valid_from,
    dbt_valid_to,
    dbt_scd_id,
    dbt_updated_at
from {{ ref('a_snapshot') }}