
# SETUP

1. You first run the setup within the rake file, that invokes:

```ruby
Testalaria::Setup.run
    |
write_config # this generates the config file, which contains what subprocesses to spawn
    |
append_dockerignore # at the test-specific files to the dockerignore
	|
seed # this actually generates the 2 RSpec/ Minitest subprocesses
```

2. Once the seed starts running your main process stalls until those 2 subprocesses finish - Let's look at minitest first

```ruby
module Testalaria
	module Adapters
		module Minitest
			module Hooks
			
				def before_setup
					super
					Testalaria::Session.current.start_example(testalaria_example_id)
				end
				
				  
				
				def after_teardown
					Testalaria::Session.current.finish_example(testalaria_example_id)
					super
				end
				
				  
				
				def testalaria_example_id
					"#{self.class.name}##{name}"
				end
			
			end
		
		  
		
			def self.install!
				return unless Session.active?
				return unless defined?(::Minitest::Test)
				
				::Minitest::Test.prepend(Hooks)
				::Minitest.after_run { Session.current.flush }
			end
		end
	end
end
```

Basically this injects some the necessary steps to record tests in the minitest test suite hooks.

Let's see what each step does

```ruby
module Testalaria
	class Session
	
		ENV_FLAG = "TESTALARIA"
		
		class << self
			def active?
				ENV[ENV_FLAG] == "1"
			end
		
			def current
				@current ||= new
			end
			
			def reset!
				@current = nil
			end
		
		end
		
		  
		
		attr_reader :entries
		
		  
		
		def initialize(
			coverage: CoverageSource.new,
			store: MapStore.new(path: ENV.fetch("TESTALARIA_MAP", MapStore::DEFAULT_PATH)),
			root: Dir.pwd,
			clock: Time,
		)	
			@collector = Collector.new(coverage: coverage, root: root)	
			@coverage = coverage
			@store = store
			@clock = clock
			@entries = {}
			@coverage.start
		end
		
		def start_example(_id)
			@collector.start_example
		end
		
		def finish_example(id)
			@entries[id] = @collector.finish_example
		end
		
		def flush
			base = @store.load
			
			merged = Map.merge(base, @entries)
			merged[:commit] = commit
			merged[:timestamp] = timestamp
			merged[:version] = Map::VERSION
			@store.dump(merged)
			flush_coverage_digest
		end
		
		private
		
		def flush_coverage_digest
			store = CoverageDigestStore.new
			store.dump(CoverageDigest.merge(store.load, @collector.executed_lines))
		end
		
		  
		
		def commit
			ENV["TESTALARIA_COMMIT"] || nil
		end
		
		  
		
		def timestamp
			env = ENV["TESTALARIA_TIMESTAMP"]
			env ? env.to_i : @clock.now.to_i
		end
		
	end

end
```

So, in the `before_suite` we call `start_example`, which in turn calls `@collector.start_example`.

```ruby
def start_example
	@before = @coverage.peek
end
```

In the `after_suite` we call `finish_example` which in turn calls `@collector.finish_example`.

```ruby
def finish_example
	after = @coverage.peek
	to_methods(diff(@before || {}, after))
end
```

So the logic that happens here is:

1. Start the test suite
2. Before running each test, take a snapshot of the coverage
3. Run the test
4. After running the test, take a snapshot of the coverage
5. Then, based on the diff between the after and before, we generate the entries for the test - what methods in the source code that we defined does this test code call?

```ruby
def diff(before, after)
	result = {}
	after.each do |file, after_counts|
		next unless in_project?(file)
		
		before_counts = before[file] || []
		lines = moved_lines(before_counts, after_counts)
		result[file] = lines unless lines.empty?
	end
	result
end


def in_project?(file)
	file.start_with?(@root) && !file.include?("/gems/") && !file.include?("/vendor/")
end

def moved_lines(before_counts, after_counts)
	lines = []
	after_counts.each_with_index do |count, idx|
		next if count.nil?
		
		before = before_counts[idx] || 0
		lines << (idx + 1) if count > before
	end
	lines
end
```

