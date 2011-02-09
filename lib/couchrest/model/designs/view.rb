module CouchRest
  module Model
    module Designs

      #
      # A proxy class that allows view queries to be created using
      # chained method calls. After each call a new instance of the method
      # is created based on the original in a similar fashion to ruby's Sequel 
      # library, or Rails 3's Arel.
      #
      # CouchDB views have inherent limitations, so joins and filters as used in 
      # a normal relational database are not possible.
      #
      class View
        include Enumerable

        attr_accessor :model, :name, :query, :result

        # Initialize a new View object. This method should not be called from
        # outside CouchRest Model.
        def initialize(parent, new_query = {}, name = nil)
          if parent.is_a?(Class) && parent < CouchRest::Model::Base
            raise "Name must be provided for view to be initialized" if name.nil?
            self.model    = parent
            self.name     = name.to_s
            # Default options:
            self.query    = { :reduce => false }
          elsif parent.is_a?(self.class)
            self.model    = (new_query.delete(:proxy) || parent.model)
            self.name     = parent.name
            self.query    = parent.query.dup
          else
            raise "View cannot be initialized without a parent Model or View"
          end
          query.update(new_query)
          super()
        end


        # == View Execution Methods
        #
        # Request to the CouchDB database using the current query values.
       
        # Return each row wrapped in a ViewRow object. Unlike the raw
        # CouchDB request, this will provide an empty array if there
        # are no results.
        def rows
          return @rows if @rows
          if execute && result['rows']
            @rows ||= result['rows'].map{|v| ViewRow.new(v, model)}
          else 
            [ ]
          end
        end

        # Fetch all the documents the view can access. If the view has
        # not already been prepared for including documents in the query,
        # it will be added automatically and reset any previously cached
        # results.
        def all
          include_docs!
          docs
        end

        # Provide all the documents from the view. If the view has not been
        # prepared with the +include_docs+ option, each document will be 
        # loaded individually.
        def docs
          @docs ||= rows.map{|r| r.doc}
        end

        # If another request has been made on the view, this will return 
        # the first document in the set. If not, a new query object will be
        # generated with a limit of 1 so that only the first document is 
        # loaded.
        def first
          result ? all.first : limit(1).all.first
        end

        # Same as first but will order the view in descending order. This
        # does not however reverse the search keys or the offset, so if you 
        # are using a +startkey+ and +endkey+ you might end up with 
        # unexpected results.
        #
        # If in doubt, don't use this method!
        #
        def last
          result ? all.last : limit(1).descending.all.last
        end

        # Perform a count operation based on the current view. If the view
        # can be reduced, the reduce will be performed and return the first
        # value. This is okay for most simple queries, but may provide
        # unexpected results if your reduce method does not calculate
        # the total number of documents in a result set.
        #
        # Trying to use this method with the group option will raise an error.
        #
        # If no reduce function is defined, a query will be performed 
        # to return the total number of rows, this is the equivalant of:
        #
        #    view.limit(0).total_rows
        #
        def count
          raise "View#count cannot be used with group options" if query[:group]
          if can_reduce?
            row = reduce.rows.first
            row.nil? ? 0 : row.value
          else
            limit(0).total_rows
          end
        end

        # Check to see if the array of documents is empty. This *will* 
        # perform the query and return all documents ready to use, if you don't
        # want to load anything, use +#total_rows+ or +#count+ instead.
        def empty?
          all.empty?
        end

        # Run through each document provided by the +#all+ method.
        # This is also used by the Enumerator mixin to provide all the standard
        # ruby collection directly on the view.
        def each(&block)
          all.each(&block)
        end

        # Wrapper for the results offset. As per the CouchDB API,
        # this may be nil if groups are used.
        def offset
          execute['offset']
        end

        # Wrapper for the total_rows value provided by the query. As per the
        # CouchDB API, this may be nil if groups are used.
        def total_rows
          execute['total_rows']
        end

        # Convenience wrapper around the rows result set. This will provide
        # and array of keys.
        def keys
          rows.map{|r| r.key}
        end

        # Convenience wrapper to provide all the values from the route
        # set without having to go through +rows+.
        def values
          rows.map{|r| r.value}
        end

        # Accept requests as if the view was an array. Used for backwards compatibity
        # with older queries:
        #
        #    Model.all(:raw => true, :limit => 0)['total_rows']
        #
        # In this example, the raw option will be ignored, and the total rows
        # will still be accessible.
        # 
        def [](value)
          execute[value]
        end

        # No yet implemented. Eventually this will provide a raw hash
        # of the information CouchDB holds about the view.
        def info
          raise "Not yet implemented"
        end


        # == View Filter Methods
        # 
        # View filters return a copy of the view instance with the query 
        # modified appropriatly. Errors will be raised if the methods
        # are combined in an incorrect fashion.
        #
       

        # Find all entries in the index whose key matches the value provided.
        #
        # Cannot be used when the +#startkey+ or +#endkey+ have been set.
        def key(value)
          raise "View#key cannot be used when startkey or endkey have been set" unless query[:startkey].nil? && query[:endkey].nil?
          update_query(:key => value)
        end

        # Find all index keys that start with the value provided. May or may 
        # not be used in conjunction with the +endkey+ option.
        #
        # When the +#descending+ option is used (not the default), the start 
        # and end keys should be reversed, as per the CouchDB API.
        #
        # Cannot be used if the key has been set.
        def startkey(value)
          raise "View#startkey cannot be used when key has been set" unless query[:key].nil?
          update_query(:startkey => value)
        end

        # The result set should start from the position of the provided document. 
        # The value may be provided as an object that responds to the +#id+ call
        # or a string.
        def startkey_doc(value)
          update_query(:startkey_docid => value.is_a?(String) ? value : value.id)
        end

        # The opposite of +#startkey+, finds all index entries whose key is before
        # the value specified.
        #
        # See the +#startkey+ method for more details and the +#inclusive_end+
        # option.
        def endkey(value)
          raise "View#endkey cannot be used when key has been set" unless query[:key].nil?
          update_query(:endkey => value)
        end

        # The result set should end at the position of the provided document. 
        # The value may be provided as an object that responds to the +#id+ 
        # call or a string.
        def endkey_doc(value)
          update_query(:endkey_docid => value.is_a?(String) ? value : value.id)
        end


        # The results should be provided in descending order.
        #
        # Descending is false by default, this method will enable it and cannot
        # be undone.
        def descending
          update_query(:descending => true)
        end

        # Limit the result set to the value supplied.
        def limit(value)
          update_query(:limit => value)
        end

        # Skip the number of entries in the index specified by value. This would be
        # the equivilent of an offset in SQL.
        #
        # The CouchDB documentation states that the skip option should not be used
        # with large data sets as it is inefficient. Use the +startkey_doc+ method
        # instead to skip ranges efficiently.
        def skip(value = 0)
          update_query(:skip => value)
        end

        # Use the reduce function on the view. If none is available this method
        # will fail. 
        def reduce
          raise "Cannot reduce a view without a reduce method" unless can_reduce?
          update_query(:reduce => true)
        end

        # Control whether the reduce function reduces to a set of distinct keys
        # or to a single result row.
        #
        # By default the value is false, and can only be set when the view's 
        # +#reduce+ option has been set.
        def group
          raise "View#reduce must have been set before grouping is permitted" unless query[:reduce]
          update_query(:group => true)
        end

        # Will set the level the grouping should be performed to. As per the 
        # CouchDB API, it only makes sense when the index key is an array.
        # 
        # This will automatically set the group option.
        def group_level(value)
          group.update_query(:group_level => value.to_i)
        end

        def include_docs
          update_query.include_docs!
        end

        ### Special View Filter Methods

        # Specify the database the view should use. If not defined,
        # an attempt will be made to load its value from the model.
        def database(value)
          update_query(:database => value)
        end

        # Set the view's proxy that will be used instead of the model
        # for any future searches. As soon as this enters the
        # new object's initializer it will be removed and replace
        # the model object.
        #
        # See the Proxyable mixin for more details.
        #
        def proxy(value)
          update_query(:proxy => value)
        end

        # Return any cached values to their nil state so that any queries
        # requested later will have a fresh set of data.
        def reset!
          self.result = nil
          @rows = nil
          @docs = nil
        end

        protected

        def include_docs!
          reset! if result && !include_docs?
          query[:include_docs] = true
          self
        end

        def include_docs?
          !!query[:include_docs]
        end

        def update_query(new_query = {})
          self.class.new(self, new_query)
        end

        def design_doc
          model.design_doc
        end

        def can_reduce?
          !design_doc['views'][name]['reduce'].blank?
        end

        def use_database
          query[:database] || model.database
        end
        
        def execute
          return self.result if result
          raise "Database must be defined in model or view!" if use_database.nil?
          retryable = true
          # Remove the reduce value if its not needed
          query.delete(:reduce) unless can_reduce?
          begin
            self.result = model.design_doc.view_on(use_database, name, query)
          rescue RestClient::ResourceNotFound => e
            if retryable
              model.save_design_doc(use_database)
              retryable = false
              retry
            else
              raise e
            end
          end
        end

        # Class Methods
        class << self
          
          # Simplified view creation. A new view will be added to the 
          # provided model's design document using the name and options.
          #
          # If the view name starts with "by_" and +:by+ is not provided in 
          # the options, the new view's map method will be interpretted and
          # generated automatically. For example:
          #
          #   View.create(Meeting, "by_date_and_name")
          #
          # Will create a view that searches by the date and name properties. 
          # Explicity setting the attributes to use is possible using the 
          # +:by+ option. For example:
          #
          #   View.create(Meeting, "by_date_and_name", :by => [:date, :firstname, :lastname])
          #
          # The view name is the same, but three keys would be used in the
          # subsecuent index.
          #
          def create(model, name, opts = {})

            unless opts[:map]
              if opts[:by].nil? && name.to_s =~ /^by_(.+)/
                opts[:by] = $1.split(/_and_/)
              end

              raise "View cannot be created without recognised name, :map or :by options" if opts[:by].nil?

              opts[:guards] ||= []
              opts[:guards].push "(doc['#{model.model_type_key}'] == '#{model.to_s}')"

              keys = opts[:by].map{|o| "doc['#{o}']"}
              emit = keys.length == 1 ? keys.first : "[#{keys.join(', ')}]"
              opts[:guards] += keys.map{|k| "(#{k} != null)"}
              opts[:map] = <<-EOF
                function(doc) {
                  if (#{opts[:guards].join(' && ')}) {
                    emit(#{emit}, 1);
                  }
                }
              EOF
              opts[:reduce] = <<-EOF
                function(key, values, rereduce) {
                  return sum(values);
                }
              EOF
            end

            model.design_doc['views'] ||= {}
            view = model.design_doc['views'][name.to_s] = { }
            view['map'] = opts[:map]
            view['reduce'] = opts[:reduce] if opts[:reduce]
            view
          end

        end

      end

      # A special wrapper class that provides easy access to the key
      # fields in a result row.
      class ViewRow < Hash
        attr_reader :model
        def initialize(hash, model)
          @model    = model
          replace(hash)
        end
        def id
          self["id"]
        end
        def key
          self["key"]
        end
        def value
          self['value']
        end
        def raw_doc
          self['doc']
        end
        # Send a request for the linked document either using the "id" field's
        # value, or the ["value"]["_id"] used for linked documents.
        def doc
          return model.build_from_database(self['doc']) if self['doc']
          doc_id = (value.is_a?(Hash) && value['_id']) ? value['_id'] : self.id
          model.get(doc_id)
        end
      end

    end
  end
end