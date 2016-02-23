require "bing_translator"

module TranslationCenter

  def self.deep_sort hash
    if hash.is_a? Hash
      hash.keys.sort.each_with_object({}) { |k,new| new[k] = deep_sort hash[k] }
    else
      hash = hash.to_s if hash.is_a? String
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

  def self.flatten_keys translations, scope = nil, all_keys = {}
    translations.each do |key, translation|
      new_scope = scope ? "#{scope}.#{key}" : key.to_s
      if translation.is_a?(Hash)
        flatten_keys(translation, new_scope, all_keys)
      else
        all_keys[new_scope] = translation
      end
    end
    all_keys
  end

  def self.insert_key full_key, value, result
    begin
      keys = full_key.split('.')
      last_key = keys.pop
      hash = keys.inject(result) { |hash, key| hash[key] ||= {} }
      hash[last_key] = value
    rescue
      puts "Error writing key: #{full_key} to yaml"
    end
  end

  def self.unflatten all_keys
    result = {}
    all_keys.sort.each do |full_key, value|
      insert_key full_key, value, result
    end
    result
  end

  def self.value_from_hash key, hash, to_sym = true
    has_value = true
    path = key.split('.')
    value = hash || {}
    path.each do |step|
      if to_sym
        step_sym = step.to_sym
      else
        step_sym = step
      end
      unless value.is_a?(Hash) && value.has_key?(step_sym)
        puts "not a hash at #{key}: #{value.inspect}" if ! value.is_a?(Hash)
        has_value = false
        value = nil
        break
      end
      value = value[step_sym]
    end
    value = value.stringify_keys if value.is_a? Hash

    [value, has_value]
  end

  # takes kay and translation and updates its value
  def self.update_translation(key, translation, all_yamls)
    value, has_value = value_from_hash key.name, all_yamls[translation.lang.to_sym]

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
      collect_keys([], translations)
    end.flatten
    all_keys.uniq!

    # Use shared key for pluralizations (foo.one: Foo, foo.other: Foos -> foo: {one: Foo, other: Foos})
    pluralization_regexp = /\.(zero|one|two|few|many|other)\Z/
    remove_keys = []
    all_keys.grep(pluralization_regexp).each do |key|
      key_prefix = key.sub /\.[^.]+\Z/, ''
      keys = all_keys.grep /\A#{Regexp.escape key_prefix}\./
      if keys.all? { |key| key =~ pluralization_regexp }
        remove_keys << keys
        all_keys << key_prefix
      end
    end
    all_keys -= remove_keys.flatten.uniq

    # remove keys which match filter
    if filter = TranslationCenter::CONFIG['key_filter']
      keys_before = all_keys.count
      all_keys.reject! { |k| k =~ /#{filter}/ }
      keys_filtered = keys_before - all_keys.count
      puts "#{keys_filtered} #{keys_filtered == 1 ? 'key' : 'keys'} filtered" if keys_filtered.nonzero?
    end

    all_keys.uniq!
    all_keys.sort!
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
      result = deep_sort unflatten all_keys
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

  def self.pack_in_batches items, max_items = 2000, max_chars = 10000
    items = items.sort{ |a,b| b.first <=> a.first }
    batches = []

    while items.any? && items.first.first >= max_chars do
      batches << [items.unshift]
    end

    while items.present? do
      batch = []
      char_count = 0
      items.reject! do |size, name|
        break if char_count >= max_chars || batch.count >= max_items
        if char_count + size <= max_chars
          batch << name
          char_count += size
          true
        else
          false
        end
      end
      batches << batch
    end
    batches
  end

  def self.prepare_value key, value, plural_n = nil
    if ! key =~ /_html\Z/ && ! value =~ /&[a-zA-Z]*;|<\/.*>|<.*\/>/
      value = CGI.escape_html value
    end
    value = value.gsub /%{count}/ do plural_n end if plural_n
    n = -1
    value = value.gsub /%{.*?}/ do n += 1; "<#{n}/>" end
    value
  end

  def self.unprepare_value key, translation, old_value, plural_n = nil
    groups = old_value.scan /%{.*?}/
    translation = translation.gsub /<(\d+)\/?>(?:<\/\1>)?/ do |match| groups[$1.to_i] end
    if plural_n
      matches = old_value.scan /#{plural_n}|%{count}/
      translation = translation.gsub /#{plural_n}/ do |match| matches.shift || match end
    end
    if ! key =~ /_html\Z/ && ! old_value =~ /&[a-zA-Z]*;|<\/.*>|<.*\/>/
      translation = CGI.unescape_html translation
    end
    translation
  end

  def self.translate_yaml(from_locale, to_locales)
    from_locale = from_locale.to_sym
    return puts "from_locale is invalid" unless from_locale.in? I18n.available_locales
    if to_locales.present?
      to_locales = to_locales.split(/[ .,:;]/) if to_locales.is_a? String
      to_locales = to_locales.map(&:to_sym)
      return puts "invalid to_locale: #{to_locales - I18n.available_locales}" if (to_locales - I18n.available_locales).any? || to_locales.none?
    else
      to_locales = I18n.available_locales - [from_locale]
    end
    return puts "from and to locale must differ" if from_locale.in? to_locales

    num = to_locales.each_with_object({}) { |locale, num| num[locale] = [] }

    I18n.backend.send(:init_translations)
    all_yamls = I18n.backend.send(:translations)
    all_yamls.select! { |locale| locale.in?(to_locales) || locale == from_locale }
    all_keys = keys_in_yamls all_yamls

    bing_id = ENV['BING_TRANSLATE_ID']
    bing_secret = ENV['BING_TRANSLATE_SECRET']
    if bing_id.present? && bing_secret.present?
      translator = BingTranslator.new(bing_id, bing_secret)
    else
      return puts "BING_TRANSLATE_ID and BING_TRANSLATE_SECRET are required"
    end

    from_plurals = I18n.t('i18n.plural.keys', locale: from_locale).map(&:to_s)
    to_locales.each do |to_locale|
      result = {}
      bing_locale =  I18n.t('i18n.bing_locale', locale: to_locale, default: to_locale.to_s)
      # plural rules for target locale
      plural = I18n.t('i18n.plural', locale: to_locale)
      to_plurals = plural[:keys].map(&:to_s)
      plural_rule = plural[:rule]

      plural_n = to_plurals.each_with_object({}) do |name, plural_n|
        name_sym = name.to_sym
        n = ((1..100).to_a << 1000000 << 1.5 << 0).find { |i| plural_rule.call(i) == name_sym }
        raise "n for plural of #{to_locale}.#{name} couldn't be determined" unless n
        plural_n[name] = n
      end
      # get keys to translate and pack them into batches of acceptable size for bing
      sizes = all_keys.each_with_object([]) do |key, sizes|
        to, has_value = value_from_hash key, all_yamls[to_locale]
        insert_key key, to, result if has_value
        next if to.present?

        # split plurals, arrays
        from, _ = value_from_hash key, all_yamls[from_locale]
        if from.is_a?(String) && from.present?
          prepared = prepare_value key, from
          sizes << [prepared.length, [key, from, prepared]]
        elsif from.is_a?(Hash) && from.keys.present? && (from.keys - ['zero', 'one', 'two', 'few', 'many', 'other']).none?
          if from['zero'].is_a?(String) && from['zero'].present?
            prepared = prepare_value key, from['zero'], 0
            sizes << [prepared.length, [key, from['zero'], prepared, 'zero']]
          end
          to_plurals.each do |plural|
            v = from[plural].presence || from['other'].presence || from.values.find { |f| f.present? }
            if v.is_a?(String) && v.present?
              prepared = prepare_value key, v, plural_n[plural]
              sizes << [prepared.length, [key, v, prepared, plural]]
            end
          end
        elsif from.is_a?(Array)
          from.each_with_index do |v,i|
            if v.is_a?(String) && v.present?
              prepared = prepare_value key, v
              sizes << [prepared.length, [key, v, prepared, i]]
            end
          end
        end
      end
      batches = pack_in_batches sizes

      begin
        plural_keys = []
        batches.each do |batch|
          # values for bing
          values = batch.map { |key, old_value, prepared, type| prepared }

          # do the translation
          #translated = values.map(&:upcase)
          translated = translator.translate_array values, from: from_locale, to: bing_locale, content_type: 'text/html'
          translated = translated.map(&:to_s) # convert translations from Nori::StringWithAttributes to String

          char_count = values.sum(&:length)
          num[to_locale] << ({ chars: char_count, values: values.length})

          translated.each_with_index do |translation, i|
            key, old_value, prepared, type = batch[i]

            # undo preparation
            translation = unprepare_value key, translation, old_value, (type == 'zero' ? 0 : plural_n[type])

            # merge plurals, arrays
            case type
            when Numeric
              to, _ = value_from_hash key, result, false
              to, _ = value_from_hash key, all_yamls[from_locale] unless to.is_a? Array
              to[type] = translation
              translation = to
            when String
              plural_keys << key
              to, _ = value_from_hash key, result, false
              to, _ = value_from_hash key, all_yamls[from_locale] unless to.is_a? Hash
              to[type] = translation
              translation = to
            end

            insert_key key, translation, result
          end
        end
      rescue BingTranslator::Exception, BingTranslator::AuthenticationException => e
        puts "translation error: #{e}"
        break
      ensure
        # has pluralizations for to_locale
        plural_keys.uniq.each do |key|
          to, _ = value_from_hash key, result, false
          (to_plurals - to.keys).each do |missing_plural|
            to[missing_plural] = to['other'].presence || to.values.find { |k,v| v.present? }
          end
          (to.keys - to_plurals - ['zero']).each do |extra_plural|
            to.delete extra_plural
          end
          insert_key key, to, result
        end

        # write results to file
        result = deep_sort result
        File.open("config/locales/#{to_locale}.yml", 'w') do |file|
          file.write(YAML.dump to_locale.to_s => result)
        end
      end
    end

    num.each do |locale, num|
      puts "translated #{num.sum{|b| b[:values]}} values and #{num.sum{|b| b[:chars]}} chars in #{num.count} batches (#{num.map{|b| [b[:values],b[:chars]]}}) to #{locale}"
    end
    puts "total #{num.sum{ |_, num| num.sum{|b| b[:values]}}} values and #{num.sum{ |_, num| num.sum{|b| b[:chars]}}} chars in #{num.sum{ |_, num| num.count}} batches"
    num
  end

end