1. We check if the file touched by the coverage is in the project (it's not gems or vendor)
2. We then get the before count by using `peek` - `before_counts = before[file] || []`

`peek` under the hood calls `peek_result` which is a ruby stdlib impl

```ruby
Returns a hash that contains filename as key and coverage array as value. This is the same as `Coverage.result(stop: false, clear: false)`.

{
  "file.rb" => [1, 2, nil],
  ...
}
```

The result of this function is 

```ruby
{
	"file_name.rb" => [1, 10, nil, 0, 5]
}
```

For which each element of the array represents the line in the code being called.

`[1, 10, nil, 0, 5]` means that:
1. line 1 was called 1 time
2. line 2 was called 10 times
3. line 3 cannot be called - nocov
4. line 4 was called 0 times
5. line 5 was called 5 times

Based on this, we do a diff to see exactly which lines were called in the after the before/ after computation


3. We then see the modified lines with `lines = moved_lines(before_counts, after_counts)`

Here we basically just see if the after is bigger than the before

If so, in modified lines we add the line numbers, and the `idx + 1` happens due to the fact that arys start from 0, whereas lines start from 1.

4. Then we assign the lines ary containing the numbers of the lines changed to the file in the result hash.


Then moving further in the collector for setup we do a `to_methods(diff(@before || {}, after))` which acts upon the diff, let's dive into what `to_methods` does.

```ruby
def to_methods(touched)
	touched.each_with_object({}) do |(abs, lines), acc|
		rel = relative(abs)
		next if ignored?(rel)
		
		acc[rel] = resolver_for(abs).names_for(lines)
	end
end
```

Iterates through the changed hash and does the `relative(abs)` call, and checks if the result is to be ignored.

```ruby
def ignored?(rel)
	@ignore.any? { |prefix| rel.start_with?(prefix) }
end

  

def relative(abs)
	abs.start_with?("#{@root}/") ? abs.sub("#{@root}/", "") : abs
end
```

Then we create the resolver which resolved the actual method names, so we know what the chain of execution is, `acc[rel] = resolver_for(abs).names_for(lines)`

```ruby
def resolver_for(abs)
	di = (@def_index_cache[abs] ||= build_def_index(abs))
	Resolver.new(di)
end

def build_def_index(abs)
	DefIndex.build(File.read(abs))
rescue ParseError, Errno::ENOENT
	DefIndex.build("")
end
```

Let's see what `DefIndex` is:

```ruby
module Testalaria
	class DefIndex
		TOPLEVEL = "(toplevel)"
		
		DYNAMIC_METHODS = %w[
			define_method class_eval module_eval instance_eval class_exec instance_exec
		].freeze
		
		Entry = Struct.new(:name, :range)
		  
		# Sorted [Entry, ...] by range start then name. Non-overlapping.
		attr_reader :entries
		
		  
		
		# @param source [String] Ruby source
		# @raise [ParseError] on unparseable source (selection escalates the file)
		def self.build(source)
			new(source)
		end
		
		  
		
		def initialize(source)
			@entries = []
			@dynamic = false
			sexp = Ripper.sexp(source)
			raise ParseError, "source did not parse" if sexp.nil?
			
			walk(sexp, [], singleton: false)
			@entries.sort_by! { |e| [e.range.begin, e.name] }
		end
		
		  
		
		def dynamic?
			@dynamic
		end
		
		private
		
		def walk(node, stack, singleton:)
			return unless node.is_a?(Array)
			
			case node[0]
			when :class
			# [:class, const, superclass_or_nil, bodystmt]
			walk(node[3], stack + [const_name(node[1])], singleton: false)
			when :module
			# [:module, const, bodystmt]
			walk(node[2], stack + [const_name(node[1])], singleton: false)
			when :sclass
			# class << self : defs inside are singleton methods on the nesting
			walk(node[2], stack, singleton: true)
			when :def
			# [:def, ident, params, bodystmt]
			record_def(node[1], node, stack, singleton: singleton)
			when :defs
			# [:defs, target, period, ident, params, bodystmt] -> always singleton
			record_def(node[3], node, stack, singleton: true)
			else
			flag_dynamic(node)
			node.each { |child| walk(child, stack, singleton: singleton) }
			end
		end
		
		  
		
		def record_def(ident, node, stack, singleton:)
			name = ident[1]
			start_line = ident[2][0]
			nesting = stack.join("::")
			sep = singleton ? "." : "#"
			@entries << Entry.new("#{nesting}#{sep}#{name}", start_line..max_line(node))
			# A def nested inside a def can't be statically keyed on reliably.
			@dynamic = true if nested_def?(node[2..])
		end
		
		def const_name(node)
			return "<anon>" unless node.is_a?(Array)
			
			case node[0]
				when :const_ref, :top_const_ref then node[1][1]
				when :const_path_ref then "#{const_name(node[1])}::#{node[2][1]}"
				when :var_ref then node[1][1]
				when :@const then node[1]
				else "<anon>"
			end
		end
		
		def max_line(node)
			max = 0
			stack = [node]
			until stack.empty?
				cur = stack.pop
				next unless cur.is_a?(Array)
				
				if cur.length == 2 && cur[0].is_a?(Integer) && cur[1].is_a?(Integer)
					max = cur[0] if cur[0] > max
				else
					cur.each { |c| stack.push(c) if c.is_a?(Array) }
				end
			end
			max
		end
		
		def flag_dynamic(node)
			@dynamic = true if node[0] == :@ident && DYNAMIC_METHODS.include?(node[1])
		end
		
		def nested_def?(node)
			return false unless node.is_a?(Array)
			return true if %i[def defs].include?(node[0])
		
			node.any? { |c| nested_def?(c) }
		end
	end
end
```

Cool so we initialize this and then pass it to the resolver, let's see what the initialization entails

```ruby
@entries = []
@dynamic = false
```

Just ivar definitions.

```ruby
sexp = Ripper.sexp(source)
```

This is the big boy because it creates a S-expression Tree from the file. This is basically how ruby's parser works internally as well, resulting in the Abstract Syntax Tree. After running this, if it works, we will have a tree containing the manner in which stuff is defined in the file. Won't be going in the internals of this, as it's beyond the scope of the gem.

Next we walk the tree to get the mapping of each line to the function definition, so we know what functions each test calls - remember the diff from before.

```ruby
walk(sexp, [], singleton: false)
```

```ruby
def walk(node, stack, singleton:)
	return unless node.is_a?(Array)
	
	case node[0]
		when :class
		# [:class, const, superclass_or_nil, bodystmt]
		walk(node[3], stack + [const_name(node[1])], singleton: false)
		when :module
		# [:module, const, bodystmt]
		walk(node[2], stack + [const_name(node[1])], singleton: false)
		when :sclass
		# class << self : defs inside are singleton methods on the nesting
		walk(node[2], stack, singleton: true)
		when :def
		# [:def, ident, params, bodystmt]
		record_def(node[1], node, stack, singleton: singleton)
		when :defs
		# [:defs, target, period, ident, params, bodystmt] -> always singleton
		record_def(node[3], node, stack, singleton: true)
		else
		flag_dynamic(node)
		node.each { |child| walk(child, stack, singleton: singleton) }
	end
end
```

This walk method carries 2 information:
1. The stack in which this is defined - module level, like Foo::Bar, either Foo or Bar
2. Singleton - are the method definitions here instance of class level.

- `node[0]` contains the type tag.
- When it's a class, you want to descend into its class stack to see where the methods are defined, so you go to node[3]

```ruby
class Foo < Bar
	def baz
		1
	end
end

#ends up being

[:program,
	[
		[:class,
		[:const_ref, [:@const, "Foo", [1, 6]]],
		[:var_ref, [:@const, "Bar", [1, 12]]],
		[:bodystmt,
			[
				[:def,
				[:@ident, "baz", [2, 6]],
				[:params, nil, nil, nil, nil, nil, nil, nil],	
				[:bodystmt, [[:@int, "1", [3, 4]]], nil, nil, nil]]],
		nil,
		nil,
		nil,]]]]
```

- where bodystmt is the body statement, meaning method definition, and it's on position 3.
- Same thing for module, but it doesn't have as many fields, so the bodystmt is on position 2.
- If we got sclass, we basically hve a `class << self` which defines class-level methods. So we place singleton: true in the next run!
- If it's def, we set singleton false and record it.
- If it's defs (def self.method) we set singleton true and record it
- The dynamic edge case is for the specific situations where metaprogramming is used and the logic in entries cannot catch runtime definitions - metaprogramming bad.

```ruby
def record_def(ident, node, stack, singleton:)
	name = ident[1]
	start_line = ident[2][0]
	nesting = stack.join("::")
	sep = singleton ? "." : "#"
	@entries << Entry.new("#{nesting}#{sep}#{name}", start_line..max_line(node))
	# A def nested inside a def can't be statically keyed on reliably.
	@dynamic = true if nested_def?(node[2..])
end

def max_line(node)
	max = 0
	stack = [node]
	until stack.empty?
		cur = stack.pop
		next unless cur.is_a?(Array)
		
		if cur.length == 2 && cur[0].is_a?(Integer) && cur[1].is_a?(Integer)
			max = cur[0] if cur[0] > max
		else
			cur.each { |c| stack.push(c) if c.is_a?(Array) }
		end
	end
	max
end
```

So maxline is quite cool because:
1. The SEXP only gives us the start of the entry we're looking at not the end
2. So what we do is we iterate through that "entry's" callstack, going until we find an item with `[integer, integer]` - thsoe are unambigous in the ripper, they define lines with `[line, col]`, so we take the highest line, for the foo baz example, this would end up being `3`
3. Therefore, the range in the `Entry` object is gonna be `(2..3)`

Now, let's go back to our collector, after we have the `DefIndex` object: `Resolver.new(di)`

```ruby
module Testalaria
	class Resolver
		def initialize(def_index)
			@def_index = def_index
		end
		
		# @return [String] enclosing method name, or DefIndex::TOPLEVEL
		
		def method_for(line)
			@def_index.entries.each do |entry|
				return entry.name if entry.range.cover?(line)
			end
		
			DefIndex::TOPLEVEL
		end
	
		def names_for(lines)
			lines.map { |line| method_for(line) }.uniq.sort
		end
	end
end
```

So, creation doesn't do much, but the `to_methods` method calls `acc[rel] = resolver_for(abs).names_for(lines)`

So, `names_for`, which calls `method_for` which iterates through the entries associated with that file, and checks if the line numbers are in the method definition based on ranges, how cool is that!

So, let's take a step back and see where we're at after all of this

1. Run the tests
2. See what lines have changed after running a test, and note that down
3. Parse the file being touched with those lines
4. See in what methods those line changes fit
5. Create the final beautiful gorgeous array with test A affects method X.

After that we go to the setup and notice a final flush

```ruby
def flush
	base = @store.load
	merged = Map.merge(base, @entries)
	merged[:commit] = commit
	merged[:timestamp] = timestamp
	merged[:version] = Map::VERSION
	@store.dump(merged)
	flush_coverage_digest
end
```

1. `@store.load` is just the current state of the map
2. We merge the new entries that we just computed above
3. We dump the values in the new store

Magical, after all of this we have the list of tests to files!

# RUN

Cool, now that we have the map setup, let's walk through the steps that a normal RUN of the test will take.

```ruby
desc "Select and run the tests a PR's changes could break; emit the report"
task :run do
	exit(Testalaria::CLI.run)
end
```

```ruby
def run(config_path: Config::DEFAULT_PATH, out: $stdout, artifact_path: ARTIFACT_PATH)
	config = Config.load(config_path)
	git = Git.new
	outcome = Flow.new(config: config, git: git).run(target_branch: ENV["TARGET_BRANCH"])
	
	report = Report.new(outcome, head: head_sha(git))
	File.write(artifact_path, report.artifact_yaml)
	out.puts report.terminal(verbose: ENV["VERBOSE"] == "1")
	
	Flow.exit_status(outcome)
end
```

1. We load the config based on the config file we defined earlier - it contains information like what commands should be used for minitest/ rspec runs
2. We create a new git object (it's just the abstraction used to run system commands)
3. Flow is the big boy who has the responsibility of taking the test run through all the necessary 5 steps to achieve the desired goal:
	1. diff vs target branch + split paths into tests / source code
	2. runs changed test files first to recreate the map
	3. refreshes the map based on that
	4. selects and runs the remainder of the tests derived from the source changes 
	5. hands off the data to the reporter (static analysis to be done and whatnot)

```ruby
def run(target_branch: nil)
	target = target_branch || @config.target_branch
	base = @git.merge_base(target)
	changed = @git.changed_files(base)
	test_files, source_files = split_changed(changed)
	...
```

As said before, it gets the target branch, the merge base - where we want to see the merge, and sees what files were changed. Then it splits the files in tests vs source code on a stupid filter that's like `rspec` or `test` path prefix.

```ruby
...
	map_before = @store.load
	suites = []
	CoverageDigestStore.new(path: @coverage_path).delete # start diff-coverage clean
	
	# Step 2-3: purge the changed test files' stale keys, then run them.
	purge_test_files(test_files)
	suites.concat(run_test_files(test_files)) unless test_files.empty?
...
```

So, it deletes the old files in the map with `purge_test_files` and runs the new test files through the runner

```ruby
def purge_test_files(test_files)
	return if test_files.empty?
	
	map = @store.load
	test_files.each do |tf|
	keys_for_test_file(map, tf).each { |k| map.delete(k) }
	end
	
	@store.dump(map)
end

  

def run_test_files(files)
	files.group_by { |f| @config.runner_for(f) }.filter_map do |runner_config, group|
		next unless runner_config
		
		@runner.run_files(runner_config, group, env: subprocess_env)
	end
end
```

Which in turn calls

```ruby
# Run whole test files (flow step 2 / full-file reruns). Returns a Result.
def run_files(runner_config, files, env: {})
	invoke(runner_config.command, files, env)
end
```

Which basically invokes the rake tasks for the rspec/ minitest files.

```ruby
map = @store.load
changed_sources = source_files.map { |p| changed_source(base, p) }
selection = build_selection(map, changed_sources, test_files)
```

1. We reload the map after the above invocations have updated the map.
2. Then we look at the changed sources based on the git diffs
3. We generate the test selection - what do we need to run??

```ruby
def build_selection(map, changed_sources, test_files)
	stub_index = build_stub_index
	selector = Selector.new(map: map, full_run_triggers: @config.full_run_triggers, stub_index: stub_index)
	selector.select(
		changed_source: changed_sources,
		changed_test: test_files,
		changed_paths: changed_sources.map(&:path) + test_files
	)
end
```

We first build the stub index:

```ruby
def build_stub_index
	sources = {}
	@config.runners.each do |runner|
		Dir.glob(runner.pattern).each { |f| sources[f] = File.read(f) if File.exist?(f) }
	end
	StubIndex.build(sources)
end
```

Well, why do we need a stub index, we got a DefIndex, right? Wrong.

Thing is, coverage does not see stubbed methods.. so if i stub a method that should be called, then it won't be tested despite being part of that method's flow. Therefore, we'll use this to backfill the stubbed methods in the files! Screw you nondeterminism.

We then create the selector, and select the tests based on the:
1. Changed Sources
2. Changed Tests
3. Changed Paths

With the end result of the select being

```ruby
Result.new(
	full_run: false, trigger: nil,
	example_reasons: state[:example_reasons],
	uncovered_files: state[:uncovered].uniq,
	escalations: state[:escalations].uniq,
	test_files: state[:test_files].uniq,
	file_reasons: state[:file_reasons]
)
```


Then we run the remainder

```ruby
if selection.full_run
	suites.concat(run_full)
else
	already = already_ran_examples(map, test_files)
	remainder = selection.example_reasons.keys - already.to_a
	suites.concat(run_examples(remainder))
	suites.concat(run_test_files(selection.test_files - test_files))
end
```

And finally we return the outcome, to be passed to the static analysis tool:

```ruby
Outcome.new(
	full_run: selection.full_run,
	trigger: selection.trigger,
	selection: selection,
	suites: suites,
	examples_run: (selection.example_reasons.keys + collected_example_keys(test_files)).uniq,
	map_before: map_before,
	map_after: @store.load,
	changed_test_files: test_files,
	changed_source_files: source_files,
	changed_sources: changed_sources,
	executed_lines: CoverageDigestStore.new(path: @coverage_path).load
)
```

Then honestly the report is not really worth explaining, the above is where the magic lives.
