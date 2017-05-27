namespace :clean do
  task reflections: :environment do
    log = File.open(Rails.root.join('log', 'clean-reflections.log'), 'wb')
    Clean::Support.set_search_path!

    print ' - Reflections: '

    errors = 0
    warnings = 0
    Clean::Support.models_in_file.each do |model|
      log.write "> #{model.name}...\n"
      reflections = model.reflect_on_all_associations(:has_many)
      foreign_keys = ActiveRecord::Base.connection.foreign_keys(model.table_name)
      if ActiveRecord::Base.connection.select_value("SELECT count(*) FROM pg_views WHERE viewname = '#{model.table_name}' AND schemaname NOT IN ('information_schema', 'pg_catalog')").to_i > 0
        log.write "  -> Not a table\n"
        next
      end
      model.reflect_on_all_associations.each do |r|
        next if r.options[:through]
        dependent = r.options[:dependent]
        unless r.polymorphic?
          begin
            foreign_model = r.class_name.constantize
          rescue NameError => e
            log.write "Cannot find model: #{r.class_name} used in #{model.name}##{r.name}\n"
            errors += 1
            next
          end
        end
        if r.macro == :belongs_to && !r.polymorphic? && model.table_name == model.name.underscore.pluralize
          unless foreign_keys.detect { |fk| fk.to_table.to_s == r.class_name.constantize.table_name.to_s && fk.column.to_s == r.foreign_key.to_s }
            log.write "Foreign key #{model.table_name}(#{r.foreign_key}) => #{r.class_name.constantize.table_name} is missing\n"
            errors += 1
          end
        end
        next unless r.macro == :has_many || r.macro == :has_one
        foreign_column = foreign_model.columns_hash[r.foreign_key.to_s]
        unless foreign_column
          log.write "Cannot find foreign key #{foreign_model.table_name}.#{r.foreign_key} used in #{model.name}##{r.name}\n"
          errors += 1
          next
        end
        next unless !foreign_column.null || foreign_model.validators_on(r.foreign_key.to_s.gsub(/_id$/, '')).detect { |v| v.is_a?(ActiveModel::Validations::PresenceValidator) }
        if dependent.nil?
          next if reflections.detect { |b| r != b && b.options[:dependent] }
          log.write "Missing dependent option on #{model.name}##{r.name}\n"
          errors += 1
        elsif !%i[destroy delete_all restrict_with_error restrict_with_exception].include?(dependent)
          next if reflections.detect { |b| r != b && %i[destroy delete_all restrict_with_error restrict_with_exception].include?(b.options[:dependent]) }
          log.write "Invalid dependent option on #{model.name}##{r.name}: #{dependent}\n"
          errors += 1
        end
      end
    end
    print "#{errors.to_s.rjust(3)} errors\n" # , #{warnings.to_s.rjust(3)} warnings
    log.close
  end
end
