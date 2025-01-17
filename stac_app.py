"""FastAPI application using PGStac."""

# Based on stac-fastapi/stac_fastapi/pgstac/stac_fastapi/pgstac/app.py
import logging
from typing import Optional
import asyncpg
from buildpg import render
from fastapi import APIRouter, HTTPException, Request, Response
from fastapi.responses import ORJSONResponse
from stac_fastapi.api.app import StacApi
from stac_fastapi.api.models import create_get_request_model, create_post_request_model
from stac_fastapi.extensions.core import (
    FieldsExtension,
    FilterExtension,
    PaginationExtension,
    QueryExtension,
    SortExtension,
    TokenPaginationExtension,
    TransactionExtension,
)
from stac_fastapi.pgstac.config import Settings
from stac_fastapi.pgstac.core import CoreCrudClient
from stac_fastapi.pgstac.db import close_db_connection, connect_to_db
from stac_fastapi.pgstac.transactions import TransactionsClient
from stac_fastapi.pgstac.types.search import PgstacSearch
import os
import time

from stac_fastapi.pgstac.extensions.filter import FiltersClient

# hijack uvicorn's logger (otherwise log messages won't be visible)
logger = logging.getLogger("uvicorn.error")

settings = Settings()
settings.openapi_url = os.environ.get("OPENAPI_URL", "/api")
settings.docs_url = os.environ.get("DOCS_URL", "/api.html")

extensions = [
    TransactionExtension(
        client=TransactionsClient(),
        settings=settings,
        response_class=ORJSONResponse,
    ),
    QueryExtension(),
    SortExtension(),
    FieldsExtension(),
    FilterExtension(client=FiltersClient()),
    TokenPaginationExtension(),
    PaginationExtension(),
]

post_request_model = create_post_request_model(extensions, base_model=PgstacSearch)
router_prefix = os.environ.get("ROUTER_PREFIX")
router_prefix_str = router_prefix.rstrip("/") if router_prefix else ""

api = StacApi(
    settings=settings,
    extensions=extensions,
    client=CoreCrudClient(post_request_model=post_request_model),
    search_get_request_model=create_get_request_model(extensions),
    search_post_request_model=post_request_model,
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
    """Execute a postgres command"""
    query, params = render(command)
    await conn.fetchval(query, *params)


async def _load_queryables_functions(conn: asyncpg.Connection) -> None:
    """Load queryables functions into the database"""
    with open("discover_queryables.sql") as f:
        sql_content = f.read().split("-- SPLITHERE --")
    try:
        for content in sql_content:
            await _execute_query(content, conn)
    except Exception:
        logger.error("Failed to update discover_queryables functions", exc_info=True)
    else:
        logger.info("Updated discover_queryables functions")


async def _load_summaries_functions(conn: asyncpg.Connection) -> None:
    """Load summaries functions into the database"""
    with open("discover_summaries.sql") as f:
        sql_content = f.read().split("-- SPLITHERE --")
    try:
        for content in sql_content:
            await _execute_query(content, conn)
    except Exception:
        logger.error("Failed to update discover_summaries functions", exc_info=True)
    else:
        logger.info("Updated discover_summaries functions")


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
        if os.getenv("STAC_DEFAULT_QUERYABLES") != "1":
            await _load_queryables_functions(conn)
        if os.getenv("STAC_DEFAULT_SUMMARIES") != "1":
            await _load_summaries_functions(conn)


@app.on_event("shutdown")
async def shutdown_event() -> None:
    """Close database connection."""
    await close_db_connection(app)


if os.getenv("STAC_DEFAULT_QUERYABLES") != "1":

    @app.patch(f"{router_prefix_str}/queryables")
    async def update_queryables(request: Request) -> Response:
        try:
            async with request.app.state.writepool.acquire() as conn:
                await _execute_query("SELECT update_queryables();", conn)
        except Exception as err:
            raise HTTPException(status_code=500, detail=f"Unable to update queryables: {err}")
        return {"detail": "Updated queryables"}


if os.getenv("STAC_DEFAULT_SUMMARIES") != "1":

    @app.patch(f"{router_prefix_str}/summaries")
    async def update_summaries(request: Request) -> Response:
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
