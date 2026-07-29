"""Custom dbt-bouncer checks for the Snowflake `meta.database_tags` pattern.

dbt-bouncer's built-in `check_model_has_meta_keys` only validates flat,
top-level meta keys. Our tags live nested inside `meta.database_tags`
(qualified tag name -> value), so we need a small custom check to confirm a
*specific* required tag is present inside that dict - this is exactly the
compatibility gap flagged in the earlier review of the BHP
standardised-work-dev project.
"""

from typing import List, Optional

from dbt_bouncer.check_framework.decorator import check, fail


def _missing_tags(meta: Optional[dict], tag_keys: Optional[List[str]]) -> List[str]:
    tag_keys = tag_keys or []
    database_tags = (meta or {}).get("database_tags", {}) or {}
    return [tag_key for tag_key in tag_keys if tag_key not in database_tags]


@check
def check_model_has_required_database_tags(model, *, tag_keys: Optional[List[str]] = None):
    """Model's meta.database_tags must contain each of the required tag keys."""
    missing = _missing_tags(model.meta, tag_keys)
    if missing:
        fail(
            f"`{model.unique_id}` is missing required Snowflake tag(s) in "
            f"`meta.database_tags`: {', '.join(missing)}."
        )


@check
def check_source_has_required_database_tags(source, *, tag_keys: Optional[List[str]] = None):
    """Source table's meta.database_tags must contain each of the required tag keys."""
    missing = _missing_tags(source.meta, tag_keys)
    if missing:
        fail(
            f"`{source.unique_id}` is missing required Snowflake tag(s) in "
            f"`meta.database_tags`: {', '.join(missing)}."
        )
