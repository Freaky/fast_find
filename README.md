# FastFind

`FastFind` is a multi-threaded alternative to the standard `Find` module,
offering increased performance on Rubies which can run `Dir#entries` and
`File#lstat` calls concurrently (i.e. JRuby).

While it can operate as a drop-in replacement for `Find`, it's best used with
a two-argument block which also yields the `File::Stat` object associated with
each yielded path.

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

Traditional Find-style (not recommended):

```ruby
FastFind.find(dir) { |entry| frob(entry) }
FastFind.find(dir, ignore_errors: false) { .. } # => explodes in your face
FastFind.find(dir) # => Enumerator
```

Extended style using the second argument to get a `File::Stat`, or `Exception`
object (if `ignore_errors` is false, this will be raised after the block).

```ruby
FastFind.find(dir) { |entry, stat| frob(entry, stat) }
```

`FastFind` uses a concurrent-ruby executor to run, which can be customised
by passing it as a named argument:

```ruby
executor = Concurrent::FixedThreadPool.new(16, idletime: 90)
FastFind.find(dir, executor: executor)
```

Or while no concurrent `find` operations are in progress, to the module itself:

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
FastFind          20.492188  41.898438  62.390625 (  7.558871)
Find              14.742188  27.804688  42.546875 ( 42.355761)
FastFind as Find  33.648438  44.757812  78.406250 ( 26.047635)
```

These results highlight the importance of the two-argument version.

ruby 3.0.0p0 (2020-12-25 revision 95aff21468) \[x86_64-freebsd12.2]:

```
                       user     system      total        real
FastFind          27.181013  26.598176  53.779189 ( 38.016831)
Find              10.672928  20.198666  30.871594 ( 30.878547)
FastFind as Find  27.008096  36.266163  63.274259 ( 38.832825)
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
