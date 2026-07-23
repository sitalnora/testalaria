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
    # stub_match | full_run_trigger; cause names the escalation trigger.
    Reason = Struct.new(:rule, :file, :method, :hunk, :cause, keyword_init: true)

    Result = Struct.new(
      :full_run, :trigger, :example_reasons, :uncovered_files,
      :escalations, :test_files, :file_reasons,
      keyword_init: true
    )

    def initialize(map:, full_run_triggers: [], stub_index: nil)
      @map = map
      @triggers = full_run_triggers
      @stub_index = stub_index
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
      hit_names = hunks.flat_map { |r| r.map { |line| resolver.method_for(line) } }.uniq
      new_methods = hit_names.reject { |n| n == DefIndex::TOPLEVEL || base_names.include?(n) }
      renamed = !deleted.empty? && !new_methods.empty?

      hit_names.each { |name| resolve_hit(name, file, head, file_examples, renamed, state) }
      select_deleted(deleted, file, file_examples, renamed, state)

      (hit_names - [DefIndex::TOPLEVEL]) + deleted
    end

    def resolve_hit(name, file, head, file_examples, renamed, state)
      if name == DefIndex::TOPLEVEL
        cause = head.dynamic? ? "dynamic_def" : "toplevel_change"
        escalate(file, cause, file_examples, state)
      elsif @by_method.key?([file, name])
        reason = Reason.new(rule: "method_match", file: file, method: name)
        @by_method[[file, name]].each { |ex| state[:example_reasons][ex] << reason }
      else
        # A def with no recorded coverage: new (or renamed) method.
        escalate(file, renamed ? "rename" : "new_method", file_examples, state, method: name)
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
