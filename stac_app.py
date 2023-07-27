"""FastAPI application using PGStac."""
# Based on stac-fastapi/stac_fastapi/pgstac/stac_fastapi/pgstac/app.py
from fastapi import APIRouter
from fastapi.responses import ORJSONResponse
from stac_fastapi.api.app import StacApi
from stac_fastapi.api.models import create_get_request_model, create_post_request_model
from stac_fastapi.extensions.core import (
    ContextExtension,
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
from starlette.middleware.cors import CORSMiddleware
import uvicorn
import os
import time

# TODO : Ok for now to use custom `FiltersClient, but will eventually need to use the official
#  `stac_fastapi.pgstac.extensions.filter`
from filters import FiltersClient

# from stac_fastapi.pgstac.extensions.filter import FiltersClient

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
    ContextExtension(),
    TokenPaginationExtension(),
    PaginationExtension(),
]

post_request_model = create_post_request_model(extensions, base_model=PgstacSearch)

api = StacApi(
    settings=settings,
    extensions=extensions,
    client=CoreCrudClient(post_request_model=post_request_model),
    search_get_request_model=create_get_request_model(extensions),
    search_post_request_model=post_request_model,
    response_class=ORJSONResponse,
    title="Data Analytics for Canadian Climate Services STAC API",
    description="Searchable spatiotemporal metadata describing climate and Earth observation datasets.",
    router=APIRouter(prefix=os.environ.get("ROUTER_PREFIX")),
)
app = api.app


@app.on_event("startup")
async def startup_event():
    """Connect to database on startup."""
    retries = 60

    # TODO : log errors to stdout

    while retries > 0:
        try:
            await connect_to_db(app)
            break
        except Exception as e:
            print("ERROR: Connection to DB failed. Retrying in 3s. ({retries})")
            print(e)
            time.sleep(3)
            retries -= 1

    if retries == 0:
        print("ERROR: Connection to DB failed after {retries} retries.")


@app.on_event("shutdown")
async def shutdown_event():
    """Close database connection."""
    await close_db_connection(app)


def run():
    """Run app from command line using uvicorn if available."""
    try:
        uvicorn.run(
            "stac_app:app",
            host=settings.app_host,
            port=settings.app_port,
            log_level="debug",
            reload=settings.reload,
            proxy_headers=True,
        )
    except ImportError:
        raise RuntimeError("Uvicorn must be installed in order to use command")


if __name__ == "__main__":
    run()


def create_handler(app):
    """Create a handler to use with AWS Lambda if mangum available."""
    try:
        from mangum import Mangum

        return Mangum(app)
    except ImportError:
        return None


handler = create_handler(app)
