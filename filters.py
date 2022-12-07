# encoding: utf-8
"""

"""
__author__ = "Mathieu Provencher"
__date__ = "21 Apr 2022"
__copyright__ = "Copyright 2022 Computer Research Institute of Montreal"
__license__ = "BSD - see LICENSE file in top-level package directory"
__contact__ = "mathieu.provencher@crim.ca"

from typing import Any, Dict, Optional

import attr
from stac_fastapi.extensions.core.fields.request import PostFieldsExtension
from stac_fastapi.pgstac.core import CoreCrudClient
from stac_fastapi.pgstac.types.search import PgstacSearch
from stac_fastapi.types.core import AsyncBaseFiltersClient

from utils import dict_merge


class PgstacSearchFieldsExtension(PgstacSearch):
    """
    Search model compatible with PostFieldsExtension.
    """

    conf: Optional[Dict] = {}
    fields: PostFieldsExtension = PostFieldsExtension()


@attr.s
class FiltersClient(AsyncBaseFiltersClient):
    """
    Get queryables for given collections.

    Eg:
    One collection : http://127.0.0.1:8000/collections/c604ffb6d610adbb9a6b4787db7b8fd7/queryables
    Multiple collections : http://127.0.0.1:8000/queryables?collections=0798aa197d54eb4332767a5a4077fb0f,c604ffb6d610adbb9a6b4787db7b8fd7
    """

    async def collection_summaries(self, collection_id: str, **kwargs) -> Dict:
        properties = {}
        core_crud_client = CoreCrudClient(
            post_request_model=PgstacSearchFieldsExtension
        )
        item_collection = await core_crud_client.item_collection(
            collection_id, **kwargs
        )

        for feat in item_collection["features"]:
            for property in feat["properties"]:
                if property == "datetime":
                    continue

                if property not in properties:
                    properties[property] = {
                        "title": property.title().replace("_", " "),
                        "type": "string",
                        "enum": [],
                    }

                if feat["properties"][property] not in properties[property]["enum"]:
                    properties[property]["enum"].append(feat["properties"][property])

        return properties

    async def get_queryables(
        self, collection_id: Optional[str] = None, **kwargs
    ) -> Dict[str, Any]:

        schema = await super().get_queryables()

        if collection_id:
            properties = await self.collection_summaries(collection_id, **kwargs)

            schema["$id"] = f'{kwargs["request"].base_url}{collection_id}/queryables'
            schema["title"] = f"Queryables for {collection_id}"
            schema[
                "description"
            ] = f"Queryable names and values for the {collection_id} collection"
            schema["properties"] = properties
        else:
            query_params = kwargs["request"].query_params
            collections = query_params.get("collections", [])
            if collections:
                collections = collections.split(",")

            properties = {}

            for collection in collections:
                if not properties:
                    # Initialise with first collection
                    properties = await self.collection_summaries(collection, **kwargs)
                else:
                    # Get properties of following collections
                    new_props = await self.collection_summaries(collection, **kwargs)
                    intersect = {}
                    for prop, value in properties.items():
                        if prop in new_props:
                            if value.get("type") == "string":
                                intersect[prop] = dict_merge(value, new_props[prop])
                    properties = intersect

                    # If the resultant intersect is an empty dict, short-circuit
                    # loop.
                    if not properties:
                        break

            schema["$id"] = f'{kwargs["request"].base_url}/queryables'
            schema["title"] = f"Global queryables, reduced by collection context"
            schema["description"] = f"Queryable names and values"
            schema["properties"] = properties

        return schema
