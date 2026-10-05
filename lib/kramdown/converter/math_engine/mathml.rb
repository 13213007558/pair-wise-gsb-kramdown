# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++

require 'strscan'

module Kramdown::Converter::MathEngine

  # Converts a documented TeX subset to Presentation MathML without a browser or external TeX.
  module Mathml

    AVAILABLE = true

    GREEK_SYMBOLS = {
      alpha: 'α', beta: 'β', gamma: 'γ', delta: 'δ', epsilon: 'ϵ', varepsilon: 'ε',
      zeta: 'ζ', eta: 'η', theta: 'θ', vartheta: 'ϑ', iota: 'ι', kappa: 'κ',
      lambda: 'λ', mu: 'μ', nu: 'ν', xi: 'ξ', omicron: 'ο', pi: 'π', varpi: 'ϖ',
      rho: 'ρ', varrho: 'ϱ', sigma: 'σ', varsigma: 'ς', tau: 'τ', upsilon: 'υ',
      phi: 'ϕ', varphi: 'φ', chi: 'χ', psi: 'ψ', omega: 'ω',
      Gamma: 'Γ', Delta: 'Δ', Theta: 'Θ', Lambda: 'Λ', Xi: 'Ξ', Pi: 'Π',
      Sigma: 'Σ', Upsilon: 'Υ', Phi: 'Φ', Psi: 'Ψ', Omega: 'Ω'
    }.freeze

    FUNCTIONS = %i[lim liminf limsup sup inf max min log ln exp sin cos tan cot sec csc
                   arcsin arccos arctan sinh cosh tanh det dim ker hom gcd Pr deg].freeze

    LARGE_OPERATORS = %i[sum prod coprod int iint iiint oint bigcap bigcup bigvee
                         bigwedge].freeze

    SYMBOLS = {
      pm: '±', mp: '∓', times: '×', div: '÷', cdot: '⋅', ast: '∗', star: '⋆',
      circ: '∘', bullet: '∙', cap: '∩', cup: '∪', vee: '∨', wedge: '∧',
      setminus: '∖', wr: '≀', leq: '≤', le: '≤', geq: '≥', ge: '≥',
      neq: '≠', ne: '≠', sim: '∼', simeq: '≃', approx: '≈', equiv: '≡',
      propto: '∝', subset: '⊂', supset: '⊃', subseteq: '⊆', supseteq: '⊇',
      in: '∈', ni: '∋', notin: '∉', exists: '∃', nexists: '∄', forall: '∀',
      emptyset: '∅', varnothing: '∅', infty: '∞', partial: '∂', nabla: '∇',
      angle: '∠', perp: '⊥', parallel: '∥', mid: '∣', cdots: '⋯', ldots: '…',
      dots: '…', ell: 'ℓ', Re: 'ℜ', Im: 'ℑ', aleph: 'ℵ', hbar: 'ℏ', wp: '℘',
      to: '→', rightarrow: '→', Rightarrow: '⇒', leftarrow: '←', Leftarrow: '⇐',
      leftrightarrow: '↔', Leftrightarrow: '⇔', mapsto: '↦', uparrow: '↑',
      downarrow: '↓', Uparrow: '⇑', Downarrow: '⇓', lbrack: '[', rbrack: ']',
      lbrace: '{', rbrace: '}', langle: '⟨', rangle: '⟩', lceil: '⌈',
      rceil: '⌉', lfloor: '⌊', rfloor: '⌋',
      sum: '∑', prod: '∏', coprod: '∐', int: '∫', iint: '∬', iiint: '∭',
      oint: '∮', bigcap: '⋂', bigcup: '⋃', bigvee: '⋁', bigwedge: '⋀'
    }.merge(GREEK_SYMBOLS).freeze

    OPERATOR_CHARACTERS = {
      '+' => '+', '-' => '−', '*' => '∗', '/' => '/', '=' => '=', '<' => '<',
      '>' => '>', '|' => '|', ':' => ':', '!' => '!', '?' => '?',
      '(' => '(', ')' => ')', '[' => '[', ']' => ']'
    }.freeze

    FENCE_COMMANDS = {
      '(' => '(', ')' => ')', '[' => '[', ']' => ']', '|' => '|',
      '{' => '{', '}' => '}',
      '/' => '/', '.' => '', 'lbrace' => '{', 'rbrace' => '}',
      'langle' => '⟨', 'rangle' => '⟩', 'lceil' => '⌈', 'rceil' => '⌉',
      'lfloor' => '⌊', 'rfloor' => '⌋', 'backslash' => '\\'
    }.freeze

    MATRIX_ENVIRONMENTS = {
      'matrix' => nil, 'pmatrix' => ['(', ')'], 'bmatrix' => ['[', ']'],
      'Bmatrix' => ['{', '}'], 'vmatrix' => ['|', '|'],
      'Vmatrix' => ['‖', '‖'], 'smallmatrix' => nil
    }.freeze

    SPACES = {
      ',' => '0.167em', ':' => '0.222em', ';' => '0.278em', '!' => '-0.278em',
      ' ' => '0.25em', quad: '1em', qquad: '2em'
    }.freeze

    STYLES = %i[mathrm mathit mathbf mathsf mathtt mathcal mathfrak mathbb mathscr].freeze
    FRACTION_COMMANDS = %i[frac dfrac tfrac].freeze
    MACRO_COMMANDS = %i[newcommand renewcommand providecommand def let].freeze

    Location = Struct.new(:offset, :line, :column)
    Node = Struct.new(:type, :value, :children, :attributes, :location) do
      def initialize(type, value: nil, children: [], attributes: {}, location: nil)
        super(type, value, children, attributes, location)
      end
    end

    def self.call(converter, el, opts)
      math = render(Parser.new(el.value).parse, el.options[:category] == :block)
      if el.attr.empty?
        math
      elsif el.options[:category] == :block
        converter.format_as_block_html('div', el.attr, math, opts[:indent])
      else
        converter.format_as_span_html('span', el.attr, math)
      end
    end

    def self.parse(source)
      Parser.new(source).parse
    end

    def self.render(tree, display = false)
      Emitter.new(display).render(tree)
    end

    class Parser
      attr_reader :source

      def initialize(source)
        @source = source
        @scanner = StringScanner.new(source)
        @fence_depth = 0
        @group_depth = 0
        @environment_stack = []
      end

      def parse
        Node.new(:seq, children: parse_sequence)
      end

      private

      def parse_sequence(terminators = nil)
        nodes = []
        skip_whitespace
        until @scanner.eos? || terminator?(terminators)
          if terminators && terminators[:right] && @scanner.match?(/\\right(?![A-Za-z])/)
            break
          end

          case @scanner.peek(1)
          when '&'
            nodes << parse_ampersand
          when '\\'
            if @group_depth.zero? && @environment_stack.any? && row_break_here?
              @scanner.getch
              @scanner.getch
              @scanner.scan(/\[[^\]]*\]/)
              nodes << :row_break
              break
            end
            command = parse_command
            nodes.concat(command.is_a?(Array) ? command : [command])
          when '_', '^'
            result = parse_script(nodes.pop)
            result.is_a?(Array) ? nodes.concat(result) : nodes.push(result)
          else
            nodes << parse_primary
          end
          skip_whitespace
        end
        nodes
      end

      def parse_ampersand
        if @environment_stack.any? && @group_depth.zero?
          @scanner.getch
          :column_break
        else
          unexpected_character('unexpected alignment character &', consume: true)
        end
      end

      def row_break_here?
        @scanner.peek(2) == (('\\' * 2))
      end

      def terminator?(terminators)
        return false unless terminators

        close_char = terminators[:close_char] || (terminators[:close] == true ? '}' : nil)
        return true if close_char && @scanner.peek(1) == close_char
        return false unless terminators[:end].is_a?(String) && @group_depth.zero?
        return false if row_break_here?

        end_source = '\end{' + terminators[:end] + '}'
        @environment_stack.last == terminators[:end] &&
          @scanner.peek(end_source.length) == end_source
      end

      def skip_whitespace
        while @scanner.scan(/[ \t\r\n\f]+|%[^\n]*(?:\n|\z)/)
        end
      end

      def current_location(byte_position = @scanner.pos)
        before = @source.byteslice(0, byte_position)
        before = before.to_s.force_encoding(@source.encoding)
        line = before.count("\n") + 1
        last_newline = before.rindex("\n")
        column = last_newline ? before[(last_newline + 1)..-1].length + 1 : before.length + 1
        Location.new(before.length, line, column)
      end

      def source_from(start_byte)
        @source.byteslice(start_byte, @scanner.pos - start_byte).to_s
      end

      def make_error(message, start_byte = @scanner.pos, children: [])
        Node.new(:error, value: message, children: children, location: current_location(start_byte))
      end

      def unexpected_character(message, consume: true)
        start = @scanner.pos
        character = @scanner.getch
        character = '' if consume == false || character.nil?
        make_error("#{message}: #{character.inspect} at #{format_location(start)}", start)
      end

      def parse_script(base)
        marker_start = @scanner.pos
        marker = @scanner.getch
        skip_whitespace

        if base.nil? || base == :column_break || base == :row_break
          return [make_error("missing base for script #{marker.inspect} at #{format_location(marker_start)}", marker_start),
                  parse_script_argument].flatten
        end

        argument = parse_script_argument
        apply_script(base, marker, argument, marker_start)
      end

      def parse_script_argument
        skip_whitespace
        if @scanner.eos? || @scanner.match?(/[&_^}]/) ||
            (@environment_stack.any? && @group_depth.zero? && row_break_here?) ||
            @scanner.match?(/\\right(?![A-Za-z])/) ||
            @scanner.match?(/\\end\{/)
          make_error("missing script argument at #{format_location(@scanner.pos)}")
        elsif @scanner.peek(1) == '{'
          parse_group
        elsif @scanner.peek(1) == '\\'
          parse_command
        else
          parse_primary
        end
      end

      def apply_script(base, marker, argument, position)
        wanted = marker == '_' ? :sub : :sup
        existing = base.type == :sub ? :sub : (base.type == :sup ? :sup : (:subsup if base.type == :subsup))

        if existing && existing != (wanted == :sub ? :sup : :sub)
          error = make_error("double #{wanted == :sub ? 'sub' : 'super'}script at #{format_location(position)}", position)
          return [base, error, argument]
        end

        if base.type == :sub && wanted == :sup
          Node.new(:subsup, children: [base.children[0], base.children[1], argument])
        elsif base.type == :sup && wanted == :sub
          Node.new(:subsup, children: [base.children[0], argument, base.children[1]])
        else
          Node.new(wanted, children: [base, argument])
        end
      end

      def format_location(position)
        location = current_location(position)
        "line #{location.line}, column #{location.column} (offset #{location.offset})"
      end

      def parse_group
        start = @scanner.pos
        @scanner.getch
        @group_depth += 1
        children = parse_sequence(close: true)
        @group_depth -= 1
        if @scanner.peek(1) == '}'
          @scanner.getch
          Node.new(:group, children: children, location: current_location(start))
        else
          make_error('unclosed group: missing }', start, children: children)
        end
      end

      def parse_primary
        skip_whitespace
        start = @scanner.pos
        character = @scanner.peek(1)

        if character == '{'
          parse_group
        elsif character == '}'
          unexpected_character('unexpected closing delimiter }')
        elsif OPERATOR_CHARACTERS.key?(character)
          @scanner.getch
          attributes = ['(', ')', '[', ']', '|'].include?(character) ? {fence: 'true'} : {}
          Node.new(:operator, value: OPERATOR_CHARACTERS[character], attributes: attributes,
                    location: current_location(start))
        elsif (number = @scanner.scan(/\d+(?:\.\d+)?/))
          Node.new(:number, value: number, location: current_location(start))
        elsif (letter = @scanner.scan(/\p{L}/))
          Node.new(:identifier, value: letter, location: current_location(start))
        elsif character == ',' || character == ';'
          @scanner.getch
          Node.new(:operator, value: character, location: current_location(start))
        elsif character == "'"
          @scanner.getch
          Node.new(:operator, value: '′', location: current_location(start))
        elsif character == '~'
          @scanner.getch
          Node.new(:space, attributes: {width: '0.25em'}, location: current_location(start))
        elsif character == '.'
          @scanner.getch
          Node.new(:operator, value: '.', location: current_location(start))
        elsif @scanner.eos?
          make_error('unexpected end of formula', start)
        else
          unexpected_character('unsupported character')
        end
      end

      def parse_command
        start = @scanner.pos
        @scanner.getch
        name = @scanner.scan(/[A-Za-z]+/) || @scanner.getch.to_s
        command = name.to_sym

        if MACRO_COMMANDS.include?(command)
          return unsupported_command(start, name, 'macros are not executed')
        elsif command == :begin
          return parse_begin(start)
        elsif command == :end
          return parse_end(start)
        elsif command == :left
          return parse_left(start)
        elsif command == :right
          return unexpected_command(start, name, 'unmatched \right')
        elsif FRACTION_COMMANDS.include?(command)
          return parse_fraction(start, command)
        elsif command == :sqrt
          return parse_sqrt(start)
        elsif STYLES.include?(command)
          return parse_style(start, command)
        end

        skip_whitespace
        if SPACES.key?(name)
          Node.new(:space, attributes: {width: SPACES[name]}, location: current_location(start))
        elsif (escaped = escape_command(name))
          Node.new(:text, value: escaped, location: current_location(start))
        elsif (value = SYMBOLS[command])
          symbol_node(command, value, start)
        elsif (value = FENCE_COMMANDS[name])
          Node.new(:operator, value: value, attributes: {fence: true}, location: current_location(start))
        else
          unsupported_command(start, name)
        end
      end

      def escape_command(name)
        case name
        when '%', '#', '&', '_', '{', '}', '$' then name
        when ',' then ' ' # rubocop:disable Layout/EmptyLineAfterGuardClause
        end
      end

      def symbol_node(command, value, start)
        type = if FUNCTIONS.include?(command)
                 :function
               elsif LARGE_OPERATORS.include?(command)
                 :largeop
               elsif GREEK_SYMBOLS.key?(command) || value.match?(/\A\p{L}+\z/u)
                 :identifier
               else
                 :operator
               end
        Node.new(type, value: value, location: current_location(start))
      end

      def unsupported_command(start, name, reason = 'unsupported command')
        source = source_from(start)
        make_error("#{reason}: #{source} at #{format_location(start)}; command was not removed", start)
      end

      def unexpected_command(start, name, message)
        source = source_from(start)
        make_error("#{message}: #{source} at #{format_location(start)}", start)
      end

      def parse_style(start, command)
        argument = parse_structure_argument
        Node.new(:style, value: command.to_s, children: [argument], location: current_location(start))
      end

      def parse_fraction(start, command)
        numerator = parse_structure_argument
        denominator = parse_structure_argument
        Node.new(:fraction, value: command.to_s, children: [numerator, denominator],
                 location: current_location(start))
      end

      def parse_sqrt(start)
        degree = nil
        skip_whitespace
        if @scanner.peek(1) == '['
          bracket_start = @scanner.pos
          @scanner.getch
          degree_children = parse_sequence(close_char: ']')
          if @scanner.peek(1) == ']'
            @scanner.getch
            degree = Node.new(:group, children: degree_children)
          else
            degree = make_error('unclosed radical index: missing ]', bracket_start,
                                children: degree_children)
          end
        end

        radicand = parse_structure_argument
        if degree
          Node.new(:root, children: [radicand, degree], location: current_location(start))
        else
          Node.new(:sqrt, children: [radicand], location: current_location(start))
        end
      end

      def parse_begin(start)
        skip_whitespace
        unless @scanner.scan(/\{([A-Za-z*]+)\}/)
          return make_error('malformed begin environment at ' + format_location(start), start)
        end

        name = @scanner[1]
        delimiters = MATRIX_ENVIRONMENTS[name]
        unless MATRIX_ENVIRONMENTS.key?(name)
          return unsupported_command(start, 'begin{' + name + '}', 'unsupported matrix environment')
        end

        parse_matrix(start, name, delimiters)
      end

      def parse_matrix(start, name, delimiters)
        @environment_stack.push(name)
        chunks = []
        until @scanner.eos? || at_matrix_end?(name)
          sequence = parse_sequence(end: name)
          chunks.concat(sequence)
          if sequence.last == :row_break
            skip_whitespace
          else
            break
          end
        end
        @environment_stack.pop

        end_source = '\\' + 'end{' + name + '}'
        end_pattern = Regexp.new(Regexp.escape(end_source))
        if @scanner.match?(end_pattern)
          @scanner.scan(end_pattern)
        else
          chunks << make_error('missing end{' + name + '} at ' + format_location(@scanner.pos))
        end

        rows = []
        cells = [[]]
        chunks.each do |chunk|
          if chunk == :column_break
            cells << []
          elsif chunk == :row_break
            rows << cells
            cells = [[]]
          else
            cells.last << chunk
          end
        end
        rows << cells

        row_nodes = rows.map do |cells|
          cell_nodes = cells.map {|children| Node.new(:matrix_cell, children: children) }
          Node.new(:matrix_row, children: cell_nodes)
        end
        attributes = delimiters ? {open: delimiters[0], close: delimiters[1]} : {}
        Node.new(:matrix, children: row_nodes, attributes: attributes, location: current_location(start))
      end

      def at_matrix_end?(name)
        @scanner.match?(Regexp.new(Regexp.escape('\end{' + name + '}')))
      end

      def parse_end(start)
        skip_whitespace
        unless @scanner.scan(/\{([A-Za-z*]+)\}/)
          return make_error('malformed end environment at ' + format_location(start), start)
        end

        name = @scanner[1]
        if @environment_stack.last == name
          make_error('unexpected end{' + name + '} at ' + format_location(start), start)
        else
          unsupported_command(start, 'end{' + name + '}', 'unmatched environment end')
        end
      end

      def parse_left(start)
        skip_whitespace
        opening = read_fence
        unless opening
          return make_error('missing left delimiter at ' + format_location(@scanner.pos), start)
        end

        @fence_depth += 1
        children = parse_sequence(right: true)
        @fence_depth -= 1

        if @scanner.scan(/\\right(?![A-Za-z])/)
          skip_whitespace
          closing = read_fence
          if closing.nil?
            children << make_error('missing right delimiter at ' + format_location(@scanner.pos))
          end
        else
          closing = nil
          children << make_error('missing right delimiter at ' + format_location(@scanner.pos))
        end

        attributes = {open: opening, close: closing.to_s}
        Node.new(:fenced, children: children, attributes: attributes, location: current_location(start))
      end

      def read_fence
        literal = FENCE_COMMANDS[@scanner.peek(1)]
        if literal && @scanner.peek(1) != '\\'
          @scanner.getch
          literal
        elsif @scanner.peek(1) == '\\'
          command_start = @scanner.pos
          @scanner.getch
          name = @scanner.scan(/[A-Za-z]+/) || @scanner.getch.to_s
          value = FENCE_COMMANDS[name]
          return value unless value.nil?

          @scanner.pos = command_start
          nil
        else
          character = @scanner.getch
          value = FENCE_COMMANDS[character]
          value
        end
      end

      def parse_structure_argument
        skip_whitespace
        if @scanner.eos? || @scanner.peek(1) == '}' || @scanner.peek(1) == '&' ||
            @scanner.match?(/[_^]/) ||
            @scanner.match?(/\\right(?![A-Za-z])/) || @scanner.match?(/\\end\{/) ||
            (@environment_stack.any? && @group_depth.zero? && row_break_here?)
          make_error("missing argument at #{format_location(@scanner.pos)}")
        elsif @scanner.peek(1) == '{'
          parse_group
        elsif @scanner.peek(1) == '\\'
          parse_command
        else
          parse_primary
        end
      end
    end

    class Emitter
      def initialize(display = false)
        @display = display
      end

      def render(tree)
        display = @display ? ' display="block"' : ''
        '<math xmlns="http://www.w3.org/1998/Math/MathML"' + display + '>' +
          render_node(tree) + '</math>'
      end

      private

      def render_node(node)
        case node.type
        when :seq then render_children(node)
        when :group then tag(:mrow, node.children)
        when :identifier then simple_tag(:mi, node.value)
        when :number then simple_tag(:mn, node.value)
        when :text then simple_tag(:mtext, node.value)
        when :function then simple_tag(:mi, node.value, mathvariant: 'normal')
        when :operator
          attributes = node.attributes[:fence] ? {fence: 'true'} : {}
          simple_tag(:mo, node.value, attributes)
        when :largeop then simple_tag(:mo, node.value, movablelimits: 'false')
        when :space then empty_tag(:mspace, width: node.attributes[:width])
        when :style then tag(:mstyle, node.children, fontstyle(node.value))
        when :fraction then tag(:mfrac, node.children)
        when :sqrt then tag(:msqrt, node.children)
        when :root then tag(:mroot, node.children)
        when :sub then tag(:msub, node.children)
        when :sup then tag(:msup, node.children)
        when :subsup then tag(:msubsup, node.children)
        when :fenced then render_fenced(node)
        when :matrix then render_matrix(node)
        when :matrix_row then tag(:mtr, node.children)
        when :matrix_cell then tag(:mtd, node.children)
        when :error then render_error(node)
        else render_error(Node.new(:error, value: "unknown AST node #{node.type}", children: [node]))
        end
      end

      def render_children(node)
        node.children.map {|child| render_node(child) }.join
      end

      def tag(name, children, attributes = {})
        opening = '<' + name.to_s + html_attributes(attributes) + '>'
        rendered = children.is_a?(Array) ? children.map {|child| render_node(child) }.join : children.to_s
        opening + rendered + '</' + name.to_s + '>'
      end

      def simple_tag(name, value, attributes = {})
        '<' + name.to_s + html_attributes(attributes) + '>' + escape_html(value.to_s) + '</' + name.to_s + '>'
      end

      def empty_tag(name, attributes = {})
        '<' + name.to_s + html_attributes(attributes) + '/>'
      end

      def render_fenced(node)
        '<mrow>' + fence_mo(node.attributes[:open], 'opening') + render_children(node) +
          fence_mo(node.attributes[:close], 'closing') + '</mrow>'
      end

      def fence_mo(value, form)
        return simple_tag(:mo, value, fence: 'true', form: form) unless value.to_s.empty?

        simple_tag(:mo, '', fence: 'true', form: form)
      end

      def render_matrix(node)
        table = tag(:mtable, node.children)
        return table unless node.attributes[:open]

        '<mrow>' + fence_mo(node.attributes[:open], 'opening') + table +
          fence_mo(node.attributes[:close], 'closing') + '</mrow>'
      end

      def render_error(node)
        location = node.location
        position = if location
                     "line #{location.line}, column #{location.column} (offset #{location.offset})"
                   else
                     'unknown position'
                   end
        text = "Error at #{position}: #{node.value}"
        children = [Node.new(:text, value: text)] + node.children
        tag(:merror, children)
      end

      def fontstyle(style)
        case style
        when 'mathrm' then {mathvariant: 'normal'}
        when 'mathit' then {mathvariant: 'italic'}
        when 'mathbf' then {mathvariant: 'bold'}
        when 'mathsf' then {mathvariant: 'sans-serif'}
        when 'mathtt' then {mathvariant: 'monospace'}
        when 'mathcal' then {mathvariant: 'script'}
        when 'mathfrak' then {mathvariant: 'fraktur'}
        when 'mathbb' then {mathvariant: 'double-struck'}
        when 'mathscr' then {mathvariant: 'script'}
        else {}
        end
      end

      def html_attributes(attributes)
        attributes.map do |key, value|
          " #{key}=\"#{escape_html(value.to_s, :attribute)}\""
        end.join
      end

      def escape_html(value, type = :text)
        map = {
          '&' => '&amp;', '<' => '&lt;', '>' => '&gt;', '"' => '&quot;'
        }
        value.gsub(/[&<>"]/) {|character| type == :text && character == '"' ? character : map[character] }
      end
    end

  end
end
