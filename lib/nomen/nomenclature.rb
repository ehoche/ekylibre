module Nomen

  # This class represent a nomenclature
  class Nomenclature

    attr_reader :attributes, :items, :name, :roots

    # Instanciate a new nomenclature
    def initialize(name)
      @name = name.to_sym
      @items = HashWithIndifferentAccess.new
      @roots = []
      @attributes = HashWithIndifferentAccess.new
    end

    class << self

      def harvest(nomenclature_name, nomenclatures)
        sets = HashWithIndifferentAccess.new
        for nomenclature in nomenclatures
          namespace, name = nomenclature.attr("name").to_s.split(NS_SEPARATOR)[0..1]
          name = :root if name.blank?
          sets[name] = nomenclature
        end

        # Find root
        unless root = sets[:root]
          raise ArgumentError.new("Missing root nomenclature in set #{nomenclature_name}")
        end

        # Browse recursively nomenclatures and sub-nomenclatures
        n = Nomenclature.new(nomenclature_name)
        n.harvest(root, sets, root: true)
        return n
      end

    end

    # Browse and harvest items recursively
    def harvest(nomenclature, sets, options = {})
      for attribute in nomenclature.xpath('xmlns:attributes/xmlns:attribute')
        add_attribute(attribute)
      end
      # Items
      for item in nomenclature.xpath('xmlns:items/xmlns:item')
        i = self.add_item(item, parent: options[:parent]) # , :attributes => attributes
        @roots << i if options[:root]
        if sets[i.name]
          self.harvest(sets[i.name], sets, :parent => i) # , :attributes => attributes
        end
      end
      return self
    end

    # Add an item to the nomenclature
    def add_item(element, options = {})
      i = Item.new(self, element, options)
      @items[i.name] = i
      return i
    end

    # Add an attribute to the nomenclature
    def add_attribute(element, options = {})
      a = AttributeDefinition.new(self, element, options)
      @attributes[a.name] = a
      return a
    end

    def check!
      # Check attributes
      for attribute in @attributes.values
        if attribute.choices_nomenclature and !attribute.inline_choices? and !Nomen[attribute.choices_nomenclature.to_s]
          raise InvalidAttribute, "[#{self.name}] #{attribute.name} nomenclature attribute must refer to an existing nomenclature. Got #{attribute.choices_nomenclature.inspect}. Expecting: #{Nomen.names.inspect}"
        end
        if attribute.type == :choice and attribute.default
          unless attribute.choices.include?(attribute.default)
            raise InvalidAttribute, "The default choice #{attribute.default.inspect} is invalid (in #{self.name}##{attribute.name}). Pick one from #{attribute.choices.sort.inspect}."
          end
        end
      end

      # Check items
      for item in list
        for attribute in @attributes.values
          choices = attribute.choices
          if item.attr(attribute.name) and attribute.type == :choice
            # Cleans for parametric reference
            name = item.attr(attribute.name).to_s.split(/\(/).first.to_sym
            unless choices.include?(name)
              raise InvalidAttribute, "The given choice #{name.inspect} is invalid (in #{self.name}##{item.name}). Pick one from #{choices.sort.inspect}."
            end
          elsif item.attr(attribute.name) and attribute.type == :list and attribute.choices_nomenclature
            for name in item.attr(attribute.name) || []
              # Cleans for parametric reference
              name = name.to_s.split(/\(/).first.to_sym
              unless choices.include?(name)
                raise InvalidAttribute, "The given choice #{name.inspect} is invalid (in #{self.name}##{item.name}). Pick one from #{choices.sort.inspect}."
              end
            end
          end
        end
      end

      # Default return
      return true
    end


    # Return human name
    def human_name
      "nomenclatures.#{nomenclature.name}.name".t(:default => ["labels.#{name}".to_sym, name.humanize])
    end
    alias :humanize :human_name

    # Returns the given item
    def [](item_name)
      @items[item_name]
    end

    # List all item names. Can filter on a given item name and its children
    def to_a(item_name = nil)
      if item_name
        @items[item_name].self_and_children.map(&:name)
      else
        return @items.keys.sort
      end
    end
    alias :all :to_a

    # Return first item name
    def first(item_name = nil)
      all(item_name).first
    end

    # Return the default item name
    def default(item_name = nil)
      first(item_name)
    end

    # Return the Item for the given name
    def find(item_name)
      return @items[item_name]
    end

    # Returns list of items as an Array
    def list
      return @items.values
    end

    # List items with attributes filtering
    def where(attributes)
      @items.values.select do |item|
        valid = true
        for attribute, value in attributes
          valid = false unless item.attr(attribute) == value
        end
        valid
      end
    end

    # Returns Attribute descriptor
    def method_missing(method_name)
      return @attributes[method_name] || super
    end

  end

end
