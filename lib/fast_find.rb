# frozen_string_literal: true

require 'set'
require 'fast_find/version'

# A Find workalike optimized for multithreaded operation on supporting Rubies
module FastFind
  DEFAULT_CONCURRENCY = %w[jruby rbx].include?(RUBY_ENGINE) ? 8 : 1

  def self.find(*paths, concurrency: DEFAULT_CONCURRENCY, ignore_error: true,
                &block)
    Finder.new(concurrency: concurrency)
          .find(*paths, ignore_error: ignore_error, &block)
  end

  def self.prune
    throw :prune
  end

  # For best performance, create a single instance of Finder with persist: true
  #
  # This class is thread-safe.
  class Finder
    def initialize(concurrency: DEFAULT_CONCURRENCY, persist: false)
      @mutex       = Mutex.new
      @queue       = Queue.new
      @persist     = persist
      @concurrency = concurrency
      @walkers     = nil
      @workers     = 0
    end

    def startup
      lock do
        return if @walkers

        @walkers = @concurrency.times.map { Walker.new.spawn(@queue) }
      end
    end

    def shutdown(force: false)
      lock do
        return unless @walkers
        raise 'running jobs' unless @workers.zero? || force

        @queue.clear
        @queue.close
        @walkers.each(&:join)

        @walkers = nil
      end
    end

    def find(*paths, ignore_error: true, &block)
      block or return enum_for(__method__, *paths, ignore_error: ignore_error)

      results = Queue.new
      pending = Set.new

      working do
        paths.map!(&:dup).each do |path|
          path = path.to_path if path.respond_to? :to_path
          results << [path, Util.safe_stat(path)]
        end
        results << %i[initial finished]
        pending << path_signature(:initial)

        while (result = results.deq)
          path, stat = result

          if stat == :finished
            break if pending.delete(path_signature(path)).empty?

            next
          end

          catch(:prune) do
            yield_entry(result, block) if path.is_a? String

            @queue << [path, results] if stat.is_a?(File::Stat) && stat.directory? && pending.add?(path_signature(path))
          end

          raise stat if stat.is_a?(Exception) && !ignore_error
        end
      end
    ensure
      shutdown if !persist? && @workers.zero?
    end

    private

    def working
      startup
      lock { @workers += 1 }
      yield
    ensure
      lock { @workers -= 1 }
    end

    def lock(&block)
      @mutex.synchronize(&block)
    end

    def path_signature(path)
      [path, path.encoding]
    end

    def persist?
      @persist
    end

    def yield_entry(entry, block)
      if block.arity == 2
        block.call(entry[0].dup.taint, entry[1])
      else
        block.call entry[0].dup.taint
      end
    end
  end

  class Walker
    FS_ENCODING = Encoding.find('filesystem')

    def spawn(queue)
      Thread.new do
        while (job = queue.deq)
          walk(job[0], job[1])
        end
      end
    end

    def walk(path, results)
      enc = path.encoding == Encoding::US_ASCII ? FS_ENCODING : path.encoding

      Dir.entries(path, encoding: enc).each do |entry|
        next if (entry == '.') || (entry == '..')

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
