-- Functions to build a json schema that describes the data in a json element.
-- TODO: make this file its own extension and pull it out into a different project.

-- Return a timestamp from a jsonb if it can be cast to a timestamp and NULL otherwise
CREATE OR REPLACE FUNCTION _jsonb_to_timestamp(s jsonb) RETURNS timestamp AS $$
BEGIN
    RETURN s::text::timestamp;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END; $$ LANGUAGE PLPGSQL;

-- NOTE: the SPLITHERE comments are used to divide this script into sections with one SQL command per section
--       this allows this script to be executed one command at a time when the app starts.
-- SPLITHERE --

-- Return a json schema that describes a range of dates.
-- Note: the first argument can either be a jsonb date string or a json schema, the second argument is a 
--       jsonb date string.
-- Note: Dates are formatted as strings and json schemas only support minumum/maximum for numeric types so 
--       minimum and maximum dates are provided as epoch seconds (in the "minimum" and "maximum" fields) and
--       as strings in the description field.
CREATE OR REPLACE FUNCTION _datetime_schema(jsonb, jsonb) RETURNS jsonb AS $$
DECLARE
    minimum jsonb;
    maximum jsonb;
BEGIN
    CASE 
        WHEN jsonb_typeof($1) = 'object' AND $1 ? '__is_summary' THEN
            minimum = '1';
            maximum = '2';
            SELECT format('"%s"', substring(($1->'description')::text, 'minimum=\\"(\S+)\\"')) INTO minimum;
            SELECT format('"%s"', substring(($1->'description')::text, 'maximum=\\"(\S+)\\"')) INTO maximum;
        ELSE
            minimum = $1;
            maximum = $1;
    END CASE;
    CASE
        -- note: RFC 3339 date strings will sort lexicographically
        WHEN maximum::text < $2::text THEN
            maximum = $2;
        WHEN minimum::text > $2::text THEN
            minimum = $2;
        ELSE
            -- noop
    END CASE;
    RETURN jsonb_build_object(
        'minimum', (SELECT extract(epoch FROM _jsonb_to_timestamp(minimum))),
        'maximum', (SELECT extract(epoch FROM _jsonb_to_timestamp(maximum))),
        'type', 'string',
        'format','date-time',
        'pattern', '(\+00:00|Z)$',
        'description',format('Datetime. minimum=%s maximum=%s', minimum, maximum),
        '__is_summary', TRUE
    );
END; $$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Return an array that contains multiple json schemas (like the value of an "anyOf" field) with the 
-- json schema that describes the second argument inserted into the array so that the array stays
-- as concise as possible.
-- Note: the first argument must be an array that contains json schemas, the second argument must be a
--       jsonb element.
-- For example:
--    schema = '[{"type": "string", "enum": ["a", "b"]}, {"type": "number", "minimum": 3, "maximum": 5}]'
--    _condense_anyOf(schema, '"c"') = '[{"type": "string", "enum": ["a", "b", "c"]}, {"type": "number", "minimum": 3, "maximum": 5}]'
--    _condense_anyOf(schema, '"a"') = schema
--    _condense_anyOf(schema, '10') -> '[{"type": "string", "enum": ["a", "b"]}, {"type": "number", "minimum": 3, "maximum": 10}]'
--    _condense_anyOf(schema, '{}') -> '[{"type": "string", "enum": ["a", "b"]}, {"type": "number", "minimum": 3, "maximum": 5}, {"type": "object", "properties": {}}]'
CREATE OR REPLACE FUNCTION _condense_anyOf(jsonb, jsonb) RETURNS jsonb AS $$
DECLARE
    best_match jsonb;
    best_match_index text;
BEGIN
    CASE 
        WHEN $1 IS NULL THEN
            RETURN $2;
        ELSE
            SELECT jsonb_object_agg(ord, new) FROM (
                SELECT length(new::text) - length(value::text) AS diff, new, ord
                FROM (SELECT value, _jsonb_schema(value, $2) AS new, ordinality - 1 AS ord
                    FROM jsonb_array_elements($1) WITH ORDINALITY) AS a 
                ORDER BY diff
                LIMIT 1
            ) AS a INTO best_match;
            SELECT jsonb_object_keys(best_match)::text INTO best_match_index;
            RETURN jsonb_set($1, array[best_match_index], best_match->best_match_index);
    END CASE;
END; $$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Aggregate function that calls _condense_anyOf as the SFUNC
-- Note: the first item passed to this aggregate function must be an array that contains json schemas
CREATE OR REPLACE AGGREGATE _condense_anyOf_agg (jsonb) (
    SFUNC = _condense_anyOf,
    STYPE = jsonb
);

-- SPLITHERE --


