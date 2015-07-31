#
# fast_find.rb: A Find workalike optimized for performance.
#
# Differences from Find:
#
# * Processes multiple directories concurrently.
# * Can pass in a File::Stat or Exception object as the second argument to the block.
# * Does not sort or otherwise provide any guarantees about order.

require 'find'
require 'set'
require 'thread'

module FastFind
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

			if stat.kind_of? File::Stat and stat.directory?
				Dir.new(path).each do |entry|
					next if entry == '.' or entry == '..'

					entry = File.join(path, entry)
					stat = safe_stat(entry)

					results << [entry, stat]
				end
			end
			results << [path, :finished]
		end
	end

	DEFAULT_CONCURRENCY = %w(jruby rbx).include?(RUBY_ENGINE) ? 8 : 1

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

			@queue = Queue.new
			@walkers = Array.new(concurrency).map! do
				Walker.new.spawn(@queue)
			end
		end

		def find(*paths, ignore_error: true, one_shot: false, &block)
			block or return enum_for(__method__, *paths)

			results = Queue.new
			pending = Set.new

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

				# FIXME: clear the pool
				raise stat if stat.kind_of? Exception and !ignore_error

				catch(:prune) do
					yield_entry(result, block)

					if stat.kind_of? File::Stat and stat.directory? and !pending.include?(path)
						pending << path
						@queue << [path, stat, results]
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
			walkers.each { @queue << nil }
			walkers.each(&:join)
			walkers.clear
		end

		private
		attr_reader :walkers, :one_shot
	end
end
