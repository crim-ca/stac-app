# STAC API implementation for [Birdhouse](https://github.com/bird-house/birdhouse-deploy/tree/master/birdhouse)

[![Latest Version](https://img.shields.io/badge/latest%20version-2.2.0-blue?logo=github)](https://github.com/crim-ca/stac-app/tree/2.2.0)
[![License](https://img.shields.io/github/license/crim-ca/stac-app)](https://github.com/crim-ca/stac-app/blob/main/LICENSE)
[![Docker Image](https://img.shields.io/badge/docker-crim--ca%2Fstac--app-blue?logo=docker)](https://github.com/crim-ca/stac-app/pkgs/container/stac-app)

This implementation extends [stac-fastapi-pgstac](https://github.com/stac-utils/stac-fastapi-pgstac)
by providing the following additional features:

- [Custom Queryables](#custom-queryables)
- [Custom Collection Summaries](#custom-collection-summaries)
- [Settable Router Prefix](#settable-router-prefix)
- [Settable OpenAPI paths](#settable-openapi-paths)

#### Custom Queryables

The [`/queryables` endpoints](https://github.com/stac-api-extensions/filter?tab=readme-ov-file#queryables) enabled
by [stac-fastapi-pgstac](https://github.com/stac-utils/stac-fastapi-pgstac) only provide basic information about the
STAC items. This includes the property type (string, array, number, etc.) but not much else.

This implementation adds additional postgres functions to help discover more detailed queryables information including
minimums and maximums for range properties and enum values for discrete properties.

> [!Note] 
> Dates are formatted as RFC 3339 strings and JSON schemas only support minimum/maximum for numeric types so
> minimum and maximum dates are provided as epoch seconds (in the "minimum" and "maximum" fields) and as 
> RFC 3339 strings in the "description" field.

This also adds the following helper route `PATCH /queryables` which will update the 
queryables stored in the database with up-to-date information from all items stored
in the database.

We recommend that you update the queryables after you add/remove/update any items in the database.

Custom queryables are enabled by default. To disable this feature and only use the 
queryables provided by [stac-fastapi-pgstac](https://github.com/stac-utils/stac-fastapi-pgstac), set the `STAC_DEFAULT_QUERYABLES` environment variable to `1`.

```shell
export STAC_DEFAULT_QUERYABLES=1
```

#### Custom Collection Summaries

Collections in STAC are strongly recommended to provide [summaries](https://github.com/radiantearth/stac-spec/blob/master/collection-spec/collection-spec.md#summaries) and [extents](https://github.com/radiantearth/stac-spec/blob/master/collection-spec/collection-spec.md#extents) of the items they contain.
This includes the temporal and spatial extents of the whole collection as well as the minimums and maximums for range
properties and enum values for discrete properties of items.

These values are not updated automatically so this implementation adds additional postgres functions to help keep these
collection summaries and extents up to date.

This also adds the following helper route `PATCH /summaries` which will update the 
collection summaries and extents stored in the database with up-to-date information from all items stored
in the database.

> [!Note]
> These functions will only update the first extent value which defines the extent of the whole collection, 
> additional extents that describe subsets of the collection will not be modified.

Custom summaries are enabled by default. To disable this feature and set the `STAC_DEFAULT_SUMMARIES` 
environment variable to `1`:

```shell
export STAC_DEFAULT_SUMMARIES=1
```

#### Settable Router Prefix

To set a custom router prefix, set the `ROUTER_PREFIX` environment variable.

For example, the following access the same route:

With no router prefix set:

```http request
GET /collections
```

With a custom router prefix set to `/my-prefix`:

```http request
GET /my-prefix/collections
```

#### Settable OpenAPI paths

To set a custom path for the OpenAPI routes set the following environment variables:

- `OPENAPI_URL`
    - default: `/api`
    - returns a description of this API in JSON format
- `DOCS_URL`
    - default: `/api.html`
    - returns a description of this API in HTML format

> [!NOTE]
> Note that other environment variables can be used to set other settings according to the 
> [FastAPI documentation](https://fastapi.tiangolo.com/advanced/settings/#settings-and-environment-variables) and the
> [STAC-FastAPI documentation](https://stac-utils.github.io/stac-fastapi/tips-and-tricks/#set-api-title-description-and-version)

## Contributing

Ensure that the pre-commit checks are installed so that you make sure that your code changes conform to
the expected style for this project.

```shell
make install-dev
```

## Releasing

Before making a new release:

```shell
make install-dev
make version  # display current version
make VERSION=<MAJOR.MINOR.PATCH> bump [dry]
```

You can also invoke `bump-my-version` directly with its relevant options.
This project uses [semantic versioning](https://semver.org/).
