module TranslationCenter
  module ApplicationHelper

    
    # get the current user the language translating from
    def from_lang
      session[:lang_from]
    end

    # get the current user the language translating to
    def to_lang
      session[:lang_to]
    end

    # returns the display name of the language
    def language_name(lang)
      TranslationCenter::CONFIG['lang'].try(:[], lang.to_s).try(:[], 'name') || lang.to_s
    end

    # returns the direction of the language rtl or ltr
    def language_direction(lang)
      TranslationCenter::CONFIG['lang'].try(:[], lang.to_s).try(:[], 'direction') || 'ltr'
    end

    # returns the current status filter for translation keys
    def current_filter
      session[:current_filter]
    end

    # returns true if the current filter is equal to the passed filter
    def current_filter_is?(filter)
      session[:current_filter] == filter
    end

    # returns true if the current user can admin translations
    def translation_admin?
      current_user.respond_to?(:can_admin_translations?) && current_user.can_admin_translations?
    end

    # returns formated date
    def format_date(date)
      date.strftime('%e %b %Y')
    end

    # returns path that changes the from_locale
    def change_from_locale_url(locale)
      current_path = "#{request.protocol}#{request.host_with_port}#{request.fullpath}"
      current_path = if current_path.include?('lang_from=')
        current_path.gsub("lang_from=#{session[:lang_from]}", "lang_from=#{locale.to_s}")
      elsif current_path.include?('?')
        "#{current_path}&lang_from=#{locale.to_s}"
      else
        "#{current_path}?lang_from=#{locale.to_s}"
      end
    end

    # returns path that changes the to_locale
    def change_to_locale_url(locale)
      current_path = "#{request.protocol}#{request.host_with_port}#{request.fullpath}"
      if current_path.include?('lang_to=')
        current_path.gsub("lang_to=#{session[:lang_to]}", "lang_to=#{locale.to_s}")
      elsif current_path.include?('?')
        "#{current_path}&lang_to=#{locale.to_s}"
      else
        "#{current_path}?lang_to=#{locale.to_s}"
      end
    end

  end
end
