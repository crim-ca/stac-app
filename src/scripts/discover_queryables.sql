-- based on https://github.com/stac-utils/pgstac/blob/e4ba4eee5c0503d16f303cbe9cfa63f25fa3f003/sql/002a_queryables.sql#L182

-- Get minimum and maximum values for all axes for the bbox of a given collection.
-- Intended to be called by the discover_queryables function
CREATE OR REPLACE FUNCTION discover_bbox_queryables(_collection text, _tablesample int, _partition text) RETURNS TABLE(collection text, name text, definition jsonb, property_wrapper text) AS $$
DECLARE
    q text;
BEGIN
    q := format(
        $q$
            WITH t AS (
                SELECT
                    content->'bbox' AS bbox
                FROM
                    %I
                TABLESAMPLE SYSTEM(%L)
            ), p AS (
                SELECT
                        CASE jsonb_array_length(bbox)
                        WHEN 4 THEN jsonb_build_object('min_axis_1',bbox->0,
                                                       'min_axis_2',bbox->1,
                                                       'min_axis_3',NULL,
                                                       'max_axis_1',bbox->2,
                                                       'max_axis_2',bbox->3,
                                                       'max_axis_3',NULL)
                        WHEN 6 THEN jsonb_build_object('min_axis_1',bbox->0,
                                                       'min_axis_2',bbox->1,
                                                       'min_axis_3',bbox->2,
                                                       'max_axis_1',bbox->3,
                                                       'max_axis_2',bbox->4,
                                                       'max_axis_3',bbox->5)
                        ELSE NULL
                    END 
                    AS values
                FROM t
            ), j AS (
                SELECT DISTINCT ON (key, value)
                    key,
                    value
                FROM p
                JOIN LATERAL jsonb_each(values) ON TRUE
            ), k as (
                SELECT
                    min(nullif(value, 'null')::float) as minvalue,
                    max(nullif(value, 'null')::float) as maxvalue,
                    key
                FROM j
                GROUP BY key
            )
            SELECT
                %L,
                'bbox',
                jsonb_build_object('oneOf', jsonb_build_array(
                    jsonb_build_object('type', 'array', 
                                       'prefixItems', jsonb_build_array(
                                            jsonb_build_object('type', 'number', 
                                                               'minimum', (SELECT minvalue FROM k WHERE key='min_axis_1'), 
                                                               'maximum', (SELECT maxvalue FROM k WHERE key='max_axis_1')),
                                            jsonb_build_object('type', 'number', 
                                                               'minimum', (SELECT minvalue FROM k WHERE key='min_axis_2'), 
                                                               'maximum', (SELECT maxvalue FROM k WHERE key='max_axis_2')),
                                            jsonb_build_object('type', 'number', 
                                                               'minimum', (SELECT minvalue FROM k WHERE key='min_axis_1'), 
                                                               'maximum', (SELECT maxvalue FROM k WHERE key='max_axis_1')),
                                            jsonb_build_object('type', 'number', 
                                                               'minimum', (SELECT minvalue FROM k WHERE key='min_axis_2'), 
                                                               'maximum', (SELECT maxvalue FROM k WHERE key='max_axis_2'))
                                       ),
                                       'minItems', 4,
                                       'maxItems', 4),
                    jsonb_build_object('type', 'array',
                                       'prefixItems', jsonb_build_array(
                                            jsonb_build_object('type', 'number', 
                                                               'minimum', (SELECT minvalue FROM k WHERE key='min_axis_1'), 
                                                               'maximum', (SELECT maxvalue FROM k WHERE key='max_axis_1')),
                                            jsonb_build_object('type', 'number', 
                                                               'minimum', (SELECT minvalue FROM k WHERE key='min_axis_2'), 
                                                               'maximum', (SELECT maxvalue FROM k WHERE key='max_axis_2')),
                                            jsonb_build_object('type', 'number', 
                                                               'minimum', (SELECT minvalue FROM k WHERE key='min_axis_3'), 
                                                               'maximum', (SELECT maxvalue FROM k WHERE key='max_axis_3')),
                                            jsonb_build_object('type', 'number', 
                                                               'minimum', (SELECT minvalue FROM k WHERE key='min_axis_1'), 
                                                               'maximum', (SELECT maxvalue FROM k WHERE key='max_axis_1')),
                                            jsonb_build_object('type', 'number', 
                                                               'minimum', (SELECT minvalue FROM k WHERE key='min_axis_2'), 
                                                               'maximum', (SELECT maxvalue FROM k WHERE key='max_axis_2')),
                                            jsonb_build_object('type', 'number', 
                                                               'minimum', (SELECT minvalue FROM k WHERE key='min_axis_3'), 
                                                               'maximum', (SELECT maxvalue FROM k WHERE key='max_axis_3'))
                                       ),
                                       'minItems', 4,
                                       'maxItems', 4)
                )),
                NULL;
        $q$,
        _partition,
        _tablesample,
        _collection
    );
    RETURN QUERY EXECUTE q;
