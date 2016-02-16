module TranslationCenter
  module TranslationKeysHelper
    def maybe_from_yaml val
      if val =~ /\A---[ \n]/
        YAML.load val
      else
        val
      end
    end

    def maybe_to_yaml val
      case val
      when String
        if val =~ /\A\s+|\s+\Z|\A\Z/
          val.to_yaml
        else
          val
        end
      when Numeric, NilClass
        val
      else
        val.to_yaml
      end
    end
  end
end
