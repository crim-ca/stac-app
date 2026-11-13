import asyncio

import orjson
import pytest
from fastapi.responses import ORJSONResponse
from fastapi.testclient import TestClient
from stac_fastapi.api.models import GeoJSONResponse, JSONSchemaResponse
from stac_fastapi.pgstac.core import CoreCrudClient

import stac_app
from ordering import _order_stac_response
from stac_app import OrderedCoreCrudClient


@pytest.mark.parametrize(
    ("response", "expected_fields", "expected_property_fields"),
    [
        (
            {
                "bbox": [0, 0, 1, 1],
                "collection": "test-collection",
                "geometry": {"type": "Point", "coordinates": [1, 2]},
                "properties": {
                    "proj:shape": [1, 2],
                    "eo:cloud_cover": 0.1,
                    "datetime": "2026-01-01T00:00:00Z",
                    "created": "2026-01-01T00:00:00Z",
                    "proj:epsg": 4326,
                    "eo:bands": [],
                },
                "assets": {},
                "links": [],
                "type": "Feature",
                "stac_extensions": ["https://example.com/proj"],
                "id": "item",
                "stac_version": "1.0.0",
            },
            [
                "stac_version",
                "stac_extensions",
                "id",
                "collection",
                "type",
                "bbox",
                "geometry",
                "properties",
                "assets",
                "links",
            ],
            ["created", "datetime", "eo:bands", "eo:cloud_cover", "proj:epsg", "proj:shape"],
        ),
        (
            {
                "assets": {
                    "thumbnail": {
                        "href": "https://example.com/thumbnail.png",
                        "type": "image/png",
                        "roles": ["thumbnail"],
                    }
                },
                "extent": {
                    "spatial": {"bbox": [[-180, -90, 180, 90]]},
                    "temporal": {"interval": [[None, None]]},
                },
                "keywords": ["climate"],
                "license": "proprietary",
                "providers": [],
                "summaries": {"platform": ["satellite"]},
                "title": "A test collection",
                "custom_field": "custom",
                "type": "Collection",
                "description": "A test collection",
                "links": [],
                "stac_extensions": [],
                "id": "collection",
                "stac_version": "1.0.0",
            },
            [
                "stac_version",
                "stac_extensions",
                "id",
                "type",
                "title",
                "description",
                "summaries",
                "keywords",
                "license",
                "providers",
                "extent",
                "custom_field",
                "assets",
                "links",
            ],
            None,
        ),
        (
            {
                "links": [
                    {
                        "rel": "self",
                        "type": "application/json",
                        "title": "This document",
                        "href": "https://example.com/stac/",
                    },
                    {
                        "rel": "data",
                        "type": "application/json",
                        "title": "Collections available for this Catalog",
                        "href": "https://example.com/stac/collections",
                    },
                    {
                        "rel": "search",
                        "type": "application/geo+json",
                        "title": "STAC search [GET]",
                        "href": "https://example.com/stac/search",
                        "method": "GET",
                    },
                ],
                "conformsTo": [
                    "https://api.stacspec.org/v1.0.0/core",
                    "https://api.stacspec.org/v1.0.0/collections",
                    "https://api.stacspec.org/v1.0.0/item-search",
                ],
                "description": "Example STAC API landing page.",
                "stac_extensions": [],
                "title": "Example STAC API",
                "type": "Catalog",
                "stac_version": "1.0.0",
                "id": "example-stac",
            },
            [
                "stac_version",
                "stac_extensions",
                "conformsTo",
                "id",
                "type",
                "title",
                "description",
                "links",
            ],
            None,
        ),
    ],
)
def test_orders_core_fields_before_grouped_extension_fields(
    response: dict,
    expected_fields: list[str],
    expected_property_fields: list[str] | None,
) -> None:
    """Tests Catalog, Collection and Item field ordering in core and namespaced fields."""
    ordered = _order_stac_response(response)

    assert list(ordered) == expected_fields
    if expected_property_fields is not None:
        assert list(ordered["properties"]) == expected_property_fields
    assert ordered == response


_ITEM_ASSET = {
    "raster:bands": [{"nodata": 0, "data_type": "uint8"}],
    "gsd": 10,
    "eo:bands": [{"name": "B1"}],
    "description": "Example asset",
    "title": "Example",
    "roles": ["data"],
    "href": "https://example.com/data.tif",
    "file:size": 1024,
    "type": "image/tiff",
}
_ITEM_ASSET_FIELDS = ["type", "href", "roles", "title", "description", "gsd", "eo:bands", "file:size", "raster:bands"]
_LINK = {
    "method": "GET",
    "title": "Example search",
    "body": {"limit": 10},
    "href": "https://example.com/search",
    "type": "application/geo+json",
    "rel": "search",
}
_LINK_FIELDS = ["rel", "type", "href", "title", "body", "method"]


