# frozen_string_literal: true
#
# fast_find.rb: Find files within a given directory, faster
#

require 'forwardable'

require 'concurrent'

require 'fast_find/version'

# Like the standard Ruby +Find+ module, the +FastFind+ module supports the
# top-down traveral of a set of file paths.
#
# +FastFind+ differs mainly in that it:
#
# * makes no guarantee about the order in which paths are yielded.
# * yields a +DirEntry+ or +DirError+ object instead of a path
# * has more filtering options
# * is +Enumerable+
# * may execute operations in background threads using an executor.
#
# For example, to naively determine the total size of all files under the user's
# home directory, ignoring any "dot" directories such as $HOME/.ssh:
#
#   require 'fast_find'
#
#   total_size = FastFind.paths(ENV['HOME'])
#                        .skip_hidden
#                        .reject(&:directory?)
#                        .sum(&:size)
#
# Or written manually:
#
#   total_size = 0
#
#   FastFind.find(ENV['HOME']).each do |entry|
#     if entry.directory?
#       if entry.basename.start_with?('.')
#         FastFind.prune # Skip this .hidden directory
#       end
#     else
#       total_size + entry.size
#     end
#   end
#
module FastFind
  class << self
    # Set the default executor for background threads.
    #
    # This object must respond to +#post+, executing the provided block in a way
    # that will not block the current thread.
    #
    # Defaults to +Concurrent.global_io_executor+
    attr_accessor :default_executor

    %i[paths min_depth max_depth follow_links skip_hidden on_error executor].each do |fn|
      define_method(fn) { |*args| Walk.new.send(fn, *args) }
    end

    # During a walk iteration, skip the current path, restarting the loop with
    # the next# entry.  If the current path is a directory, do not recurse into
    # it.
    def prune
      throw :prune
    end
  end

  self.default_executor = Concurrent.global_io_executor

  # A type representing a path which has an associated +File::Stat+ available.
  class DirEntry
    # Depth of the entry within the walk
    attr_reader :depth

    # The entry's basename - i.e. the file or directory name on its own
    attr_reader :basename

    # The entry's containing directory
    attr_reader :dirname

    # The path of the entry
    attr_reader :path

    # The associated +File::Stat+ - note most methods are delegated.
    attr_reader :stat

    extend Forwardable
    def_delegators :@stat, :atime, :birthtime, :blksize, :blockdev?, :blocks,
                   :chardev?, :ctime, :dev, :dev_major, :dev_minor, :directory?,
                   :executable?, :executable_real?, :file?, :ftype, :gid,
                   :grpowned?, :ino, :inspect, :mode, :mtime, :nlink, :owned?,
                   :pipe?, :pretty_print, :rdev, :rdev_major, :rdev_minor,
                   :readable?, :readable_real?, :setgid?, :setuid?, :size,
                   :size?, :socket?, :sticky?, :symlink?, :uid,
                   :world_readable?, :world_writable?, :writable?,
                   :writable_real?, :zero?

    def initialize(depth:, basename:, dirname:, stat:)
      @depth = depth
      @basename = basename
      @dirname = dirname
      @path = File.join(dirname, basename)
      @stat = stat
      freeze
    end

    # Always false
    def error?()
      false
    end
  end

  # A type representing a path with an associated error condition when attempting
  # to either read a directory or stat a file.
  class DirError
    # Depth of the entry within the walk
    attr_reader :depth

    # The entry's basename - i.e. the file or directory name on its own
    attr_reader :basename

    # The entry's containing directory
    attr_reader :dirname

    # The path of the entry
    attr_reader :path

    # The associated exception
    attr_reader :error

    def initialize(depth:, basename:, dirname:, error:)
      @depth = depth
      @basename = basename
      @dirname = dirname
      @path = File.join(dirname, basename)
      @error = error
      freeze
    end

    # Always true
    def error?()
      true
    end
  end

  DIR_FINISHED = Object.new.freeze

  # A class responsible for walking a tree of files.  Normally created using
  # one of the +FastFind+ module functions with the same names.
  #
  # Each method returns a new immutable +Walk+ instance.
  #
  # Instances are inert until iterated on, and are +Enumerable+.
  #
  class Walk
    include Enumerable
    OPTS = {
      paths: [].freeze,
      min_depth: 0,
      max_depth: Float::INFINITY,
      skip_hidden: false,
      on_error: :ignore,
      concurrency: RUBY_ENGINE == 'jruby' ? 8 : 1,
      executor: nil
    }.freeze

    # Initialize a new walker with default options.
    def initialize
      @opts = OPTS
    end

    # Return a +FastFind::Walk+ for the given paths - as with +Find+, objects
    # responding to +#to_path+ will be converted automatically.
    #
    # Beware mistakingly calling this +#find+ out of habit - this is an
    # +Enumerable+ function that will iterate to find a matching element.
    def paths(*paths)
      paths = paths.flatten.map!(&:dup).map! do |path|
        if path.respond_to? :to_path
          path.to_path
        else
          path
        end
      end
      merge(paths: paths)
    end

    # Return a +FastFind::Walk+ which yields only entries of this depth or
    # deeper.  Directories will be automatically recursed into despite not being
    # yielded.
    #
    # Errors below this depth will be ignored regardless of the +on_error+
    # configuration.
    def min_depth(depth)
      merge(min_depth: Integer(depth).clamp(0, Float::INFINITY))
    end

    # Return a +FastFind::Walk+ which will not recurse beyond the given depth.
    def max_depth(depth)
      merge(max_depth: Integer(depth).clamp(0, Float::INFINITY))
    end

    # Return a +FastFind::Walk+ which will skip over dot-files - i.e. files with
    # names that start with a '.'
    def skip_hidden(bool = true)
      merge(skip_hidden: !!bool)
    end

    # Return a +FastFind::Walk+ with configured error handling:
    #
    # * +:ignore+ - Skip over folders with errors (default)
    # * +:yield+ - Yield errors as +DirError+ instances
    # * +:raise+ - Raise errors as exceptions
    #
    def on_error(action)
      raise ArgumentError unless %i[ignore yield raise].include? action
      merge(on_error: action)
    end

    # Return a +FastFind::Walk+ with a configured concurrency limit.
    # Currently clamped to 1..32.
    #
    # This limits items posted to the +executor+ on each individual walk,
    # and may be further limited by the executor.
    def concurrency(concurrency)
      merge(concurrency: Integer(concurrency).clamp(1, 32))
    end

    # Return a +FastFind::Walk+ which executes its searches on the provided
    # +Concurrent::Ruby+ or similar executor.
    #
    # Executors must respond to +#post+ and must not block the calling thread.
    #
    # Defaults to +FastFind.default_executor+
    def executor(executor)
      raise ArgumentError unless executor.respond_to?(:post)
      merge(executor: executor)
    end

    # Call the associated block with a +DirEntry+ or +DirError+ for every file
    # and directory this instance is configured for
    #
    # Returns an enumerator if no block is given.
    def each
      return enum_for(__method__) unless block_given?

      executor = opts[:executor] || FastFind.default_executor
      concurrency = opts[:concurrency]

      # Entries waiting to be yielded
      results = SizedQueue.new(64)

      # Yield the paths we were passed
      results << opts[:paths].map do |path|
        path, name = File.split(path)
        stat(path, name, 0)
      end
      results << DIR_FINISHED
      walking = 0
      pending = []

      until walking < 0
        result = results.deq
        if result == DIR_FINISHED
          walking -= 1
        else
          result.each do |entry|
            next if opts[:skip_hidden] && entry.basename.start_with?('.')

            if entry.error?
              next unless opts[:min_depth] <= entry.depth && opts[:max_depth] >= entry.depth
              yield(entry) if opts[:on_error] == :yield
              raise entry.error if opts[:on_error] == :raise
            else
              catch(:prune) do
                yield(entry) if opts[:min_depth] <= entry.depth && opts[:max_depth] >= entry.depth
                pending << entry if entry.directory? && opts[:max_depth] > entry.depth
              end
            end
          end
        end

        if walking < concurrency && !pending.empty?
          pending.pop(concurrency - walking).each do |entry|
            walking += 1
            executor.post(entry, results) do |entry|
              walk(entry.path, entry.depth + 1, results) unless results.closed?
            end
          end
        end
      end
    ensure
      results&.close
    end

    protected
    attr_accessor :opts

    def merge(opts = nil || (return self))
      c = dup
      c.opts = c.opts.merge(opts)
      c.freeze
    end

    private

    def walk(path, depth, results)
      enc = path.encoding == Encoding::US_ASCII ? FS_ENCODING : path.encoding

      Dir.children(path, encoding: enc).each_slice(8) do |entries|
        results << entries.map! { |entry| stat(path, entry, depth) }
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP, Errno::ENAMETOOLONG => e
      dirname, basename = File.split(path)
      results << [DirError.new(basename: basename, dirname: dirname, depth: depth, error: e)]
    rescue ClosedQueueError
    rescue => e
      warn e
      raise
    ensure
      results << DIR_FINISHED unless results.closed?
    end

    def stat(dirname, basename, depth)
      begin
        DirEntry.new(
          basename: basename,
          dirname: dirname,
          depth: depth,
          stat: File.lstat(File.join(dirname, basename))
        )
      rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR, Errno::ELOOP, Errno::ENAMETOOLONG => e
        DirError.new(
          basename: basename,
          dirname: dirname,
          depth: depth,
          error: e
        )
      rescue => e
        warn e
        raise
      end
    end
  end
end