END;
$$ LANGUAGE PLPGSQL;

-- NOTE: the SPLITHERE comments are used to divide this script into sections with one SQL command per section
--       this allows this script to be executed one command at a time when the app starts.
-- SPLITHERE --

-- Get minimum and maximum values for the date properties.
-- Dates are formatted as RFC 3339 strings and JSON schemas only support minumum/maximum for numeric types so 
-- minimum and maximum dates are provided as epoch seconds (in the "minimum" and "maximum" fields) and as RFC 3339
-- strings in the "description" field.
-- Intended to be called by the discover_queryables function
CREATE OR REPLACE FUNCTION discover_range_queryables(_collection text, _tablesample int, _partition text) RETURNS TABLE(collection text, name text, definition jsonb, property_wrapper text) AS $$
DECLARE
    q text;
BEGIN
    q := format(
        $q$
            WITH t AS (
                SELECT
                    content->'properties' AS properties
                FROM
                    %I
                TABLESAMPLE SYSTEM(%L)
            ), p AS (
                SELECT DISTINCT ON (key, value)
                    key,
                    value
                FROM t
                JOIN LATERAL jsonb_each(properties) ON TRUE
                -- see: https://schemas.stacspec.org/v1.0.0/item-spec/json-schema/datetime.json#/properties/datetime
                WHERE key IN ('datetime', 'end_datetime', 'start_datetime', 'created', 'updated')
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
                %L,
                key,
                -- copies https://github.com/stac-utils/pgstac/blob/e4ba4eee5c0503d16f303cbe9cfa63f25fa3f003/sql/002a_queryables.sql#L16
                jsonb_build_object('title','Acquired',
                                   'type','string',
                                   'format','date-time',
                                   'pattern', '(\+00:00|Z)$',
                                   'minimum', (SELECT extract(epoch from minvalue::timestamp)),
                                   'maximum', (SELECT extract(epoch from maxvalue::timestamp)),
                                   'description',format('Datetime. minimum=%%s maximum=%%s', minvalue, maxvalue)),
                NULL
            FROM j;
        $q$,
        _partition,
        _tablesample,
        _collection
    );
    RETURN QUERY EXECUTE q;
END;
$$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Get enum values for most properties (not including date values).
-- Intended to be called by the discover_queryables function
CREATE OR REPLACE FUNCTION discover_enum_queryables(_collection text, _tablesample int, _partition text) RETURNS TABLE(collection text, name text, definition jsonb, property_wrapper text) AS $$
DECLARE
    q text;
BEGIN
    q := format(
        $q$
            WITH t AS (
                SELECT
                    content->'properties' AS properties
                FROM
                    %I
                TABLESAMPLE SYSTEM(%L)
            ), p AS (
                SELECT DISTINCT ON (key, value)
                    key,
                    value
                FROM t
                JOIN LATERAL jsonb_each(properties) ON TRUE
                -- see: https://schemas.stacspec.org/v1.0.0/item-spec/json-schema/datetime.json#/properties/datetime
                WHERE key NOT IN ('datetime', 'end_datetime', 'start_datetime', 'created', 'updated')
            ), j as (
                SELECT
                    array_agg(value) as values,
                    key
                FROM p
                GROUP BY key
            )
            SELECT
                %L,
                key,
                jsonb_build_object('type',jsonb_typeof(values[1]),'enum',values) as definition,
                CASE jsonb_typeof(values[1])
                    WHEN 'number' THEN 'to_float'
                    WHEN 'array' THEN 'to_text_array'
                    ELSE 'to_text'
                END
            FROM j;
        $q$,
        _partition,
        _tablesample,
        _collection
    );
    RETURN QUERY EXECUTE q;
END;
$$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Analogous to the missing_queryables function but gets all queryables (not just the missing ones).
-- This also generates more informative JSON schemas including: bbox bounds, date ranges, property enums
CREATE OR REPLACE FUNCTION discover_queryables(_collection text, _tablesample int DEFAULT 5) RETURNS TABLE(collection text, name text, definition jsonb, property_wrapper text) AS $$
DECLARE
    q text;
    _partition text;
    explain_json json;
    psize bigint;
BEGIN
    SELECT format('_items_%s', key) INTO _partition FROM collections WHERE id=_collection;

    EXECUTE format('EXPLAIN (format json) SELECT 1 FROM %I;', _partition)
    INTO explain_json;
    psize := explain_json->0->'Plan'->'Plan Rows';
    IF _tablesample * .01 * psize < 10 THEN
        _tablesample := 100;
    END IF;
    RAISE NOTICE 'Using tablesample % to find queryables from % % that has ~% rows', _tablesample, _collection, _partition, psize;
    q := format(
        $q$
            SELECT * FROM discover_enum_queryables(%1$L, %2$L, %3$L)
            UNION ALL
            SELECT * FROM discover_range_queryables(%1$L, %2$L, %3$L)
            UNION ALL
            SELECT * FROM discover_bbox_queryables(%1$L, %2$L, %3$L);
        $q$,
        _collection,
        _tablesample,
        _partition
    );

    RETURN QUERY EXECUTE q;
END;
$$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Analogous to the missing_queryables function but gets all queryables (not just the missing ones).
-- This also generates more informative JSON schemas including: bbox bounds, date ranges, property enums
CREATE OR REPLACE FUNCTION discover_queryables(_tablesample int DEFAULT 5) RETURNS TABLE(collection_ids text[], name text, definition jsonb, property_wrapper text) AS $$
    SELECT
        ARRAY[collection],
        name,
        definition,
        property_wrapper
    FROM
        collections
        JOIN LATERAL
        discover_queryables(id, _tablesample) c
        ON TRUE
    ;
$$ LANGUAGE SQL;

-- SPLITHERE --

-- Updates the queryables table by discovering all queryables that exist in the database and inserts them
-- all into the queryables table. 
-- This function is idempotent.
CREATE OR REPLACE FUNCTION update_queryables() RETURNS void AS $$
    INSERT INTO 
        queryables (collection_ids, name, definition, property_wrapper)
    SELECT * FROM discover_queryables(100)
    ON CONFLICT (collection_ids, name) DO UPDATE
        SET collection_ids=EXCLUDED.collection_ids,
            name=EXCLUDED.name,
            definition=EXCLUDED.definition,
            property_wrapper=EXCLUDED.property_wrapper
    ;
$$ LANGUAGE SQL;

-- SPLITHERE --

-- Updates the get_queryables function to accomodate the slight differences in the way that JSON schemas
-- are created using the functions above. These differences include: 
--    - each row in the queryables table corresponds to one collection if the collection_ids row is not null
--    - the name column in the queryables table can have different JSON schema definitions for different collections
CREATE OR REPLACE FUNCTION get_queryables(_collection_ids text[] DEFAULT NULL) RETURNS jsonb AS $$
BEGIN
    -- Build up queryables if the input contains valid collection ids or is empty
    IF EXISTS (
        SELECT 1 FROM collections
        WHERE
            _collection_ids IS NULL
            OR cardinality(_collection_ids) = 0
            OR id = ANY(_collection_ids)
    )
    THEN
        RETURN (
            SELECT
                jsonb_build_object(
                    '$schema', 'http://json-schema.org/draft-07/schema#',
                    '$id', 'https://example.org/queryables',
                    'type', 'object',
                    'title', 'STAC Queryables.',
                    'properties', jsonb_object_agg(name, definition)
                )
            FROM (
                SELECT
                    name,
                    (
                        CASE COUNT(definition)
                        WHEN 1 THEN 
                            jsonb_agg(definition)->0
                        ELSE
                            jsonb_build_object('anyOf', jsonb_agg(definition))
                        END
                    ) AS definition
                FROM (
                        SELECT DISTINCT ON (definition, name) 
                            definition,
                            name
                        FROM queryables
                        WHERE
                            _collection_ids IS NULL OR
                            cardinality(_collection_ids) = 0 OR
                            collection_ids IS NULL OR
                            _collection_ids && collection_ids
                ) AS a
                GROUP BY name
            ) AS b
        );
    ELSE
        RETURN NULL;
    END IF;
END;
$$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Replace the unique constraint on queryables.name with a unique constraint on both 
-- queryables.name AND queryables.collection_ids. This allows us to store different definitions for different
-- collections. For example, if one collection contains a different list of possible "variable_id" properties.
ALTER TABLE queryables DROP constraint IF EXISTS queryables_name_key;

-- SPLITHERE --

DO LANGUAGE PLPGSQL $$ 
DECLARE
    error_msg text;
BEGIN
    ALTER TABLE queryables ADD constraint queryables_collections_ids_name_key UNIQUE (collection_ids, name);
EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS error_msg = MESSAGE_TEXT;
    RAISE NOTICE '%s', error_msg;
END
$$;
