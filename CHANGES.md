# Changes

[Unreleased](https://github.com/crim-ca/stac-app/tree/master)
------------------------------------------------------------------------------------------------------------------

- Refactor repository to employ `pyproject.toml`, `bump-my-version` and `Makefile` DevOps utilities.

[2.0.1](https://github.com/crim-ca/stac-app/tree/2.0.1)
------------------------------------------------------------------------------------------------------------------

- Fix missing `packaging` dependency.
- Add a CI test building the Docker and doing a `curl` request on the landing page to ensure the API definition
  can at the very least start without error. A DB connection is also used to validate that PostgreSQL is reachable
  from the API service container using basic configurations.

[2.0.0](https://github.com/crim-ca/stac-app/tree/2.0.0)
------------------------------------------------------------------------------------------------------------------

# Changed

- Add `CollectionSearchExtension` base class to support the `pgstac` `collection_search` operator 
  for `GET /collections` request.

  _**NOTE**_: <br>
  Because this extension relies on a specific SQL function `collection_search` and its adjusted feature
  for parameter `q`, [`pgstac>=0.9.2`](https://stac-utils.github.io/pgstac/release-notes/#v092) is required. This
  means the underlying PostgreSQL version **MUST** be migrated to 17.
  
  _**NOTE**_: <br>
  The `CollectionSearchPostExtension` is *purposely* omitted as it would conflict with the `Transaction` extension
  that both uses the same `POST /collections` endpoint for search and collection creation respectively.

- Extended search parameters using `FreeTextAdvancedExtension` to allow
  free-form `q` parameter text search of the collection or its items
  across `description`, `title`, `keywords`.

  The ["advanced"](https://github.com/stac-api-extensions/freetext-search?tab=readme-ov-file#advanced) portion of
  the extension allows additional operators such as `OR`, `AND`, `+`, `-` and `()` within the text search to form
  complex search criteria.

  To ease user experience, ["basic"](https://github.com/stac-api-extensions/freetext-search?tab=readme-ov-file#basic)
  free-text search is also supported seamlessly, to allow simpler queries. Normally, both extensions would conflict
  between each other using the same `q` parameter, but little additional logic makes it possible to support both.

  Enabled requests using `q`:

    - `POST /search` with `{"q": ["term", "other"]}` (basic free-text search form)
    - `POST /search` with `{"q": "term OR other"}` (advanced free-text search form)
    - `GET /search?q=term,other`
    - `GET /search?q=term OR other`
    - `GET /collections?q=term,other`
    - `GET /collections?q=term OR other`
    - `GET /collections/{collectionId}/items?q=term,other`
    - `GET /collections/{collectionId}/items?q=term OR other`

  For the same `Transaction` extension reason as above, `POST` cannot be used elsewhere than on `/search` endpoint.

- Extended search parameters using `FreeTextAdvancedExtension` to allow

- Enabled `Settings(validate_extensions=True)` when configuring the `StacAPI` application.
  This ensures that, when a STAC Collection or Item is POST'ed to the API, all the `stac_extensions` that it declares
  will also be validated against their respective schemas, rather than limiting itself only to core STAC definitions.

# Fixed

- Fix breaking PG connection setting when using ``stac-fastapi>=6``.

[1.1.0](https://github.com/crim-ca/stac-app/tree/1.1.0)
------------------------------------------------------------------------------------------------------------------

# Changed

- Update to latest available versions `stac-fastapi.api==5.2.0`, `stac-fastapi.pgstac==5.0.2` and `uvicorn==0.34.2`.
  This mostly includes security fixes, minor performance improvements, and many additional STAC-API extension features
  that are not yet enabled, but planned in a following release. 

# Fixed

- Fix `rel=next` paging link in `/collections/{collectionID}/items` that was not correctly resolving the `token`
  parameter, leading to an endless loop over the first paging items
  (fixes [#26](https://github.com/crim-ca/stac-app/issues/26)).

[1.0.1](https://github.com/crim-ca/stac-app/tree/1.0.1)
------------------------------------------------------------------------------------------------------------------

# Fixed

- Fix bug where arrays of datetime values were not handled correctly

  Arrays of datetime strings were not being considered as values that can have a minimum and
  maximum (ie. a range) so were summarized as deeply nested `anyOf` schemas. This is a very 
  inefficient way to store a schema representing these values.

[1.0.0](https://github.com/crim-ca/stac-app/tree/1.0.0)
------------------------------------------------------------------------------------------------------------------

# Changed

- Make queryables and summaries automatically updatable

  Previously this app implemented a custom /queryables endpoint that crawled the database to display information about the 
  items stored in the database. This method has some limitations:

  It only worked for individual collections, not all queryables across all collections
  It was really slow since it had to inspect the entire database every time the endpoint was called

  This improves on this method by introducing postgres functions to collect the same queryables information from the database and store it in the queryables table. This caches the queryables information and allows the default /queryables endpoint function to get the same information quickly for a single collection or for all collections.

  A similar strategy is also implemented here to ensure that the collection summaries and extents are kept up to date.

- Update README.md to document the new functionality described above.

- Add `PATCH /queryables` endpoint to update queryables to reflect the current items stored in the database.
  This endpoint takes the optional parameter `minimal`. If the minimal parameter is True, then only "minimal" 
  queryables will set. Minimal queryables are those whose values are scalar JSON types. Collection JSON types 
  (objects and arrays) will be omitted.

- Add `PATCH /summaries` endpoint to update collection summaries to reflect the current items associated with
  all collections.

- Moved source code to the `src/` folder to improve code organization.

- Introduced `ruff` as a linter and formatter used by `pre-commit`.

- Only build docker images for published tags.

Prior Versions
------------------------------------------------------------------------------------------------------------------

All versions prior to [1.0.0](https://github.com/crim-ca/stac-app/1.0.0) were not officially tagged.
Is it strongly recommended to use a tagged version to ensure better traceability of changes that could impact behavior
and potential issues.
The docker image for the version directly prior to 1.0.0 is tagged as [version 0.0.0](https://github.com/crim-ca/stac-app/pkgs/container/stac-app/113480762?tag=0.0.0).
