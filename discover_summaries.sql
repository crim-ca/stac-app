-- Get minimum and maximum values for all axes for the bbox of a given collection.
CREATE OR REPLACE FUNCTION discover_bbox_extent(_collection text) RETURNS TABLE(definition jsonb) as $$
DECLARE
    q text;
    _partition text;
BEGIN
    SELECT format('_items_%s', key) INTO _partition FROM collections WHERE id=_collection;
    q := format(
        $q$
            WITH t AS (
                SELECT public.ST_3DEXTENT(geometry) as bbox
                FROM %I
            ), p AS (
                SELECT 
                    public.ST_XMin(bbox) AS xmin,
                    public.ST_YMin(bbox) AS ymin,
                    public.ST_ZMin(bbox) AS zmin,
                    public.ST_XMax(bbox) AS xmax,
                    public.ST_YMax(bbox) AS ymax,
                    public.ST_ZMax(bbox) AS zmax
                FROM t
            )
            SELECT
                CASE
                WHEN (ROUND(zmin::numeric, 10) = 0) AND (ROUND(zmax::numeric, 10) = 0) THEN
                    -- Assume there is no Z axis represented 
                    -- (null z values are sometimes represented as approximately zero due to floating point errors)
                    jsonb_build_array(xmin, ymin, xmax, ymax)
                ELSE
                    jsonb_build_array(xmin, ymin, zmin, xmax, ymax, zmax)
                END
            FROM p;
        $q$,
        _partition
    );
    RETURN QUERY EXECUTE q;
END
$$ LANGUAGE PLPGSQL;


-- NOTE: the SPLITHERE comments are used to divide this script into sections with one SQL command per section
--       this allows this script to be executed one command at a time when the app starts.
-- SPLITHERE --

-- Get minimum and maximum values for the datetime extents of a given collection.
CREATE OR REPLACE FUNCTION discover_range_extent(_collection text) RETURNS TABLE(definition jsonb) as $$
DECLARE
    q text;
    _partition text;
BEGIN
    SELECT format('_items_%s', key) INTO _partition FROM collections WHERE id=_collection;
    q := format(
        $q$
            WITH t AS (
                SELECT content->'properties' AS properties
                FROM %I
            ), p AS (
                SELECT key, value
                FROM t
                JOIN LATERAL jsonb_each(properties) ON TRUE
                WHERE key IN ('datetime', 'end_datetime', 'start_datetime')
            ), j as (
                SELECT
                    -- note: RFC 3339 date strings will sort lexicographically
                    min(value::text) as minvalue,
                    max(value::text) as maxvalue
                FROM p
            )
            SELECT
                jsonb_build_array(minvalue::jsonb, maxvalue::jsonb)
            FROM j;
        $q$,
        _partition
    );
    RETURN QUERY EXECUTE q;
END
$$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Update the spatial and temporal extents for a given collection
-- Note: this only updates the first extent which defines the whole collection, additional
--       extents that describe subsets of the collection will not be modified.
CREATE OR REPLACE FUNCTION update_extents(_collection text) RETURNS void as $$
    UPDATE collections
    SET content = jsonb_set(
                    jsonb_set(content, 
                            '{extent, temporal, interval, 0}', 
                            (SELECT definition FROM discover_range_extent(_collection)), 
                            TRUE),
                    '{extent, spatial, bbox, 0}',
                    (SELECT definition FROM discover_bbox_extent(_collection)),
                    TRUE)
    WHERE id = _collection;
$$ LANGUAGE SQL;

-- SPLITHERE --

-- Update the spatial and temporal extents for all collections
-- Note: this only updates the first extent which defines the whole collection, additional
--       extents that describe subsets of the collection will not be modified.
CREATE OR REPLACE FUNCTION update_extents() RETURNS void as $$
    select update_extents(id) from collections;
$$ LANGUAGE SQL;

-- SPLITHERE --

