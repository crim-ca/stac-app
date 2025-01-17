# Changes

[Unreleased](https://github.com/crim-ca/stac-app/tree/master)
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

- Moved source code to the `src/` folder to improve code organization.

- Introduced `ruff` as a linter and formatter used by `pre-commit`.

- Only build docker images for published tags.

Prior Versions
------------------------------------------------------------------------------------------------------------------

All versions prior to [1.0.0](https://github.com/crim-ca/stac-app/1.0.0) were not officially tagged.
Is it strongly recommended employing later versions to ensure better traceability of changes that could impact behavior
and potential issues. 
