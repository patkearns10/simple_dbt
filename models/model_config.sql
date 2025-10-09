{{
    config(
        freshness={
            "build_after": {
                "count": 1,
                "period": "hour",
                "updates_on": "all"
            }
        }
    )
}}


select 'foo' as some_column