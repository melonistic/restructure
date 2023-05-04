# frozen_string_literal: true

module TableGenerators
  def self.singularize(str)
    if str.end_with? 'ies'
      str[0..-4] + 'y'
    elsif str.end_with? 's'
      str[0..-2]
    end
  end

  def self.item_history_table(*args)
    name = args[0]
    generate_table = args[1]
    attrib = args[2..-1]

    if name.nil? || name == ''
      puts "Usage:
      db/table_generators/generate.sh item_history_table <pluralized_table_name> create|drop 'field1' 'field2'...
      "
      return
    end

    @implementation_table_name = name
    singular_name = singularize(name)

    unless singular_name
      puts 'The provided table name does not appear to be pluralized'
      return
    end

    if %i[drop drop_do].include?(generate_table)
      sql = <<EOF

      DROP TABLE if exists #{singular_name}_history CASCADE;
      DROP FUNCTION if exists log_#{singular_name}_update() CASCADE;

EOF

    else

      # variable used for spec tests
      @implementation_attr_name = attrib

      attrib_pair = {}
      attrib.each do |a|
        f = 'varchar'
        f = 'bigint' if a.end_with?('_id')
        if a == 'created_by_user_id'
          created_by = true
          f = 'integer'
        end
        f = 'date' if a.end_with?('_when')
        f = 'date' if a.end_with?('_date')
        f = 'time' if a.end_with?('_time')
        f = 'timestamp' if a.end_with?('_at')
        f = 'varchar' if a == 'data'
        f = 'varchar' if a.end_with?('_name')
        f = 'boolean' if a.end_with?('_check')
        f = 'varchar' if a == 'notes'
        f = 'varchar' if a.start_with?('select_')
        f = 'integer' if a == 'age'
        f = 'integer' if a.start_with?('number_')
        f = 'integer' if a.end_with?('_number')
        f = 'integer' if a.end_with?('_timestamp')
        f += ','
        attrib_pair[a] = f
      end

      sql = <<~EOF1

              reversible do |dir|
                dir.up do

        execute <<EOF

        -- Command line:
        -- table_generators/generate.sh item_history_table create #{name} #{attrib.join(' ')}

              CREATE FUNCTION log_#{singular_name}_update() RETURNS trigger
                  LANGUAGE plpgsql
                  AS $$
                      BEGIN
                          INSERT INTO #{singular_name}_history
                          (
                              master_id,
                              #{attrib.join(",\n                      ")}#{!attrib.empty? ? ',' : ''}
                              user_id,
                              created_at,
                              updated_at,
                              #{singular_name}_id
                              )
                          SELECT
                              NEW.master_id,
                              #{!attrib.empty? ? 'NEW.' : ''}#{attrib.join(",\n                      NEW.")}#{!attrib.empty? ? ',' : ''}
                              NEW.user_id,
                              NEW.created_at,
                              NEW.updated_at,
                              NEW.id
                          ;
                          RETURN NEW;
                      END;
                  $$;

              CREATE TABLE #{singular_name}_history (
                  id integer NOT NULL,
                  master_id integer,
                  #{attrib_pair.map { |a, f| "#{a} #{f}" }.join("\n          ")}
                  user_id integer,
                  created_at timestamp without time zone,
                  updated_at timestamp without time zone,
                  #{singular_name}_id integer
              );

              CREATE SEQUENCE #{singular_name}_history_id_seq
                  START WITH 1
                  INCREMENT BY 1
                  NO MINVALUE
                  NO MAXVALUE
                  CACHE 1;

              ALTER SEQUENCE #{singular_name}_history_id_seq OWNED BY #{singular_name}_history.id;

              ALTER TABLE ONLY #{singular_name}_history ALTER COLUMN id SET DEFAULT nextval('#{singular_name}_history_id_seq'::regclass);

              ALTER TABLE ONLY #{singular_name}_history
                  ADD CONSTRAINT #{singular_name}_history_pkey PRIMARY KEY (id);

              CREATE INDEX index_#{singular_name}_history_on_master_id ON #{singular_name}_history USING btree (master_id);

              CREATE INDEX index_#{singular_name}_history_on_#{singular_name}_id ON #{singular_name}_history USING btree (#{singular_name}_id);
              CREATE INDEX index_#{singular_name}_history_on_user_id ON #{singular_name}_history USING btree (user_id);

              CREATE TRIGGER #{singular_name}_history_insert AFTER INSERT ON #{name} FOR EACH ROW EXECUTE PROCEDURE log_#{singular_name}_update();
              CREATE TRIGGER #{singular_name}_history_update AFTER UPDATE ON #{name} FOR EACH ROW WHEN ((old.* IS DISTINCT FROM new.*)) EXECUTE PROCEDURE log_#{singular_name}_update();

              ALTER TABLE ONLY #{singular_name}_history
                  ADD CONSTRAINT fk_#{singular_name}_history_users FOREIGN KEY (user_id) REFERENCES users(id);

              ALTER TABLE ONLY #{singular_name}_history
                  ADD CONSTRAINT fk_#{singular_name}_history_masters FOREIGN KEY (master_id) REFERENCES masters(id);

              ALTER TABLE ONLY #{singular_name}_history
                  ADD CONSTRAINT fk_#{singular_name}_history_#{name} FOREIGN KEY (#{singular_name}_id) REFERENCES #{name}(id);

              #{created_by ? '' : '--'} ALTER TABLE ONLY #{singular_name}_history
              #{created_by ? '' : '--'}     ADD CONSTRAINT fk_#{singular_name}_history_cb_users FOREIGN KEY (created_by_user_id) REFERENCES users(id);

              GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA ml_app TO fphs;
              GRANT USAGE ON ALL SEQUENCES IN SCHEMA ml_app TO fphs;
              GRANT SELECT ON ALL SEQUENCES IN SCHEMA ml_app TO fphs;

        EOF
            end
            dir.down do

        execute <<EOF


        DROP TABLE if exists #{singular_name}_history CASCADE;
        DROP FUNCTION if exists log_#{singular_name}_update() CASCADE;

        EOF

            end
          end



      EOF1
    end

    if [true, :create_do, :drop_do].include?(generate_table)
      ActiveRecord::Base.connection.execute sql
      ActiveRecord::Base.connection.schema_cache.clear!
    else

      puts sql
      sql
    end
  end
end
