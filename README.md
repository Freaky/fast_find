# FastFind

FastFind is a performance-oriented multi-threaded alternative to the standard
`Find` module that ships with Ruby.  It should generally be a drop-in
replacement.

FastFind is expected to be marginally slower on MRI/YARV, since multithreaded
`File#lstat` calls there appear to serialize.  However, using the FastFind-
specific second argument to pass in the `File::Stat` object for each file may
still prove a win.

This code is considered experimental.  Beware of dog.

## Installation

Add this line to your application's Gemfile:

    gem 'fast_find'

And then execute:

    $ bundle

## Usage

Traditional Find-style:

    FastFind.find(dir) {|entry| frob(entry) }
    FastFind.find(dir, ignore_errors: false) { .. } # => explodes in your face
    FastFind.find(dir) # => Enumerator

Extended style using the second argument to get a `File::Stat`, or `Exception`
object (if `ignore_errors` is false, this will be raised instead).

    FastFind.find(dir) {|entry, stat| frob(entry, stat) }

For increased performance and better scaling behaviour, it is recommended to use
a single shared FastFind object.  Multiple concurrent calls to
`FastFind::Finder#find` are safe and will share a persistant work pool.

    Finder = FastFind::Finder.new
    Finder.find(dir) { .. }

You can call `Finder#shutdown` to close the work pool if you're done with the
instance for the time being.  Ensure no other calls to its `#find` are in flight
beforehand.  The pool is restarted the next time `#find` is called.

Use the `concurrency` named argument to change the number of worker threads:

    FastFind.find(dir, concurrency: 4)
    FastFind::Finder.new(concurrency: 4)

Defaults are `8` for Rubinius and JRuby, `1` for anything else.

Note the yielded blocks are all executed in the parent thread, *not* in workers.

`FastFind#prune` works.  So does `Find#prune`.

## Performance

Scanning a cached copy of the NetBSD CVS repository:

jruby 9.0.1.0-SNAPSHOT (2.2.2) 2015-07-23 e88911e OpenJDK 64-Bit Server VM
25.51-b03 on 1.8.0_51-b16 +jit [FreeBSD-amd64]:

                   user     system      total        real
    Find      32.890625  27.742188  60.632813 ( 47.518944)
    FastFind  35.273438  41.742188  77.015625 (  8.140893)

ruby 2.2.2p95 (2015-04-13 revision 50295) [x86_64-freebsd10.1]:

                   user     system      total        real
    Find      10.187500  22.351562  32.539062 ( 32.545201)
    FastFind   9.039062  14.226562  23.265625 ( 23.277589)

On MRI `Find` here is penalised because both `Find` and the benchmark code is
performing a `File#lstat`.  This matches common use-cases.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run
`bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To
release a new version, update the version number in `version.rb`, and then run
`bundle exec rake release` to create a git tag for the version, push git commits
and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).
