module TranslationCenter
  class ApplicationController < ActionController::Base
    before_filter :translation_langs_filters
    before_filter :authenticate_user!
    before_filter :can_translate?

    if Rails.env.development? && ! TranslationCenter::CONFIG['disable_send_error_report']

      # if an exception happens show the error page
      rescue_from Exception do |exception|
        @exception = exception
        @path = request.path

        render "translation_center/errors/exception"
      end

    end

    # defaults
    def translation_langs_filters
      session[:current_filter] ||= 'untranslated'
      session[:lang_from] = params[:lang_from] || session[:lang_from] || I18n.default_locale
      session[:lang_from] = I18n.default_locale unless session[:lang_from].to_sym.in? I18n.available_locales
      session[:lang_to] = params[:lang_to] || session[:lang_to] || I18n.default_locale
      session[:lang_to] = I18n.default_locale unless session[:lang_to].to_sym.in? I18n.available_locales
      I18n.locale = session[:lang_from]
    end

    protected

    def can_translate?
      redirect_to '/' unless current_user.can_translate?
    end

    def can_admin?
      redirect_to root_url unless current_user.can_admin_translations?
    end

    def set_page_number
      params[:page] ||= 1
      @page = params[:page].to_i
    end

  end
end
