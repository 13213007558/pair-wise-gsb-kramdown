# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++
#

require 'kramdown/parser'
require 'kramdown/converter'
require 'kramdown/utils'

module Kramdown

  module Converter

    # Converts a Kramdown::Document to HTML.
    #
    # You can customize the HTML converter by sub-classing it and overriding the +convert_NAME+
    # methods. Each such method takes the following parameters:
    #
    # [+el+] The element of type +NAME+ to be converted.
    #
    # [+indent+] A number representing the current amount of spaces for indent (only used for
    #            block-level elements).
    #
    # The return value of such a method has to be a string containing the element +el+ formatted as
    # HTML element.
    class Html < Base

      include ::Kramdown::Utils::Html
      include ::Kramdown::Parser::Html::Constants

      # The amount of indentation used when nesting HTML tags.
      attr_accessor :indent

      # Initialize the HTML converter with the given Kramdown document +doc+.
      def initialize(root, options)
        super
        @footnote_counter = @footnote_start = @options[:footnote_nr]
        @footnotes = []
        @footnotes_by_name = {}
        @footnote_location = nil
        @toc = []
        @toc_code = nil
        @indent = 2
        @stack = []

        if @options[:accessible_tables]
          @accessible_table_cells = {}
          @accessible_tables = {}
          @accessible_table_count = 0
          @accessible_table_ids = {}
          reserve_document_ids(@root)
        end

        # stash string representation of symbol to avoid allocations from multiple interpolations.
        @highlighter_class = " highlighter-#{options[:syntax_highlighter]}"
        @dispatcher = Hash.new {|h, k| h[k] = :"convert_#{k}" }
      end

      # Dispatch the conversion of the element +el+ to a +convert_TYPE+ method using the +type+ of
      # the element.
      def convert(el, indent = -@indent)
        send(@dispatcher[el.type], el, indent)
      end

      # Return the converted content of the children of +el+ as a string. The parameter +indent+ has
      # to be the amount of indentation used for the element +el+.
      #
      # Pushes +el+ onto the @stack before converting the child elements and pops it from the stack
      # afterwards.
      def inner(el, indent)
        result = +''
        indent += @indent
        @stack.push(el)
        el.children.each do |inner_el|
          result << send(@dispatcher[inner_el.type], inner_el, indent)
        end
        @stack.pop
        result
      end

      def convert_blank(_el, _indent)
        "\n"
      end

      def convert_text(el, _indent)
        escaped = escape_html(el.value, :text)
        @options[:remove_line_breaks_for_cjk] ? fix_cjk_line_break(escaped) : escaped
      end

      def convert_p(el, indent)
        if el.options[:transparent]
          inner(el, indent)
        elsif el.children.size == 1 && el.children.first.type == :img &&
            el.children.first.options[:ial]&.[](:refs)&.include?('standalone')
          convert_standalone_image(el, indent)
        else
          format_as_block_html("p", el.attr, inner(el, indent), indent)
        end
      end

      # Helper method used by +convert_p+ to convert a paragraph that only contains a single :img
      # element.
      def convert_standalone_image(el, indent)
        figure_attr = el.attr.dup
        image_attr = el.children.first.attr.dup

        if image_attr.key?('class') && !figure_attr.key?('class')
          figure_attr['class'] = image_attr.delete('class')
        end
        if image_attr.key?('id') && !figure_attr.key?('id')
          figure_attr['id'] = image_attr.delete('id')
        end

        body = "#{' ' * (indent + @indent)}<img#{html_attributes(image_attr)} />\n" \
          "#{' ' * (indent + @indent)}<figcaption>#{image_attr['alt']}</figcaption>\n"
        format_as_indented_block_html("figure", figure_attr, body, indent)
      end

      def convert_codeblock(el, indent)
        attr = el.attr.dup
        lang = extract_code_language!(attr)
        hl_opts = {}
        highlighted_code = highlight_code(el.value, el.options[:lang] || lang, :block, hl_opts)

        if highlighted_code
          add_syntax_highlighter_to_class_attr(attr, lang || hl_opts[:default_lang])
          "#{' ' * indent}<div#{html_attributes(attr)}>#{highlighted_code}#{' ' * indent}</div>\n"
        else
          result = escape_html(el.value)
          result.chomp!
          if el.attr['class'].to_s =~ /\bshow-whitespaces\b/
            result.gsub!(/(?:(^[ \t]+)|([ \t]+$)|([ \t]+))/) do |m|
              suffix = ($1 ? '-l' : ($2 ? '-r' : ''))
              m.scan(/./).map do |c|
                case c
                when "\t" then "<span class=\"ws-tab#{suffix}\">\t</span>"
                when " " then "<span class=\"ws-space#{suffix}\">&#8901;</span>"
                end
              end.join
            end
          end
          code_attr = {}
          code_attr['class'] = "language-#{lang}" if lang
          "#{' ' * indent}<pre#{html_attributes(attr)}>" \
            "<code#{html_attributes(code_attr)}>#{result}\n</code></pre>\n"
        end
      end

      def convert_blockquote(el, indent)
        format_as_indented_block_html("blockquote", el.attr, inner(el, indent), indent)
      end

      def convert_header(el, indent)
        attr = el.attr.dup
        if @options[:auto_ids] && !attr['id']
          attr['id'] = generate_id(el.options[:raw_text])
        end

        if @options[:header_links] && attr['id'].to_s.length > 0
          link = Element.new(:a, nil, nil)
          link.attr['href'] = "##{attr['id']}"
          el.children.unshift(link)
        end

        @toc << [el.options[:level], attr['id'], el.children] if attr['id'] && in_toc?(el)
        level = output_header_level(el.options[:level])
        format_as_block_html("h#{level}", attr, inner(el, indent), indent)
      end

      def convert_hr(el, indent)
        "#{' ' * indent}<hr#{html_attributes(el.attr)} />\n"
      end

      ZERO_TO_ONETWENTYEIGHT = (0..128).to_a.freeze
      private_constant :ZERO_TO_ONETWENTYEIGHT

      def convert_ul(el, indent)
        if !@toc_code && el.options.dig(:ial, :refs)&.include?('toc')
          @toc_code = [el.type, el.attr, ZERO_TO_ONETWENTYEIGHT.map { rand(36).to_s(36) }.join]
          @toc_code.last
        elsif !@footnote_location && el.options.dig(:ial, :refs)&.include?('footnotes')
          @footnote_location = ZERO_TO_ONETWENTYEIGHT.map { rand(36).to_s(36) }.join
        else
          format_as_indented_block_html(el.type, el.attr, inner(el, indent), indent)
        end
      end
      alias convert_ol convert_ul

      def convert_dl(el, indent)
        format_as_indented_block_html("dl", el.attr, inner(el, indent), indent)
      end

      def convert_li(el, indent)
        output = ' ' * indent << "<#{el.type}" << html_attributes(el.attr) << ">"
        res = inner(el, indent)
        if el.children.empty? || (el.children.first.type == :p && el.children.first.options[:transparent])
          output << res << (res.match?(/\n\Z/) ? ' ' * indent : '')
        else
          output << "\n" << res << ' ' * indent
        end
        output << "</#{el.type}>\n"
      end
      alias convert_dd convert_li

      def convert_dt(el, indent)
        attr = el.attr.dup
        @stack.last.options[:ial][:refs].each do |ref|
          if ref =~ /\Aauto_ids(?:-([\w-]+))?/
            attr['id'] = "#{$1}#{basic_generate_id(el.options[:raw_text])}".lstrip
            break
          end
        end if !attr['id'] && @stack.last.options[:ial] && @stack.last.options[:ial][:refs]
        format_as_block_html("dt", attr, inner(el, indent), indent)
      end

      def convert_html_element(el, indent)
        if @options[:accessible_tables] && el.type == :html_element && el.value == 'table'
          prepare_accessible_table(el)
        end
        res = inner(el, indent)
        if el.options[:category] == :span
          "<#{el.value}#{html_attributes(el.attr)}" + \
            (res.empty? && HTML_ELEMENTS_WITHOUT_BODY.include?(el.value) ? " />" : ">#{res}</#{el.value}>")
        else
          output = +''
          if @stack.last.type != :html_element || @stack.last.options[:content_model] != :raw
            output << ' ' * indent
          end
          output << "<#{el.value}#{html_attributes(el.attr)}"
          if el.options[:is_closed] && el.options[:content_model] == :raw
            output << " />"
          elsif !res.empty? && el.options[:content_model] != :block
            output << ">#{res}</#{el.value}>"
          elsif !res.empty?
            output << ">\n#{res.chomp}\n" << ' ' * indent << "</#{el.value}>"
          elsif HTML_ELEMENTS_WITHOUT_BODY.include?(el.value)
            output << " />"
          else
            output << "></#{el.value}>"
          end
          output << "\n" if @stack.last.type != :html_element || @stack.last.options[:content_model] != :raw
          output
        end
      end

      def convert_xml_comment(el, indent)
        if el.options[:category] == :block &&
            (@stack.last.type != :html_element || @stack.last.options[:content_model] != :raw)
          ' ' * indent << el.value << "\n"
        else
          el.value
        end
      end
      alias convert_xml_pi convert_xml_comment

      def convert_table(el, indent)
        prepare_accessible_table(el) if @options[:accessible_tables] && el.type == :table
        format_as_indented_block_html(el.type, el.attr, inner(el, indent), indent)
      end
      alias convert_thead convert_table
      alias convert_tbody convert_table
      alias convert_tfoot convert_table
      alias convert_tr convert_table

      ENTITY_NBSP = ::Kramdown::Utils::Entities.entity('nbsp') # :nodoc:

      def convert_td(el, indent)
        res = inner(el, indent)
        type = (@stack[-2].type == :thead ? :th : :td)
        attr = el.attr
        column = @accessible_table_cells&.dig(el, :column) || @stack.last.children.index(el)
        alignment = @stack[-3].options[:alignment][column] if @stack[-3].type == :table
        if alignment && alignment != :default
          attr = el.attr.dup
          attr['style'] = (attr.key?('style') ? "#{attr['style']}; " : '') + "text-align: #{alignment}"
        end
        format_as_block_html(type, attr, res.empty? ? entity_to_str(ENTITY_NBSP) : res, indent)
      end

      ACCESSIBLE_TABLE_SCOPES = %w[rowgroup row colgroup col].freeze
      private_constant :ACCESSIBLE_TABLE_SCOPES

      def reserve_document_ids(root)
        generated_header_ids = {}
        each_element(root) do |el|
          add_used_id(el.attr['id']) if el.attr.is_a?(Hash) && el.attr['id']
          if el.type == :header && @options[:auto_ids]
            id = basic_generate_id(el.options[:raw_text].to_s)
            id = 'section' if id.empty?
            if el.attr['id'].nil?
              if generated_header_ids.key?(id)
                id = "#{id}-#{generated_header_ids[id] += 1}"
              else
                generated_header_ids[id] = 0
              end
              id = @options[:auto_id_prefix].to_s + id
            end
            add_used_id(id)
            add_used_id("markdown-toc-#{id}")
          elsif el.type == :footnote
            add_used_id("fnref:#{@options[:footnote_prefix]}#{el.options[:name]}")
            add_used_id("fn:#{@options[:footnote_prefix]}#{el.options[:name]}")
          elsif el.type == :dl && el.options.dig(:ial, :refs)&.include?('auto_ids')
            each_element(el) do |definition|
              next unless definition.type == :dt

              add_used_id(basic_generate_id(definition.options[:raw_text].to_s))
            end
          end
        end
        add_used_id('markdown-toc')
      end

      def add_used_id(id)
        @accessible_table_ids[id] = true if id && !id.strip.empty?
      end

      def unique_accessible_table_id(table_number, row, column)
        base = "table-#{table_number}-r#{row + 1}c#{column + 1}"
        id = base
        suffix = 1
        while @accessible_table_ids.key?(id)
          suffix += 1
          id = "#{base}-#{suffix}"
        end
        @accessible_table_ids[id] = true
        id
      end

      def prepare_accessible_table(table)
        return if @accessible_tables&.key?(table)

        @accessible_tables[table] = true

        native = table.type == :table
        rows = accessible_table_rows(table, native)
        return if rows.empty?

        @accessible_table_count += 1
        records = []
        occupied = {}
        width = 0
        rows.each_with_index do |row, row_index|
          column_index = 0
          cells_in(row, native).each do |cell|
            column_index += 1 while occupied[[row_index, column_index]]
            colspan = accessible_span(cell.attr['colspan'])
            next if colspan.zero?

            rowspan = accessible_span(cell.attr['rowspan'])
            if rowspan.zero?
              section_end = rows.rindex {|table_row| table_row[:section_id] == row[:section_id] }
              rowspan = [section_end - row_index + 1, 1].max
            end
            rowspan.times do |row_offset|
              colspan.times do |column_offset|
                occupied[[row_index + row_offset, column_index + column_offset]] = true
              end
            end
            column_index += colspan
            width = [width, column_index].max
          end

          cells_in(row, native).each do |cell|
            next unless accessible_span(cell.attr['colspan']).zero?

            cell_column = 0
            cell_column += 1 while occupied[[row_index, cell_column]]
            occupied[[row_index, cell_column]] = true
            width = [width, cell_column + 1].max
          end
        end

        occupied.clear
        rows.each_with_index do |row, row_index|
          column_index = 0
          cells_in(row, native).each do |cell|
            column_index += 1 while occupied[[row_index, column_index]]
            colspan = accessible_span(cell.attr['colspan'])
            rowspan = accessible_span(cell.attr['rowspan'])
            colspan = width - column_index if colspan.zero?
            colspan = 1 if colspan.negative?
            if rowspan.zero?
              section_end = rows.rindex {|table_row| table_row[:section_id] == row[:section_id] }
              rowspan = [section_end - row_index + 1, 1].max
            end
            record = {
              element: cell,
              section: row[:section],
              section_id: row[:section_id],
              row: row_index,
              column: column_index,
              colspan: accessible_span(cell.attr['colspan']),
              rowspan: accessible_span(cell.attr['rowspan']),
              grid_colspan: colspan,
              grid_rowspan: rowspan
            }
            records << record
            @accessible_table_cells[cell] = record
            record[:grid_rowspan].times do |row_offset|
              record[:grid_colspan].times do |column_offset|
                occupied[[row_index + row_offset, record[:column] + column_offset]] = record
              end
            end
            column_index += colspan
          end
        end

        headers = records.select {|record| accessible_cell_tag(record, native) == 'th' }
        header_ids = {}
        headers.each do |record|
          id = record[:element].attr['id']
          if id.nil? || id.strip.empty?
            id = unique_accessible_table_id(@accessible_table_count, record[:row], record[:column])
          end
          record[:element].attr['id'] ||= id
          record[:id] = record[:element].attr['id']
          header_ids[record[:id]] = record
        end

        headers.each do |record|
          record[:scope], record[:explicit_scope] = accessible_scope(record, native)
        end
        validate_accessible_headers(records, header_ids)
        assign_accessible_headers(records, headers, native)
      end

      def accessible_table_rows(table, native)
        rows = []
        if native
          table.children.each_with_index do |section, section_index|
            next unless %i[thead tbody tfoot].include?(section.type)
            section.children.each do |row|
              if row.type == :tr
                rows << {element: row, section: section.type.to_s, section_id: section_index}
              end
            end
          end
        else
          section_index = -1
          table.children.each do |child|
            section_index += 1
            section = implicit_section?(child) ? 'tbody' : child.value
            collect_accessible_rows(child, section, section_index, rows)
          end
        end
        rows
      end

      def collect_accessible_rows(element, section, section_id, rows)
        return unless element.type == :html_element

        if element.value == 'tr'
          rows << {element: element, section: section, section_id: section_id}
        elsif %w[thead tbody tfoot].include?(element.value)
          element.children.each do |child|
            collect_accessible_rows(child, element.value, section_id, rows)
          end
        end
      end

      def implicit_section?(element)
        element.type == :html_element && element.value == 'tr'
      end

      def cells_in(row, native)
        row[:element].children.select do |cell|
          native ? cell.type == :td : cell.type == :html_element && %w[td th].include?(cell.value)
        end
      end

      def accessible_cell_tag(record, native)
        return 'th' if native && record[:section] == 'thead'

        native ? 'td' : record[:element].value
      end

      def accessible_span(value)
        span = value.to_s.strip
        return 1 unless /\A\d+\z/.match?(span)

        span.to_i
      end

      def accessible_scope(record, native)
        scope = record[:element].attr['scope']
        return [infer_accessible_scope(record, native), false] if scope.nil?

        scope = scope.strip.downcase
        return [infer_accessible_scope(record, native), false] if scope.empty? ||
          scope == 'auto'

        if ACCESSIBLE_TABLE_SCOPES.include?(scope)
          [scope, true]
        else
          warning("Invalid scope '#{record[:element].attr['scope']}' " \
                  "on table header cell '#{record[:id]}'")
          [nil, true]
        end
      end

      def infer_accessible_scope(record, native)
        if native || record[:section] == 'thead'
          return 'colgroup' if record[:grid_colspan] > 1

          'col'
        elsif record[:section] == 'tfoot'
          'col'
        elsif record[:grid_rowspan] > 1 || record[:grid_colspan] > 1
          'rowgroup'
        else
          'row'
        end
      end

      def validate_accessible_headers(records, header_ids)
        records.each do |record|
          value = record[:element].attr['headers']
          next if value.nil?

          value.split(/\s+/).reject(&:empty?).each do |id|
            unless header_ids.key?(id)
              warning("Table cell headers reference '#{id}' which does not reference " \
                      'a header cell in the same table')
            end
          end
        end
      end

      def assign_accessible_headers(records, headers, native)
        records.each do |record|
          next if accessible_cell_tag(record, native) != 'td'
          next if record[:element].attr.key?('headers') || record[:section] == 'thead'

          associated = headers.select do |header|
            accessible_header_applies?(header, record)
          end
          next if associated.empty?

          associated.sort_by! do |header|
            [ACCESSIBLE_TABLE_SCOPES.index(header[:scope]) || 4, header[:row], header[:column]]
          end
          record[:element].attr['headers'] = associated.map {|header| header[:id] }.uniq.join(' ')
        end
      end

      def accessible_header_applies?(header, record)
        return false if header[:scope].nil?
        column_section_applies = header[:explicit_scope] || header[:section] == 'thead' ||
          header[:section_id] == record[:section_id]

        column_intersects = header[:column] < record[:column] + record[:grid_colspan] &&
          header[:column] + header[:grid_colspan] > record[:column]
        row_intersects = header[:row] < record[:row] + record[:grid_rowspan] &&
          header[:row] + header[:grid_rowspan] > record[:row]

        case header[:scope]
        when 'col'
          column_section_applies && column_intersects && (header[:explicit_scope] ||
            header[:row] + header[:grid_rowspan] <= record[:row])
        when 'colgroup'
          column_section_applies && column_intersects && (header[:explicit_scope] ||
            header[:row] + header[:grid_rowspan] <= record[:row])
        when 'row'
          header[:section_id] == record[:section_id] && row_intersects
        when 'rowgroup'
          header[:section_id] == record[:section_id] &&
            (header[:explicit_scope] || (row_intersects && record[:row] >= header[:row]))
        end
      end

      def each_element(element, &block)
        block.call(element)
        element.children.each {|child| each_element(child, &block) }
      end

      def convert_comment(el, indent)
        if el.options[:category] == :block
          "#{' ' * indent}<!-- #{el.value} -->\n"
        else
          "<!-- #{el.value} -->"
        end
      end

      def convert_br(_el, _indent)
        "<br />"
      end

      def convert_a(el, indent)
        format_as_span_html("a", el.attr, inner(el, indent))
      end

      def convert_img(el, _indent)
        "<img#{html_attributes(el.attr)} />"
      end

      def convert_codespan(el, _indent)
        attr = el.attr.dup
        lang = extract_code_language(attr)
        hl_opts = {}
        result = highlight_code(el.value, lang, :span, hl_opts)
        if result
          add_syntax_highlighter_to_class_attr(attr, lang || hl_opts[:default_lang])
        else
          result = escape_html(el.value)
        end

        format_as_span_html('code', attr, result)
      end

      def convert_footnote(el, _indent)
        repeat = ''
        name = @options[:footnote_prefix] + el.options[:name]
        if (footnote = @footnotes_by_name[name])
          number = footnote[2]
          repeat = ":#{footnote[3] += 1}"
        else
          number = @footnote_counter
          @footnote_counter += 1
          @footnotes << [name, el.value, number, 0]
          @footnotes_by_name[name] = @footnotes.last
        end
        formatted_link_text = sprintf(@options[:footnote_link_text], number)
        "<sup id=\"fnref:#{name}#{repeat}\">" \
          "<a href=\"#fn:#{name}\" class=\"footnote\" rel=\"footnote\" role=\"doc-noteref\">" \
          "#{formatted_link_text}</a></sup>"
      end

      def convert_raw(el, _indent)
        if !el.options[:type] || el.options[:type].empty? || el.options[:type].include?('html')
          el.value + (el.options[:category] == :block ? "\n" : '')
        else
          ''
        end
      end

      def convert_em(el, indent)
        format_as_span_html(el.type, el.attr, inner(el, indent))
      end
      alias convert_strong convert_em

      def convert_entity(el, _indent)
        entity_to_str(el.value, el.options[:original])
      end

      TYPOGRAPHIC_SYMS = {
        mdash: [::Kramdown::Utils::Entities.entity('mdash')],
        ndash: [::Kramdown::Utils::Entities.entity('ndash')],
        hellip: [::Kramdown::Utils::Entities.entity('hellip')],
        laquo_space: [::Kramdown::Utils::Entities.entity('laquo'),
                      ::Kramdown::Utils::Entities.entity('nbsp')],
        raquo_space: [::Kramdown::Utils::Entities.entity('nbsp'),
                      ::Kramdown::Utils::Entities.entity('raquo')],
        laquo: [::Kramdown::Utils::Entities.entity('laquo')],
        raquo: [::Kramdown::Utils::Entities.entity('raquo')],
      } # :nodoc:
      def convert_typographic_sym(el, _indent)
        if (result = @options[:typographic_symbols][el.value])
          escape_html(result, :text)
        else
          TYPOGRAPHIC_SYMS[el.value].map {|e| entity_to_str(e) }.join
        end
      end

      def convert_smart_quote(el, _indent)
        entity_to_str(smart_quote_entity(el))
      end

      def convert_math(el, indent)
        if (result = format_math(el, indent: indent))
          result
        else
          attr = el.attr.dup
          attr['class'] = "#{attr['class']} kdmath".lstrip
          if el.options[:category] == :block
            format_as_block_html('div', attr, "$$\n#{el.value}\n$$", indent)
          else
            format_as_span_html('span', attr, "$#{el.value}$")
          end
        end
      end

      def convert_abbreviation(el, _indent)
        title = @root.options[:abbrev_defs][el.value]
        attr = @root.options[:abbrev_attr][el.value].dup
        attr['title'] = title unless title.empty?
        format_as_span_html("abbr", attr, el.value)
      end

      def convert_root(el, indent)
        result = inner(el, indent)
        if @footnote_location
          result.sub!(/#{@footnote_location}/, footnote_content.gsub(/\\/, "\\\\\\\\"))
        else
          result << footnote_content
        end
        if @toc_code
          toc_tree = generate_toc_tree(@toc, @toc_code[0], @toc_code[1] || {})
          text = toc_tree.children.empty? ? '' : convert(toc_tree, 0)
          result.sub!(/#{@toc_code.last}/, text.gsub(/\\/, "\\\\\\\\"))
        end
        result
      end

      # Format the given element as span HTML.
      def format_as_span_html(name, attr, body)
        "<#{name}#{html_attributes(attr)}>#{body}</#{name}>"
      end

      # Format the given element as block HTML.
      def format_as_block_html(name, attr, body, indent)
        "#{' ' * indent}<#{name}#{html_attributes(attr)}>#{body}</#{name}>\n"
      end

      # Format the given element as block HTML with a newline after the start tag and indentation
      # before the end tag.
      def format_as_indented_block_html(name, attr, body, indent)
        "#{' ' * indent}<#{name}#{html_attributes(attr)}>\n#{body}#{' ' * indent}</#{name}>\n"
      end

      # Add the syntax highlighter name to the 'class' attribute of the given attribute hash. And
      # overwrites or add a "language-LANG" part using the +lang+ parameter if +lang+ is not nil.
      def add_syntax_highlighter_to_class_attr(attr, lang = nil)
        (attr['class'] = (attr['class'] || '') + @highlighter_class).lstrip!
        attr['class'].sub!(/\blanguage-\S+|(^)/) { "language-#{lang}#{$1 ? ' ' : ''}" } if lang
      end

      # Generate and return an element tree for the table of contents.
      def generate_toc_tree(toc, type, attr)
        sections = Element.new(type, nil, attr.dup)
        sections.attr['id'] ||= 'markdown-toc'
        stack = []
        toc.each do |level, id, children|
          li = Element.new(:li, nil, nil, level: level)
          li.children << Element.new(:p, nil, nil, transparent: true)
          a = Element.new(:a, nil)
          a.attr['href'] = "##{id}"
          a.attr['id'] = "#{sections.attr['id']}-#{id}"
          a.children.concat(fix_for_toc_entry(Marshal.load(Marshal.dump(children))))
          li.children.last.children << a
          li.children << Element.new(type)

          success = false
          until success
            if stack.empty?
              sections.children << li
              stack << li
              success = true
            elsif stack.last.options[:level] < li.options[:level]
              stack.last.children.last.children << li
              stack << li
              success = true
            else
              item = stack.pop
              item.children.pop if item.children.last.children.empty?
            end
          end
        end
        until stack.empty?
          item = stack.pop
          item.children.pop if item.children.last.children.empty?
        end
        sections
      end

      # Fixes the elements for use in a TOC entry.
      def fix_for_toc_entry(elements)
        remove_footnotes(elements)
        unwrap_links(elements)
        elements
      end

      # Remove all link elements by unwrapping them.
      def unwrap_links(elements)
        elements.map! do |c|
          unwrap_links(c.children)
          c.type == :a ? c.children : c
        end.flatten!
      end

      # Remove all footnotes from the given elements.
      def remove_footnotes(elements)
        elements.delete_if do |c|
          remove_footnotes(c.children)
          c.type == :footnote
        end
      end

      # Obfuscate the +text+ by using HTML entities.
      def obfuscate(text)
        result = +''
        text.each_byte do |b|
          result << (b > 128 ? b.chr : sprintf("&#%03d;", b))
        end
        result.force_encoding(text.encoding)
        result
      end

      FOOTNOTE_BACKLINK_FMT = "%s<a href=\"#fnref:%s\" class=\"reversefootnote\" role=\"doc-backlink\">%s</a>"

      # Return an HTML ordered list with the footnote content for the used footnotes.
      def footnote_content
        ol = Element.new(:ol)
        ol.attr['start'] = @footnote_start if @footnote_start != 1
        i = 0
        backlink_text = escape_html(@options[:footnote_backlink], :text)
        while i < @footnotes.length
          name, data, _, repeat = *@footnotes[i]
          li = Element.new(:li, nil, 'id' => "fn:#{name}")
          li.children = Marshal.load(Marshal.dump(data.children))

          para = nil
          if li.children.last.type == :p || @options[:footnote_backlink_inline]
            parent = li
            while !parent.children.empty? && ![:p, :header].include?(parent.children.last.type)
              parent = parent.children.last
            end
            para = parent.children.last
            insert_space = true
          end

          unless para
            li.children << (para = Element.new(:p))
            insert_space = false
          end

          unless @options[:footnote_backlink].empty?
            nbsp = entity_to_str(ENTITY_NBSP)
            value = sprintf(FOOTNOTE_BACKLINK_FMT, (insert_space ? nbsp : ''), name, backlink_text)
            para.children << Element.new(:raw, value)
            (1..repeat).each do |index|
              value = sprintf(FOOTNOTE_BACKLINK_FMT, nbsp, "#{name}:#{index}",
                              "#{backlink_text}<sup>#{index + 1}</sup>")
              para.children << Element.new(:raw, value)
            end
          end

          ol.children << Element.new(:raw, convert(li, 4))
          i += 1
        end
        if ol.children.empty?
          ''
        else
          format_as_indented_block_html('div', {class: "footnotes", role: "doc-endnotes"}, convert(ol, 2), 0)
        end
      end

    end

  end
end