-- Get enum values for most properties for a given collection (not including date values).
CREATE OR REPLACE FUNCTION discover_enum_summaries(_collection text) RETURNS TABLE(definition jsonb) as $$
DECLARE
    q text;
    _partition text;
BEGIN
    SELECT format('_items_%s', key) INTO _partition FROM collections WHERE id=_collection;
    q := format(
        $q$
            WITH t AS (
                SELECT content->'properties' AS properties
                FROM %I
            ), p AS (
                SELECT DISTINCT ON (key, a.value)
                    key, 
                    a.value
                FROM t
                JOIN LATERAL jsonb_each(properties) ON TRUE
                JOIN LATERAL jsonb_array_elements(
                    CASE jsonb_typeof(value)
                        WHEN 'array' THEN
                            value
                        ELSE
                            jsonb_build_array(value)
                    END
                ) AS a ON TRUE
                -- see https://github.com/stac-extensions/timestamps
                WHERE key NOT IN ('created', 'updated', 'published', 'expires', 'unpublished', 'datetime', 'start_datetime', 'end_datetime')
            ), j as (
                SELECT
                    jsonb_agg(value) as values,
                    key
                FROM p
                GROUP BY key
            )
            SELECT
                jsonb_object_agg(key, values)
            FROM j;
        $q$,
        _partition
    );
    RETURN QUERY EXECUTE q;
END
$$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Get minimum and maximum values for the date properties.
-- Note: This does not include the following properties 'datetime', 'end_datetime', 'start_datetime'
--       since those are used to determine the temporal extent (see above).
CREATE OR REPLACE FUNCTION discover_range_summaries(_collection text) RETURNS TABLE(definition jsonb) as $$
DECLARE
    q text;
    _partition text;
BEGIN
    SELECT format('_items_%s', key) INTO _partition FROM collections WHERE id=_collection;
    q := format(
        $q$
            WITH t AS (
                SELECT content->'properties' AS properties
                FROM %I
            ), p AS (
                SELECT key, value
                FROM t
                JOIN LATERAL jsonb_each(properties) ON TRUE
                -- see https://github.com/stac-extensions/timestamps
                WHERE key IN ('created', 'updated', 'published', 'expires', 'unpublished')
            ), j as (
                SELECT
                    -- note: RFC 3339 date strings will sort lexicographically
                    min(value::text) as minvalue,
                    max(value::text) as maxvalue,
                    key
                FROM p
                GROUP BY key
            )
            SELECT
                jsonb_object_agg(key, jsonb_build_object('minimum', minvalue::jsonb, 'maximum', maxvalue::jsonb))
            FROM j;
        $q$,
        _partition
    );
    RETURN QUERY EXECUTE q;
END
$$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Update summaries for a given collection
CREATE OR REPLACE FUNCTION update_summaries(_collection text) RETURNS void as $$
    UPDATE collections
    SET content = jsonb_set(content, '{summaries}', (
        SELECT jsonb_object_agg(key, value) FROM (
            SELECT key, value FROM jsonb_each((SELECT definition FROM discover_enum_summaries(_collection)))
            UNION ALL
            SELECT key, value FROM jsonb_each((SELECT definition FROM discover_range_summaries(_collection)))
        ) AS t
    ), TRUE)
    WHERE id = _collection;
$$ LANGUAGE SQL;

-- SPLITHERE --

-- Update summaries for all collections
CREATE OR REPLACE FUNCTION update_summaries() RETURNS void as $$
    select update_summaries(id) from collections;
$$ LANGUAGE SQL;

-- SPLITHERE --

-- Update summaries and extents for a given collection
CREATE OR REPLACE FUNCTION update_summaries_and_extents(_collection text) RETURNS void as $$
    select update_summaries(_collection);
    select update_extents(_collection);
$$ LANGUAGE SQL;

-- SPLITHERE --

-- Update summaries and extents for all collections
CREATE OR REPLACE FUNCTION update_summaries_and_extents() RETURNS void as $$
    select update_summaries(id) from collections;
    select update_extents(id) from collections;
$$ LANGUAGE SQL;
