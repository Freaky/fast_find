#!/usr/bin/env ruby

require 'fast_find'

# FastFind.find('.') do |path, stat|
# 	puts "#{path}: #{stat.inspect}"
# end

require 'benchmark'

#BMDir = '/home/freaky/code/freshbsd/v4-roda'
BMDir = '/cvs/netbsd/othersrc'

FastFinder = FastFind::Finder.new

# FastFind.find('/tmp',  errors: :raise) do |f, s|
# 	p [f, s] if f =~ /adir/
# end
# exit

5.times do
Benchmark.bmbm do |b|
	b.report("Find") do
		files = Set.new
		Find.find(BMDir) do |f|
			files << f
		end
	end

	b.report("FastFind") do
		files =  Set.new
		FastFinder.find(BMDir) do |f|
			files << f
		end
	end
end
end
