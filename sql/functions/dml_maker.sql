/*
 *  DML maker function.
 */
CREATE FUNCTION dml_maker(
    p_src_table text
    , p_dblink_id int
    , p_dest_table text DEFAULT NULL
    , p_index boolean DEFAULT true
    , p_filter text[] DEFAULT NULL
    , p_condition text DEFAULT NULL
    , p_pulldata boolean DEFAULT true
    , p_pk_name text[] DEFAULT NULL
    , p_pk_type text[] DEFAULT NULL
    , p_debug boolean DEFAULT false) 
RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

v_create_trig               text;
v_data_source               text;
v_dblink_name               text;
v_dblink_schema             text;
v_dest_schema_name          text;
v_dest_table_name           text;
v_exists                    int := 0;
v_field                     text;
v_insert_refresh_config     text;
v_jobmon                    boolean;
v_key_type                  text;
v_old_search_path           text;
v_pk_counter                int := 1;
v_pk_name                   text[] := p_pk_name;
v_pk_name_csv               text;
v_pk_name_n_type            text[];
v_pk_type                   text[] := p_pk_type;
v_pk_value                  text := '';
v_remote_exists             int := 0;
v_remote_grants_sql         text;
v_remote_key_sql            text;
v_remote_q_index            text;
v_remote_q_table            text;
v_row                       record;
v_source_queue_counter      int := 0;
v_source_queue_exists       text;
v_source_queue_function     text;
v_source_queue_table        text;
v_source_queue_trigger      text;
v_src_schema_name            text;
v_src_table_name             text;
v_src_table_template        text;
v_table_exists              boolean;
v_trigger_func              text;

BEGIN

v_dblink_name := @extschema@.check_name_length('mimeo_dml_maker_'||p_src_table);

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_dblink_schema||',public'',''false'')';

IF (p_pk_name IS NULL AND p_pk_type IS NOT NULL) OR (p_pk_name IS NOT NULL AND p_pk_type IS NULL) THEN
    RAISE EXCEPTION 'Cannot manually set primary/unique key field(s) without defining type(s) or vice versa';
END IF;

SELECT data_source INTO v_data_source FROM @extschema@.dblink_mapping_mimeo WHERE data_source_id = p_dblink_id; 
IF NOT FOUND THEN
    RAISE EXCEPTION 'Database link ID is incorrect %', p_dblink_id; 
END IF;

IF p_dest_table IS NULL THEN
    p_dest_table := p_src_table;
END IF;

IF position('.' in p_dest_table) > 0 AND position('.' in p_src_table) > 0 THEN
    -- Do nothing. Schema & table variable names set below after table is created
ELSE
    RAISE EXCEPTION 'Source (and destination) table must be schema qualified';
END IF;

PERFORM dblink_connect(v_dblink_name, @extschema@.auth(p_dblink_id));

SELECT schemaname ||'_'|| tablename, schemaname, tablename
INTO v_src_table_template, v_src_schema_name, v_src_table_name
FROM dblink(v_dblink_name, format('
            SELECT schemaname, tablename
            FROM (
                SELECT schemaname, tablename 
                FROM pg_catalog.pg_tables 
                WHERE schemaname ||''.''|| tablename = %L
                UNION
                SELECT schemaname, viewname AS tablename
                FROM pg_catalog.pg_views
                WHERE schemaname || ''.'' || viewname = %L
            ) tables LIMIT 1'
        , p_src_table, p_src_table) )
    t (schemaname text, tablename text);

IF v_src_table_template IS NULL THEN
    RAISE EXCEPTION 'Source table given (%) does not exist in configured source database', p_src_table;
END IF;

v_source_queue_table :=  check_name_length(v_src_table_template, '_q');
v_source_queue_function := check_name_length(v_src_table_template, '_mimeo_queue');
v_source_queue_trigger := check_name_length(v_src_table_template, '_mimeo_trig');

