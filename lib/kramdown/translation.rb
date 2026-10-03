# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++
#

require 'kramdown/document'

module Kramdown

  # Extraction and backfill support for human translation workflows.
  #
  # A document is split into independent *translation units* based on semantic
  # blocks (paragraphs, headers, list items, ...). Non-text structures inside
  # a unit (links, emphasis, code spans, math, ...) are represented by
  # identified placeholder tokens. This allows translators to freely change
  # word order while the original URLs, code contents and math expressions are
  # preserved.
  #
  # Placeholder identity is scoped to a unit: a token created for one unit can
  # never be used in the translation of another unit. During backfill the
  # placeholder pairs, the allowed nesting of container placeholders and the
  # appearance of every required placeholder are validated. On failure a
  # Translation::Error is raised and the document is left untouched.
  #
  #   package = Kramdown::Translation.extract(document)
  #   package.units.each do |unit|
  #     package.translate(unit.id, translate(unit.source))
  #   end
  #   package.apply!
  module Translation

    # Error raised during placeholder validation. The message always includes
    # the id (and, if known, type and source line) of the offending unit.
    class Error < Kramdown::Error; end

    # Matches an open (+{{KD:u1:n2:a}}+), close (+{{KD:/u1:n2:a}}+) or atomic
    # (+{{KD:u1:n3:codespan}}+) placeholder token.
    TOKEN_RE = /\{\{KD:(\/?)u(\d+):n(\d+):([a-z_]+)\}\}/

    # Container placeholder tags and the element type they restore.
    CONTAINER_TAGS = {
      'a' => :a,
      'em' => :em,
      'strong' => :strong,
    }.freeze

    # Which container placeholder may directly contain which other container.
    # Links may wrap emphasis/strong, but links cannot contain other links.
    CONTAINER_NESTING = {
      'a' => %w[em strong],
      'em' => %w[a em strong],
      'strong' => %w[a em strong],
    }.freeze

    # Atomic placeholder tags that are replaced as a whole and never contain
    # placeholders themselves.
    LEAF_TAGS = %w[codespan math br image footnote entity typographic_sym
      smart_quote abbreviation html_element xml_comment xml_pi comment raw
      separator node].freeze

    # Mapping from atomic element types to their placeholder tag.
    ATOMIC_ELEMENT_TAGS = {
      codespan: 'codespan',
      math: 'math',
      br: 'br',
      img: 'image',
      footnote: 'footnote',
      entity: 'entity',
      typographic_sym: 'typographic_sym',
      smart_quote: 'smart_quote',
      abbreviation: 'abbreviation',
      html_element: 'html_element',
      xml_comment: 'xml_comment',
      xml_pi: 'xml_pi',
      comment: 'comment',
      raw: 'raw',
    }.freeze

    # A single semantic block that should be translated as a whole.
    class Unit
      # The unique, document scoped id of the unit, e.g. +"u1"+.
      attr_reader :id

      # The semantic type of the unit (+:paragraph+, +:header+, +:list_item+,
      # +:definition_term+ or +:table_cell+).
      attr_reader :type

      # The source text with placeholder tokens in place of non-text
      # structures. Multi-segment units (list items) join their segments with
      # +separator+ placeholders.
      attr_reader :source

      # The element that is replaced on backfill.
      attr_reader :element

      # The original inline-bearing block elements, one per segment.
      attr_reader :segments

      # Placeholder records keyed by node id (e.g. +"n2"+).
      attr_reader :entries

      def initialize(id, type, element, segments, source, entries)
        @id = id
        @type = type
        @element = element
        @segments = segments
        @source = source
        @entries = entries
      end

      # The source line of the unit in the original document, if known.
      def location
        @segments.first.options[:location]
      end
    end

    # Holds the extracted units and performs the validated backfill.
    class Package
      # All extracted Unit objects in document order.
      attr_reader :units

      def initialize(root)
        @root = root
        @units = []
        @unit_counter = 0
        @node_counter = 0
        @translations = {}
        extract_units
      end

      # Store the +translation+ of the unit identified by +unit_id+.
      def translate(unit_id, translation)
        unit = find_unit(unit_id)
        @translations[unit.id] = String(translation)
        self
      end

      # Validate all collected translations and apply them to the document.
      #
      # Every translation is validated first; the element tree is only
      # modified when all translations are valid. Returns the package on
      # success and raises Translation::Error (leaving the document
      # untouched) otherwise.
      def apply!
        replacements = {}
        @units.reverse_each do |unit|
          translated = @translations[unit.id]
          raise_error(unit, 'no translation provided for unit') if translated.nil?
          replacements[unit.element.object_id] = build_replacement(unit, translated, replacements)
        end
        @units.each do |unit|
          commit(unit, replacements[unit.element.object_id])
        end
        self
      end

      private

      def find_unit(unit_id)
        @units.find {|unit| unit.id == unit_id.to_s } ||
          raise(Error, "unknown translation unit: #{unit_id}")
      end

      def next_unit_id
        @unit_counter += 1
        "u#{@unit_counter}"
      end

      def next_node_id
        @node_counter += 1
        "n#{@node_counter}"
      end

      ## Extraction ########################################################

      def extract_units
        walk_blocks(@root.children) {|unit| @units << unit }
      end

      def walk_blocks(elements, &block)
        elements.each do |element|
          case element.type
          when :p, :header, :dt
            block.call(make_simple_unit(element))
          when :td
            if inline_block?(element)
              block.call(make_simple_unit(element))
            else
              walk_blocks(element.children, &block)
            end
          when :li
            unit = make_list_item_unit(element)
            block.call(unit) if unit
            walk_list_item_contents(element, &block)
          else
            walk_blocks(element.children, &block)
          end
        end
      end

      def walk_list_item_contents(list_item, &block)
        list_item.children.each do |child|
          next if %i[p header dt td li].include?(child.type)
          walk_blocks(child.children, &block)
        end
      end

      def inline_block?(element)
        element.children.all? {|child| Element.category(child) == :span }
      end

      def gather_segments(list_item)
        segments = []
        # Collect inline-bearing blocks inside this list item, but never cross
        # into another (nested) list item: those become their own units.
        descend = lambda do |children|
          children.each do |child|
            next if child.type == :li
            if %i[p header dt td].include?(child.type) &&
               child.children.all? {|grandchild| Element.category(grandchild) == :span }
              segments << child
            else
              descend.call(child.children)
            end
          end
        end
        descend.call(list_item.children)
        segments
      end

      def make_simple_unit(element)
        build_unit(unit_type(element), element, [element])
      end

      def make_list_item_unit(list_item)
        segments = gather_segments(list_item)
        return nil if segments.empty?
        build_unit(:list_item, list_item, segments)
      end

      def unit_type(element)
        case element.type
        when :p then :paragraph
        when :header then :header
        when :dt then :definition_term
        when :td then :table_cell
        end
      end

      def build_unit(type, element, segments)
        id = next_unit_id
        entries = {}
        source_parts = segments.map do |segment|
          serialize_children(segment.children, id, entries)
        end
        source = source_parts.each_with_index.map do |part, index|
          if index < source_parts.length - 1
            node_id = register_entry(id, entries, 'separator', nil)
            "#{part}#{token(id, node_id, 'separator')}"
          else
            part
          end
        end.join
        Unit.new(id, type, element, segments, source, entries)
      end

      def token(unit_id, node_id, tag, closing = false)
        "{{KD:#{'/' if closing}#{unit_id}:#{node_id}:#{tag}}}"
      end

      def register_entry(unit_id, entries, tag, element)
        node_id = next_node_id
        entries[node_id] = {tag: tag, element: element, unit: unit_id}
        node_id
      end

      def serialize_children(children, unit_id, entries)
        children.map {|child| serialize_inline(child, unit_id, entries) }.join
      end

      def serialize_inline(element, unit_id, entries)
        case element.type
        when :text
          element.value
        when :a, :em, :strong
          tag = element.type.to_s
          node_id = register_entry(unit_id, entries, tag, element)
          inner = serialize_children(element.children, unit_id, entries)
          "#{token(unit_id, node_id, tag)}#{inner}#{token(unit_id, node_id, tag, true)}"
        else
          tag = ATOMIC_ELEMENT_TAGS[element.type] || 'node'
          node_id = register_entry(unit_id, entries, tag, element)
          token(unit_id, node_id, tag)
        end
      end

      ## Backfill ##########################################################

      def build_replacement(unit, translated, descendant_replacements = nil)
        inline = parse_translation(unit, translated)
        segment_children = split_segments(unit, inline)
        element_clone, clone_map = deep_clone(unit.element, descendant_replacements || {})
        cloned_segments = unit.segments.map do |segment|
          clone_map.fetch(segment.object_id) do
            raise_error(unit, 'could not map a segment back to the document tree')
          end
        end
        target_blocks = unit.type == :list_item ? cloned_segments : [cloned_segments.first]
        target_blocks.each_with_index do |block, index|
          assign_inline_children(block, segment_children[index])
        end
        element_clone
      end

      def assign_inline_children(block, children)
        block.children = children
        return unless block.type == :header
        block.options[:raw_text] = children.map {|child| raw_text(child) }.join
      end

      def raw_text(element)
        case element.type
        when :text then element.value
        when :img then element.attr['alt'].to_s
        when :br then ' '
        else
          element.children.map {|child| raw_text(child) }.join
        end
      end

      def commit(unit, replacement)
        parent = find_parent(@root, unit.element)
        # Nested units are already absorbed by an ancestor replacement.
        return unless parent
        index = parent.children.index(unit.element)
        parent.children[index] = replacement
      end

      def find_parent(element, target)
        element.children.each do |child|
          return element if child.equal?(target)
          parent = find_parent(child, target)
          return parent if parent
        end
        nil
      end

      def deep_clone(element, replacements)
        map = {}
        clone = deep_clone_recursive(element, map, replacements)
        [clone, map]
      end

      def deep_clone_recursive(element, map, replacements)
        if (replacement = replacements[element.object_id])
          map[element.object_id] = replacement
          return replacement
        end
        clone = Element.new(element.type, element.value,
                           element.attr.dup, element.options.dup)
        clone.children = element.children.map do |child|
          deep_clone_recursive(child, map, replacements)
        end
        map[element.object_id] = clone
        clone
      end

      def split_segments(unit, children)
        segments = [[]]
        children.each do |child|
          if child.type == :separator
            segments << []
          else
            segments.last << child
          end
        end
        if segments.length != unit.segments.length
          raise_error(unit, 'expected a separator between all segments of the list item')
        end
        segments
      end

      def parse_translation(unit, translated)
        root_children = []
        # Each frame is [element, node_id, tag]; new children go to the frame's
        # element, or to the root list when the stack is empty.
        stack = []
        used = {}
        append_text = lambda do |text|
          target = stack.empty? ? root_children : stack.last[0].children
          append_text_node(target, text)
        end
        position = 0
        translated.scan(TOKEN_RE) do
          match = Regexp.last_match
          append_text.call(translated[position...match.begin(0)]) if match.begin(0) > position
          position = match.end(0)
          consume_token(unit, match, stack, used, root_children)
        end
        append_text.call(translated[position..]) if position < translated.length
        unless stack.empty?
          node_id = stack.last[1]
          raise_error(unit, "unclosed open placeholder for node #{node_id} (#{stack.last[2]})")
        end
        unit.entries.each_key do |node_id|
          unless used[node_id]
            raise_error(unit, "required placeholder node #{node_id} is missing from the translation")
          end
        end
        root_children
      end

      def append_text_node(target, text)
        target << Element.new(:text, text) unless text.empty?
      end

      def consume_token(unit, match, stack, used, result)
        closing = match[1] == '/'
        token_unit = "u#{match[2]}"
        node_id = "n#{match[3]}"
        tag = match[4]
        validate_token(unit, token_unit, node_id, tag, closing, stack)
        entry = unit.entries[node_id]
        if closing
          stack.pop
        else
          if used[node_id]
            raise_error(unit, "placeholder node #{node_id} appears more than once")
          end
          used[node_id] = true
          if CONTAINER_TAGS.key?(tag)
            element = Element.new(CONTAINER_TAGS[tag], nil, entry[:element].attr.dup)
            (stack.empty? ? result : stack.last[0].children) << element
            stack.push([element, node_id, tag])
          elsif tag == 'separator'
            result << Element.new(:separator)
          else
            (stack.empty? ? result : stack.last[0].children) << deep_clone_node(entry[:element])
          end
        end
      end

      def deep_clone_node(element)
        clone = Element.new(element.type, element.value, element.attr.dup, element.options.dup)
        clone.children = element.children.map {|child| deep_clone_node(child) }
        clone
      end

      def validate_token(unit, token_unit, node_id, tag, closing, stack)
        valid_tag = CONTAINER_TAGS.key?(tag) || LEAF_TAGS.include?(tag)
        raise_error(unit, "unknown placeholder tag #{tag.inspect}") unless valid_tag
        if token_unit != unit.id
          raise_error(unit, "placeholder #{tag} belongs to unit #{token_unit}, not #{unit.id}")
        end
        entry = unit.entries[node_id]
        if entry.nil?
          raise_error(unit, "unknown placeholder node #{node_id} for this unit")
        elsif entry[:tag] != tag
          raise_error(unit, "tag mismatch for node #{node_id}: expected #{entry[:tag]}, got #{tag}")
        end
        if closing
          if stack.empty?
            raise_error(unit, "closing placeholder #{tag} without an open placeholder")
          elsif stack.last[1] != node_id
            open_node_id = stack.last[1]
            raise_error(unit, "closing placeholder for node #{node_id} does not match open " \
                             "placeholder for node #{open_node_id}")
          end
          return
        end
        parent_tag = stack.last&.at(2)
        if CONTAINER_TAGS.key?(tag)
          if parent_tag && !CONTAINER_NESTING[parent_tag].include?(tag)
            raise_error(unit, "placeholder #{tag} is not allowed directly inside #{parent_tag}")
          end
        elsif tag == 'separator'
          if parent_tag
            raise_error(unit, 'separator placeholder is not allowed inside another placeholder')
          end
        elsif parent_tag
          raise_error(unit, "atomic placeholder #{tag} is not allowed inside #{parent_tag} " \
                           'without its own placeholder pair')
        end
      end

      def raise_error(unit, message)
        location = unit.location ? " at line #{unit.location}" : ''
        raise Error, "translation unit #{unit.id} (#{unit.type}#{location}): #{message}"
      end

    end

    class << self
      # Extract translation units from a Kramdown::Document.
      def extract(document)
        Package.new(document.root)
      end
    end

  end

  class Document

    # Return a Translation::Package for this document's element tree.
    def translation_package
      Translation::Package.new(@root)
    end

    # Validate +translations+ (a hash mapping unit ids to translated strings)
    # and apply them to the document. Raises Translation::Error without
    # modifying the document if any translation is invalid.
    def apply_translations(translations)
      package = Translation::Package.new(@root)
      translations.each {|id, text| package.translate(id, text) }
      package.apply!
      self
    end

  end

end
