# frozen_string_literal: true

module Dynamic
  module DefHandler
    extend ActiveSupport::Concern

    included do
      after_save :generate_model, if: -> { ready_to_generate? }
      after_save :check_implementation_class
      after_save :force_option_config_parse

      after_save :add_master_association, if: -> { @regenerate }
      after_save :add_user_access_controls, if: -> { @regenerate }
      after_save :reset_active_model_configurations!

      after_commit :update_tracker_events, if: -> { @regenerate }
      after_commit :restart_server, if: -> { @regenerate }
      after_commit :other_regenerate_actions
      after_commit :handle_disabled, if: -> { disabled }

      attr_accessor :configurations, :data_dictionary, :options_constants, :force_regenerate
    end

    class_methods do
      # Attribute holding option configs text
      # This is the default and may be overridden in definition classes
      def option_configs_attr
        :options
      end

      # String naming the namespace prefix for the implementation
      # Must be overriden
      def implementation_prefix
        raise FphsException, "implementation_prefix not overridden for class: #{name}"
      end

      # A list of model names for models that have been generated and are ready to be used
      def model_names
        @model_names ||= []
      end

      # A list of model names for models that have been generated and are ready to be used
      def model_name_strings
        model_names.map(&:to_s)
      end

      # A list of models that have been generated and are ready to be used
      def models
        @models ||= {}
      end

      # If necessary, ensure other dynamic implementations have been loaded before we attempt to create this one
      def preload
        nil
      end

      #
      # Class that implements options for this dynamic type.
      # Inherits from ExtraOptions.
      # Must be overridden by specific dynamic type classes
      # @return [ExtraOptions]
      def options_provider
        nil
      end

      #
      # Should the options provider allow empty / nil options to be defined.
      # If true, it will set up an empty configuration instance to use by default
      # Otherwise, the option config type will return nil if not defined
      # @return [Boolean]
      def allow_empty_options
        true
      end

      # Get the list of model defintions based on them being available in
      # the active app types.
      # This means that we drop out configurations for app types that are disabled
      # or are not included in the OnlyLoadAppTypes setting.
      # This is typically used to improve load times and ensure we only generate
      # templates for models that will actually be used.
      # @return [ActiveRecord::Relation] scoped results
      def active_model_configurations
        # return @active_model_configurations if @active_model_configurations

        olat = Admin::AppType.active_app_types

        # List of names that the associated_* items have already returned
        # to avoid building huge lists of repetitive joined queries
        got_names = []

        if olat&.present?
          qs = []
          olat.each do |app_type|
            resnames = []
            # Compare against string class names, to avoid autoload errors
            case name
            when 'ActivityLog'
              res = app_type.associated_activity_logs(not_resource_names: got_names)
              resnames = app_type.associated_activity_log_names
            when 'DynamicModel'
              res = app_type.associated_dynamic_models(valid_resources_only: false, not_resource_names: got_names)
              resnames = app_type.associated_dynamic_model_names
            when 'ExternalIdentifier'
              res = app_type.associated_external_identifiers(not_resource_names: got_names)
              resnames = app_type.associated_external_identifier_names
            end
            if resnames.present? && (resnames - got_names).present?
              qs << res.reorder('').to_sql
              got_names |= resnames
            end
          end
          if qs.present?
            unions = qs.join("\nUNION\n")
            dma = from(Arel.sql("(#{unions}) AS #{table_name}"))
          else
            dma = where(id: nil)
          end
        else
          dma = active
        end
        @active_model_configurations = dma
      end

      def reset_active_model_configurations!
        @active_model_configurations = nil
      end

      #
      # Run through the configurations to implement them and make them available for use
      # Since ActivityLog types actually preload DynamicModel and ExternalIdentifier types
      # typically this is only called as ``::ActivityLog.define_models`
      def define_models
        preload

        begin
          dma = active_model_configurations

          logger.info "Generating models #{name} #{dma.length}"

          dma.each do |dm|
            dm.generate_model
            # Force the admin for cases that this is run outside of the admin console
            # It is expected that this is mostly when originally seeding the database
            dm.current_admin ||= dm.admin

            dm.update_tracker_events
          end
        rescue Exception => e
          msg = "Failed to generate models. Hopefully this is only during a migration. \n***** #{e.inspect}"
          puts msg
          puts e.backtrace.join("\n")
          Rails.logger.warn msg
        end
      end

      # Reload routes when a definition is regenerated
      def routes_reload
        return unless @regenerate

        Rails.application.reload_routes!
        Rails.application.routes_reloader.reload!
      end

      # Enable active configurations for the dynamic type
      # This checks that underlying tables are available, the implementation
      # class is defined, and then it adds associations to Master
      # Both log and put any errors to stdout, since this may run in a migration
      # and a log alone won't be visible to the end user
      # To ensure that the db migrations can run,
      # check for the existence of the appropriate admin table
      # before attempting to do anything. Otherwise Rake tasks fail and
      # the admin table can't be generated, preventing setup of the app.
      def enable_active_configurations
        if Admin::MigrationGenerator.table_or_view_exists? table_name
          active_model_configurations.each do |dm|
            klass = if dm.is_a? ExternalIdentifier
                      Object
                    else
                      dm.class.name.constantize
                    end

            if dm.ready_to_generate? && dm.implementation_class_defined?(klass, fail_without_exception: true)
              dm.add_master_association
            else
              msg = "Failed to enable #{dm} #{dm.id} #{dm.resource_name}. Table ready? #{dm.table_or_view_ready?}"
              puts msg
              Rails.logger.warn msg
            end
          end
        else
          msg = "Table doesn't exist yet: #{table_name}"
          puts msg
          Rails.logger.warn msg
        end
      end

      # Get all the resource names for options configs in all active dynamic definitions
      # Used by user filestore filters
      # @param [Proc] an optional block may be passed to allow filtering based
      #   on values in the option config for each entry
      #   for example:
      #      all_option_configs_resource_names {|e| e && e.references && e.references[:nfs_store__manage__container]}
      # @return [Array] array of string names
      def all_option_configs_resource_names(&block)
        res = []

        @all_option_configs_resource_names ||= active_model_configurations.map(&:option_configs)

        @all_option_configs_resource_names.each do |a|
          elts = if block_given?
                   a.select(&block)
                 else
                   a
                 end
          res += elts.map(&:resource_name)
        end

        res
      end

      # Get all the resource names for options configs in all active dynamic definitions
      # grouped by the item category + name.
      # Used by user access control definitions
      # @param [Proc] an optional block may be passed to allow filtering based
      #   on values in the option config for each entry
      #   for example:
      #      all_option_configs_resource_names {|e| e && e.references && e.references[:nfs_store__manage__container]}
      # @return [Array] array of string names
      def all_option_configs_grouped_resources(&block)
        res = {}

        @all_option_configs_resource_names ||= active_model_configurations.map(&:option_configs)

        @all_option_configs_resource_names.each do |a|
          elts = if block_given?
                   a.select(&block)
                 else
                   a
                 end

          group_name = [a.first.def_item.category, a.first.def_item.name].select(&:present?).join(': ')
          res[group_name] = elts.map { |r| [r.resource_name, r.label] }.to_h
        end

        res
      end

      # Force the memoized version of #all_option_configs_resource_names to be reset so it
      # will be regenerated next time
      def reset_all_option_configs_resource_names!
        @all_option_configs_resource_names = nil
      end

      # The list of defined and usable activity log implementation classes
      def implementation_classes
        @implementation_classes = active_model_configurations.map(&:implementation_class)
      end

      # List of item types that can be used to define Classification::GeneralSelection drop downs
      # This does not represent the actual item types that are valid for selection
      # when defining a new definition record, which
      # is in fact provided by self.use_with_class_names
      def item_types(refresh: false)
        cname = "#{name}.item_types"
        Rails.cache.delete(cname) if refresh

        Rails.cache.fetch(cname) do
          list = []
          implementation_classes.each do |imp_class|
            list += imp_class.attribute_names
                             .select { |a| Classification::GeneralSelection.use_with_attribute?(a) }
                             .map do |a|
              mn = imp_class.model_name.to_s.ns_underscore
              mn = mn.pluralize unless imp_class.respond_to?(:is_activity_log)
              "#{mn}_#{a}".to_sym
            end
          end

          list
        end
      end

      # Allow new models to be added to the nested attributes dynamically by models as they are configured
      def add_nested_attribute(attrib)
        @master_nested_attrib ||= Master::MasterNestedAttribs.dup
        @master_nested_attrib << attrib
        Master.accepts_nested_attributes_for(*@master_nested_attrib)
      end

      #
      # Get the timestamp for the latest definition stored in the DB.
      # @return [DateTime]
      def latest_stored_update
        active_model_configurations
          .select(:updated_at)
          .reorder('')
          .order('updated_at desc nulls last')
          .limit(1)
          .pluck(:updated_at)
          .first
      end

      #
      # Does the persisted latest updated definition match the memoized update?
      # Returns nil if not previously memoized, otherwise true or false.
      # @return [true | false | nil]
      def up_to_date?
        lu = latest_stored_update

        if !lu && !@prev_latest_update
          # They match if both nil
          true
        elsif lu && @prev_latest_update && (lu - @prev_latest_update).abs < 2
          # Consider them a match if they are within 2 seconds of one another,
          # accounting for the difference between Rails and DB times
          true
        elsif @prev_latest_update.nil?
          # The remembered value was nil, so let the caller know this
          self.prev_latest_update = lu
          nil
        else
          # There was no match
          self.prev_latest_update = lu
          false
        end
      end

      #
      # Remember the latest updated at timestamp
      def prev_latest_update=(updated_at)
        return if @prev_latest_update && updated_at && updated_at <= @prev_latest_update

        @prev_latest_update = updated_at
      end

      #
      # Reload the models and configurations any definitions that
      # do not match the memoized version, since these may have changed on
      # another server in the cluster.
      def refresh_outdated
        utd = up_to_date?
        # If up to date, or not previously set
        # (and therefore we are on our first load and everything will have just been set up) just return
        return if utd || utd.nil?

        defs = active_model_configurations.reorder('').order('updated_at desc nulls last')
        any_new = false
        defs.each do |d|
          rn = d.resource_name
          u = d.updated_at
          m = Resources::Models.find_by(resource_name: rn)&.model&.definition
          # Skip if the model was previous set and the updated timestamps match
          next if m && m.updated_at == u

          this_is_new = !m
          any_new ||= this_is_new
          d.force_regenerate = true
          d.generate_model
          d.check_implementation_class
          d.force_option_config_parse
          d.add_master_association
          d.add_user_access_controls
          d.reset_active_model_configurations! if this_is_new
          d.update_tracker_events
          d.other_regenerate_actions
        end

        routes_reload if any_new
      end

      # End of class_methods
    end

    def secondary_key
      return @secondary_key if @secondary_key_set

      @secondary_key_set = true
      # Parse option configs if necessary
      option_configs
      @secondary_key = configurations && configurations[:secondary_key]
    end

    # Return result based on the current
    # list of model defintions based on them being available in
    # the active app types.
    def active_model_configuration?
      self.class.active_model_configurations.include? self
    end

    # At this time dynamic models only use one config definition, under the 'default' key
    # Simplify access to the default options configuration
    def default_options
      option_type_config_for :default
    end

    #
    # Get the definition's stored option config text from its appropriate attribute
    # Return nil if there is option_configs_attr is nil
    # @param [String | Symbol] alt_option_config_attr - specify an alternative attribute
    #   containing the options config. Used when multiple options are available within a single model.
    # @return [String | nil]
    def options_text(alt_option_config_attr = nil)
      alt_option_config_attr ||= self.class.option_configs_attr
      return unless alt_option_config_attr

      send(alt_option_config_attr).dup
    end

    #
    # Parse option configs
    # @param [Boolean] force forces the memoized version to be updated
    # @param [<Type>] raise_bad_configs ensures bad configurations are checked and
    #    exceptions raised to halt execution
    # @return [Array] configurations
    def option_configs(force: false, raise_bad_configs: false)
      return if disabled?

      @option_configs = nil if force
      @option_configs ||= self.class.options_provider.parse_config(self, force)
      self.class.options_provider.raise_bad_configs @option_configs if raise_bad_configs
      @option_configs
    end

    #
    # Array of option config names (Symbols)
    # @return [Array{Symbol}]
    def option_configs_names
      option_configs&.map(&:name)
    end

    #
    # The option config for a specific named type
    # @param [Symbol] name to match
    # @param [Symbol] result_if_empty optionally selects the result to return if there is no matching name
    #    The options are:
    #      - :default - the default if not specified, generates an empty configuration with the name :default
    #      - :first_config - get the first item in the option_configs array
    #      - generates an empty configuration with the name specified in result_if_empty
    # @return [Class] options provider instance
    def option_type_config_for(name, result_if_empty: :default)
      return unless option_configs

      res = option_configs.find { |s| s.name == name.to_s.underscore.to_sym }

      if !res && self.class.allow_empty_options
        res = if result_if_empty == :first_config
                option_configs.first
              else
                self.class.options_provider.new(result_if_empty, {}, self)
              end

      end
      res
    end

    #
    # Validate that the option configs parse correctly
    # @return [Boolean]
    def option_configs_valid?
      self.class.options_provider.configs_valid?(self)
    end

    #
    # Simply parse option configs, forcing the memoized version to be updated
    # @return [Array] parsed configs
    def force_option_config_parse
      return if disabled?

      option_configs force: true, raise_bad_configs: true
    end

    #
    # Simple test to see if the controller associated with the implementation model is defined
    # @param [Module | Class] parent_class is the parent for the controller, to handle namespacing issues
    # @return [Boolean]
    def implementation_controller_defined?(parent_class = Module)
      return false unless full_implementation_controller_name

      # Check that the class is defined
      klass = parent_class.const_get(full_implementation_controller_name)
      klass.is_a?(Class)
    rescue NameError
      false
    end

    # Is the implementation class for this configuration defined so that it
    # can be instantiated?
    # @param [Module | Class] parent_class
    # @param [Hash] opt options
    # @option opt [String] :class_name is an alternative class name within the
    #   parent class to test. This can be used to avoid namespacing issues
    # @option opt [Boolean] :fail_without_exception if true we return a Boolean rather than raising an exception
    # @return [Boolean] true if the class is defined, and false or a raised exception depending on the options
    def implementation_class_defined?(parent_class = Module, opt = {})
      icn = opt[:class_name] || full_implementation_class_name
      return false unless icn

      # Check that the class is defined
      klass = parent_class.const_get(icn)
      res = klass.is_a?(Class)

      return false unless res

      begin
        # Check if it can be instantiated correctly - if it can't, allow it to raise an exception
        # since this is seriously unexpected
        klass.new
      rescue Exception => e
        err = "Failed to instantiate the class #{icn} in parent #{parent_class}: #{e}"
        logger.warn err
        raise FphsException, err unless opt[:fail_without_exception]

        # By default, return false if an error occurred attempting the initialization.
        # In certain cases (for example, checking if a class exists so it can be removed), returning true if the
        # class is defined regardless of whether it can be initialized makes most sense. Provide an option to support this.
        opt[:fail_without_exception_newable_result]
      end
    rescue NameError => e
      logger.warn e
      false
    end

    #
    # Decide whether to regenerate a model based on it not existing already in the namespace
    # @return [Class | nil] truthy result unless the model exists in the namespace
    def prevent_regenerate_model
      return if force_regenerate

      got_class = begin
        full_implementation_class_name.constantize
      rescue StandardError
        nil
      end
      got_class if got_class&.to_s&.start_with?(self.class.implementation_prefix)

      return unless fields_match_columns?

      got_class
    end

    #
    # Check the defined field list matches the columns in the database. If not,
    # we may need to regenerate the model
    def fields_match_columns?
      fields = all_implementation_fields
      fields.reject! { |f| f.index(/^embedded_report_|^placeholder_/) }

      (fields.sort - table_columns.map { |c| c.name.to_s }.sort).empty?
    end

    # Is the definition ready for a class to be defined?
    # Is it enabled and does it have an underlying table?
    def ready_to_generate?
      !disabled && table_or_view_ready?
    end

    #
    # Check if the underlying database table exists
    # @return [boolean]
    def table_or_view_ready?
      Admin::MigrationGenerator.table_or_view_exists?(table_name)
    rescue StandardError => e
      @extra_error = e
      false
    end

    # This needs to be overridden in each provider to allow consistency of calculating model names for implementations
    # Non-namespaced model definition name
    # @return [String]
    def implementation_model_name
      nil
    end

    # Non-namespaced model definition name
    def model_class_name
      implementation_model_name.ns_camelize
    end

    # Return the model class for this definition
    def model_class
      self.class.models[implementation_model_name]
    end

    # The name of the association within the Master class
    def model_association_name
      full_implementation_class_name.pluralize.ns_underscore.to_sym
    end

    # Full namespaced item type name, underscored with double underscores
    # If there is no prefix then this matches the simple model name
    def full_item_type_name
      prefix = ''
      prefix = "#{self.class.implementation_prefix.ns_underscore}__" if self.class.implementation_prefix.present?

      "#{prefix}#{implementation_model_name}"
    end

    # Full namespaced item types (pluralized) name, underscored with double underscores
    def full_item_types_name
      full_item_type_name.pluralize
    end

    # Hyphenated name, typically used in HTML markup for referencing target blocks and panels
    def hyphenated_name
      implementation_model_name.ns_hyphenate
    end

    # Absolute namespaced class name for the model
    def full_implementation_class_name
      full_item_type_name.ns_camelize
    end

    # Absolute namespaced class name for the matching controller
    def full_implementation_controller_name
      "#{model_class_name.pluralize}Controller"
    end

    # The model class that can be instantiated
    def implementation_class
      full_implementation_class_name.ns_constantize
    rescue StandardError => e
      msg = "Failed to get the implementation_class for #{full_implementation_class_name}: #{e}"
      Rails.logger.warn msg
      raise e, msg
    end

    # Allow definitions to not be associated with a master record,
    # but only if we allow a foreign key name to be specified and it isn't
    # In reality, only DynamicModel classes can do this
    def implementation_no_master_association
      defined?(foreign_key_name) && foreign_key_name.blank?
    end

    # Tracker events are required for each dynamic class. It is the
    # responsibility of the individual definition classes to handle this
    def update_tracker_events
      raise 'DynamicModel configuration implementation must define update_tracker_events'
    end

    # After a regeneration, certain other cleanups may be required
    def other_regenerate_actions
      return if disabled

      self.class.prev_latest_update = updated_at
      self.class.preload
      Rails.logger.info 'Reloading column definitions'
      implementation_class.reset_column_information
      Rails.logger.info 'Refreshing item types'
      Classification::GeneralSelection.item_types refresh: true
    end

    # After disabling an item, clean up any mess
    def handle_disabled
      Rails.logger.info 'Refreshing item types'
      begin
        Classification::GeneralSelection.item_types refresh: true
      rescue NameError => e
        Rails.logger.info "Failed to clear general selections for #{model_class_name}"
      end

      remove_model_from_list
      remove_assoc_class 'Master'
      remove_implementation_class
      remove_implementation_controller_class
    end

    # A list of model names and definitions is stored in the class so we can
    # quickly see what dynamic classes are available elsewhere
    # Add an item to this list
    def add_model_to_list(m)
      tn = implementation_model_name
      self.class.models[tn] = m
      logger.info "Added new model #{tn}"
      self.class.model_names << tn unless self.class.model_names.include? tn
      Resources::Models.add(m)
    end

    # Remove an item from the list of available dynamic classes
    # @param [String] tn (optional)
    def remove_model_from_list(tn = nil)
      tn ||= implementation_model_name
      logger.info "Removed disabled model #{tn}"
      self.class.models.delete(tn)
      self.class.model_names.delete(tn)
      Resources::Models.remove(resource_name: resource_name)
    end

    # Dump the old association
    def remove_assoc_class(in_class_name, alt_target_class = nil)
      cns = in_class_name.to_s.split('::')
      klass = Object
      klass = cns.first.constantize if cns.length == 2
      short_class_name = cns.last
      alt_target_class ||= model_class_name.pluralize
      assoc_ext_name = "#{short_class_name}#{alt_target_class}AssociationExtension"
      return unless klass.constants.include?(assoc_ext_name.to_sym)

      klass.send(:remove_const, assoc_ext_name) if implementation_class_defined?(Object)
    rescue StandardError => e
      logger.debug "Failed to remove #{assoc_ext_name} : #{e}"
    end

    def prefix_class
      klass = Object
      klass = "::#{self.class.implementation_prefix}".constantize if self.class.implementation_prefix.present?
      klass
    end

    def remove_implementation_class(alt_prefix_class = nil)
      klass = alt_prefix_class || prefix_class
      # This may fail if an underlying dependent class (parent class) has been redefined by
      # another dynamic implementation, such as external identifier
      return unless implementation_class_defined?(klass, fail_without_exception: true,
                                                         fail_without_exception_newable_result: true)

      klass.send(:remove_const, model_class_name)
    rescue StandardError => e
      logger.info <<~END_TEXT
        *************************************************************************************
        Failed to remove the old definition of #{model_class_name}. #{e.inspect}
        *************************************************************************************
      END_TEXT
    end

    def remove_implementation_controller_class
      klass = prefix_class
      return unless implementation_controller_defined?(klass)

      # This may fail if an underlying dependent class (parent class) has been redefined by
      # another dynamic implementation, such as external identifier
      klass.send(:remove_const, full_implementation_controller_name)
    rescue StandardError => e
      logger.info <<~END_TEXT
        *************************************************************************************
        Failed to remove the old definition of #{full_implementation_controller_name}. #{e.inspect}
        *************************************************************************************
      END_TEXT
    end

    #
    # Create a user access control for the item with a template role, to
    # ensure that it is correctly exported from an app type, even
    # if no real end users or roles have been applied to it
    # The underlying call will update an existing user access control if it
    # already exists.
    # This is called by an after_save trigger, and may also be used in specs directly
    # when the force named argument is typically used
    # @param [boolean] force the action to happen even
    #    if the item is not ready or is disabled
    # @param [Admin::AppType] app_type to add the user access control to
    # @return [Admin::UserAccessControl] the created or updated user access control
    def add_user_access_controls(force: false, app_type: nil)
      changed_name = if respond_to? :table_name
                       saved_change_to_table_name?
                     elsif respond_to? :name
                       saved_change_to_name?
                     end

      return unless !persisted? || saved_change_to_disabled? || changed_name || force

      begin
        if ready_to_generate? || disabled? || force
          app_type ||= admin.matching_user_app_type
          Admin::UserAccessControl.create_template_control admin,
                                                           app_type,
                                                           :table,
                                                           model_association_name,
                                                           disabled: disabled
        end
      rescue StandardError => e
        raise FphsException,
              "A failure occurred creating user access control for app with: #{model_association_name}.\n#{e}"
      end
    end

    #
    # Get the field_list (or an alternative attribute string) as a
    # cleaned up array of strings
    # The string is a space or comma separated list
    # @param [String] for_attrib string from an alternative attribute
    # @return [Array{String}] strings representing the list of fields
    def field_list_array(for_attrib: nil)
      for_attrib ||= field_list
      for_attrib.split(/[,\s]+/).map(&:strip).compact if for_attrib
    end

    #
    # Database table column definitions
    def table_columns
      ActiveRecord::Base.connection.columns(table_name)
    end

    #
    # Check if the implementation class has been correctly defined
    # This checks that the underlying database table has been created.
    # If the table is not available, (and we are in the development environment)
    # a migration for the appropriate schema will be written (and run)
    def check_implementation_class
      return unless !disabled && errors.empty?

      # Check the implementation class is actually defined and can be instantiated
      begin
        res = implementation_class_defined?
      rescue StandardError => e
        err = "Failed to instantiate the class #{full_implementation_class_name}: #{e}"
        logger.warn err
        errors.add :name, err
        # Force exit of callbacks
        raise FphsException, err
      end

      # For some reason the underlying table exists but the class doesn't. Inform the admin
      unless res
        err = "The implementation of #{model_class_name} was not completed. " \
              "The DB table #{table_name} has #{table_or_view_ready? ? '' : 'NOT '}been created"
        logger.warn err
        errors.add :name, err
        # Force exit of callbacks
        raise FphsException, err
      end
    end

    #
    # Active model configurations are memoized in a class attribute and need to be reset on a change
    def reset_active_model_configurations!
      self.class.reset_active_model_configurations!
    end

    # If we have forced a regeneration of classes, for example if a new DB table
    # has been created, restart the server.
    # This is called from an after_commit trigger
    def restart_server
      AppControl.restart_server # if Rails.env.production?
    end
  end
end
