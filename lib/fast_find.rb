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

				@walkers = @concurrency.times.map { Walker.new.spawn(@queue) }
			end
		end

		def shutdown
			@mutex.synchronize do
				return unless @walkers

				@queue.clear
				@walkers.each { @queue << nil }
				@walkers.each(&:join)

				@walkers = nil
			end
		end

		def find(*paths, ignore_error: true, &block)
			block or return enum_for(__method__, *paths, ignore_error: ignore_error)

			results = Queue.new
			pending = Set.new

			startup

			paths.map!(&:dup).each do |path|
				path = path.to_path if path.respond_to? :to_path
				results << [path, Util.safe_stat(path)]
			end
			results << [:initial, :finished]
			pending << path_signature(:initial)

			while result = results.deq
				path, stat = result

				if stat == :finished
					pending.delete(path_signature(path))

					if pending.empty?
						break
					else
						next
					end
				end

				catch(:prune) do
					yield_entry(result, block) if path.is_a? String

					if stat.is_a? File::Stat and stat.directory? and pending.add?(path_signature(path))
						@queue << [path, results]
					end
				end

				raise stat if stat.is_a? Exception and !ignore_error
			end
		ensure
			if one_shot?
				@queue.clear
				shutdown
			end
		end

		private

		def path_signature(path)
			[path, path.encoding]
		end

		def one_shot?() !!@one_shot end

		def yield_entry(entry, block)
			if block.arity == 2
				block.call(entry[0].dup.taint, entry[1])
			else
				block.call entry[0].dup.taint
			end
		end
	end

	class Walker
		FS_ENCODING = Encoding.find("filesystem")

		def spawn(queue)
			Thread.new do
				while job = queue.deq
					walk(job[0], job[1])
				end
			end
		end

		def walk(path, results)
			enc = path.encoding == Encoding::US_ASCII ? FS_ENCODING : path.encoding

			Dir.entries(path, encoding: enc).each do |entry|
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
