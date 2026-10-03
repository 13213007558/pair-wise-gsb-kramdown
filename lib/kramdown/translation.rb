# -*- coding: utf-8; frozen_string_literal: true -*-

require 'kramdown/document'
require 'kramdown/converter/kramdown'

module Kramdown

  module Translation

    BUNDLE_ID_CHARS = ('a'..'z').to_a.freeze
    private_constant :BUNDLE_ID_CHARS

    UNIT_TYPES = {
      p: 'paragraph',
      header: 'header',
      li: 'list_item',
      dt: 'definition_term',
      td: 'table_cell',
      th: 'table_cell'
    }.freeze
    private_constant :UNIT_TYPES

    LITERAL_TYPES = [:text, :entity, :smart_quote, :typographic_sym].freeze
    private_constant :LITERAL_TYPES

    LITERAL_PARSER_OPTIONS = {
      auto_ids: false,
      footnote_nr: 1,
      entity_output: :as_char,
      typographic_symbols: {},
      smart_quotes: %w[apos apos quot quot]
    }.freeze
    private_constant :LITERAL_PARSER_OPTIONS

    TOKEN_RE = /\u27e6KD-(?<bundle>[a-z]+)-(?<unit>[1-9]\d*)-(?<node>[1-9]\d*)-(?<kind>[ocs])\u27e7/
    private_constant :TOKEN_RE

    class InvalidTranslation < Error

      attr_reader :unit_id

      def initialize(message, unit_id = nil)
        @unit_id = unit_id
        super(unit_id ? "Translation unit #{unit_id}: #{message}" : message)
      end

    end

    Node = Struct.new(:id, :kind, :element, :ancestors, keyword_init: true)
    Unit = Struct.new(:id, :type, :location, :source, :target, :nodes, keyword_init: true)

    class Bundle

      attr_reader :id, :document, :units

      def initialize(id, document, units)
        @id = id
        @document = document
        @units = units
        @sequence = 0
      end

      def to_h
        units.map do |unit|
          {id: unit.id, type: unit.type, location: unit.location, source: unit.source}
        end
      end

      def apply(translations)
        Translation.apply(document, self, translations)
      end
      alias apply_translations apply

      def next_unit_id
        @sequence += 1
        "#{id}-#{@sequence}"
      end

    end

    class SourceConverter < Converter::Kramdown

      def ial_for_element(_element)
        nil
      end

      def convert_p(element, opts)
        inner(element, opts)
      end

      def convert_a(element, opts)
        inner(element, opts)
      end

      alias convert_em convert_a
      alias convert_strong convert_a
      alias convert_codespan convert_a
      alias convert_math convert_a
      alias convert_img convert_a
      alias convert_footnote convert_a
      alias convert_abbreviation convert_a
      alias convert_html_element convert_a

      def convert_br(_element, _opts)
        ''
      end

      alias convert_raw convert_br
      alias convert_xml_comment convert_br
      alias convert_xml_pi convert_br

    end
    private_constant :SourceConverter

    class Extractor

      attr_reader :bundle

      def initialize(document, bundle_id)
        @document = document
        @bundle = Bundle.new(bundle_id, document, [])
      end

      def extract
        collect_units(@document.root)
        bundle
      end

      private

      def collect_units(element)
        if inline_container?(element)
          add_unit(element)
        elsif element.type == :li
          element.children.each {|child| collect_units(child) }
        else
          element.children.each {|child| collect_units(child) }
        end
      end

      def inline_container?(element)
        case element.type
        when :p, :header, :dt, :td, :th then true
        when :li then list_item_translatable?(element)
        else false
        end
      end

      def list_item_translatable?(element)
        first = element.children.first
        first&.type == :p && element.children[1].nil?
      end

      def add_unit(element)
        nodes = {}
        @node_sequence = 0
        source_element = element.dup
        source_element.children = protected_children(element, nodes)
        unit = Unit.new(
          id: bundle.next_unit_id,
          type: UNIT_TYPES.fetch(element.type),
          location: element.options[:location],
          source: render_inline(source_element, element),
          target: element,
          nodes: nodes
        )
        bundle.units << unit
      end

      def protected_children(element, nodes)
        element.children.map {|child| protect(child, nodes, []) }
      end

      def protect(element, nodes, ancestors)
        duplicate = duplicate_element(element)

        if wrapper?(element)
          node = register_node(element, :wrapper, nodes, ancestors)
          duplicate.children.concat(element.children.map {|child| protect(child, nodes, ancestors + [node.id]) })
          wrap_token(duplicate, node.id)
        elsif atom?(element)
          node = register_node(element, :atom, nodes, ancestors)
          duplicate.children = [token_element(node.id, 's')]
          duplicate
        else
          duplicate.children.concat(element.children.map {|child| protect(child, nodes, ancestors) })
          duplicate
        end
      end

      def duplicate_element(element)
        duplicate = element.dup
        duplicate.children = []
        duplicate.attr.replace(deep_duplicate(element.attr))
        duplicate.options.replace(deep_duplicate(element.options))
        duplicate
      end

      def deep_duplicate(value)
        case value
        when Hash then value.transform_values {|item| deep_duplicate(item) }
        when Array then value.map {|item| deep_duplicate(item) }
        else value
        end
      end

      def wrapper?(element)
        element.type == :a || element.type == :em || element.type == :strong ||
          (element.type == :html_element && element.options[:category] == :span && !element.children.empty?)
      end

      def atom?(element)
        !LITERAL_TYPES.include?(element.type) && !element.block?
      end

      def register_node(element, kind, nodes, ancestors)
        @node_sequence += 1
        unit_number = bundle.units.size + 1
        id = "#{bundle.id}-#{unit_number}-#{@node_sequence}"
        nodes[id] = Node.new(id: id, kind: kind, element: element, ancestors: ancestors)
        nodes[id]
      end

      def wrap_token(element, node_id)
        children = [token_element(node_id, 'o')]
        children.concat(element.children)
        children << token_element(node_id, 'c')
        element.children = children
        element
      end

      def token_element(node_id, kind)
        match = /\A(?<bundle>[a-z]+)-(?<unit>[1-9]\d*)-(?<node>[1-9]\d*)\z/.match(node_id)
        Element.new(:text, "\u27e6KD-#{match[:bundle]}-#{match[:unit]}-#{match[:node]}-#{kind}\u27e7")
      end

      def render_inline(element, original)
        target = original.type == :li ? element.children.first : element
        root = synthetic_root
        paragraph = Element.new(:p)
        paragraph.children = target.children
        root.children << paragraph
        output, = SourceConverter.convert(root, @document.options)
        output.sub(/\n\z/, '')
      end

      def synthetic_root
        options = @document.root.options.dup
        root = Element.new(:root, nil, nil, options)
        root.options[:abbrev_defs] = {}
        root.options[:abbrev_attr] = {}
        root
      end

    end
    private_constant :Extractor

    class Backfiller

      def initialize(document, bundle, translations)
        @document = document
        @bundle = bundle
        @translations = translations
      end

      def apply
        ensure_document!
        prepared = @bundle.units.map do |unit|
          next unless @translations.key?(unit.id)
          [unit, build_children(unit, @translations.fetch(unit.id).to_s)]
        end.compact

        prepared.each {|unit, children| replace(unit, children) }
        @document
      end

      private

      def ensure_document!
        return if @bundle.document.equal?(@document)
        raise InvalidTranslation, 'translation bundle belongs to another document'
      end

      def build_children(unit, translation)
        frame = [{children: [], ancestors: []}]
        occurrences = Hash.new(0)

        split_translation(translation, unit).each do |part|
          if part[:token]
            apply_token(unit, part[:match], frame, occurrences)
          elsif part[:text].strip.empty?
            frame.last[:children] << Element.new(:text, part[:text]) unless part[:text].empty?
          else
            parse_literal(unit, part[:text]).each {|child| frame.last[:children] << child }
          end
        end

        if frame.size > 1
          raise InvalidTranslation.new("missing closing placeholder for #{frame.last[:node_id]}", unit.id)
        end
        verify_required_nodes(unit, occurrences)
        frame.first[:children]
      end

      def split_translation(translation, unit)
        parts = []
        position = 0
        translation.scan(TOKEN_RE) do
          match = Regexp.last_match
          if match.begin(0) > position
            parts << {token: false, text: translation[position...match.begin(0)]}
          end
          parts << {token: true, match: match}
          position = match.end(0)
        end
        if position < translation.length
          parts << {token: false, text: translation[position..-1] || ''}
        end
        marker_count = translation.scan(/\u27e6KD/).length
        unless marker_count == parts.count {|part| part[:token] }
          raise InvalidTranslation.new('malformed placeholder', unit.id)
        end
        parts
      end

      def apply_token(unit, match, frame, occurrences)
        node_id = "#{match[:bundle]}-#{match[:unit]}-#{match[:node]}"
        node = unit.nodes[node_id]
        unless node
          raise InvalidTranslation.new("unknown placeholder \u27e6KD-#{match[:unit]}-#{match[:node]}", unit.id)
        end

        occurrences[node_id] += 1
        if node.kind == :wrapper
          case match[:kind]
          when 'o'
            validate_open(node, frame.last, unit)
            duplicate = duplicate_element(node.element)
            frame << {
              children: [],
              ancestors: node.ancestors + [node.id],
              node_id: node.id,
              element: duplicate
            }
          when 'c'
            validate_close(node, frame, unit, occurrences)
            current = frame.pop
            current[:element].children = current[:children]
            frame.last[:children] << current[:element]
          else
            raise InvalidTranslation.new("placeholder #{node.id} must use an opening and closing pair", unit.id)
          end
        else
          unless match[:kind] == 's'
            raise InvalidTranslation.new("placeholder #{node.id} must not be paired", unit.id)
          end
          validate_atom(node, frame.last, unit, occurrences)
          duplicate = duplicate_element(node.element)
          frame.last[:children] << duplicate
        end
      end

      def duplicate_element(element)
        duplicate = element.dup
        duplicate.children = []
        duplicate.attr.replace(deep_duplicate(element.attr))
        duplicate.options.replace(deep_duplicate(element.options))
        duplicate
      end

      def deep_duplicate(value)
        case value
        when Hash then value.transform_values {|item| deep_duplicate(item) }
        when Array then value.map {|item| deep_duplicate(item) }
        else value
        end
      end

      def validate_open(node, current, unit)
        unless current[:ancestors] == node.ancestors
          raise InvalidTranslation.new("placeholder #{node.id} is not allowed at this nesting", unit.id)
        end
      end

      def validate_close(node, frame, unit, occurrences)
        current = frame.last
        if frame.size == 1 || current[:node_id] != node.id
          raise InvalidTranslation.new("unexpected closing placeholder #{node.id}", unit.id)
        end
        validate_nesting(node, current[:ancestors][0...-1], unit)
        if occurrences[node.id] != 2
          raise InvalidTranslation.new("placeholder #{node.id} must appear exactly twice", unit.id)
        end
      end

      def validate_atom(node, current, unit, occurrences)
        validate_nesting(node, current[:ancestors], unit)
        if occurrences[node.id] != 1
          raise InvalidTranslation.new("placeholder #{node.id} may not be repeated", unit.id)
        end
      end

      def validate_nesting(node, current_ancestors, unit)
        unless current_ancestors[0...node.ancestors.length] == node.ancestors
          raise InvalidTranslation.new("placeholder #{node.id} crosses a protected boundary", unit.id)
        end
      end

      def verify_required_nodes(unit, occurrences)
        unit.nodes.each do |node_id, node|
          expected = node.kind == :wrapper ? 2 : 1
          next if occurrences[node_id] == expected
          raise InvalidTranslation.new("placeholder #{node_id} must appear #{expected} time(s)", unit.id)
        end
      end

      def parse_literal(unit, text)
        return [] if text.strip.empty?
        parsed = Kramdown::Document.new(text, @document.options.merge(LITERAL_PARSER_OPTIONS))
        children = parsed.root.children.reject {|child| child.type == :blank }
        unless children.one? && children.first.type == :p
          raise InvalidTranslation.new('translated text must be one inline paragraph', unit.id)
        end
        children.first.children.each do |child|
          unless literal_child?(child)
            raise InvalidTranslation.new("unprotected #{child.type} markup is not allowed", unit.id)
          end
        end
        leading = text[/\A\s+/].to_s
        trailing = text[/\s+\z/].to_s
        result = []
        result << Element.new(:text, leading) unless leading.empty?
        result.concat(children.first.children)
        result << Element.new(:text, trailing) unless trailing.empty?
        result
      end

      def literal_child?(element)
        LITERAL_TYPES.include?(element.type) && element.children.empty?
      end

      def replace(unit, children)
        if unit.target.type == :li
          unit.target.children.first.children = children
        else
          unit.target.children = children
        end
        if unit.target.type == :header || unit.target.type == :dt
          unit.target.options[:raw_text] = raw_text(children)
        end
      end

      def raw_text(children)
        children.map do |child|
          if child.type == :text
            child.value
          else
            raw_text(child.children)
          end
        end.join
      end

    end
    private_constant :Backfiller

    class << self

      def bundle_id
        @bundle_sequence = (@bundle_sequence || 0) + 1
        value = @bundle_sequence
        result = +''
        until value.zero?
          value, remainder = (value - 1).divmod(BUNDLE_ID_CHARS.length)
          result << BUNDLE_ID_CHARS[remainder]
        end
        result.reverse
      end

      def extract(document)
        Extractor.new(document, bundle_id).extract
      end

      def apply(document, bundle, translations)
        Backfiller.new(document, bundle, translations).apply
      end

    end

  end

  class Document

    def translation_units
      Translation.extract(self)
    end
    alias extract_translation_units translation_units

    def apply_translations(bundle, translations)
      Translation.apply(self, bundle, translations)
    end

  end

end
