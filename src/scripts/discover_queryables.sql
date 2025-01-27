-- This file contains functions to extract queryables definitions from existing items in the database.
-- It inspects items and builds a json schema that describes the items in the collection.
-- This file uses functions that are defined in the json_schema_builder.sql file (ensure those functions are also loaded).
-- Loosely based on https://github.com/stac-utils/pgstac/blob/e4ba4eee5c0503d16f303cbe9cfa63f25fa3f003/sql/002a_queryables.sql#L182

-- Analogous to the missing_queryables function but gets all queryables (not just the missing ones).
-- This also generates more informative JSON schemas including date ranges, property enums, and more complex json schemas
CREATE OR REPLACE FUNCTION discover_queryables(_collection text, _tablesample int DEFAULT 5, _minimal boolean DEFAULT FALSE) RETURNS TABLE(collection text, name text, definition jsonb, property_wrapper text) AS $$
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
            WITH a AS (
                SELECT 
                    jsonb_schema_agg(content->'properties')->'properties' as properties
                FROM 
                    %I 
                TABLESAMPLE SYSTEM(%L)
            )
            SELECT
                %L,
                key,
                value,
                CASE value->'type'
                    WHEN '"number"' THEN 'to_float'
                    WHEN '"array"' THEN 'to_text_array'
                    WHEN '"object"' THEN NULL
                    ELSE 'to_text'
                END
            FROM jsonb_each((SELECT * FROM a))
            WHERE (
                CASE %L::boolean
                    WHEN TRUE THEN value @> '{"type": "string"}' OR value @> '{"type": "number"}'
                    ELSE TRUE
                END
            );
        $q$,
        _partition,
        _tablesample,
        _collection,
        _minimal
    );
    RETURN QUERY EXECUTE q;
END;
$$ LANGUAGE PLPGSQL;

-- NOTE: the SPLITHERE comments are used to divide this script into sections with one SQL command per section
--       this allows this script to be executed one command at a time when the app starts.
-- SPLITHERE --

-- Analogous to the missing_queryables function but gets all queryables (not just the missing ones).
-- This also generates more informative JSON schemas including: bbox bounds, date ranges, property enums
CREATE OR REPLACE FUNCTION discover_queryables(_tablesample int DEFAULT 5, _minimal boolean DEFAULT FALSE) RETURNS TABLE(collection_ids text[], name text, definition jsonb, property_wrapper text) AS $$
    SELECT
        ARRAY[collection],
        name,
        definition,
        property_wrapper
    FROM
        collections
        JOIN LATERAL
        discover_queryables(id, _tablesample, _minimal) c
        ON TRUE
    ;
$$ LANGUAGE SQL;

-- SPLITHERE --

-- Updates the queryables table by discovering all queryables that exist in the database and inserts them
-- all into the queryables table. 
-- This function is idempotent.
CREATE OR REPLACE FUNCTION update_queryables(_minimal boolean DEFAULT FALSE) RETURNS void AS $$
    INSERT INTO 
        queryables (collection_ids, name, definition, property_wrapper)
    SELECT * FROM discover_queryables(100, _minimal)
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
