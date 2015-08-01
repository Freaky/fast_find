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
				results << [path, Util.safe_stat(path)]
			end
			results << [:initial, :finished]
			pending << :initial

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

				catch(:prune) do
					yield_entry(result, block) unless path == :exception

					case stat
					when Exception then raise stat if !ignore_error
					when File::Stat
						if stat.directory? and !pending.include?(path)
							pending << path
							@queue << [path, results]
						end
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
					walk(job[0], job[1])
				end
			end
		end

		def walk(path, results)
			Dir.new(path).each do |entry|
				next if entry == '.' or entry == '..'

				stat(File.join(path, entry), results)
			end
		rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP,
		       Errno::ENAMETOOLONG => e
			error(e, results)
		ensure
			finish(path, results)
		end

		def stat(entry, results)
			results << [entry, Util.safe_stat(entry)]
		end

		def finish(path, results)
			results << [path, :finished]
		end

		def error(e, results)
			results << [:exception, e]
		end
	end

	module Util
		def self.safe_stat(path)
			File.lstat(path)
		rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP,
		       Errno::ENAMETOOLONG => e
			e
		end
	end
end
