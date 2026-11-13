"""Ordering of STAC response fields with core fields first and extension fields grouped by namespace."""

import functools
from typing import TypeVar, cast

import orjson
from fastapi.responses import ORJSONResponse

# field ordering to be respected
# if unknown, it gets placed where 'None' is set (only one allowed)
# NOTE:
#   nested core/extension fields in 'properties', 'assets', 'links', etc.
#   follow a namespace-grouped and alphabetical order instead
_STAC_FIELD_ORDER: tuple[str | None, ...] = (
    "stac_version",
    "stac_extensions",
    "conformsTo",
    "id",
    "collection",
    "rel",
    "type",
    "href",
    "roles",
    "title",
    "description",
    "summaries",
    "keywords",
    "license",
    "providers",
    "bbox",
    "geometry",
    "extent",
    "properties",
    None,
    "assets",
    "links",
)
# build a mapping for much quicker access to the order position
# tuple above kept only to simplify readability
_STAC_FIELD_RANK = {field: rank for rank, field in enumerate(_STAC_FIELD_ORDER)}
_STAC_EXTENSION_RANK = len(_STAC_FIELD_ORDER)
_STAC_UNKNOWN_RANK = _STAC_FIELD_RANK[None]
ResponseT = TypeVar("ResponseT")


# apply a cache for even faster access of often-evaluated field names
@functools.lru_cache(maxsize=1024)
def _stac_field_order(field: str, nested: bool = False) -> tuple[int, str, str]:
    if ":" in field:
        namespace, name = field.split(":", maxsplit=1)
        return (_STAC_EXTENSION_RANK, namespace.casefold(), name.casefold())
    # nested fields only distinguish core from extension fields, ordering them alphabetically
    rank = None if nested else _STAC_FIELD_RANK.get(field)
    if rank is None:
        return (_STAC_UNKNOWN_RANK, field.casefold(), "")
    return (rank, "", "")


_stac_nested_field_order = functools.partial(_stac_field_order, nested=True)


def _order_nested_fields(value: ResponseT, stac_order: bool = False) -> ResponseT:
    """Order fields of a nested object, and recursively any object it contains."""
    if isinstance(value, dict):
        field_order = _stac_field_order if stac_order else _stac_nested_field_order
        ordered = {field: _order_nested_fields(value[field]) for field in sorted(value, key=field_order)}
        return cast(ResponseT, ordered)
    if isinstance(value, list):
        return cast(ResponseT, [_order_nested_fields(item) for item in value])
    return value


def _order_stac_object(stac_object: dict) -> dict:
    """Order fields of a STAC object, applying the relevant nested ordering according to each field."""
    ordered = {}
    for field in sorted(stac_object, key=_stac_field_order):
        value = stac_object[field]
        if field in ("features", "collections") and isinstance(value, list):
            value = [_order_stac_object(item) if isinstance(item, dict) else item for item in value]
        elif field == "links" and isinstance(value, list):
            value = [_order_nested_fields(link, stac_order=True) for link in value]
        elif field in ("assets", "item_assets") and isinstance(value, dict):
            # asset keys are user-defined names, only the fields of each asset object are ordered
            value = {key: _order_nested_fields(asset, stac_order=True) for key, asset in value.items()}
        elif field != "geometry":  # GeoJSON geometry is not a STAC object, preserve it as is
            value = _order_nested_fields(value)
        ordered[field] = value
    return ordered


def _order_stac_response(value: ResponseT) -> ResponseT:
    """Order STAC fields with core fields first and extension fields grouped by namespace."""
    if isinstance(value, dict):
        return cast(ResponseT, _order_stac_object(value))
    if isinstance(value, list):
        return cast(ResponseT, [_order_stac_response(item) for item in value])
    if isinstance(value, ORJSONResponse) and "json" in value.media_type:
        headers = dict(value.headers)
        response = type(value)(
            _order_stac_response(orjson.loads(value.body)),
            status_code=value.status_code,
            headers=headers,
            background=value.background,
        )
        return cast(ResponseT, response)
    return value
