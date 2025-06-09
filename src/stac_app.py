"""FastAPI application using PGStac."""

# Based on stac-fastapi/stac_fastapi/pgstac/stac_fastapi/pgstac/app.py
import logging
import os
import time
from typing import Optional, Type, cast

import attr
import asyncpg
from buildpg import render
from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import ORJSONResponse
from stac_fastapi.api.app import StacApi
from stac_fastapi.api.models import (
    EmptyRequest,
    ItemCollectionUri,
    create_request_model,
    create_get_request_model,
    create_post_request_model,
)
from stac_fastapi.types.stac import ItemCollection
from stac_fastapi.types.search import APIRequest
from stac_fastapi.extensions.core import (
    CollectionSearchExtension,
    CollectionSearchFilterExtension,
    CollectionSearchPostExtension,
    FreeTextAdvancedExtension,
    FieldsExtension,
    FilterExtension,
    ItemCollectionFilterExtension,
    PaginationExtension,
    QueryExtension,
    SortExtension,
    TokenPaginationExtension,
    TransactionExtension,
)
from stac_fastapi.extensions.core.collection_search.client import BaseCollectionSearchClient
from stac_fastapi.extensions.core.collection_search.request import BaseCollectionSearchPostRequest
from stac_fastapi.extensions.core.free_text.request import FreeTextAdvancedExtensionPostRequest
from stac_fastapi.pgstac.config import Settings
from stac_fastapi.pgstac.core import CoreCrudClient
from stac_fastapi.pgstac.db import close_db_connection, connect_to_db
from stac_fastapi.pgstac.extensions.filter import FiltersClient
from stac_fastapi.pgstac.transactions import TransactionsClient
from stac_fastapi.pgstac.types.search import PgstacSearch

# hijack uvicorn's logger (otherwise log messages won't be visible)
logger = logging.getLogger("uvicorn.error")

settings = Settings()
settings.openapi_url = os.environ.get("OPENAPI_URL", "/api")
settings.docs_url = os.environ.get("DOCS_URL", "/api.html")

items_get_request_model = cast(
    Type[APIRequest],
    create_request_model(
        "ItemCollectionURI",
        base_model=ItemCollectionUri,
        mixins=[TokenPaginationExtension().GET],
    ),
)
collections_get_request_model = cast(
    Type[APIRequest],
    create_request_model(
        "CollectionsURI",
        base_model=EmptyRequest,
        mixins=[TokenPaginationExtension().GET, PaginationExtension().GET],
    ),
)


class CollectionSearchPostRequest(BaseCollectionSearchPostRequest, FreeTextAdvancedExtensionPostRequest):
    pass


@attr.s
class CollectionSearchPostClient(BaseCollectionSearchClient):
    def post_all_collections(self, search_request: CollectionSearchPostRequest, **kwargs) -> ItemCollection:
        return search_request.model_dump()


extensions = [
    TransactionExtension(
        client=TransactionsClient(),
        settings=settings,
        response_class=ORJSONResponse,
    ),
    QueryExtension(),
    SortExtension(),
    FieldsExtension(),
    FreeTextAdvancedExtension(),
    # FIXME: following 'Filter' variants are conflicting (duplicate GET model) - what are their differences???
    FilterExtension(client=FiltersClient()),
    # ItemCollectionFilterExtension(),
    # CollectionSearchFilterExtension(),
    # CollectionSearchExtension(),  # only GET
    CollectionSearchPostExtension(client=CollectionSearchPostClient(), settings=settings),  # GET + POST
    TokenPaginationExtension(),
    PaginationExtension(),
]

post_request_model = create_post_request_model(extensions, base_model=PgstacSearch)
router_prefix = os.environ.get("ROUTER_PREFIX")
router_prefix_str = router_prefix.rstrip("/") if router_prefix else ""

THIS_DIR = os.path.dirname(os.path.abspath(__file__))

