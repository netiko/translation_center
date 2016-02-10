module TranslationCenter
  module TranslationKeysHelper
    def maybe_from_yaml val
      if val =~ /\A--- *\n/
        YAML.load val
      else
        val
      end
    end

    def maybe_to_yaml val
      case val
      when String, Numeric, NilClass
        val
      else
        val.to_yaml
      end
    end
  end
end
