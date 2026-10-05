# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++

require 'cgi'

module Kramdown::Converter::MathEngine

  # Pure Ruby TeX-to-Presentation-MathML engine. It deliberately supports only a small, explicit
  # subset and never expands macros or invokes an external TeX implementation.
  module MathML

    AVAILABLE = true

    ParseError = Class.new(::Kramdown::Error) do
      attr_reader :source, :position

      def initialize(message, source, position)
        @source = source
        @position = position
        line = source[0, position].count("\n") + 1
        column = position - (source.rindex("\n", position - 1) || -1)
        super("#{message} at line #{line}, column #{column} (offset #{position})")
      end
    end

    Node = Struct.new(:type, :value, :children, :attrs, :position, keyword_init: true) do
      def initialize(type:, value: nil, children: [], attrs: {}, position: nil)
        super
      end
    end

    SYMBOLS = {
      'alpha' => ['α'], 'beta' => ['β'], 'gamma' => ['γ'], 'delta' => ['δ'],
      'epsilon' => ['ε'], 'varepsilon' => ['ε'], 'zeta' => ['ζ'], 'eta' => ['η'],
      'theta' => ['θ'], 'vartheta' => ['ϑ'], 'iota' => ['ι'], 'kappa' => ['κ'],
      'lambda' => ['λ'], 'mu' => ['μ'], 'nu' => ['ν'], 'xi' => ['ξ'],
      'pi' => ['π'], 'varpi' => ['ϖ'], 'rho' => ['ρ'], 'varrho' => ['ϱ'],
      'sigma' => ['σ'], 'varsigma' => ['ς'], 'tau' => ['τ'], 'upsilon' => ['υ'],
      'phi' => ['φ'], 'varphi' => ['ϕ'], 'chi' => ['χ'], 'psi' => ['ψ'],
      'omega' => ['ω'], 'Gamma' => ['Γ'], 'Delta' => ['Δ'], 'Theta' => ['Θ'],
      'Lambda' => ['Λ'], 'Xi' => ['Ξ'], 'Upsilon' => ['Υ'], 'Phi' => ['Φ'],
      'Psi' => ['Ψ'], 'Omega' => ['Ω'],
      'cdot' => ['⋅'], 'cdots' => ['⋯'], 'ldots' => ['…'], 'dots' => ['…'],
      'vdots' => ['⋮'], 'ddots' => ['⋱'], 'times' => ['×'], 'div' => ['÷'],
      'pm' => ['±'], 'mp' => ['∓'], 'ast' => ['∗'], 'star' => ['⋆'],
      'circ' => ['∘'], 'bullet' => ['•'], 'cap' => ['∩'], 'cup' => ['∪'],
      'setminus' => ['∖'], 'smallsetminus' => ['∖'], 'wedge' => ['∧'],
      'vee' => ['∨'], 'otimes' => ['⊗'], 'oplus' => ['⊕'], 'odot' => ['⊙'],
      'leq' => ['≤'], 'le' => ['≤'], 'geq' => ['≥'], 'ge' => ['≥'],
      'eq' => ['='], 'neq' => ['≠'], 'ne' => ['≠'], 'approx' => ['≈'],
      'equiv' => ['≡'],
      'sim' => ['∼'], 'simeq' => ['≃'], 'cong' => ['≅'], 'propto' => ['∝'],
      'll' => ['≪'], 'gg' => ['≫'], 'subset' => ['⊂'], 'subseteq' => ['⊆'],
      'supset' => ['⊃'], 'supseteq' => ['⊇'], 'in' => ['∈'], 'notin' => ['∉'],
      'ni' => ['∋'], 'perp' => ['⊥'], 'parallel' => ['∥'], 'mid' => ['|'],
      'colon' => [':'], 'rightarrow' => ['→'], 'to' => ['→'],
      'leftarrow' => ['←'], 'gets' => ['←'], 'Rightarrow' => ['⇒'],
      'implies' => ['⇒'], 'Leftarrow' => ['⇐'], 'iff' => ['⇔'],
      'leftrightarrow' => ['↔'], 'mapsto' => ['↦'], 'uparrow' => ['↑'],
      'downarrow' => ['↓'], 'Uparrow' => ['⇑'], 'Downarrow' => ['⇓'],
      'infty' => ['∞'], 'partial' => ['∂'], 'nabla' => ['∇'], 'forall' => ['∀'],
      'exists' => ['∃'], 'emptyset' => ['∅'], 'varnothing' => ['∅'],
      'angle' => ['∠'], 'degree' => ['°'], 'aleph' => ['ℵ'], 'hbar' => ['ℏ'],
      'ell' => ['ℓ'], 'Re' => ['ℜ'], 'Im' => ['ℑ'], 'wp' => ['℘'],
      'prime' => ['′'],
      'sum' => ['∑', operator: true, largeop: true, limits: true],
      'prod' => ['∏', operator: true, largeop: true, limits: true],
      'coprod' => ['∐', operator: true, largeop: true, limits: true],
      'int' => ['∫', operator: true, largeop: true, integral: true],
      'iint' => ['∬', operator: true, largeop: true, integral: true],
      'iiint' => ['∭', operator: true, largeop: true, integral: true],
      'oint' => ['∮', operator: true, largeop: true, integral: true],
      'bigcup' => ['⋃', operator: true, largeop: true, limits: true],
      'bigcap' => ['⋂', operator: true, largeop: true, limits: true],
      'bigvee' => ['⋁', operator: true, largeop: true, limits: true],
      'bigwedge' => ['⋀', operator: true, largeop: true, limits: true],
      'Pi' => ['Π', operator: true, largeop: true, limits: true],
      'Sigma' => ['Σ', operator: true, largeop: true, limits: true],
      'lim' => ['lim', function: true, limits: true],
      'max' => ['max', function: true, limits: true],
      'min' => ['min', function: true, limits: true],
      'sup' => ['sup', function: true, limits: true],
      'inf' => ['inf', function: true, limits: true],
      'log' => ['log', function: true], 'ln' => ['ln', function: true],
      'lg' => ['lg', function: true], 'exp' => ['exp', function: true],
      'sin' => ['sin', function: true], 'cos' => ['cos', function: true],
      'tan' => ['tan', function: true], 'cot' => ['cot', function: true],
      'sec' => ['sec', function: true], 'csc' => ['csc', function: true],
      'sinh' => ['sinh', function: true], 'cosh' => ['cosh', function: true],
      'tanh' => ['tanh', function: true], 'coth' => ['coth', function: true],
      'arcsin' => ['arcsin', function: true],
      'arccos' => ['arccos', function: true],
      'arctan' => ['arctan', function: true],
      'det' => ['det', function: true], 'dim' => ['dim', function: true],
      'gcd' => ['gcd', function: true], 'ker' => ['ker', function: true],
      'deg' => ['deg', function: true], 'arg' => ['arg', function: true],
      'hom' => ['hom', function: true],
      'mathbb' => ['', variant: 'double-struck'],
      'mathbf' => ['', variant: 'bold'], 'mathit' => ['', variant: 'italic'],
      'mathrm' => ['', variant: 'normal'], 'mathsf' => ['', variant: 'sans-serif'],
      'mathtt' => ['', variant: 'monospace'], 'mathcal' => ['', variant: 'script'],
      'mathfrak' => ['', variant: 'fraktur'],
    }.freeze

    FUNCTIONS = %w[
      lim max min sup inf log lg exp sin cos tan cot sec csc sinh cosh tanh coth
      arcsin arccos arctan det dim gcd ker deg arg hom
    ].freeze

    TEXT_VARIANTS = {
      'textbf' => 'bold', 'textit' => 'italic', 'textrm' => 'normal',
      'textsf' => 'sans-serif', 'texttt' => 'monospace',
    }.freeze

    MATRICES = {
      'matrix' => nil, 'pmatrix' => ['(', ')'], 'bmatrix' => ['[', ']'],
      'Bmatrix' => ['{', '}'], 'vmatrix' => ['|', '|'],
      'Vmatrix' => ['‖', '‖'],
    }.freeze

    DELIMITERS = {
      '(' => '(', ')' => ')', '[' => '[', ']' => ']', '|' => '|',
      '/' => '/', '\\' => '\\', 'lbrace' => '{', 'rbrace' => '}',
      'langle' => '⟨', 'rangle' => '⟩', 'lfloor' => '⌊',
      'rfloor' => '⌋', 'lceil' => '⌈', 'rceil' => '⌉',
      'lgroup' => '⦗', 'rgroup' => '⦘', 'updownarrow' => '↕',
      'Updownarrow' => '⇕', '.' => "\u2063"
    }.freeze

    LITERALS = {
      ',' => ',', ';' => ';', ':' => ':', '!' => '!', '?' => '?',
      '+' => '+', '-' => '−', '*' => '*', '/' => '/', '=' => '=',
      '<' => '<', '>' => '>', '|' => '|', '.' => '.', '{' => '{',
      '}' => '}', '\\' => '\\',
    }.freeze

    ESCAPED_TEXT = {
      '{' => '{', '}' => '}', '\\' => '\\', '$' => '$', '&' => '&',
      '#' => '#', '%' => '%', '_' => '_', '^' => '^', '~' => ' ',
      ' ' => ' ',
    }.freeze

    SPACES = {
      ',' => '0.1667em', 'thinspace' => '0.1667em', '!' => '-0.1667em',
      ':' => '0.2222em', ';' => '0.2778em', ' ' => '0.25em',
      'quad' => '1em', 'qquad' => '2em', 'enspace' => '0.5em',
    }.freeze

    BIG_SIZES = {
      'big' => '1.2em', 'bigl' => '1.2em', 'bigr' => '1.2em', 'bigm' => '1.2em',
      'Big' => '1.623em', 'Bigl' => '1.623em', 'Bigr' => '1.623em',
      'Bigm' => '1.623em', 'bigg' => '2.047em', 'biggl' => '2.047em',
      'biggr' => '2.047em', 'biggm' => '2.047em', 'Bigg' => '2.47em',
      'Biggl' => '2.47em', 'Biggr' => '2.47em', 'Biggm' => '2.47em',
    }.freeze

    MACRO_COMMANDS = %w[
      def newcommand renewcommand providecommand let gdef xdef edef futurelet
    ].map {|name| [name, true] }.to_h.freeze

    IDENTIFIER_SYMBOLS = %w[
      alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta iota kappa
      lambda mu nu xi omicron pi varpi rho varrho sigma varsigma tau upsilon phi
      varphi chi psi omega Gamma Delta Theta Lambda Xi Upsilon Phi Psi Omega
    ].freeze

    def self.call(converter, el, opts)
      display = el.options[:category] == :block
      mathml = generate(el.value, display: display,
                                 errors: converter.options[:math_engine_opts][:errors])
      if el.attr.empty?
        mathml + (display ? "\n" : '')
      elsif display
        converter.format_as_block_html('div', el.attr, mathml, opts[:indent])
      else
        converter.format_as_span_html('span', el.attr, mathml)
      end
    end

    def self.generate(source, display: false, errors: :merror)
      root = parse(source)
      Renderer.new(display: display).render(root)
    rescue ParseError => error
      raise if errors == :raise

      Renderer.error_mathml(error, display)
    end

    def self.parse(source)
      TeXParser.new(source).parse!
    end

    class TeXParser
      def initialize(source)
        @source = source.to_s.dup.force_encoding(Encoding::UTF_8)
        @chars = @source.chars.to_a
        @pos = 0
        @depth = 0
      end

      def parse!
        nodes = parse_sequence
        skip_spaces
        unless at_end?
          char = current
          error(char == '}' ? 'Unexpected closing group' : "Unexpected character #{char.inspect}")
        end
        if nodes.empty?
          error('Empty math expression')
        end
        Node.new(type: :root, children: nodes, position: 0)
      end

      private

      def parse_sequence(stop = nil)
        nodes = []
        skip_spaces
        until boundary?(stop)
          node = parse_element(stop)
          nodes << node if node
          skip_spaces
        end
        nodes
      end

      def boundary?(stop)
        return true if at_end?
        return false unless stop
        return true if stop == :group && current == '}'
        return true if stop == :radical_index && current == ']'
        return true if matrix_boundary?(stop)
        return true if delimiter_boundary?(stop)

        false
      end

      def matrix_boundary?(stop)
        stop.is_a?(Hash) && stop[:matrix] && @depth == stop[:depth] &&
          ((current == '&' && stop[:kind] == :cell) ||
           (current == '\\' && %w[\\ end].include?(peek_command_name)))
      end

      def parse_element(stop = nil)
        char = current
        case char
        when '{' then apply_scripts(parse_group)
        when '}' then error('Unexpected closing group')
        when '&'
          stop.is_a?(Hash) && stop[:matrix] ? nil : error('Alignment separator outside matrix')
        when '^', '_' then error("#{char.inspect} without a base")
        when '~'
          Node.new(type: :space, value: '0.25em', position: @pos)
        when "'" then parse_prime
        when '%' then error('TeX comments are not supported')
        when '\\' then parse_command
        when /[0-9]/ then parse_number
        when /[\p{L}\p{N}]/ then parse_identifier
        when '(', ')', '[', ']', '|' then parse_raw_delimiter(char)
        when /\p{P}/, /[\p{Sm}\p{Sk}]/ then parse_punctuation(char)
        else error("Unsupported character #{char.inspect}")
        end
      end

      def parse_group
        start = @pos
        @pos += 1
        @depth += 1
        children = parse_sequence(:group)
        if current != '}'
          error('Unclosed group', start)
        end
        @pos += 1
        @depth -= 1
        Node.new(type: :group, children: children, position: start)
      end

      def parse_raw_delimiter(char)
        start = @pos
        @pos += 1
        node = Node.new(type: :delimiter, value: char,
                        attrs: {fence: true}, position: start)
        apply_scripts(node)
      end

      def parse_number
        start = @pos
        value = +''
        while !at_end? && (current =~ /[0-9]/ || (current == '.' && next_char =~ /[0-9]/))
          value << current
          @pos += 1
        end
        Node.new(type: :number, value: value, position: start)
      end

      def parse_identifier
        start = @pos
        char = current
        @pos += 1
        make_token(char, :identifier, start)
      end

      def parse_punctuation(char)
        start = @pos
        if LITERALS.key?(char)
          @pos += 1
          return make_token(LITERALS[char], :operator, start)
        end
        @pos += 1
        error("Unsupported punctuation #{char.inspect}", start)
      end

      def parse_prime
        start = @pos
        count = 0
        count += 1 while current == "'" && (@pos += 1)
        value = count == 1 ? '′' : '″'
        value = '‴' if count == 3
        value = '⁗' if count >= 4
        Node.new(type: :prime, value: value, position: start)
      end

      def scan_command_name
        @pos += 1
        if at_end?
          error('Unterminated TeX command')
        elsif current =~ /[a-zA-Z]/
          start = @pos
          @pos += 1 while !at_end? && current =~ /[a-zA-Z]/
          @source[start...@pos]
        elsif current == '\\'
          @pos += 1
          '\\'
        else
          char = current
          @pos += 1
          char
        end
      end

      def peek_command_name
        return nil unless current == '\\'
        saved = @pos
        name = scan_command_name
        @pos = saved
        name
      end

      def parse_line_break(start)
        error('Line breaks are supported inside matrix environments only')
      end

      def parse_braced_name(start)
        unless current == '{'
          error('Expected environment name in braces')
        end
        @pos += 1
        name = +''
        until at_end? || current == '}'
          name << current
          @pos += 1
        end
        expect_char('}', 'Unclosed environment name')
        unless name =~ /\A[a-zA-Z*]+\z/
          error("Invalid environment name #{name.inspect}", start)
        end
        name
      end

      def parse_environment(name, start)
        canonical = name.sub(/\*\z/, '')
        unless MathML::MATRICES.key?(canonical)
          return error("Unsupported environment #{name.inspect}", start)
        end
        environment_start = @pos
        @depth += 1
        matrix_depth = @depth
        old_matrix_depth = @matrix_depth
        @matrix_depth = matrix_depth
        rows = parse_matrix_rows(matrix_depth, environment_start)
        expect_environment_end(name, start)
        @depth -= 1
        @matrix_depth = old_matrix_depth
        node = Node.new(type: :matrix, value: canonical, children: rows,
                        attrs: {delimiters: MathML::MATRICES[canonical]}, position: start)
        apply_scripts(node)
      end

      def parse_matrix_rows(depth, position)
        rows = []
        skip_spaces
        until at_end? || current_end_environment?(depth)
          row = parse_matrix_row(depth)
          rows << Node.new(type: :row, children: row, position: position)
          skip_spaces
        end
        rows
      end

      def parse_matrix_row(depth)
        cells = []
        loop do
          cell_start = @pos
          cells << Node.new(type: :cell, children: parse_matrix_cell(depth),
                                          position: cell_start)
          if current == '&'
            @pos += 1
            skip_spaces
          else
            consume_row_separator(depth)
            break
          end
        end
        cells
      end

      def consume_row_separator(depth)
        if current == '\\' && peek_command_name == '\\'
          start = @pos
          scan_command_name
          if current == '['
            error('Unsupported optional row spacing argument', start)
          end
          skip_spaces
        elsif !(at_end? || current_end_environment?(depth))
          error('Malformed matrix')
        end
      end

      def parse_matrix_cell(depth)
        parse_sequence(matrix_stop(depth, :cell))
      end

      def current_end_environment?(depth)
        @depth == depth && current == '\\' && peek_command_name == 'end'
      end

      def matrix_stop(depth, kind)
        {matrix: true, depth: depth, kind: kind}
      end

      def expect_environment_end(expected_name, start)
        end_start = @pos
        if current != '\\' || scan_command_name != 'end'
          error("Unclosed matrix environment #{expected_name.inspect}", start)
        end
        name = parse_braced_name(end_start)
        unless name == expected_name || name.sub(/\*\z/, '') == expected_name.sub(/\*\z/, '')
          error("Mismatched environment end #{name.inspect}", end_start)
        end
      end

      def parse_left(start)
        opening = parse_delimiter_token
        parts = [{kind: :open, value: opening, position: start}]
        children = parse_delimiter_body(parts, start)
        Node.new(type: :delimited, children: children, attrs: {parts: parts},
                 position: start).tap do |node|
          apply_scripts_in_place(node)
        end
      end

      def parse_delimiter_body(parts, start)
        children = []
        loop do
          skip_spaces
          children.concat(parse_sequence(delimited_stop))
          if current == '\\' && peek_command_name == 'middle'
            middle_start = @pos
            scan_command_name
            value = parse_delimiter_token
            children << delimiter_node_from_value(value, middle_start)
          elsif current == '\\' && peek_command_name == 'right'
            right_start = @pos
            scan_command_name
            parts << {kind: :close, value: parse_delimiter_token, position: right_start}
            return children
          elsif at_end?
            error('Missing \\right for \\left', start)
          else
            error('Malformed delimited expression')
          end
        end
      end

      def delimited_stop
        {delimiter: true, depth: @depth}
      end

      def delimiter_boundary?(stop)
        stop.is_a?(Hash) && stop[:delimiter] && @depth == stop[:depth] && current == '\\' &&
          %w[middle right].include?(peek_command_name)
      end

      def parse_delimiter_token
        skip_spaces
        if current == '\\'
          start = @pos
          name = scan_command_name
          unless MathML::DELIMITERS.key?(name)
            error("Unsupported delimiter #{name.inspect}", start)
          end
          delimiter_value(name)
        else
          char = current
          unless %w[( ) [ ] | .].include?(char)
            error("Expected a delimiter, got #{char.inspect}")
          end
          @pos += 1
          char == '.' ? MathML::DELIMITERS['.'] : char
        end
      end

      def delimiter_value(name)
        value = MathML::DELIMITERS[name]
        value == "\u2063" ? {value: value, invisible: true} : value
      end

      def parse_sized_delimiter(name, start)
        value = parse_delimiter_token
        node = delimiter_node_from_value(value, start, MathML::BIG_SIZES[name])
        apply_scripts(node)
      end

      def delimiter_node(name, position, size = nil)
        value = MathML::DELIMITERS[name]
        delimiter_node_from_value(value, position, size)
      end

      def delimiter_node_from_value(value, position, size = nil)
        invisible = value.is_a?(Hash)
        actual = invisible ? value[:value] : value
        attrs = {fence: true, stretchy: true}
        attrs[:minsize] = size if size
        attrs[:invisible] = true if invisible
        Node.new(type: :delimiter, value: actual, attrs: attrs, position: position)
      end

      def parse_text_like(name, start)
        variant = MathML::TEXT_VARIANTS[name]
        if name == 'text'
          text = scan_text_argument(start)
          Node.new(type: :text, value: text, position: start)
        else
          parse_variant_command(name, start, variant)
        end
      end

      def parse_variant_command(name, start, variant = nil)
        variant ||= MathML::TEXT_VARIANTS[name]
        scan_required_argument(name, start) do |children|
          node = Node.new(type: :style, children: children,
                          attrs: {mathvariant: variant}, position: start)
          return apply_scripts(node)
        end
      end

      def scan_required_argument(name, start)
        skip_spaces
        if current != '{'
          error("Missing argument for \\#{name}", start)
        end
        group = parse_group
        yield(group.children)
      end

      def scan_text_argument(start)
        skip_spaces
        error('Missing argument for \\text', start) unless current == '{'
        opening = @pos
        depth = 0
        result = +''
        @pos += 1
        closed = false
        until at_end?
          char = current
          if char == '{'
            depth += 1
            @pos += 1
          elsif char == '}'
            depth -= 1
            @pos += 1
            if depth.negative?
              closed = true
              break
            end
          elsif char == '\\'
            command_start = @pos
            command = scan_command_name
            if MathML::ESCAPED_TEXT.key?(command)
              result << MathML::ESCAPED_TEXT[command]
            else
              error("Unsupported TeX command \\#{command} inside \\text", command_start)
            end
          else
            result << char
            @pos += 1
          end
        end
        error('Unclosed \\text argument', opening) unless closed
        result
      end

      def parse_fraction(name, start)
        numerator = parse_math_argument(name, start)
        denominator = parse_math_argument(name, start)
        attrs = name == 'tfrac' ? {style: '0'} : {}
        node = Node.new(type: :fraction, children: [wrap(numerator, start), wrap(denominator, start)],
                        attrs: attrs, position: start)
        apply_scripts(node)
      end

      def parse_sqrt(start)
        index = nil
        skip_spaces
        if current == '['
          @pos += 1
          skip_spaces
          index = parse_sequence(:radical_index)
          if current != ']'
            error('Missing closing bracket for radical index', start)
          end
          @pos += 1
        end
        radicand = parse_math_argument('sqrt', start)
        node = Node.new(type: :radical, children: [wrap(radicand, start)],
                                     attrs: {index: index}, position: start)
        apply_scripts(node)
      end

      def parse_math_argument(name, start)
        skip_spaces
        if current == '{'
          parse_group.then {|node| node.type == :group ? node.children : [node] }
        elsif at_end?
          error("Missing argument for \\#{name}", start)
        else
          [parse_element]
        end
      end

      def wrap(children, start)
        Node.new(type: :group, children: children, position: start)
      end

      def apply_scripts(base)
        base = apply_scripts_in_place(base)
        base
      end

      def apply_scripts_in_place(base)
        subscript = superscript = nil
        loop do
          skip_spaces
          break unless current == '_' || current == '^' || current == "'"
          if current == "'"
            prime = parse_prime
            superscript = merge_prime(superscript, prime)
            next
          end
          marker = current
          marker_start = @pos
          @pos += 1
          skip_spaces
          argument = parse_math_argument(marker == '_' ? '_' : '^', marker_start)
          if marker == '_'
            error('Duplicate subscript', marker_start) unless subscript.nil?
            subscript = wrap(argument, marker_start)
          else
            error('Duplicate superscript', marker_start) unless superscript.nil?
            superscript = wrap(argument, marker_start)
          end
        end
        return base if subscript.nil? && superscript.nil?

        type = if !subscript.nil? && !superscript.nil?
                 :script
               elsif !subscript.nil?
                 :subscript
               else
                 :superscript
               end
        children = [base]
        children << subscript if subscript
        children << superscript if superscript
        Node.new(type: type, children: children, position: base.position)
      end

      def merge_prime(existing, prime)
        if existing.nil?
          Node.new(type: :group, children: [prime], position: prime.position)
        else
          existing.children << prime
          existing
        end
      end

      def make_token(value, type, position)
        node = Node.new(type: type, value: value, position: position)
        apply_scripts(node)
      end

      def parse_command
        start = @pos
        name = scan_command_name
        return parse_line_break(start) if name == '\\'

        if name == 'begin'
          skip_spaces
          return parse_environment(parse_braced_name(start), start)
        end
        return error('Unexpected \\end outside matrix') if name == 'end'
        return parse_text_like(name, start) if name == 'text' || TEXT_VARIANTS.key?(name)
        if variant_for(name)
          return parse_variant_command(name, start, variant_for(name))
        end
        return parse_sized_delimiter(name, start) if MathML::BIG_SIZES.key?(name)
        return error("Macro \\#{name} is not executed", start) if MathML::MACRO_COMMANDS.key?(name)
        return parse_left(start) if name == 'left'
        return error('Unexpected \\right outside \\left') if name == 'right'
        return parse_fraction(name, start) if %w[frac dfrac tfrac].include?(name)
        return parse_sqrt(start) if name == 'sqrt'
        return error('\\sqrt is the only supported radical command') if name == 'root'

        if MathML::SYMBOLS.key?(name)
          return apply_scripts(symbol_node(name, start))
        end
        if MathML::DELIMITERS.key?(name)
          return apply_scripts(delimiter_node(name, start))
        end
        if MathML::SPACES.key?(name)
          return Node.new(type: :space, value: MathML::SPACES[name], position: start)
        end
        if MathML::ESCAPED_TEXT.key?(name)
          return make_token(MathML::ESCAPED_TEXT[name], :operator, start)
        end
        error("Unsupported TeX command \\#{name}", start)
      end

      def variant_for(name)
        definition = MathML::SYMBOLS[name]
        return nil unless definition
        options = definition[1..-1].grep(Hash)
        options.first && options.first[:variant]
      end

      def symbol_node(name, position)
        value = MathML::SYMBOLS[name].first
        attrs = MathML::SYMBOLS[name][1..-1].grep(Hash).inject({}, &:merge)
        if name == 'ln' || MathML::FUNCTIONS.include?(name)
          attrs.delete(:function)
          Node.new(type: :function, value: value, attrs: attrs, position: position)
        else
          type = MathML::IDENTIFIER_SYMBOLS.include?(name) && attrs.empty? ? :identifier : :operator
          Node.new(type: type, value: value, attrs: attrs, position: position)
        end
      end

      def expect_char(char, message, position = @pos)
        if current != char
          error(message, position)
        end
        @pos += 1
      end

      def skip_spaces
        @pos += 1 while !at_end? && current =~ /[ \t\r\n\f]/
      end

      def current
        @chars[@pos]
      end

      def next_char
        @chars[@pos + 1]
      end

      def at_end?
        @pos >= @chars.length
      end

      def error(message, position = @pos)
        raise ParseError.new(message, @source, position)
      end

    end

    class Renderer
      def initialize(display: false)
        @display = display
      end

      def render(root)
        attrs = {'xmlns' => 'http://www.w3.org/1998/Math/MathML',
                 'display' => @display ? 'block' : 'inline'}
        tag('math', attrs, root.children.map {|child| render_node(child) }.join)
      end

      def self.error_mathml(error, display)
        attrs = {'xmlns' => 'http://www.w3.org/1998/Math/MathML',
                 'display' => display ? 'block' : 'inline'}
        message = escape(error.message)
        renderer = new
        body = renderer.send(:tag, 'mtext', {}, message)
        renderer.send(:tag, 'math', attrs, renderer.send(:tag, 'merror', {}, body))
      end

      private

      def render_node(node)
        send("render_#{node.type}", node)
      end

      def render_root(node)
        render_children(node)
      end

      def render_group(node)
        tag('mrow', {}, render_children(node))
      end

      def render_identifier(node)
        tag('mi', variant_attrs(node.attrs), escape(node.value))
      end

      def render_function(node)
        tag('mi', {'mathvariant' => 'normal'}, escape(node.value))
      end

      def render_number(node)
        tag('mn', {}, escape(node.value))
      end

      def render_text(node)
        tag('mtext', {}, escape(node.value))
      end

      def render_operator(node)
        attrs = {}
        attrs['largeop'] = 'true' if node.attrs[:largeop]
        attrs['movablelimits'] = 'true' if node.attrs[:limits]
        tag('mo', attrs, escape(node.value))
      end

      def render_delimiter(node)
        attrs = {}
        attrs['fence'] = 'true' if node.attrs[:fence]
        attrs['stretchy'] = 'true' if node.attrs[:stretchy]
        attrs['minsize'] = node.attrs[:minsize] if node.attrs[:minsize]
        tag('mo', attrs, escape(node.value))
      end

      def render_space(node)
        tag('mspace', {'width' => node.value}, nil, true)
      end

      def render_prime(node)
        tag('mo', {}, escape(node.value))
      end

      def render_fraction(node)
        attrs = node.attrs[:style] ? {'linethickness' => node.attrs[:style]} : {}
        tag('mfrac', attrs, render_children(node))
      end

      def render_radical(node)
        index = node.attrs[:index]
        if index
          index_html = tag('mrow', {}, index.map {|child| render_node(child) }.join)
          tag('mroot', {}, render_node(node.children.first) + index_html)
        else
          tag('msqrt', {}, render_node(node.children.first))
        end
      end

      def render_subscript(node)
        tag(limits?(node.children.first) ? 'munder' : 'msub', {}, render_children(node))
      end

      def render_superscript(node)
        tag(limits?(node.children.first) ? 'mover' : 'msup', {}, render_children(node))
      end

      def render_script(node)
        tag(limits?(node.children.first) ? 'munderover' : 'msubsup', {}, render_children(node))
      end

      def render_delimited(node)
        parts = node.attrs[:parts]
        opening = parts.find {|part| part[:kind] == :open }
        closing = parts.find {|part| part[:kind] == :close }
        middle = parts.select {|part| part[:kind] == :middle }
        body = render_children(node)
        result = +delimiter_html(opening[:value])
        result << body
        middle.each {|part| result << delimiter_html(part[:value]) }
        result << delimiter_html(closing[:value])
        tag('mrow', {}, result)
      end

      def render_matrix(node)
        rows = node.children.map do |row|
          cells = row.children.map {|cell| tag('mtd', {}, render_children(cell)) }.join
          tag('mtr', {}, cells)
        end.join
        table = tag('mtable', {'columnalign' => 'center'}, rows)
        return table unless node.attrs[:delimiters]

        left, right = node.attrs[:delimiters]
        tag('mrow', {}, delimiter_html(left) + table + delimiter_html(right))
      end

      def render_style(node)
        tag('mstyle', {'mathvariant' => node.attrs[:mathvariant]}, render_children(node))
      end

      def limits?(node)
        @display && node.attrs[:limits] && !node.attrs[:integral]
      end

      def delimiter_html(value)
        attrs = {'fence' => 'true', 'stretchy' => 'true'}
        tag('mo', attrs, escape(value))
      end

      def variant_attrs(attrs)
        attrs[:variant] ? {'mathvariant' => attrs[:variant]} : {}
      end

      def render_children(node)
        node.children.map {|child| render_node(child) }.join
      end

      def tag(name, attrs, body, void = false)
        serialized_attrs = attrs.map do |key, value|
          next if value.nil?
          " #{key}=\"#{escape(value.to_s, true)}\""
        end.compact.join
        void ? "<#{name}#{serialized_attrs}/>" : "<#{name}#{serialized_attrs}>#{body}</#{name}>"
      end

      def self.escape(value, _attribute = false)
        CGI.escapeHTML(value.to_s)
      end

      def escape(value, attribute = false)
        self.class.escape(value, attribute)
      end

    end

  end

end