api = StacApi(
    settings=settings,
    extensions=extensions,
    client=CoreCrudClient(pgstac_search_model=post_request_model),
    search_get_request_model=create_get_request_model(extensions),
    search_post_request_model=post_request_model,
    collections_get_request_model=collections_get_request_model,
    items_get_request_model=items_get_request_model,
    response_class=ORJSONResponse,
    title=(os.getenv("STAC_FASTAPI_TITLE") or "Data Analytics for Canadian Climate Services STAC API"),
    description=(
        os.getenv("STAC_FASTAPI_DESCRIPTION")
        or "Searchable spatiotemporal metadata describing climate and Earth observation datasets."
    ),
    router=APIRouter(prefix=router_prefix),
)
app = api.app


async def _execute_query(command: str, conn: asyncpg.Connection) -> None:
    """Execute a postgres command."""
    query, params = render(command)
    await conn.fetchval(query, *params)


async def _load_script(script_basename: str, conn: asyncpg.Connection) -> None:
    """Load script into the database."""
    script_name = os.path.splitext(script_basename)[0]
    with open(os.path.join(THIS_DIR, "scripts", script_basename)) as f:
        sql_content = f.read().split("-- SPLITHERE --")
    try:
        for content in sql_content:
            await _execute_query(content, conn)
    except Exception:
        logger.error("Failed to update %s functions", script_name, exc_info=True)
    else:
        logger.info("Updated %s functions", script_name)


@app.on_event("startup")
async def startup_event() -> None:
    """Connect to database on startup and load custom functions."""
    max_retries = 60
    for retry in range(max_retries):
        try:
            await connect_to_db(app)
            break
        except Exception as err:
            logger.warning(
                "Unable to connect to database. Retrying in 3s. (%s/%s): Error: %s",
                retry + 1,
                max_retries,
                err,
                exc_info=True,
            )
            time.sleep(3)
    else:
        logger.error("Unable to connect to database after %s retries", max_retries)
        return
    async with app.state.writepool.acquire() as conn:
        await _load_script("json_schema_builder.sql", conn)
        if os.getenv("STAC_DEFAULT_QUERYABLES") != "1":
            await _load_script("discover_queryables.sql", conn)
        if os.getenv("STAC_DEFAULT_SUMMARIES") != "1":
            await _load_script("discover_summaries.sql", conn)


@app.on_event("shutdown")
async def shutdown_event() -> None:
    """Close database connection."""
    await close_db_connection(app)


if os.getenv("STAC_DEFAULT_QUERYABLES") != "1":

    @app.patch(f"{router_prefix_str}/queryables")
    async def update_queryables(request: Request, minimal: bool = False) -> Response:
        """
        Update the queryables table based on the data present in the database.

        If the minimal parameter is True, then only "minimal" queryables will set.
        Minimal queryables are those whose values are scalar JSON types. Collection
        JSON types (objects and arrays) will be omitted.
        """
        try:
            async with request.app.state.writepool.acquire() as conn:
                await _execute_query(f"SELECT update_queryables({'TRUE' if minimal else ''});", conn)
        except Exception as err:
            raise HTTPException(status_code=500, detail=f"Unable to update queryables: {err}")
        return {"detail": f"Updated {'minimal ' if minimal else ''}queryables"}


if os.getenv("STAC_DEFAULT_SUMMARIES") != "1":

    @app.patch(f"{router_prefix_str}/summaries")
    async def update_summaries(request: Request) -> Response:
        """Update the collection summaries based on the data present in the database."""
        try:
            async with request.app.state.writepool.acquire() as conn:
                await _execute_query("SELECT update_summaries_and_extents();", conn)
        except Exception as err:
            raise HTTPException(status_code=500, detail=f"Unable to update summaries: {err}")
        return {"detail": "Updated summaries"}


def run() -> None:
    """Run app from command line using uvicorn if available."""
    try:
        import uvicorn
    except ImportError:
        raise RuntimeError("Uvicorn must be installed in order to use command")
    uvicorn.run(
        "stac_app:app",
        host=settings.app_host,
        port=settings.app_port,
        log_level="debug",
        reload=settings.reload,
        proxy_headers=True,
    )


if __name__ == "__main__":
    run()


def create_handler() -> Optional["Mangum"]:  # type: ignore # noqa: F821
    """Create a handler to use with AWS Lambda if mangum available."""
    try:
        from mangum import Mangum  # type: ignore

        return Mangum(app)
    except ImportError:
        return None


handler = create_handler()
