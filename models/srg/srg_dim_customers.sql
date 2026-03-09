with

customers as (
    select
        1 as id,
        'pat' as name,
        'blue' as color,
        '2025-01-01' as valid_from,
        '2025-02-01' as valid_to
    union all
    select
        1 as id,
        'pat' as name,
        'green' as color,
        '2025-02-01' as valid_from,
        '2025-03-01' as valid_to
    union all
    select
        1 as id,
        'pat' as name,
        'blue' as color,
        '2025-03-01' as valid_from,
        '2025-04-01' as valid_to
)

select
    hash(id, valid_from) as customer_key,
    *
from customers