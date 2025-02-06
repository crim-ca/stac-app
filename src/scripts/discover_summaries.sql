-- This file contains functions to extract collection summaries based on the items in the given collection.
-- This file uses functions that are defined in the json_schema_builder.sql file (ensure those functions are also loaded).

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
            WITH a AS (
                SELECT jsonb_path_query(
                            (SELECT jsonb_object_agg(key, value) 
                             FROM jsonb_each(content->'properties') 
                             WHERE key = ANY ('{datetime,end_datetime,start_datetime}')),
                            '$.*'
                        ) AS dates from %I
            ), b AS (
                SELECT jsonb_schema_agg(dates)->'description' AS description FROM a
            )
            SELECT
                jsonb_build_array(substring(description::text, 'minimum=\\"(\S+)\\"'), 
                                  substring(description::text, 'maximum=\\"(\S+)\\"'))
            FROM b;
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

-- Get summaries of the properties in each item in the collection
CREATE OR REPLACE FUNCTION discover_summaries(_collection text) RETURNS TABLE(property text, summary jsonb) AS $$
DECLARE
    q text;
    _partition text;
BEGIN
    SELECT format('_items_%s', key) INTO _partition FROM collections WHERE id=_collection;
    q := format(
        $q$
            WITH a AS (
                SELECT 
                    jsonb_schema_agg(content->'properties')->'properties' as properties
                FROM 
                    %I 
            ), b AS (
                SELECT
                    key,
                    value,
                    jsonb_path_query(value, '$.enum') AS enum,
                    jsonb_path_query(value, '$.description') as description,
                    jsonb_path_query(value, '$.minimum') as minimum,
                    jsonb_path_query(value, '$.maximum') as maximum
                FROM jsonb_each((SELECT * FROM a))
            )
            SELECT key, (
                CASE 
                    WHEN enum IS NOT NULL THEN
                        enum
                    WHEN description IS NOT NULL THEN
                        jsonb_build_object('minimum', substring(description::text, 'minimum=\\"(\S+)\\"'), 
                                           'maximum', substring(description::text, 'maximum=\\"(\S+)\\"'))
                    WHEN minimum IS NOT NULL and maximum IS NOT NULL THEN
                        jsonb_build_object('minimum', minimum, 
                                           'maximum', maximum)
                    ELSE
                        value
                END
            ) FROM b;
        $q$,
        _partition,
        _collection
    );
    RETURN QUERY EXECUTE q;
END; $$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Update summaries for a given collection
CREATE OR REPLACE FUNCTION update_summaries(_collection text) RETURNS void as $$
    UPDATE collections
    SET content = jsonb_set(content, '{summaries}', (
        SELECT jsonb_object_agg(property, summary) FROM discover_summaries(_collection)
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
