module ZendeskAPI
  module Save
    # If this resource hasn't been deleted, then create or save it.
    # Executes a POST if it is a {Data#new_record?}, otherwise a PUT.
    # Merges returned attributes on success.
    # @return [Boolean] Success?
    def save(options={})
      return false if respond_to?(:destroyed?) && destroyed?

      if new_record?
        method = :post
        req_path = path
      else
        method = :put
        req_path = url || path
      end

      req_path = options[:path] if options[:path]

      save_associations

      @response = @client.connection.send(method, req_path) do |req|
        req.body = if self.class.unnested_params
          attributes.changes
        else
          {self.class.singular_resource_name.to_sym => attributes.changes}
        end
      end

      @attributes.replace @attributes.deep_merge(@response.body[self.class.singular_resource_name] || {})
      @attributes.clear_changes
      clear_associations
      true
    end

    # Saves, raising an Argument error if it fails
    # @raise [ArgumentError] if saving failed
    def save!(options={})
      save(options) || raise("Save failed")
    end

    # Removes all cached associations
    def clear_associations
      self.class.associations.each do |association_data|
        name = association_data[:name]
        instance_variable_set("@#{name}", nil) if instance_variable_defined?("@#{name}")
      end
    end

    # Saves associations
    # Takes into account inlining, collections, and id setting on the parent resource.
    def save_associations
      self.class.associations.each do |association_data|
        association_name = association_data[:name]
        next unless send("#{association_name}_used?") && association = send(association_name)

        inline_creation = association_data[:inline] == :create && new_record?
        changed = association.is_a?(Collection) || !association.changes.empty?

        if association.respond_to?(:save) && changed && !inline_creation && association.save
          self.send("#{association_name}=", association) # set id/ids columns
        end

        if association_data[:inline] == true || inline_creation
          if association.changed?
            attributes[association_name] = (association.is_a?(Collection) ? association.map(&:to_param) : association.to_param)
          end
        end
      end
    end
  end

  module Read
    include Rescue

    def self.extended(klass)
      klass.send(:include, ZendeskAPI::Sideloading)
    end

    # Finds a resource by an id and any options passed in.
    # A custom path to search at can be passed into opts. It defaults to the {Data.resource_name} of the class.
    # @param [Client] client The {Client} object to be used
    # @param [Hash] options Any additional GET parameters to be added
    def find(client, options = {})
      @client = client # so we can use client.logger in rescue

      raise ArgumentError, "No :id given" unless options[:id] || options["id"] || ancestors.include?(SingularResource)
      association = options.delete(:association) || Association.new(:class => self)

      includes = Array(options[:include])
      options[:include] = includes.join(",") if includes.any?

      response = client.connection.get(association.generate_path(options)) do |req|
        req.params = options
      end

      new(client, response.body[singular_resource_name]).tap do |resource|
        resource.set_includes(resource, includes, response.body)
      end
    end

    rescue_client_error :find
  end

  module Create
    include Save

    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      include Rescue

      # Create a resource given the attributes passed in.
      # @param [Client] client The {Client} object to be used
      # @param [Hash] attributes The attributes to create.
      def create(client, attributes = {})
        ZendeskAPI::Client.check_deprecated_namespace_usage attributes, singular_resource_name
        resource = new(client, attributes)
        return unless resource.save
        resource
      end

      # Creates the resource, raising an ArgumentError if it fails
      # @raise [ArgumentError] if the creation fails
      def create!(client, attributes={})
        c = create(client, attributes)
        c || raise("Create failed #{self} #{attributes}")
      end

      rescue_client_error :create
    end
  end

  module Destroy
    include Rescue

    def self.included(klass)
      klass.extend(ClassMethod)
    end

    # Has this object been deleted?
    def destroyed?
      @destroyed ||= false
    end

    # If this resource hasn't already been deleted, then do so.
    # @return [Boolean] Successful?
    def destroy
      return false if destroyed? || new_record?
      @client.connection.delete(url || path)
      @destroyed = true
    end

    rescue_client_error :destroy, :with => false

    module ClassMethod
      include Rescue

      # Deletes a resource given the id passed in.
      # @param [Client] client The {Client} object to be used
      # @param [Hash] opts The optional parameters to pass. Defaults to {}
      def destroy(client, opts = {})
        @client = client # so we can use client.logger in rescue
        association = opts.delete(:association) || Association.new(:class => self)

        client.connection.delete(association.generate_path(opts)) do |req|
          req.params = opts
        end

        true
      end

      rescue_client_error :destroy, :with => false
    end
  end

  module Update
    include Rescue
    include Save

    def self.included(klass)
      klass.extend(ClassMethod)
    end

    rescue_client_error :save, :with => false

    module ClassMethod
      include Rescue

      # Updates  a resource given the id passed in.
      # @param [Client] client The {Client} object to be used
      # @param [Hash] attributes The attributes to update. Default to {} 
      def update(client, attributes = {})
        ZendeskAPI::Client.check_deprecated_namespace_usage attributes, singular_resource_name
        resource = new(client, :id => attributes.delete(:id))
        resource.attributes.merge!(attributes)
        resource.save
      end

      rescue_client_error :update, :with => false
    end
  end
end
