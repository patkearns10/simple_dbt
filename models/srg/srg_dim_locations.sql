with

locations as (
    select
        2 as id,
        'ny' as name,
        'store' as type,
        '2025-01-01' as valid_from,
        '2025-02-01' as valid_to
    union all
    select
        2 as id,
        'ny' as name,
        'pop up store' as type,
        '2025-02-01' as valid_from,
        '2025-03-01' as valid_to
    union all
    select
        2 as id,
        'ny' as name,
        'flagship store' as type,
        '2025-03-01' as valid_from,
        '2025-04-01' as valid_to
)

select
    hash(id, valid_from) as location_key,
    *
from locations