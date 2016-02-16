require "uri"
require "net/http"

namespace :translation_center do

  def send_exception(exception)
    raise exception if TranslationCenter::CONFIG['disable_send_error_report']

    puts "An error has ocurred while performing this rake, would you like to send the exception to us so we may fix this problem ? press [Y/n]"
    confirm = $stdin.gets.chomp

    if confirm.blank? || confirm == 'y' || confirm == 'yes'
      puts 'Sending ...'
      params = {message: "#{exception.message} #{exception.backtrace.join("\n")}"}
      Net::HTTP.post_form(URI.parse('http://translation-center.herokuapp.com/translation_center_feedbacks/create_rake'), params)
      puts 'We have received your feedback. Thanks!'
    end

    # show the exception message
    puts exception.message
    puts exception.backtrace.join("\n")
  end

  desc "Insert yaml translations in db"
  task :yaml2db, [:locale ] => :environment do |t, args|
    begin
      TranslationCenter.yaml2db(args[:locale])
    rescue Exception => e
      send_exception(e)
    end
  end

  desc "Export translations from db to yaml"
  task :db2yaml, [:locale ] => :environment do |t, args|
    begin
      TranslationCenter.db2yaml(args[:locale])
    rescue Exception => e
      send_exception(e)
    end
  end

  desc "Delete keys From db that don't exist in yaml and delete categories with 0 keys"
  task :deldbkeys, [:dry_run, :locales] => :environment do |t, args|
    begin
      locales = args[:locales].to_s.split(/[ .:;]/) + args.extras
      if args[:dry_run] =~ /1|on|true|yes/
        dry_run = true
      elsif args[:dry_run].present?
        locales.push args[:dry_run]
      end
      TranslationCenter.deldbkeys(locales, dry_run)
    rescue Exception => e
      send_exception(e)
    end
  end

  desc "Calls yaml2db then db2yaml"
  task :synch, [:locale ] => :environment do |t, args|
    begin
      if TranslationCenter::Category.any?
        puts "WARNING: You already have translations stored in the db, do you want to destroy them? press [Y|n]"
        confirm = $stdin.gets.chomp

        TranslationCenter::Category.destroy_all if confirm.blank? || confirm == 'y' || confirm == 'yes'
      end
      TranslationCenter.yaml2db(args[:locale])
      TranslationCenter.db2yaml(args[:locale])
    rescue Exception => e
      send_exception(e)
    end
  end

end
