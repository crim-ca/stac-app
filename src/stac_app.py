"""FastAPI application using PGStac."""

# Based on https://github.com/stac-utils/stac-fastapi-pgstac/blob/main/stac_fastapi/pgstac/app.py
import logging
import os
import time
from typing import Annotated, Optional, Type, Union, cast

import asyncpg
from buildpg import render
from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import ORJSONResponse
from packaging.version import Version
from pydantic import BaseModel, Field
from pydantic.functional_serializers import PlainSerializer
from stac_fastapi.api.app import StacApi
from stac_fastapi.api.models import (
    ItemCollectionUri,
    create_get_request_model,
    create_post_request_model,
)
from stac_fastapi.api.version import __version__ as stac_fastapi_version
from stac_fastapi.extensions.core import (
    CollectionSearchFilterExtension,
    FieldsExtension,
    FilterExtension,
    ItemCollectionFilterExtension,
    PaginationExtension,
    QueryExtension,
    SortExtension,
    TokenPaginationExtension,
    TransactionExtension,
)
from stac_fastapi.extensions.core.collection_search import CollectionSearchExtension
from stac_fastapi.extensions.core.fields import FieldsConformanceClasses
from stac_fastapi.extensions.core.free_text import FreeTextAdvancedExtension, FreeTextConformanceClasses
from stac_fastapi.extensions.core.query import QueryConformanceClasses
from stac_fastapi.extensions.core.sort import SortConformanceClasses
from stac_fastapi.pgstac.config import Settings
from stac_fastapi.pgstac.core import CoreCrudClient
from stac_fastapi.pgstac.db import close_db_connection, connect_to_db
from stac_fastapi.pgstac.extensions.filter import FiltersClient
from stac_fastapi.pgstac.transactions import TransactionsClient
from stac_fastapi.pgstac.types.search import PgstacSearch
from stac_fastapi.types.search import APIRequest, BaseSearchGetRequest, BaseSearchPostRequest

# hijack uvicorn's logger (otherwise log messages won't be visible)
logger = logging.getLogger("uvicorn.error")

settings = Settings(validate_extensions=True)
settings.openapi_url = os.environ.get("OPENAPI_URL", "/api")
settings.docs_url = os.environ.get("DOCS_URL", "/api.html")


class FreeTextCombinedExtensionPostRequest(BaseModel):
    """Free-text Extension POST request model allowing for either Basic or Advanced formats."""

    q: Annotated[
        Optional[Union[str, list[str]]],
        PlainSerializer(
            lambda x: " OR ".join(x) if isinstance(x, list) else x,
            return_type=str,
            when_used="json",
        ),
    ] = Field(
        None,
        description=(
            "Parameter to perform free-text queries against STAC metadata. "
            "Basic free-text search is performed when using an array of words. "
            "Advanced free-text search is performed when using a string containing the expression."
        ),
    )


class FreeTextCombinedExtension(FreeTextAdvancedExtension):
    # POST needs override to deal with basic:list[str] vs advanced:str
    # GET uses 'q: str' for both basic and advanced
    POST = FreeTextCombinedExtensionPostRequest


# /search
search_extensions = [
    QueryExtension(),
    SortExtension(),
    FieldsExtension(),
    FreeTextCombinedExtension(conformance_classes=[
        # both basic/advanced are handled simultaneously with the same query parameters and their respective formats
        # however, only one of the extension class is added explicitly to avoid parameter conflict when loading the API
        FreeTextConformanceClasses.SEARCH,
        FreeTextConformanceClasses.SEARCH_ADVANCED,
    ]),
    FilterExtension(client=FiltersClient()),
    PaginationExtension(),
]
search_get_request_model = cast(
    Union[Type[APIRequest], Type[BaseSearchGetRequest]],
    create_get_request_model(search_extensions)
)
search_post_request_model = cast(
    Union[Type[APIRequest], Type[BaseSearchPostRequest]],
    create_post_request_model(search_extensions, base_model=PgstacSearch),
)

# object creation/update/delete operations
transaction_extensions = [
    TransactionExtension(
        client=TransactionsClient(),
        settings=settings,
        response_class=ORJSONResponse,
    ),
]

# /collections
collection_base_extensions = [
    QueryExtension(conformance_classes=[QueryConformanceClasses.COLLECTIONS]),
    SortExtension(conformance_classes=[SortConformanceClasses.COLLECTIONS]),
    FieldsExtension(conformance_classes=[FieldsConformanceClasses.COLLECTIONS]),
    FreeTextAdvancedExtension(conformance_classes=[
        # both basic/advanced are handled simultaneously with the same query parameters and their respective formats
        # however, only one of the extension class is added explicitly to avoid parameter conflict when loading the API
        FreeTextConformanceClasses.COLLECTIONS,
        FreeTextConformanceClasses.COLLECTIONS_ADVANCED,
    ]),
    TokenPaginationExtension(),
]
# NOTE:
#   Using only the 'GET /collections' for search, since 'POST /collections' search
#   would conflict with Transaction extension to create/update/delete collections.
collection_search_extension = CollectionSearchExtension.from_extensions(
    collection_base_extensions
    + [
        CollectionSearchFilterExtension(client=FiltersClient()),
    ],
)
# collection_search_extension = CollectionSearchPostExtension.from_extensions(  # GET + POST
#     collection_base_extensions,
#     client=CollectionSearchPostClient(),
#     settings=settings,
# )
collections_get_request_model = cast(
    Union[Type[APIRequest], Type[CollectionSearchExtension]], collection_search_extension.GET
)
collection_extensions = collection_base_extensions + [collection_search_extension]

# /collections/{collectionID}/items
items_extensions = [
    QueryExtension(conformance_classes=[QueryConformanceClasses.ITEMS]),
    SortExtension(conformance_classes=[SortConformanceClasses.ITEMS]),
    FieldsExtension(conformance_classes=[FieldsConformanceClasses.ITEMS]),
    FreeTextAdvancedExtension(conformance_classes=[
        # both basic/advanced are handled simultaneously with the same query parameters and their respective formats
        # however, only one of the extension class is added explicitly to avoid parameter conflict when loading the API
        FreeTextConformanceClasses.ITEMS,
        FreeTextConformanceClasses.ITEMS_ADVANCED,
    ]),
    ItemCollectionFilterExtension(client=FiltersClient()),
    TokenPaginationExtension(),
]
items_get_request_model = cast(
    Type[APIRequest],
    create_get_request_model(
        extensions=items_extensions,
        base_model=ItemCollectionUri,
    ),
)

app_extensions = search_extensions + transaction_extensions + collection_extensions + items_extensions

router_prefix = os.environ.get("ROUTER_PREFIX")
router_prefix_str = router_prefix.rstrip("/") if router_prefix else ""

THIS_DIR = os.path.dirname(os.path.abspath(__file__))

api = StacApi(
    settings=settings,
    extensions=app_extensions,
    client=CoreCrudClient(pgstac_search_model=search_post_request_model),
    search_get_request_model=search_get_request_model,
    search_post_request_model=search_post_request_model,
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

    # forward-compatibility setting
    connect_to_db_kwargs = {}
    if Version(stac_fastapi_version) >= Version("6.0"):
        connect_to_db_kwargs["add_write_connection_pool"] = True

    for retry in range(max_retries):
        try:
            await connect_to_db(app, **connect_to_db_kwargs)
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
