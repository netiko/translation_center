module TranslationCenter

  def self.deep_sort hash
    if hash.is_a? Hash
      hash.keys.sort.each_with_object({}) { |k,new| new[k] = deep_sort hash[k] }
    else
      hash
    end
  end

  def self.collect_keys(scope, translations)
    full_keys = []
    translations.to_a.each do |key, translations|
      new_scope = scope.dup << key
      if translations.is_a?(Hash)
        full_keys += collect_keys(new_scope, translations)
      else
        full_keys << new_scope.join('.')
      end
    end
    return full_keys
  end

  # takes kay and translation and updates its value
  def self.update_translation(key, translation, all_yamls)
    has_value = true
    path = key.name.split('.')
    value = all_yamls[translation.lang.to_sym] || {}
    path.each do |step|
      step_sym = step.to_sym
      unless value.has_key? step_sym
        has_value = false
        break
      end
      value = value[step_sym]
    end
    value = value.stringify_keys if value.is_a? Hash

    if ! has_value
      translation.destroy unless translation.new_record?
      false
    elsif value.is_a?(Proc)
      puts "proc removed for translation #{translation.lang}.#{key.name}"
      translation.destroy unless translation.new_record?
      true
    elsif translation.value != value || translation.new_record?
      begin
        translation.update_attribute(:value, value)
        translation.accept if TranslationCenter::CONFIG['yaml2db_translations_accepted']
        true
      rescue StandardError => e
        puts "invalid translation: #{translation.lang}.#{key.name}: #{value.inspect}: #{e}"
        translation.destroy unless translation.new_record?
        false
      end
    else
      true
    end
  end

  # takes key and creates locale and creates a new translation
  def self.ceate_missing_translation(key, locale, translator, all_yamls)
    translation = TranslationCenter::Translation.new translation_key: key, lang: locale,
      translator_type: TranslationCenter::CONFIG['translator_type'], translator: translator

    update_translation key, translation, all_yamls
  end

  # takes array of keys and creates/updates the keys in the db with translations in the given locales
  def self.yaml2db_keys(all_keys, translator, locales, all_yamls)
    # initialize stats variables
    new_keys = 0
    missing_keys = locales.inject({}) do |memo, lang|
      memo[lang] = 0
      memo
    end
    options = { translator_id: translator.id }
    options.merge!(lang: locales) if (I18n.available_locales - locales).present?

    all_keys.each_slice(20) do |key_names|
      present_keys = []

      # update keys that exist in the db
      keys = TranslationCenter::TranslationKey.where(name: key_names)
      ActiveRecord::Associations::Preloader.new.preload(keys, [:translations], TranslationCenter::Translation.where(options))
      keys.each do |key|
        present_keys << key.name
        present_locales = []

        # update translations that exist in the db
        key.translations.each do |translation|
          locale = translation.lang.to_sym
          present_locales << locale
          missing_keys[locale] += 1 unless update_translation(key, translation, all_yamls)
        end

        # create missing translations for existing keys
        (locales - present_locales).each do |locale|
          missing_keys[locale] += 1 unless ceate_missing_translation(key, locale, translator, all_yamls)
        end
      end

      missing = key_names - present_keys

      # create missing keys
      missing.each do |key_name|
        new_keys += 1

        key = TranslationCenter::TranslationKey.new(name: key_name)
        key.save

        # create translations
        locales.each do |locale|
          missing_keys[locale] += 1 unless ceate_missing_translation(key, locale, translator, all_yamls)
        end
      end
    end

    puts "found new #{new_keys} key(s)"
    missing_keys.each do |locale, count|
      puts "missing #{count} translation(s) for #{locale}" if count > 0
    end
  end

  def self.overlap()
    I18n.backend.send(:init_translations)
    all_yamls = I18n.backend.send(:translations)
    all_keys = keys_in_yamls all_yamls

    # check for overlapping keys (e.g foo and foo.bar)
    overlap = all_keys.map do |key|
      key if all_keys.grep(/\A#{key}\./).any?
    end.compact
    puts "overlapping keys: #{overlap.inspect}" if overlap.any?
    overlap
  end

  def self.keys_in_yamls all_yamls
    all_keys = all_yamls.collect do |check_locale, translations|
      collect_keys([], translations).sort
    end.flatten.uniq

    # Use shared key for pluralizations (foo.one: Foo, foo.other: Foos -> foo: {one: Foo, other: Foos})
    pluralization_regexp = /\.(zero|one|two|few|many|other)\Z/
    remove_keys = []
    all_keys.grep(pluralization_regexp).map do |key|
      key_prefix = key.sub /\.[^.]+\Z/, ''
      keys = all_keys.grep /\A#{key_prefix}\./
      if keys.all? { |key| key =~ pluralization_regexp }
        remove_keys << keys
        all_keys << key_prefix
      end
    end
    all_keys -= remove_keys.flatten.uniq
    all_keys.uniq!.sort!

    if filter = TranslationCenter::CONFIG['key_filter']
      keys_before = all_keys.count
      all_keys.reject! { |k| k =~ /#{filter}/ }
      keys_filtered = keys_before - all_keys.count
      puts "#{keys_filtered} #{keys_filtered == 1 ? 'key' : 'keys'} filtered" if keys_filtered.nonzero?
    end

    all_keys
  end

  # take the yaml translations and update the db with them
  def self.yaml2db(locale=nil)

    # prepare translator by creating the translator if he doesn't exist
    translator = TranslationCenter.prepare_translator

    # if couldn't create translator then print error msg and quit
    if translator.blank?
      puts "ERROR: Unable to create default translator with #{TranslationCenter::CONFIG['identifier_type']} = #{TranslationCenter::CONFIG['yaml_translator_identifier']}"
      puts "Create this user manually and run the rake again"
      return false
    end

    # Make sure we've loaded the translations
    I18n.backend.send(:init_translations)
    puts "#{I18n.available_locales.size} #{I18n.available_locales.size == 1 ? 'locale' : 'locales'} available: #{I18n.available_locales.join(', ')}"

    # Get all keys from all locales
    all_yamls = I18n.backend.send(:translations)
    all_keys = keys_in_yamls all_yamls

    puts "#{all_keys.size} #{all_keys.size == 1 ? 'unique key' : 'unique keys'} found."

    locales = locale.blank? ? I18n.available_locales : locale.split(' ').map(&:to_sym)
    # create records for all keys that exist in the yaml
    yaml2db_keys(all_keys, translator, locales, all_yamls)
  end

  def self.db2yaml(locale=nil)
    locales = locale.blank? ? I18n.available_locales : locale.split(' ').map(&:to_sym)

    # for each locale build a hash for the translations and write to file
    locales.each do |locale|
      puts "Started exporting translations in #{locale}"
      all_keys = {}
      TranslationCenter::Translation.where(lang: locale, status: 'accepted').includes(:translation_key).in_batches do |batch|
        batch.each do |t|
          all_keys[t.key.name] = t.value
        end
      end
      result = {}
      all_keys.sort.each do |full_key, value|
        begin
          keys = full_key.split('.')
          last_key = keys.pop
          hash = keys.inject(result) { |hash, key| hash[key] ||= {} }
          hash[last_key] = value
        rescue
          puts "Error writing key: #{locale}.#{full_key} to yaml"
        end
      end
      File.open("config/locales/#{locale.to_s}.yml", 'w') do |file|
        file.write(YAML.dump locale.to_s => result)
      end
      puts "Done exporting translations of #{locale} to #{locale.to_s}.yml"
    end
  end

  def self.deldbkeys(locales = nil, dry_run = false)
    if locales.present?
      locales = locales.split(/[ .,:;]/) if locales.is_a? String
      locales = locales.map(&:to_sym)
      if (locales - I18n.available_locales).any? || locales.none?
        puts "invalid locale: #{locales - I18n.available_locales}"
        return
      end
    end

    I18n.backend.send(:init_translations)
    all_yamls = I18n.backend.send(:translations)
    all_yamls.select! { |loc| loc.in? locales } if locales.present?
    yaml_keys = keys_in_yamls all_yamls
    num = { keys: 0 }

    db_keys = TranslationCenter::TranslationKey.pluck(:name) - yaml_keys
    if dry_run
      puts db_keys
      num[:keys] += db_keys.count

      puts "would have removed #{num[:keys]} keys"
    else
      db_keys.each_slice(100) do |keys|
        num[:keys] += TranslationCenter::TranslationKey.where(name: keys).destroy_all.count
      end

      num[:categories] = TranslationCenter::Category.joins('LEFT JOIN translation_center_translation_keys ON translation_center_translation_keys.category_id = translation_center_categories.id')
        .where(translation_center_translation_keys: { id: nil }).destroy_all.count

      puts "removed #{num[:keys]} keys and #{num[:categories]} categories"
    end

    num
  end

end