@pytest.mark.parametrize(
    ("response", "path", "expected_fields"),
    [
        ({"type": "Catalog", "links": [_LINK]}, ("links", 0), _LINK_FIELDS),
        ({"type": "Feature", "assets": {"thumbnail": {}, "data": _ITEM_ASSET}}, ("assets",), ["thumbnail", "data"]),
        ({"type": "Feature", "assets": {"data": _ITEM_ASSET}}, ("assets", "data"), _ITEM_ASSET_FIELDS),
        ({"type": "Collection", "item_assets": {"data": _ITEM_ASSET}}, ("item_assets", "data"), _ITEM_ASSET_FIELDS),
        (
            {"type": "Feature", "properties": {"title": "", "eo:cloud_cover": 0, "description": "", "datetime": None}},
            ("properties",),
            ["datetime", "description", "title", "eo:cloud_cover"],
        ),
        (
            {"type": "Collection", "providers": [{"url": "", "roles": [], "name": "", "description": ""}]},
            ("providers", 0),
            ["description", "name", "roles", "url"],
        ),
        (
            {"type": "Feature", "geometry": {"type": "Point", "coordinates": [1, 2]}},
            ("geometry",),
            ["type", "coordinates"],
        ),
        (
            {"type": "FeatureCollection", "features": [{"links": [_LINK], "id": "item", "type": "Feature"}]},
            ("features", 0),
            ["id", "type", "links"],
        ),
        (
            {"type": "FeatureCollection", "features": [{"links": [_LINK], "type": "Feature"}]},
            ("features", 0, "links", 0),
            _LINK_FIELDS,
        ),
        (
            {"collections": [{"assets": {"data": _ITEM_ASSET}, "id": "collection", "type": "Collection"}]},
            ("collections", 0, "assets", "data"),
            _ITEM_ASSET_FIELDS,
        ),
    ],
)
def test_orders_nested_fields_according_to_their_parent_field(
    response: dict,
    path: tuple[str | int, ...],
    expected_fields: list[str],
) -> None:
    """Tests nested field ordering of links, assets and other objects contained in STAC objects."""
    ordered = _order_stac_response(response)

    nested = ordered
    for key in path:
        nested = nested[key]
    assert list(nested) == expected_fields
    assert ordered == response


@pytest.mark.parametrize(
    "response_class",
    [ORJSONResponse, GeoJSONResponse, JSONSchemaResponse],
)
def test_orders_json_response_body_and_preserves_headers(response_class: type[ORJSONResponse]) -> None:
    """Tests JSON response ordering while retaining response class, media-type and headers."""
    response = response_class(
        content={
            "geometry": {"type": "Point", "coordinates": [1, 2]},
            "properties": {"datetime": "2026-01-01T00:00:00Z"},
            "id": "item",
            "type": "Feature",
        },
        headers={"x-request-id": "test"},
    )

    ordered = _order_stac_response(response)

    assert type(ordered) is response_class
    assert ordered.media_type == response.media_type
    assert ordered.headers["content-type"] == response.headers["content-type"]
    assert list(orjson.loads(ordered.body)) == ["id", "type", "geometry", "properties"]
    assert ordered.headers["x-request-id"] == "test"
    assert ordered.headers["content-length"] == response.headers["content-length"]
    assert int(ordered.headers["content-length"]) == len(ordered.body)


@pytest.mark.parametrize(
    ("method", "args"),
    [
        ("landing_page", ()),
        ("get_collection", ("example-collection", None)),
        ("all_collections", (None,)),
        ("_search_base", (None, None)),
    ],
)
def test_ordered_client_orders_parent_client_responses(
    monkeypatch: pytest.MonkeyPatch,
    method: str,
    args: tuple,
) -> None:
    """Tests client response ordering applied to responses of the parent pgstac client."""

    async def parent_response(*_: object, **__: object) -> dict:
        return {"links": [], "description": "Example", "type": "Catalog", "id": "example", "stac_version": "1.0.0"}

    monkeypatch.setattr(CoreCrudClient, method, parent_response)
    client = OrderedCoreCrudClient()

    ordered = asyncio.run(getattr(client, method)(*args))

    assert list(ordered) == ["stac_version", "id", "type", "description", "links"]


@pytest.mark.parametrize(
    ("path", "parent_method", "parent_response", "expected_fields"),
    [
        (
            "/",
            "landing_page",
            {"links": [], "conformsTo": [], "description": "Example", "type": "Catalog", "id": "example"},
            ["conformsTo", "id", "type", "description", "links"],
        ),
        (
            "/collections/example-collection",
            "get_collection",
            {"links": [], "extent": {}, "license": "proprietary", "type": "Collection", "id": "example-collection"},
            ["id", "type", "license", "extent", "links"],
        ),
        (
            "/collections/example-collection/items/example-item",
            "_search_base",
            {
                "type": "FeatureCollection",
                "features": [
                    {
                        "links": [],
                        "properties": {"proj:code": "EPSG:4326", "datetime": "2026-01-01T00:00:00Z"},
                        "geometry": {"type": "Point", "coordinates": [1, 2]},
                        "type": "Feature",
                        "id": "example-item",
                    }
                ],
                "links": [],
            },
            ["id", "type", "geometry", "properties", "links"],
        ),
    ],
)
def test_ordered_routes_preserve_upstream_content_type_and_length(
    monkeypatch: pytest.MonkeyPatch,
    path: str,
    parent_method: str,
    parent_response: dict,
    expected_fields: list[str],
) -> None:
    """Tests that reordered route contents keep the content-type and content-length produced by stac-fastapi."""

    async def get_parent_response(*_: object, **__: object) -> dict:
        return parent_response

    async def get_collection(*_: object, **__: object) -> dict:
        return {"type": "Collection", "id": "example-collection"}

    # Item retrieval validates its parent Collection before searching for the Item.
    monkeypatch.setattr(CoreCrudClient, "get_collection", get_collection)
    monkeypatch.setattr(CoreCrudClient, parent_method, get_parent_response)
    client = TestClient(stac_app.app)
    url = f"{stac_app.router_prefix_str}{path}"

    ordered = client.get(url)
    with monkeypatch.context() as unordered_patch:
        unordered_patch.setattr(stac_app, "_order_stac_response", lambda value: value)
        unordered = client.get(url)

    assert ordered.status_code == unordered.status_code == 200
    assert list(ordered.json()) == expected_fields
    assert ordered.json() == unordered.json()
    assert ordered.headers["content-type"] == unordered.headers["content-type"]
    assert ordered.headers["content-length"] == unordered.headers["content-length"]
    assert int(ordered.headers["content-length"]) == len(ordered.content)