-- Automatically get source primary/unique key if none given
IF p_pk_name IS NULL AND p_pk_type IS NULL THEN
    SELECT key_type, indkey_names, indkey_types INTO v_key_type, v_pk_name, v_pk_type FROM fetch_replication_key(v_src_schema_name, v_src_table_name, v_dblink_name, p_debug);
END IF;

v_pk_name_csv := '"'||array_to_string(v_pk_name, '","')||'"';
PERFORM gdb(p_debug, 'v_key_type: '||COALESCE(v_key_type, ''));
PERFORM gdb(p_debug, 'v_pk_name: '||COALESCE(v_pk_name_csv, ''));
PERFORM gdb(p_debug, 'v_pk_type: '||COALESCE(array_to_string(v_pk_type, ','), ''));

IF v_pk_name IS NULL OR v_pk_type IS NULL THEN
    RAISE EXCEPTION 'Source table has no valid primary key or unique index';
END IF;

IF p_filter IS NOT NULL THEN
    FOREACH v_field IN ARRAY v_pk_name LOOP
        IF v_field = ANY(p_filter) THEN
            CONTINUE;
        ELSE
            RAISE EXCEPTION 'ERROR: filter list did not contain all columns that compose primary/unique key for source table %',p_src_table; 
        END IF;
    END LOOP;
END IF;

-- Do check for existing queue table(s) to support multiple destinations
SELECT tablename 
    INTO v_source_queue_exists 
