# frozen_string_literal: true
#
# fast_find.rb: Find files within a given directory, faster
#

require 'set'

require 'concurrent'

require 'fast_find/version'

# Like the standard Ruby +Find+ module, the +FastFind+ module supports the
# top-down traveral of a set of file paths.
#
# +FastFind+ differs mainly in that it:
#
# * makes no guarantee about the order in which paths are yielded.
# * yields a +File::Stat+ or +Exception+ object to +#arity+ 2 blocks.
# * may execute operations in background threads using an executor.
#
# For example, to test the total size of all files under the user's home
# directory, ignoring any "dot" directories such as $HOME/.ssh:
#
#   require 'fast_find'
#
#   FastFind.find(ENV['HOME']) do |path, stat|
#     if stat.directory?
#       if File.basename(path).start_with?('.')
#         FastFind.prune # Skip this .hidden directory
#       end
#     else
#       total_size + stat.size
#     end
#   end
#
module FastFind
  class << self
    # Set the default executor for background threads.
    #
    # This object must respond to +#post+, executing the provided block in a way
    # that will not block the current thread.
    attr_accessor :default_executor

    # Call the associated block with the name of every file and directory listed
    # as arguments, and recurse into all readable subdirectories unless
    # +FastFind.prune+ is called to prevent it during iteration.
    #
    # Returns an enumerator if no block is given.
    #
    # A concurrent-ruby-compatible executor such as a Concurrent::FixedThreadPool
    # may be passed as +executor:+.  Currently its queue should be unbounded and
    # it must not run tasks in the current thread.
    #
    def find(*paths, ignore_error: true, executor: default_executor, &block)
      block or return enum_for(__method__, *paths, ignore_error: ignore_error, executor: executor)

      yielder = if block.arity == 2
                  ->(entry) { block.call(entry.path.dup, entry.val) }
                else
                  ->(entry) { block.call(entry.path.dup) }
                end

      results = SizedQueue.new(1024)

      # Directories that are currently being walked.
      pending = Set.new

      paths.map!(&:dup).each do |path|
        # Find unconditionally raises on ENOENT here
        path = path.to_path if path.respond_to? :to_path
        results << stat(path)
      end
      results << Types::DirFinished.new(:initial)
      pending << path_signature(:initial)

      until pending.empty?
        result = results.deq
        case result
        when Types::EntryStat
          catch(:prune) do
            yielder.call(result)

            if result.val.directory? && pending.add?(path_signature(result.path))
              executor.post(result.path, results) do |path, results_|
                walk(path, results_)
              end
            end
          end
        when Types::DirFinished
          pending.delete(path_signature(result.path))
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

    # Skip the current path, restarting the loop with the next# entry.  If the
    # current path is a directory, do not recurse into it.
    def prune
      throw :prune
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

      # This benchmarks as about 10% faster than Dirs.each_child
      Dir.children(path, encoding: enc).each do |entry|
        results << stat(File.join(path, entry))
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP, Errno::ENAMETOOLONG => e
      results << Types::DirError.new(path, e)
    rescue => e
      warn e
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
