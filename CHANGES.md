# Changes

[Unreleased](https://github.com/crim-ca/stac-app/tree/master)
------------------------------------------------------------------------------------------------------------------

# Changed

- Update to latest available versions `stac-fastapi.api==5.2.0`, `stac-fastapi.pgstac==5.0.2` and `uvicorn==0.34.2`.
  This mostly includes security fixes, minor performance improvements, and many additional STAC-API extension features
  that are not yet enabled, but planned in a following release. 

# Fixed

- Fix `rel=next` paging link in `/collections/{collectionID}/items` that was not correctly resolving the `token`
  parameter, leading to an endless loop over the first paging items.

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