FROM dblink(v_dblink_name
        , 'SELECT tablename 
        FROM pg_catalog.pg_tables 
        WHERE schemaname = ''@extschema@''
        AND tablename = '||quote_literal(v_source_queue_table)) t (tablename text);
WHILE v_source_queue_exists IS NOT NULL LOOP -- loop until a tablename that doesn't exist is found
    v_source_queue_counter := v_source_queue_counter + 1;
    IF v_source_queue_counter > 99 THEN
        RAISE EXCEPTION 'Limit of 99 queue tables for a single source table reached. No more destination tables possible (and HIGHLY discouraged)';
    END IF;
    v_source_queue_table := check_name_length(v_src_table_template, '_q'||to_char(v_source_queue_counter, 'FM00'));
    SELECT tablename 
        INTO v_source_queue_exists 
    FROM dblink(v_dblink_name
        , 'SELECT tablename 
        FROM pg_catalog.pg_tables 
        WHERE schemaname = ''@extschema@''
        AND tablename = '||quote_literal(v_source_queue_table)) t (tablename text);
    v_source_queue_function := check_name_length(v_src_table_template, '_mimeo_queue'||to_char(v_source_queue_counter, 'FM00'));
    v_source_queue_trigger := check_name_length(v_src_table_template, '_mimeo_trig'||to_char(v_source_queue_counter, 'FM00'));
END LOOP;

v_remote_q_table := format('CREATE TABLE %I.%I (', '@extschema@', v_source_queue_table);
    PERFORM gdb(p_debug, 'v_remote_q_table: '||v_remote_q_table);
WHILE v_pk_counter <= array_length(v_pk_name,1) LOOP
    v_remote_q_table := v_remote_q_table || format('%I', v_pk_name[v_pk_counter]) ||' '||v_pk_type[v_pk_counter];
    v_pk_counter := v_pk_counter + 1;
    IF v_pk_counter <= array_length(v_pk_name,1) THEN
        v_remote_q_table := v_remote_q_table || ', ';
    END IF;
END LOOP;
v_remote_q_table := v_remote_q_table || ', processed boolean)';
v_remote_q_index := format('CREATE INDEX ON %I.%I (', '@extschema@', v_source_queue_table) || v_pk_name_csv ||')';

v_pk_counter := 1;
v_trigger_func := format('CREATE FUNCTION %I.%I() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $_$ ', '@extschema@', v_source_queue_function);
    v_trigger_func := v_trigger_func || ' 
        BEGIN IF TG_OP = ''INSERT'' THEN ';
    v_pk_value := 'NEW."' || array_to_string(v_pk_name, '", NEW."') || '"';
    v_trigger_func := v_trigger_func || format(' 
            INSERT INTO %I.%I (', '@extschema@', v_source_queue_table) || v_pk_name_csv ||') VALUES ('||v_pk_value||'); ';
    v_trigger_func := v_trigger_func || ' 
        ELSIF TG_OP = ''UPDATE'' THEN ';
    -- UPDATE needs to insert the NEW values so reuse v_pk_value from INSERT operation
    v_trigger_func := v_trigger_func || format(' 
            INSERT INTO %I.%I (', '@extschema@', v_source_queue_table) || v_pk_name_csv ||') VALUES ('||v_pk_value||'); ';
    -- Only insert the old row if the new key doesn't match the old key. This handles edge case when only one column of a composite key is updated
    v_trigger_func := v_trigger_func || ' 
            IF ';
    FOREACH v_field IN ARRAY v_pk_name LOOP
        IF v_pk_counter > 1 THEN
            v_trigger_func := v_trigger_func || ' OR ';
        END IF;
        v_trigger_func := v_trigger_func || format(' NEW.%I != OLD.%I ', v_field, v_field);
        v_pk_counter := v_pk_counter + 1;
    END LOOP;
    v_trigger_func := v_trigger_func || ' THEN ';
    v_pk_value := 'OLD."' || array_to_string(v_pk_name, '", OLD."') || '"';
    v_trigger_func := v_trigger_func || format(' 
                INSERT INTO %I.%I (', '@extschema@', v_source_queue_table)|| v_pk_name_csv ||') VALUES ('||v_pk_value||'); ';
    v_trigger_func := v_trigger_func || ' 
            END IF;';
    v_trigger_func := v_trigger_func || ' 
        ELSIF TG_OP = ''DELETE'' THEN ';
    -- DELETE needs to insert the OLD values so reuse v_pk_value from UPDATE operation
    v_trigger_func := v_trigger_func || format(' 
            INSERT INTO %I.%I (', '@extschema@', v_source_queue_table)|| v_pk_name_csv ||') VALUES ('||v_pk_value||'); ';
v_trigger_func := v_trigger_func || ' 
        END IF; RETURN NULL; END $_$;';

v_create_trig := format('CREATE TRIGGER %I AFTER INSERT OR DELETE OR UPDATE', v_source_queue_trigger);
IF p_filter IS NOT NULL THEN
    v_create_trig := v_create_trig || ' OF "'||array_to_string(p_filter, '","')||'"';
END IF;
v_create_trig := v_create_trig || format(' ON %I.%I FOR EACH ROW EXECUTE PROCEDURE %I.%I()', v_src_schema_name, v_src_table_name, '@extschema@', v_source_queue_function);

RAISE NOTICE 'Creating objects on source database (function, trigger & queue table)...';

PERFORM gdb(p_debug, 'v_remote_q_table: '||v_remote_q_table);
PERFORM dblink_exec(v_dblink_name, v_remote_q_table);
PERFORM gdb(p_debug, 'v_remote_q_index: '||v_remote_q_index);
PERFORM dblink_exec(v_dblink_name, v_remote_q_index);
PERFORM gdb(p_debug, 'v_trigger_func: '||v_trigger_func);
PERFORM dblink_exec(v_dblink_name, v_trigger_func);
PERFORM gdb(p_debug, 'v_create_trig: '||v_create_trig);
PERFORM dblink_exec(v_dblink_name, v_create_trig);

SELECT 
    CASE 
        WHEN count(nspname) > 0 THEN true
        ELSE false
    END AS jobmon_schema
INTO v_jobmon 
FROM pg_namespace n, pg_extension e WHERE e.extname = 'pg_jobmon' AND e.extnamespace = n.oid;

v_insert_refresh_config := 'INSERT INTO @extschema@.refresh_config_dml(
        source_table
        , dest_table
        , dblink
        , control
        , pk_name
        , pk_type
        , last_run
        , filter
        , condition
        , jobmon) 
    VALUES('||quote_literal(p_src_table)
        ||', '||quote_literal(p_dest_table)
        ||', '||p_dblink_id
        ||', '||quote_literal('@extschema@.'||v_source_queue_table)
        ||', '||quote_literal(v_pk_name)
        ||', '||quote_literal(v_pk_type)
        ||', '||quote_literal(CURRENT_TIMESTAMP)
        ||', '||COALESCE(quote_literal(p_filter), 'NULL')
        ||', '||COALESCE(quote_literal(p_condition), 'NULL')
        ||', '||v_jobmon||')';
PERFORM gdb(p_debug, 'v_insert_refresh_config: '||v_insert_refresh_config);
EXECUTE v_insert_refresh_config;

SELECT p_table_exists FROM manage_dest_table(p_dest_table, NULL, v_dblink_name , p_debug) INTO v_table_exists;

SELECT schemaname, tablename 
INTO v_dest_schema_name, v_dest_table_name 
FROM pg_catalog.pg_tables 
WHERE schemaname||'.'||tablename = p_dest_table;

IF p_pulldata AND v_table_exists = false THEN
    RAISE NOTICE 'Pulling data from source...';
    EXECUTE 'SELECT refresh_dml('||quote_literal(p_dest_table)||', p_repull := true, p_debug := '||p_debug||')';
END IF;

IF p_index AND v_table_exists = false THEN
    PERFORM create_index(p_dest_table, v_src_schema_name, v_src_table_name, NULL, p_debug);
ELSIF v_table_exists = false THEN
-- Ensure destination indexes that are needed for efficient replication are created even if p_index is set false
    PERFORM gdb(p_debug, 'Creating indexes needed for replication');
    IF v_key_type = 'primary' THEN
        EXECUTE format('ALTER TABLE %I.%I ADD PRIMARY KEY (', v_dest_schema_name, v_dest_table_name) || v_pk_name_csv ||')';
    ELSE
        EXECUTE format('CREATE UNIQUE INDEX ON %I.%I (', v_dest_schema_name, v_dest_table_name) || v_pk_name_csv ||')';
    END IF;
END IF;

IF v_table_exists THEN
    RAISE NOTICE 'Destination table % already exists. No data or indexes were pulled from source', p_src_table;
END IF;

RAISE NOTICE 'Analyzing destination table...';
EXECUTE format('ANALYZE %I.%I', v_dest_schema_name, v_dest_table_name);

PERFORM dblink_disconnect(v_dblink_name);

EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

RAISE NOTICE 'Done';

RETURN;

EXCEPTION
    WHEN OTHERS THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_dblink_schema||''',''false'')';
        -- Only cleanup remote objects if replication doesn't exist at all for source table
        EXECUTE 'SELECT count(*) FROM @extschema@.refresh_config_dml WHERE source_table = '||quote_literal(p_src_table) INTO v_exists;
        IF dblink_get_connections() @> '{mimeo_dml}' THEN
            IF v_exists = 0 THEN
                PERFORM dblink_exec(v_dblink_name, format('DROP TRIGGER IF EXISTS %I ON %I.%I', v_source_queue_trigger, v_src_schema_name, v_src_table_name));
                PERFORM dblink_exec(v_dblink_name, format('DROP TABLE IF EXISTS %I.%I', '@extschema@', v_source_queue_table));
                PERFORM dblink_exec(v_dblink_name, format('DROP FUNCTION IF EXISTS %I.%I()', '@extschema@', v_source_queue_function));
            END IF;
            PERFORM dblink_disconnect(v_dblink_name);
        END IF;
        IF v_exists = 0 AND dblink_get_connections() @> '{mimeo_dml}' THEN
            EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
            RAISE EXCEPTION 'dml_maker() failure. Cleaned up source table mimeo objects (queue table, function & trigger) if they existed. SQLERRM: %', SQLERRM;
        ELSE
            EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
            RAISE EXCEPTION 'dml_maker() failure. Unable to clean up source database objects (trigger/queue table) if they were made. SQLERRM: % ', SQLERRM;
        END IF;

END
$$;


