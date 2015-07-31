#
# fast_find.rb: A Find workalike optimized for performance.
#

require 'set'
require 'thread'
require 'fast_find/version'

module FastFind
	DEFAULT_CONCURRENCY = %w(jruby rbx).include?(RUBY_ENGINE) ? 8 : 1

	def self.find(*paths, concurrency: DEFAULT_CONCURRENCY, ignore_error: true,
	              &block)
		Finder.new(concurrency: concurrency, one_shot: true)
			.find(*paths, ignore_error: ignore_error, &block)
	end

	def self.prune
		throw :prune
	end

	class Finder
		def initialize(concurrency: DEFAULT_CONCURRENCY, one_shot: false)
			@mutex       = Mutex.new
			@queue       = Queue.new
			@one_shot    = one_shot
			@concurrency = concurrency
			@walkers     = nil
		end

		def startup
			@mutex.synchronize do
				return if @walkers

				@walkers = concurrency.times.map { Walker.new.spawn(@queue) }
			end
		end

		def shutdown
			@mutex.synchronize do
				return unless @walkers

				@queue.clear
				walkers.each { @queue << nil }
				walkers.each(&:join)

				@walkers = nil
			end
		end

		def find(*paths, ignore_error: true, &block)
			block or return enum_for(__method__, *paths, ignore_error: ignore_error)

			results = Queue.new
			pending = Set.new

			startup

			paths.map!(&:dup).each do |path|
				pending << path
				@queue << [path, nil, results]
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

				raise stat if stat.is_a?(Exception) and !ignore_error

				catch(:prune) do
					yield_entry(result, block)

					if stat.is_a?(File::Stat) and stat.directory? and !pending.include?(path)
						pending << path
						@queue << [path, stat, results]
					end
				end
			end
		ensure
			@queue.clear
			shutdown if one_shot
		end

		private

		def yield_entry(entry, block)
			if block.arity == 2
				block.call(entry[0].dup, entry[1])
			else
				block.call entry[0].dup
			end
		end

		attr_reader :walkers, :one_shot, :concurrency
	end

	class Walker
		def spawn(queue)
			Thread.new do
				while job = queue.deq
					walk(*job)
				end
			end
		end

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

			if stat.is_a?(File::Stat) and stat.directory?
				Dir.new(path).each do |entry|
					next if entry == '.' or entry == '..'

					entry = File.join(path, entry)
					stat = safe_stat(entry)

					results << [entry, stat]
				end
			end
		rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP,
		       Errno::ENAMETOOLONG => e
			# Unreadable directory
			# TODO: if ignore_error = false, we should raise this
		ensure
			results << [path, :finished]
		end
	end
end
