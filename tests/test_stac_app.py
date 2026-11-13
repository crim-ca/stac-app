import orjson
import pytest
from fastapi.responses import ORJSONResponse

from stac_app import _order_stac_response


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
                "license",
                "keywords",
                "providers",
                "extent",
                "assets",
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
    """Tests [Item and Collection field ordering] in core and namespaced fields."""
    ordered = _order_stac_response(response)

    assert list(ordered) == expected_fields
    if expected_property_fields is not None:
        assert list(ordered["properties"]) == expected_property_fields
    assert ordered == response


def test_orders_json_response_body_and_preserves_headers() -> None:
    """Tests [JSON response ordering] while retaining response metadata."""
    response = ORJSONResponse(
        content={
            "geometry": {"type": "Point", "coordinates": [1, 2]},
            "properties": {"datetime": "2026-01-01T00:00:00Z"},
            "id": "item",
            "type": "Feature",
        },
        headers={"x-request-id": "test"},
    )

    ordered = _order_stac_response(response)

    assert list(orjson.loads(ordered.body)) == ["id", "type", "geometry", "properties"]
    assert ordered.headers["x-request-id"] == "test"
    assert int(ordered.headers["content-length"]) == len(ordered.body)


def test_places_conformance_context_before_regular_fields() -> None:
    """Tests [API context ordering] so conformance details appear before other fields."""
    response = {"links": [], "conformsTo": ["https://example.com/conformance"], "type": "Catalog"}

    ordered = _order_stac_response(response)

    assert list(ordered) == ["conformsTo", "type", "links"]