-- Create a json schema that describes the data in the first and second arguments together.
-- This function is primarily used by the _jsonb_schema_agg aggregate function to a single schema from
-- multiple similar jsonb objects.
-- Note: the first argument can either be a jsonb element or a json schema, the second argument is a 
--       jsonb element.
CREATE OR REPLACE FUNCTION _jsonb_schema(jsonb, jsonb) RETURNS jsonb AS $$
DECLARE
    json_type1 text;
    json_type2 text;
    result jsonb;
BEGIN
    json_type1 = jsonb_typeof($1);
    json_type2 = jsonb_typeof($2);
    CASE 
        WHEN $1 IS NULL THEN
            -- initial case when called from jsonb_concat_deep_agg
            result = _jsonb_schema($2); 
        WHEN $2 IS NULL THEN
            result = _jsonb_schema($1);
        WHEN $1 ? '__is_summary' THEN
            CASE
                WHEN $1 ? 'properties' AND json_type2 = 'object' THEN
                    result = jsonb_build_object(
                        '__is_summary', TRUE, 
                        'type', 'object',
                        'properties', COALESCE(
                            (SELECT jsonb_object_agg(key, values) FROM (
                                SELECT key, _jsonb_schema_agg(value) as values
                                FROM (
                                    SELECT key, value FROM jsonb_each($1->'properties')
                                    UNION ALL
                                    SELECT key, value FROM jsonb_each($2)
                                ) AS a
                                GROUP BY key
                            ) AS b),
                            jsonb_build_object()));
                WHEN $1 @> '{"type": "number"}' AND json_type2 = 'number' THEN
                    result = jsonb_build_object(
                        'minimum', (CASE WHEN ($1->'minimum')::numeric < $2::numeric THEN $1->'minimum' ELSE $2 END),
                        'maximum', (CASE WHEN ($1->'maximum')::numeric > $2::numeric THEN $1->'maximum' ELSE $2 END),
                        'type', 'number',
                        '__is_summary', TRUE
                    );
                WHEN $1 @> '{"format": "date-time"}' AND _jsonb_to_timestamp($2) IS NOT NULL THEN
                    result = _datetime_schema($1, $2);
                WHEN $1 @> '{"type": "array"}' AND json_type2 = 'array' THEN
                    CASE 
                        WHEN $1->'items' ? 'enum' THEN
                            result = jsonb_build_object(
                                'items', (SELECT _jsonb_schema_agg(value) FROM (
                                            SELECT value 
                                            FROM 
                                                jsonb_array_elements(jsonb_path_query_array(jsonb_build_array($1->'items'->'enum', $2), '$[*][*]'))
                                            WITH ORDINALITY
                                            GROUP BY value
                                            ORDER BY min(ordinality)
                                        ) as a),
                                'type', 'array',
                                '__is_summary', TRUE
                            );
                        WHEN $1->'items' ? 'anyOf' THEN
                            result = jsonb_build_object(
                                'items', jsonb_build_object('__is_summary', TRUE,
                                                            'anyOf', (SELECT _condense_anyOf_agg(elem) 
                                                                      FROM jsonb_array_elements(
                                                                                jsonb_path_query_array(
                                                                                    jsonb_build_array($1->'items'->'anyOf', $2), 
                                                                                    '$[*][*]'))),
                                'type', 'array',
                                '__is_summary', TRUE
                            ));
                        WHEN $1->'items' = jsonb_build_array() THEN
                            result = _jsonb_schema($2);
                        ELSE
                            result = _jsonb_schema(
                                        jsonb_path_query_array(
                                            jsonb_build_array(
                                                jsonb_build_array($1->'items'->'minimum', $1->'items'->'maximum'),
                                                $2
                                            ), '$[*][*]'));
                    END CASE;
                WHEN $1 ? 'enum' AND json_type2 = jsonb_typeof($1->'enum'->0) THEN
                    result = jsonb_build_object(
                        'enum', (
                            SELECT jsonb_agg(elems) FROM (
                                SELECT DISTINCT
                                    jsonb_array_elements(jsonb_path_query_array(jsonb_build_array($1->'enum', $2), '$[*][*]')) AS elems
                            ) AS a
                        ),
                        'type', json_type2,
                        '__is_summary', TRUE
                    );
                WHEN $1 ? 'anyOf' THEN
                    result = jsonb_build_object('anyOf', _condense_anyOf($1->'anyOf', $2), '__is_summary', TRUE);
                ELSE
                    result = jsonb_build_object('anyOf', jsonb_build_array($1, _jsonb_schema($2)),
                                                '__is_summary', TRUE);
            END CASE;
        ELSE
            CASE 
                WHEN json_type1 = 'object' AND json_type2 = 'object' THEN
                    result = jsonb_build_object(
                        '__is_summary', TRUE, 
                        'type', 'object',
                        'properties', COALESCE(
                            (SELECT jsonb_object_agg(key, values) FROM (
                                SELECT key, _jsonb_schema_agg(value) as values
                                FROM (
                                    SELECT key, value FROM jsonb_each($1)
                                    UNION ALL
                                    SELECT key, value FROM jsonb_each($2)
                                ) AS a
                                GROUP BY key
                            ) AS b), 
                            jsonb_build_object()));
                WHEN json_type1 = 'number' AND json_type2 = 'number' THEN
                    result = jsonb_build_object(
                        'minimum', (CASE WHEN $1::numeric < $2::numeric THEN $1 ELSE $2 END),
                        'maximum', (CASE WHEN $1::numeric > $2::numeric THEN $1 ELSE $2 END),
                        'type', 'number',
                        '__is_summary', TRUE
                    );
                WHEN _jsonb_to_timestamp($1) IS NOT NULL AND _jsonb_to_timestamp($2) IS NOT NULL THEN
                    result = _datetime_schema($1, $2);
                WHEN json_type1 = 'array' AND json_type2 = 'array' THEN
                    result = jsonb_build_object(
                        'items', COALESCE((SELECT _jsonb_schema_agg(elems) FROM (
                                            SELECT DISTINCT
                                                jsonb_array_elements(jsonb_path_query_array(jsonb_build_array($1, $2), '$[*][*]')) 
                                                AS elems
                                            ) as a),
                                          jsonb_build_array()),
                        'type', 'array',
                        '__is_summary', TRUE
                    );
                WHEN json_type1 = json_type2 THEN
                    result = jsonb_build_object(
                        'enum', jsonb_build_array($1, $2),
                        'type', json_type1,
                        '__is_summary', TRUE
                    );
                ELSE
                    result = jsonb_build_object('anyOf', jsonb_build_array(_jsonb_schema($1), _jsonb_schema($2)),
                                                '__is_summary', TRUE);
            END CASE;
        END CASE;
    RETURN result;
