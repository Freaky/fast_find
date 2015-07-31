require "bundler/gem_tasks"

task :test do
	$:.unshift './test'
  Dir['./test/test_*.rb'].each { |file| require file }
end
