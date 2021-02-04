# FastFind

`FastFind` is a multi-threaded alternative to the standard `Find` module,
offering increased performance on Rubies which can run `Dir#children` and
`File#lstat` calls concurrently (i.e. JRuby).

+FastFind+ has a slightly different API and cannot be used as a drop-in
replacement.

## Installation

Add this line to your application's Gemfile:

```shell
gem 'fast_find'
```

And then execute:

```shell
$ bundle
```

## Usage

`FastFind` is driven primarily by `FastFind::Walk` instances, which are created
by chaining methods.  Each instance is immutable and inert, and can be shared
between threads.

```ruby
finder = FastFind.paths(dir)
finder.each { |entry| frob(entry.path) }
finder.on_error(:raise).to_a # Make an array of DirEntry instances or raise an exception
finder.each # => Enumerator
```

`FastFind` uses a concurrent-ruby executor to run, which can be customised
by passing it as a builder argument:

```ruby
executor = Concurrent::FixedThreadPool.new(16, idletime: 90)
finder_with_executor = FastFind.executor(executor)
```

Or to the module itself:

```ruby
FastFind.default_executor = Concurrent::FixedThreadPool.new(16, idletime: 90)
```

Due to the use of a bounded result queue it is *not* recommended to use an
executor with a bounded queue or which runs in the same thread as this may
result in deadlocks or dropped results.

As with `Find`, `FastFind#prune` will avoid recursing into a directory.

## Performance

Scanning a cached copy of the NetBSD CVS repository with default settings:

jruby 9.2.14.0 (2.5.7) 2020-12-08 ebe64bafb9 OpenJDK 64-Bit Server VM 15.0.2+7-1 on 15.0.2+7-1 +jit:

```
               user     system      total        real
FastFind  22.453125  42.609375  65.062500 (  7.785491)
Find      15.929688  27.882812  43.812500 ( 43.750860)
```

These results highlight the importance of the two-argument version.

ruby 3.0.0p0 (2020-12-25 revision 95aff21468) \[x86_64-freebsd12.2]:

```
               user     system      total        real
FastFind  22.056920  18.092734  40.149654 ( 36.409812)
Find      10.233514  21.035376  31.268890 ( 31.270866)
```

Sadly the current implementation is a significant pessimisation on MRI, likely
due to thread overhead.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run
`bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To
release a new version, update the version number in `version.rb`, and then run
`bundle exec rake release` to create a git tag for the version, push git commits
and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).
