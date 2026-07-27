# frozen_string_literal: true

require "testalaria/def_index"
require "testalaria/resolver"
require "testalaria/map"

module Testalaria
  # Turns a PR's changes into the set of examples to run, each carrying a
  # complete provenance record (why it was selected). Pure: map + already-parsed
  # diff data in, examples + reasons out. All IO (git, parsing) happens in the
  # caller; the selector only reads DefIndex objects, hunks, and the map.
  #
  # Method-level by default; widens to file-level only when method resolution is
  # genuinely ambiguous (new methods, class-body/toplevel, dynamic defs, renames).
  class Selector
    # One changed source file, with its diff and parsed forms already resolved
    # by the caller. head_index is nil if the file was deleted at HEAD;
    # base_index is nil if the file is new (absent at the merge-base).
    ChangedSource = Struct.new(:path, :hunks, :head_index, :base_index, keyword_init: true)

    # A single reason an example (or test file) was selected. Value-equal for
    # dedup. rule ∈ changed_test_file | method_match | file_escalation |
    # stub_match | const_match | full_run_trigger; cause names the escalation
    # trigger (or, for const_match, the changed constant).
    Reason = Struct.new(:rule, :file, :method, :hunk, :cause, keyword_init: true)

    Result = Struct.new(
      :full_run, :trigger, :example_reasons, :uncovered_files,
      :escalations, :test_files, :file_reasons,
      keyword_init: true
    )

    def initialize(map:, full_run_triggers: [], stub_index: nil, const_index: nil)
      @map = map
      @triggers = full_run_triggers
      @stub_index = stub_index
      @const_index = const_index
      @by_method, @by_file = build_reverse_index(map)
    end

    def select(changed_source: [], changed_test: [], changed_paths: nil)
      changed_paths ||= changed_source.map(&:path) + changed_test

      if (trigger = changed_paths.find { |p| trigger?(p) })
        return Result.new(full_run: true, trigger: trigger, example_reasons: {},
                          uncovered_files: [], escalations: [], test_files: [],
                          file_reasons: {})
      end

      state = new_state
      changed_test.each do |tf|
        add_file_reason(state, tf, Reason.new(rule: "changed_test_file", file: tf))
        state[:test_files] << tf
      end
      changed_source.each { |cs| process_source(cs, state) }

      finalize(state)
    end

    private

    def new_state
      {
        example_reasons: Hash.new { |h, k| h[k] = [] },
        file_reasons: Hash.new { |h, k| h[k] = [] },
        uncovered: [],
        escalations: [],
        test_files: []
      }
    end

    def finalize(state)
      state[:example_reasons].each_value(&:uniq!)
      state[:file_reasons].each_value(&:uniq!)
      Result.new(
        full_run: false, trigger: nil,
        example_reasons: state[:example_reasons],
        uncovered_files: state[:uncovered].uniq,
        escalations: state[:escalations].uniq,
        test_files: state[:test_files].uniq,
        file_reasons: state[:file_reasons]
      )
    end

    def process_source(cs, state)
      file = cs.path
      file_examples = @by_file[file] || []

      changed_names =
        if cs.head_index.nil?
          handle_deleted_file(cs, file, file_examples, state)
        else
          handle_present_file(cs, file, file_examples, state)
        end

      stub_files = @stub_index ? @stub_index.test_files_for(changed_names) : []

      # A changed source file with no coverage and no stub: nothing can be
      # selected for it — surface it as exposed rather than silently safe.
      state[:uncovered] << file if file_examples.empty? && stub_files.empty?

      stub_files.each do |tf|
        state[:test_files] << tf
        add_file_reason(state, tf, Reason.new(rule: "stub_match", file: file))
      end
    end

    # @return [Array<String>] method names considered changed (for stub match)
    def handle_deleted_file(cs, file, file_examples, state)
      escalate(file, "file_deleted", file_examples, state) unless file_examples.empty?
      cs.base_index ? names(cs.base_index) : []
    end

    # @return [Array<String>] method names considered changed (for stub match)
    def handle_present_file(cs, file, file_examples, state)
      head = cs.head_index
      resolver = Resolver.new(head)
      hunks = Array(cs.hunks)

      # No hunk detail (e.g. mode/binary change we still see): widen to file.
      if hunks.empty?
        escalate(file, "file_change", file_examples, state)
        return names(head)
      end

      base_names = cs.base_index ? names(cs.base_index) : []
      head_names = names(head)
      deleted = base_names - head_names

      # Classify each changed line: a method hit, a changed constant, or a
      # genuine toplevel (class-body) change. Constant assignments are pulled
      # out of the toplevel bucket so they trigger a reference lookup instead of
      # a blunt whole-file escalation.
      method_hits = []
      changed_consts = []
      toplevel = false
      hunks.flat_map(&:to_a).each do |line|
        name = resolver.method_for(line)
        if name != DefIndex::TOPLEVEL
          method_hits << name
        elsif @const_index && (consts = const_names_at(head, line)).any?
          # Constant change with an index to resolve its readers -> targeted.
          changed_consts.concat(consts)
        else
          # Genuine class-body change, or a constant with no index to resolve
          # its readers -> fall back to the safe whole-file escalation.
          toplevel = true
        end
      end
      method_hits.uniq!
      changed_consts.uniq!

      new_methods = method_hits.reject { |n| base_names.include?(n) }
      renamed = !deleted.empty? && !new_methods.empty?

      method_hits.each { |name| resolve_hit(name, file, head, file_examples, renamed, state) }
      escalate_toplevel(file, head, file_examples, state) if toplevel
      select_const_refs(changed_consts, state)
      select_deleted(deleted, file, file_examples, renamed, state)

      method_hits + deleted
    end

    def resolve_hit(name, file, _head, file_examples, renamed, state)
      if @by_method.key?([file, name])
        reason = Reason.new(rule: "method_match", file: file, method: name)
        @by_method[[file, name]].each { |ex| state[:example_reasons][ex] << reason }
      else
        # A def with no recorded coverage: new (or renamed) method.
        escalate(file, renamed ? "rename" : "new_method", file_examples, state, method: name)
      end
    end

    def escalate_toplevel(file, head, file_examples, state)
      escalate(file, head.dynamic? ? "dynamic_def" : "toplevel_change", file_examples, state)
    end

    # Constant names whose assignment range covers this line.
    def const_names_at(def_index, line)
      def_index.const_entries.select { |e| e.range.cover?(line) }.map(&:name)
    end

    # A changed constant reaches its dependents only through reads coverage never
    # recorded. Look each name up in the const reference index, resolve the
    # reading site to a mapped example set, and select those.
    def select_const_refs(const_names, state)
      return if const_names.empty? || @const_index.nil?

      const_names.each do |cname|
        @const_index.sites_for([cname]).each do |ref_file, ref_method|
          key = [ref_file, ref_method]
          next unless @by_method.key?(key)

          reason = Reason.new(rule: "const_match", file: ref_file, method: ref_method, cause: cname)
          @by_method[key].each { |ex| state[:example_reasons][ex] << reason }
        end
      end
    end

    def select_deleted(deleted, file, file_examples, renamed, state)
      deleted.each do |name|
        key = [file, name]
        next unless @by_method.key?(key)

        reason =
          if renamed
            Reason.new(rule: "file_escalation", file: file, method: name, cause: "rename")
          else
            Reason.new(rule: "method_match", file: file, method: name)
          end
        @by_method[key].each { |ex| state[:example_reasons][ex] << reason }
      end
      escalate(file, "rename", file_examples, state) if renamed
    end

    def escalate(file, cause, file_examples, state, method: nil)
      reason = Reason.new(rule: "file_escalation", file: file, cause: cause, method: method)
      state[:escalations] << reason
      file_examples.each { |ex| state[:example_reasons][ex] << reason }
    end

    def add_file_reason(state, file, reason)
      state[:file_reasons][file] << reason
    end

    def names(def_index)
      def_index.entries.map(&:name).uniq
    end

    def build_reverse_index(map)
      by_method = Hash.new { |h, k| h[k] = [] }
      by_file = Hash.new { |h, k| h[k] = [] }
      Map.example_keys(map).each do |example|
        (map[example] || {}).each do |file, methods|
          by_file[file] << example
          Array(methods).each { |m| by_method[[file, m]] << example }
        end
      end
      [by_method, by_file]
    end

    def trigger?(path)
      @triggers.any? do |pattern|
        path == pattern ||
          File.fnmatch?(pattern, path, File::FNM_PATHNAME | File::FNM_EXTGLOB) ||
          File.fnmatch?(pattern, path, File::FNM_EXTGLOB)
      end
    end
  end
end
