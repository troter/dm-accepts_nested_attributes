require 'data_mapper/nested_attributes/assignment'
require 'data_mapper/nested_attributes/assignment/guard'

module DataMapper
  module NestedAttributes
    class Acceptor
      # Truthy values for the +:_delete+ flag.
      # TODO: eliminate; replace with %w[1 t true].include?(value.to_s.downcase)
      TRUE_VALUES = [true, 1, '1', 't', 'T', 'true', 'TRUE'].to_set

      def self.for(relationship, options)
        if relationship.kind_of?(DataMapper::Associations::ManyToMany::Relationship)
          Acceptor::ManyToMany.new(relationship, options)
        else
          Acceptor.new(relationship, options)
        end
      end

      attr_reader :relationship
      attr_reader :assignment_guard
      attr_writer :assignment_factory

      def initialize(relationship, options)
        @relationship     = relationship
        @allow_destroy    = !!options.fetch(:allow_destroy, false)
        guard_factory     = options.fetch(:guard_factory) { Assignment::Guard }
        @assignment_guard = guard_factory.for(options.fetch(:reject_if, nil))
      end

      def allow_destroy?
        @allow_destroy
      end

      def accept(resource, attributes)
        sanitized_attributes = sanitize_attributes(resource, attributes)
        assignment = assignment_factory.for(self, resource)
        assignment.assign(sanitized_attributes)
        sanitized_attributes
      end

      def collection?
        relationship.max > 1
      end

      def resource?
        !collection?
      end

      # Updates a record with the +attributes+ or marks it for destruction if
      # the +:allow_destroy+ option is +true+ and {#has_delete_flag?} returns
      # +true+.
      #
      # @param [DataMapper::Resource] resource
      #   The resource to be updated or destroyed
      #
      # @param [Hash{Symbol => Object}] attributes
      #   The attributes to assign to the relationship's target end.
      #   All attributes except {#unupdatable_keys} will be assigned.
      #
      # @return [void]
      def update_or_mark_as_destroyable(assignee, resource, attributes)
        if has_delete_flag?(attributes) && allow_destroy?
          mark_as_destroyable(assignee, resource)
        else
          update(resource, attributes)
        end
      end

      def update(resource, attributes)
        assert_nested_update_clean_only(resource)
        resource.attributes = updatable_attributes(resource, attributes)
        # TODO: do we really want to call +resource#save+ here?
        #   after all, resource is set via a relationship on assignee;
        #   +resource+ will receive a #save call via +assignee#save+
        resource.save
      end

      def mark_as_destroyable(assignee, resource)
        destroyables(assignee) << resource
      end

      def destroyables(assignee)
        assignee.__send__(:destroyables)
      end

      # Extracts the primary key values necessary to retrieve or update a nested
      # resource when using {Model#accepts_nested_attributes_for}. Values are taken from
      # the specified resource and attribute hash with the former having priority.
      # Values for properties in the primary key that are *not* included in the
      # foreign key must be specified in the attributes hash.
      #
      # @param [DataMapper::Resource] resource
      #   The resource that accepts nested attributes.
      #
      # @param [Hash] attributes
      #   The attributes assigned to the nested attribute setter on the
      #   +resource+.
      #
      # @return [Array, NilClass]
      #   Array if valid key values are present, nil otherwise
      # 
      # @api private
      def extract_key_values(resource, attributes)
        raw_key_values = extract_target_primary_key_values(resource, attributes)
        key_values     = target_model_key.typecast(raw_key_values)

        verify_key_values(key_values)
      end

      def extract_target_primary_key_values(resource, attributes)
        target_model_key.map do |target_property|
          if source_property = target_key_to_source_key_map[target_property]
            resource[source_property.name]
          else
            attributes[target_property.name]
          end
        end
      end

      def target_key_to_source_key_map
        @target_key_to_source_key_map ||=
          Hash[target_key.to_a.zip(source_key.to_a)]
      end

      # @api private
      def verify_key_values(key_values)
        key_properties_and_values = target_model_key.zip(key_values)

        invalid = key_properties_and_values.any? do |property, value|
          verify_key_value(property, value)
        end

        invalid ? nil : key_values
      end

      # @return [Boolean]
      #   whether +value+ is valid for +property+
      # 
      # @api private
      # 
      # TODO: move this into Property?
      def verify_key_value(property, value)
        case
        when property.allow_nil?            then false
        when property.allow_blank?          then value.nil?
        when Property::Boolean === property then false
        else
          DataMapper::Ext.blank?(value)
        end
      end

      # TODO: resolve Law of Demeter violation
      def target_model_key
        target_model.key
      end

      def target_model
        relationship.target_model
      end

      def target_key
        relationship.target_key
      end

      def source_key
        relationship.source_key
      end

      # Can be used to remove ambiguities from the passed attributes.
      # Consider a situation with a belongs_to association where both a valid value
      # for the foreign_key attribute *and* nested_attributes for a new record are
      # present (i.e. item_type_id and item_type_attributes are present).
      # Also see http://is.gd/sz2d on the rails-core ml for a discussion on this.
      # The basic idea is, that there should be a well defined behavior for what
      # exactly happens when such a situation occurs. I'm currently in favor for
      # using the foreign_key if it is present, but this probably needs more thinking.
      # For now, this method basically is a no-op, but at least it provides a hook where
      # everyone can perform it's own sanitization by overwriting this method.
      #
      # @param [Hash] attributes
      #   The attributes to sanitize.
      #
      # @return [Hash]
      #   The sanitized attributes.
      def sanitize_attributes(resource, attributes)
        if resource.respond_to?(:sanitize_attributes)
          # TODO: issue deprecation warning for Resource#sanitize_attributes
          resource.sanitize_attributes(attributes)
        else
          attributes
        end
      end

      # Attribute hash keys that are excluded when creating a nested resource.
      # Excluded attributes include +:_delete+, a special value used to mark a
      # resource for destruction.
      #
      # @param [DataMapper::Resource] resource
      #   Resource for which +attributes+ will be filtered
      #
      # @param [Hash<Symbol => Object>] attributes
      #   Attributes to be filtered according to which of its keys are
      #   creatable in +resource+
      #
      # @return [Hash<Symbol => Object>]
      #   Filtered attributes which are valida for creating +resource+
      def creatable_attributes(resource, attributes)
        DataMapper::Ext::Hash.except(attributes, *uncreatable_keys(resource))
      end

      # Attribute hash keys that are excluded when creating a nested resource.
      # Excluded attributes include +:_delete+, a special value used to mark a
      # resource for destruction.
      #
      # @param [DataMapper::Resource] resource
      #   Resource for which valid creatable attribute keys will be returned
      #
      # @return [Array<Symbol>] Excluded attribute names.
      def uncreatable_keys(resource)
        if resource.respond_to?(:uncreatable_keys)
          # TODO: deprecation warning about Resource#uncreatable_keys
          resource.uncreatable_keys
        else
          [delete_key]
        end
      end

      def updatable_attributes(resource, attributes)
        DataMapper::Ext::Hash.except(attributes, *unupdatable_keys(resource))
      end

      # Attribute hash keys that are excluded when updating a nested resource.
      # Excluded attributes include the model key and :_delete, a special value
      # used to mark a resource for destruction.
      #
      # @param [DataMapper::Resource] resource
      #   Resource for which valid updatable attribute keys will be returned
      #
      # @return [Array<Symbol>] Excluded attribute names.
      def unupdatable_keys(resource)
        if resource.respond_to?(:unupdatable_keys)
          # TODO: deprecation warning about Resource#unupdatable_keys
          resource.unupdatable_keys
        else
          resource.model.key.map { |property| property.name } << delete_key
        end
      end

      def delete_key
        :_delete
      end

      # Determines whether the given attributes hash contains a truthy :_delete key.
      #
      # @param [Hash{Symbol => Object}] attributes
      #   The attributes to test.
      #
      # @return [Boolean]
      #   +true+ if attributes contains a truthy :_delete key.
      #
      # @see TRUE_VALUES
      def has_delete_flag?(attributes)
        value = attributes[delete_key]
        if value.is_a?(String) && value !~ /\S/
          nil
        else
          TRUE_VALUES.include?(value)
        end
      end

      # Determines if a new record should be built with the given attributes.
      # Rejects a new record if {#has_delete_flag?} returns +true+ for the given
      # attributes, or if a +:reject_if+ guard exists for the passed relationship
      # that evaluates to +true+.
      #
      # @param [Hash{Symbol => Object}] attributes
      #   The attributes to test with {#has_delete_flag?}.
      #
      # @return [Boolean]
      #   +true+ if the given attributes will be rejected.
      def reject_new_record?(resource, attributes)
        # if relationship guard is nil, nothing will be rejected
        assignment_guard.active? &&
          (has_delete_flag?(attributes) ||
          assignment_guard.reject?(resource, attributes))
      end

      def assignment_factory
        @assignment_factory || Assignment
      end

      # Raises an exception if the specified resource is dirty or has dirty
      # children.
      #
      # @param [DataMapper::Resource] resource
      #   The resource to check.
      #
      # @return [void]
      #
      # @raise [UpdateConflictError]
      #   If the resource is dirty.
      #
      # @api private
      def assert_nested_update_clean_only(resource)
        if resource.send(:dirty_self?) || resource.send(:dirty_children?)
          new_or_dirty = resource.new? ? 'new' : 'dirty'
          raise UpdateConflictError, "#{resource.model}#update cannot be called on a #{new_or_dirty} nested resource"
        end
      end


      class ManyToMany < Acceptor
        def mark_as_destroyable(assignee, resource)
          intermediary_collection = relationship.through.get(assignee)
          intermediaries = intermediary_collection.all(relationship.via => resource)
          intermediaries.each { |i| destroyables(assignee) << i }

          super
        end

        def extract_key_values(resource, attributes)
          child_key      = relationship.child_key
          raw_key_values = attributes.values_at(*child_key.map { |key| key.name })
          key_values     = child_key.typecast(raw_key_values)

          verify_key_values(key_values)
        end
      end # class ManyToMany

    end # class Acceptor
  end # module NestedAttributes
end # module DataMapper