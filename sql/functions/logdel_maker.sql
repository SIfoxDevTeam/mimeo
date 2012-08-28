/*
 *  DML maker function. Optional custom destination table name.
 */
CREATE FUNCTION logdel_maker(p_src_table text, p_dblink_id int, p_pk_field text[], p_pk_type text[], p_dest_table text DEFAULT NULL) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE

v_cols                      text[];
v_cols_csv                  text;
v_cols_n_types              text[];
v_cols_n_types_csv          text;
v_conns                     text[];
v_create_trig               text;
v_dblink_schema             text;
v_insert_refresh_config     text;
v_old_search_path           text;
v_counter                int := 1;
v_pk_field_csv              text := '';
v_pk_field_type_csv         text := '';
v_remote_sql                text;
v_remote_q_index            text;
v_remote_q_table            text;
v_table_name                text;
v_trigger_func              text;
v_types                     text[];


BEGIN

SELECT nspname INTO v_dblink_schema FROM pg_namespace n, pg_extension e WHERE e.extname = 'dblink' AND e.extnamespace = n.oid;

-- Set custom search path to allow easier calls to other functions
SELECT current_setting('search_path') INTO v_old_search_path;
EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_dblink_schema||''',''false'')';

IF p_dest_table IS NULL THEN
    p_dest_table := p_src_table;
END IF;

-- Split off schema name if it exists
IF position('.' in p_src_table) > 0 THEN 
    v_table_name := substring(p_src_table from position('.' in p_src_table)+1);
END IF;

PERFORM dblink_connect('mimeo_logdel', @extschema@.auth(p_dblink_id));

v_remote_sql := 'SELECT array_agg(attname) as cols, array_agg(atttypid::regtype::text) as types, array_agg(attname||'' ''||atttypid::regtype::text) as cols_n_types FROM pg_attribute WHERE attnum > 0 AND attisdropped is false AND attrelid = ' || quote_literal(p_src_table) || '::regclass';
v_remote_sql := 'SELECT cols, types, cols_n_types FROM dblink(''mimeo_logdel'', ' || quote_literal(v_remote_sql) || ') t (cols text[], types text[], cols_n_types text[])';
EXECUTE v_remote_sql INTO v_cols, v_types, v_cols_n_types;

v_cols_csv := array_to_string(v_cols, ',');
v_cols_n_types_csv := array_to_string(v_cols_n_types, ',');

v_remote_q_table := 'CREATE TABLE @extschema@.'||v_table_name||'_pgq ('||v_cols_n_types_csv||', mimeo_source_deleted timestamptz, processed boolean)';

v_pk_field_csv := array_to_string(p_pk_field, ',');
WHILE v_counter <= array_length(p_pk_field,1) LOOP
    IF v_counter > 1 THEN
        v_pk_field_type_csv := v_pk_field_type_csv || ', ';
    END IF;
    v_pk_field_type_csv := v_pk_field_type_csv ||p_pk_field[v_counter]||' '||p_pk_type[v_counter];
    v_counter := v_counter + 1;
END LOOP;

v_remote_q_index := 'CREATE INDEX ON @extschema@.'||v_table_name||'_pgq ('||v_pk_field_csv||')';

v_counter := 1;
v_trigger_func := 'CREATE FUNCTION @extschema@.'||v_table_name||'_mimeo_queue() RETURNS trigger LANGUAGE plpgsql AS $_$ DECLARE ';
    WHILE v_counter <= array_length(v_cols,1) LOOP
        v_trigger_func := v_trigger_func||'v_'||v_cols[v_counter]||' '||v_types[v_counter]||'; ';
        v_counter := v_counter + 1;
    END LOOP;
    v_trigger_func := v_trigger_func || 'v_del_time timestamptz; ';
    v_counter := 1;
    v_trigger_func := v_trigger_func || ' BEGIN IF TG_OP = ''INSERT'' THEN ';
    WHILE v_counter <= array_length(p_pk_field,1) LOOP
        v_trigger_func := v_trigger_func||' v_'||p_pk_field[v_counter]||' := NEW.'||p_pk_field[v_counter]||'; ';
        v_counter := v_counter + 1;
    END LOOP;
    v_counter := 1;
    v_trigger_func := v_trigger_func || ' ELSIF TG_OP = ''UPDATE'' THEN  ';
    WHILE v_counter <= array_length(p_pk_field,1) LOOP
        v_trigger_func := v_trigger_func||' v_'||p_pk_field[v_counter]||' := OLD.'||p_pk_field[v_counter]||'; ';
        v_counter := v_counter + 1;
    END LOOP;
    v_counter := 1;
    v_trigger_func := v_trigger_func || ' ELSIF TG_OP = ''DELETE'' THEN  ';
    WHILE v_counter <= array_length(v_cols,1) LOOP
        v_trigger_func := v_trigger_func||' v_'||v_cols[v_counter]||' := OLD.'||v_cols[v_counter]||'; ';
        v_counter := v_counter + 1;
    END LOOP;
    v_trigger_func := v_trigger_func || 'v_del_time := clock_timestamp(); ';
    v_counter := 1;
    v_trigger_func := v_trigger_func || ' END IF; INSERT INTO @extschema@.'||v_table_name||'_pgq ('||v_cols_csv||', mimeo_source_deleted) ';
    v_trigger_func := v_trigger_func || ' VALUES (';
    WHILE v_counter <= array_length(v_cols,1) LOOP
        IF v_counter > 1 THEN
            v_trigger_func := v_trigger_func || ', ';
        END IF;
        v_trigger_func := v_trigger_func||'v_'||v_cols[v_counter];
        v_counter := v_counter + 1;
    END LOOP;
    v_trigger_func := v_trigger_func ||', v_del_time); RETURN NULL; END $_$;';

v_create_trig := 'CREATE TRIGGER '||v_table_name||'_mimeo_trig AFTER INSERT OR UPDATE OR DELETE ON '||p_src_table||
    ' FOR EACH ROW EXECUTE PROCEDURE @extschema@.'||v_table_name||'_mimeo_queue()';

RAISE NOTICE 'Creating objects on source database (function, trigger & queue table)...';
PERFORM dblink_exec('mimeo_logdel', v_remote_q_table);
PERFORM dblink_exec('mimeo_logdel', v_remote_q_index);
PERFORM dblink_exec('mimeo_logdel', v_trigger_func);
PERFORM dblink_exec('mimeo_logdel', v_create_trig);

PERFORM dblink_disconnect('mimeo_logdel');

RAISE NOTICE 'Snapshotting source table to pull all current source data...';
-- Snapshot the table after triggers have been created to ensure all new data after setup is replicated
v_insert_refresh_config := 'INSERT INTO @extschema@.refresh_config_snap(source_table, dest_table, dblink) VALUES('
    ||quote_literal(p_src_table)||', '||quote_literal(p_dest_table)||', '|| p_dblink_id||')';

EXECUTE v_insert_refresh_config;

PERFORM @extschema@.refresh_snap(p_dest_table);
PERFORM @extschema@.snapshot_destroyer(p_dest_table, 'ARCHIVE');

EXECUTE 'ALTER TABLE '||p_dest_table||' ADD COLUMN mimeo_source_deleted timestamptz';

v_insert_refresh_config := 'INSERT INTO @extschema@.refresh_config_logdel(source_table, dest_table, dblink, control, pk_field, pk_type, last_value) VALUES('
    ||quote_literal(p_src_table)||', '||quote_literal(p_dest_table)||', '|| p_dblink_id||', '||quote_literal('@extschema@.'||v_table_name||'_pgq')||', '
    ||quote_literal(p_pk_field)||', '||quote_literal(p_pk_type)||', '||quote_literal(clock_timestamp())||')';
RAISE NOTICE 'Inserting data into config table';

EXECUTE v_insert_refresh_config;

EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';

RAISE NOTICE 'Done';

EXCEPTION
    WHEN OTHERS THEN
        EXECUTE 'SELECT set_config(''search_path'',''@extschema@,'||v_dblink_schema||''',''false'')';
        v_conns := dblink_get_connections();
        IF dblink_get_connections() @> '{mimeo_logdel}' THEN
            PERFORM dblink_disconnect('mimeo_logdel');
        END IF;
        EXECUTE 'SELECT set_config(''search_path'','''||v_old_search_path||''',''false'')';
        RAISE EXCEPTION '%', SQLERRM;    
END
$$;