END;
$$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Create a json schema that describes the data in the argument.
-- Note: includes the __is_summary keys (see _clean_jsonb_schema)
CREATE OR REPLACE FUNCTION _jsonb_schema(jsonb) RETURNS jsonb AS $$
DECLARE
    json_type text;
    result jsonb;
BEGIN
    json_type = jsonb_typeof($1);
    CASE
        WHEN $1 ? '__is_summary' THEN
            result = $1;
        WHEN json_type = 'object' THEN
            result = _jsonb_schema($1, jsonb_build_object());
        WHEN json_type = 'array' THEN
            result = _jsonb_schema($1, jsonb_build_array());
        WHEN json_type = 'number' OR _jsonb_to_timestamp($1) IS NOT NULL THEN
            result = _jsonb_schema($1, $1);
        ELSE
            result = jsonb_build_object(
                'enum', jsonb_build_array($1),
                'type', json_type,
                '__is_summary', TRUE
            );
    END CASE;
    RETURN result;
END;
$$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Returns a copy of the json shema generated by _jsonb_schema or _jsonb_schema_agg
-- with the __is_summary keys removed recursively
-- Note: __is_summary keys are used to keep track of the schema state when it is being built.
--       These keys are not intended to be part of the final schema or shown to the end-user.
CREATE OR REPLACE FUNCTION _clean_jsonb_schema(jsonb) RETURNS jsonb AS $$
DECLARE
    result jsonb;
BEGIN
    CASE jsonb_typeof($1)
        WHEN 'object' THEN
            result = COALESCE((SELECT jsonb_object_agg(key, _clean_jsonb_schema(value)) FROM jsonb_each($1 - '__is_summary')), 
                               jsonb_build_object());
        WHEN 'array' THEN
            result = COALESCE((SELECT jsonb_agg(_clean_jsonb_schema(elem)) FROM jsonb_array_elements($1) as elem),
                               jsonb_build_array());
        ELSE
            result = $1;
    END CASE;
    RETURN result;
END;
$$ LANGUAGE PLPGSQL;

-- SPLITHERE --

-- Aggregate function that creates a json schema that describes multiple similar jsonb objects.
-- Note: includes the __is_summary keys (see _clean_jsonb_schema)
CREATE OR REPLACE AGGREGATE _jsonb_schema_agg (jsonb) (
    SFUNC = _jsonb_schema,
    STYPE = jsonb
);

-- SPLITHERE --

-- Create a json schema that describes the data in the argument.
CREATE OR REPLACE FUNCTION jsonb_schema(jsonb) RETURNS jsonb AS $$
    SELECT _clean_jsonb_schema(_jsonb_schema($1));
$$ LANGUAGE SQL;

-- SPLITHERE --

-- Aggregate function that creates a json schema that describes multiple similar jsonb objects.
CREATE OR REPLACE AGGREGATE jsonb_schema_agg (jsonb) (
    SFUNC = _jsonb_schema,
    STYPE = jsonb,
    FINALFUNC = _clean_jsonb_schema
);
