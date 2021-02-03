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

      yielder = if block.arity == 2
                  ->(entry) { block.call(entry.path.dup, entry.val) }
                else
                  ->(entry) { block.call(entry.path.dup) }
                end

      results = SizedQueue.new(1024)
      pending = Set.new

      paths.map!(&:dup).each do |path|
        path = path.to_path if path.respond_to? :to_path
        results << stat(path)
      end
      results << Types::DirFinished.new(:initial)
      pending << path_signature(:initial)

      while (result = results.deq)
        case result
        when Types::DirFinished
          break if pending.delete(path_signature(result.path)).empty?
        when Types::EntryStat
          catch(:prune) do
            yielder.call(result)

            if result.val.directory? && pending.add?(path_signature(result.path))
              executor.post(result.path, results) do |path, results_|
                walk(path, results_)
              end
            end
          end
        when Types::EntryError
          yielder.call(result)
          raise result.val unless ignore_error
        when Types::DirError
          raise result.val unless ignore_error
        end
      end
    ensure
      results&.close
    end

    private

    FS_ENCODING = Encoding.find('filesystem')

    module Types
      EntryStat = Struct.new(:path, :val)
      EntryError = Struct.new(:path, :val)
      DirError = Struct.new(:path, :val)
      DirFinished = Struct.new(:path)
    end

    def walk(path, results)
      enc = path.encoding == Encoding::US_ASCII ? FS_ENCODING : path.encoding

      # This benchmarks as about 10% faster than Dirs.foreach
      Dir.children(path, encoding: enc).each do |entry|
        results << stat(File.join(path, entry))
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP, Errno::ENAMETOOLONG => e
      results << Types::DirError.new(path, e)
    ensure
      results << Types::DirFinished.new(path)
    end

    def stat(entry)
      Types::EntryStat.new(entry, File.lstat(entry))
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP, Errno::ENAMETOOLONG => e
      Types::EntryError.new(entry, e)
    end

    def path_signature(path)
      [path, path.encoding]
    end
  end

  self.default_executor = case RUBY_ENGINE
                          when 'jruby', 'rbx'
                            Concurrent::FixedThreadPool.new(8, idletime: 60)
                          else
                            Concurrent::FixedThreadPool.new(1, idletime: 60)
                          end
end
