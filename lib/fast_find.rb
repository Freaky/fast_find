# frozen_string_literal: true

require 'set'

require 'concurrent'

require 'fast_find/version'

# A Find workalike optimized for multithreaded operation on supporting Rubies
module FastFind
  class << self
    attr_accessor :default_executor

    def prune
      throw :prune
    end

    def find(*paths, ignore_error: true, executor: default_executor, &block)
      block or return enum_for(__method__, *paths, ignore_error: ignore_error, executor: executor)

      results = SizedQueue.new(1024)
      pending = Set.new

      paths.map!(&:dup).each do |path|
        path = path.to_path if path.respond_to? :to_path
        results << [path, safe_stat(path)]
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

          if stat.is_a?(File::Stat) && stat.directory? && pending.add?(path_signature(path))
            executor.post(path, results) do |path_, results_|
              walk(path_, results_)
            end
          end
        end

        raise stat if stat.is_a?(Exception) && !ignore_error
      end
    ensure
      results.close if results
    end

    private

    FS_ENCODING = Encoding.find('filesystem')

    def walk(path, results)
      enc = path.encoding == Encoding::US_ASCII ? FS_ENCODING : path.encoding

      # This benchmarks as about 10% faster than Dirs.foreach
      Dir.entries(path, encoding: enc).each do |entry|
        next if (entry == '.') || (entry == '..')

        results << stat(File.join(path, entry))
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP,
           Errno::ENAMETOOLONG => e
      results << error(e)
    ensure
      results << finish(path)
    end

    def stat(entry)
      [entry, safe_stat(entry)]
    end

    def finish(path)
      [path, :finished]
    end

    def error(e)
      [:exception, e]
    end

    def path_signature(path)
      [path, path.encoding]
    end

    def yield_entry(entry, block)
      if block.arity == 2
        block.call(entry[0].dup, entry[1])
      else
        block.call entry[0].dup
      end
    end

    def safe_stat(path)
      File.lstat(path)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP,
           Errno::ENAMETOOLONG => e
      e
    end
  end

  self.default_executor = case RUBY_ENGINE
                          when 'jruby', 'rbx'
                            Concurrent::FixedThreadPool.new(8, idletime: 60)
                          else
                            Concurrent::FixedThreadPool.new(1, idletime: 60)
                          end
end
