module RR
  module ReplicationExtenders

    # Provides Mysql specific functionality for database replication
    module MysqlReplication
      RR::ReplicationExtenders.register :mysql => self

      # Creates or replaces the replication trigger function.
      # See #create_replication_trigger for a descriptions of the +params+ hash.
      def create_or_replace_replication_trigger_function(params)
        execute(<<-end_sql)
          DROP PROCEDURE IF EXISTS #{params[:trigger_name]};
        end_sql
        
        activity_check = ""
        if params[:exclude_rr_activity] then
          activity_check = <<-end_sql
            DECLARE active INT;
            SELECT count(*) INTO active FROM #{params[:activity_table]};
            IF active <> 0 THEN
              LEAVE p;
            END IF;
          end_sql
        end

        execute(<<-end_sql)
          CREATE PROCEDURE #{params[:trigger_name]}(change_key varchar(2000), change_org_key varchar(2000), change_type varchar(1))
          p: BEGIN
            #{activity_check}
            INSERT INTO #{params[:log_table]}(change_table, change_key, change_org_key, change_type, change_time)
              VALUES('#{params[:table]}', change_key, change_org_key, change_type, now());
          END;
        end_sql
        
      end

      # Returns the key clause that is used in the trigger function.
      # * +trigger_var+: should be either 'NEW' or 'OLD'
      # * +params+: the parameter hash as described in #create_rep_trigger
      def key_clause(trigger_var, params)
        "concat_ws('#{params[:key_sep]}', " +
          params[:keys].map { |key| "'#{key}', #{trigger_var}.#{key}"}.join(", ") +
          ")"
      end
      private :key_clause

      # Creates a trigger to log all changes for the given table.
      # +params+ is a hash with all necessary information:
      # * :+trigger_name+: name of the trigger
      # * :+table+: name of the table that should be monitored
      # * :+keys+: array of names of the key columns of the monitored table
      # * :+log_table+: name of the table receiving all change notifications
      # * :+activity_table+: name of the table receiving the rubyrep activity information
      # * :+key_sep+: column seperator to be used in the key column of the log table
      # * :+exclude_rr_activity+:
      #   if true, the trigger will check and filter out changes initiated by RubyRep
      def create_replication_trigger(params)
        create_or_replace_replication_trigger_function params

        %w(insert update delete).each do |action|
          execute(<<-end_sql)
            DROP TRIGGER IF EXISTS #{params[:trigger_name]}_#{action};
          end_sql

          # The created triggers can handle the case where the trigger procedure
          # is updated (that is: temporarily deleted and recreated) while the
          # trigger is running.
          # For that an MySQL internal exception is raised if the trigger
          # procedure cannot be found. The exception is caught by an trigger
          # internal handler. 
          # The handler causes the trigger to retry calling the
          # trigger procedure several times with short breaks in between.

          trigger_var = action == 'delete' ? 'OLD' : 'NEW'
          if action == 'update'
            call_statement = "CALL #{params[:trigger_name]}(#{key_clause('NEW', params)}, #{key_clause('OLD', params)}, '#{action[0,1].upcase}');"
          else
            call_statement = "CALL #{params[:trigger_name]}(#{key_clause(trigger_var, params)}, null, '#{action[0,1].upcase}');"
          end
          execute(<<-end_sql)
            CREATE TRIGGER #{params[:trigger_name]}_#{action}
              AFTER #{action} ON #{params[:table]} FOR EACH ROW BEGIN
                DECLARE number_attempts INT DEFAULT 0;
                DECLARE failed INT;
                DECLARE CONTINUE HANDLER FOR 1305 BEGIN
                  DO SLEEP(0.05);
                  SET failed = 1;
                  SET number_attempts = number_attempts + 1;
                END;
                REPEAT
                  SET failed = 0;
                  #{call_statement}
                UNTIL failed = 0 OR number_attempts >= 40 END REPEAT;
              END;
          end_sql
        end

      end

      # Removes a trigger and related trigger procedure.
      # * +trigger_name+: name of the trigger
      # * +table_name+: name of the table for which the trigger exists
      def drop_replication_trigger(trigger_name, table_name)
        %w(insert update delete).each do |action|
          execute "DROP TRIGGER #{trigger_name}_#{action};"
        end
        execute "DROP PROCEDURE #{trigger_name};"
      end

      # Returns +true+ if the named trigger exists for the named table.
      # * +trigger_name+: name of the trigger
      # * +table_name+: name of the table
      def replication_trigger_exists?(trigger_name, table_name)
        !select_all("select 1 from information_schema.triggers where trigger_schema = database() and trigger_name = '#{trigger_name}_insert' and event_object_table = '#{table_name}'").empty?
      end
    end
  end
end

