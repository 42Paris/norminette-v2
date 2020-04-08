#!/usr/bin/env ruby

require 'bundler'
require 'optparse'
require 'parseconfig'
require 'securerandom'

$current_path = Dir.pwd

if File.symlink?(__FILE__)
	    dir = File.expand_path(File.dirname(File.readlink(__FILE__)))
			Dir.chdir dir
else
	    dir = File.expand_path(File.dirname(__FILE__))
		    Dir.chdir dir
end

$config = ParseConfig.new("#{dir}/config.conf")

Bundler.require

class Sender
	def initialize &block
		@conn = Bunny.new 	hostname: 	$config['hostname'],
							vhost: 		"/",
							user: 		$config['user'],
							password: 	$config['password']
		
		@conn.start
		@ch 			= @conn.create_channel
		@x  			= @ch.default_exchange
		@reply_queue    = @ch.queue("", exclusive: true)
		@lock      		= Mutex.new
		@condition 		= ConditionVariable.new
		@routing_key	= "norminette"
		@counter		= 0

		@reply_queue.subscribe do |delivery_info, properties, payload|
			@counter -= 1
			block.call delivery_info, properties, payload
	    	@lock.synchronize { @condition.signal }
	  	end

	  	at_exit { desinitialize }
	end

	def desinitialize
		@ch.close if @ch
		@conn.close if @conn
	end

	def publish content
		@counter += 1
		@x.publish content,	routing_key:  @routing_key,
							reply_to:     @reply_queue.name,
							correlation_id: SecureRandom.uuid
	end

	def sync_if_needed
		@lock.synchronize { @condition.wait(@lock) }
	end

	def sync
		sync_if_needed until @counter == 0
	end
end



class Norminette
	def initialize
		@files			= []
		@sender 		= Sender.new do |delivery_info, properties, payload|
	    	manage_result JSON.parse(payload)
		end
	end

	def check files_or_directories, options
		if options.version
			version 
		else
			populate_recursive files_or_directories.any? ? files_or_directories : [$current_path]
			send_files options
		end

		@sender.sync
	end

	private

	def populate_recursive objects
		objects.each do |object|
			object = (Pathname.new(object).absolute? ? object : File.join($current_path, object))

			if File.directory? object
				populate_recursive Dir["#{object}/*"]
			else
				populate_file object
			end
		end
	end

	def version
		puts "Local version:\n1.0.0.rc1"
		puts "Norminette version:"
		send_content({action: "version"}.to_json)
	end

	def file_description file, opts = {}
		({filename: file, content: File.read(file)}.merge(opts)).to_json
	end

	def is_a_valid_file? file
		File.file? file and File.exists? file and file =~ /\.[ch]\z/
	end

	def populate_file file
		unless is_a_valid_file? file
			manage_result 'filename' => file, 'display' => "Warning: Not a valid file"
			return
		end

		@files << file
	end

	def send_files options
		@files.each do |file|
			send_file file, options.rules
			@sender.sync_if_needed
		end
	end

	def send_file file, rules
		send_content file_description(file, rules: rules)
	end

	def send_content content
		@sender.publish content
	end

	def cleanify_path filename
		File.expand_path(filename).gsub(/^#$current_path\/?/, "./")
	end

	def manage_result result
		puts "Norme: #{cleanify_path(result['filename'])}" 	if result['filename']
		puts result['display']	 							if result['display']
		exit 0 												if result['stop'] == true
	end
end

class Parser
  def self.parse(options)
  	args 	= OpenStruct.new
    opt_parser = OptionParser.new do |opts|
      opts.banner = "Usage: #$0 [options] [files_or_directories]"

      opts.on("-v", "--version", "Print version") do |n|
      	args.version = true
      end

      opts.on("-R", "--rules Array", Array, "Rule to disable") do |rules|
      	args.rules = rules
      end

      opts.on("-h", "--help", "Prints this help") do
  		sender 	= Sender.new do |delivery_info, properties, payload|
  			puts JSON.parse(payload)['display']
		end

        puts opts
        puts "Norminette usage:"
        sender.publish({action: "help"}.to_json)
        sender.sync
        exit
      end
    end

    opt_parser.parse!(options) rescue abort $!.to_s

    return args
  end
end

Norminette.new.check ARGV, Parser.parse(ARGV) if __FILE__ == $0

