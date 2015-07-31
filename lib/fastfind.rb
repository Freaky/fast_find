#
# fast_find.rb: A Find workalike optimized for performance.
#
# Differences from Find:
#
# * Processes multiple directories concurrently.
# * Can pass in a File::Stat or Exception object as the second argument to the block.
# * Does not support #prune.
# * Does not sort or otherwise provide any guarantees about order.

require 'find'
require 'set'
require 'thread'
require 'celluloid/current'

# Celluloid.task_class = Celluloid::Task::Threaded

module FastFind
	class Walker
		include Celluloid

		def safe_stat(path)
			File.lstat(path)
		rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP,
		       Errno::ENAMETOOLONG => e
			e
		end

		def walk(path, stat, results)
			path = path

			unless stat
				stat = safe_stat(path)
				results << [path, stat]
			end

			if stat.kind_of? File::Stat and stat.directory?
				Dir.new(path).each do |entry|
					next if entry == '.' or entry == '..'

					entry = File.join(path, entry)
					stat = safe_stat(entry)

					results << [entry, stat]
				end
			end
			results << [path, :finished]
		rescue => e
			puts "Walker exception: #{e.class}, #{e.message}"
			exit!
			# results << [path, :finished]
		end
	end

	DEFAULT_CONCURRENCY = %w(jruby rbx).include?(RUBY_ENGINE) ? 16 : 1
	QUEUE_SIZE = 1024

	def self.find(*paths,
	              concurrency: DEFAULT_CONCURRENCY, ignore_error: true,
	              &block)
		Finder.new(concurrency: concurrency, one_shot: true).find(*paths,
		  ignore_error: ignore_error, &block)
	end

	def self.prune
		throw :prune
	end

	class Finder
		def initialize(concurrency: DEFAULT_CONCURRENCY, one_shot: false)
			@one_shot = one_shot
			@walkers = Walker.pool(size: concurrency)
		end

		def find(*paths, ignore_error: true, one_shot: false, &block)
			block or return enum_for(__method__, paths)

			results = Queue.new # SizedQueue.new(QUEUE_SIZE)
			pending = Set.new
			done = Set.new

			paths.map!(&:dup).each do |path|
				pending << path
				walkers.async.walk(path, nil, results)
			end

			while result = results.deq
				path, stat = result

				if stat == :finished
					pending.delete(path)

					if pending.empty?
						break
					else
						next
					end
				end

				# FIXME: clear the pool
				raise stat if stat.kind_of? Exception and !ignore_error

				catch(:prune) do
					yield_entry(result, block)

					if stat.kind_of? File::Stat and stat.directory? and !pending.include?(path)
						# puts "Pushing #{path}"
						pending << path
						walkers.async.walk(path, stat, results)
					end
				end
			end
		ensure
			finish if one_shot
		end

		def yield_entry(entry, block)
			if block.arity == 2
				block.call(entry[0].dup, entry[1])
			else
				block.call entry[0].dup
			end
		end

		def finish
			walkers.shutdown if walkers.active?
		end

		private
		attr_reader :walkers, :one_shot
	end
end
