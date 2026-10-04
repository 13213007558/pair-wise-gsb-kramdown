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
        @accessible_table_nr = 0
        @accessible_cells = {}

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
        prepare_accessible_table(el) if @options[:accessible_tables] && el.value == 'table'
        res = inner(el, indent)
        value = el.value
        attr = el.attr
        if (cell_info = @accessible_cells[el])
          value = cell_info[:value] if cell_info[:value]
          if cell_info[:id] || cell_info[:headers]
            attr = attr.dup
            attr['id'] = cell_info[:id] if cell_info[:id]
            attr['headers'] = cell_info[:headers] if cell_info[:headers]
          end
        end
        if el.options[:category] == :span
          "<#{value}#{html_attributes(attr)}" + \
            (res.empty? && HTML_ELEMENTS_WITHOUT_BODY.include?(value) ? " />" : ">#{res}</#{value}>")
        else
          output = +''
          if @stack.last.type != :html_element || @stack.last.options[:content_model] != :raw
            output << ' ' * indent
          end
          output << "<#{value}#{html_attributes(attr)}"
          if el.options[:is_closed] && el.options[:content_model] == :raw
            output << " />"
          elsif !res.empty? && el.options[:content_model] != :block
            output << ">#{res}</#{value}>"
          elsif !res.empty?
            output << ">\n#{res.chomp}\n" << ' ' * indent << "</#{value}>"
          elsif HTML_ELEMENTS_WITHOUT_BODY.include?(value)
            output << " />"
          else
            output << "></#{value}>"
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
        prepare_accessible_table(el) if el.type == :table && @options[:accessible_tables]
        format_as_indented_block_html(el.type, el.attr, inner(el, indent), indent)
      end
      alias convert_thead convert_table
      alias convert_tbody convert_table
      alias convert_tfoot convert_table
      alias convert_tr convert_table

      ENTITY_NBSP = ::Kramdown::Utils::Entities.entity('nbsp') # :nodoc:

      def convert_td(el, indent)
        res = inner(el, indent)
        cell_info = @accessible_cells[el]
        type = (cell_info ? cell_info[:header] : @stack[-2].type == :thead) ? :th : :td
        attr = el.attr
        alignment = @stack[-3].options[:alignment][@stack.last.children.index(el)]
        if (cell_info && (cell_info[:id] || cell_info[:headers])) || alignment != :default
          attr = attr.dup
          if cell_info
            attr['id'] = cell_info[:id] if cell_info[:id]
            attr['headers'] = cell_info[:headers] if cell_info[:headers]
          end
          if alignment != :default
            attr['style'] = (attr.key?('style') ? "#{attr['style']}; " : '') + "text-align: #{alignment}"
          end
        end
        format_as_block_html(type, attr, res.empty? ? entity_to_str(ENTITY_NBSP) : res, indent)
      end

      # Struct holding the grid position and the role of a single table cell while the
      # accessibility attributes of a table are computed.
      AccessibleTableCell = Struct.new(:el, :header, :scope, :row, :col, :rows, :cols,
                                       :section, :section_type, :id, :headers, keyword_init: true)
      private_constant :AccessibleTableCell

      # Compute the accessibility attributes (stable header cell IDs and data cell +headers+
      # associations) for the table element +el+, which may either be a native :table element or
      # an HTML element with the value 'table'. The computed attributes are stored in
      # +@accessible_cells+ and applied when the affected cells are converted so that the
      # document tree itself is not modified.
      #
      # Header cells (cells of the table head section as well as cells explicitly marked with a
      # valid +scope+ attribute) get an +id+ attribute unless they are blank or already have one.
      # Each data cell gets a +headers+ attribute referencing the IDs of all applicable header
      # cells, taking row, column and group headers as well as +rowspan+/+colspan+ coverage into
      # account. Existing +headers+ attributes are kept as-is but their references are checked.
      def prepare_accessible_table(table)
        native = (table.type == :table)
        @accessible_table_nr += 1

        grid = []
        cells = []
        row_nr = 0
        accessible_table_sections(table, native).each do |section, section_type, rows|
          rows.each_with_index do |row, row_in_section|
            grid[row_nr] ||= []
            col_nr = 0
            accessible_table_row_cells(row, native).each do |cell_el|
              col_nr += 1 while grid[row_nr][col_nr]
              colspan = [cell_el.attr['colspan'].to_i, 1].max
              rowspan = cell_el.attr['rowspan'].to_i
              rowspan = rows.size - row_in_section if rowspan <= 0 && cell_el.attr['rowspan']
              rowspan = [[rowspan, 1].max, rows.size - row_in_section].min

              scope = cell_el.attr['scope']
              if scope && !%w[row col rowgroup colgroup].include?(scope)
                warning("Ignoring invalid scope attribute value '#{scope}' on table cell")
                scope = nil
              end
              header = section_type == :thead || !scope.nil? || (!native && cell_el.value == 'th')
              if header && scope.nil?
                scope = (section_type == :thead ? (colspan > 1 ? 'colgroup' : 'col') :
                         (rowspan > 1 ? 'rowgroup' : 'row'))
              end

              cell = AccessibleTableCell.new(el: cell_el, header: header, scope: scope,
                                             row: row_nr, col: col_nr, rows: rowspan, cols: colspan,
                                             section: section, section_type: section_type)
              (row_nr...(row_nr + rowspan)).each do |r|
                grid[r] ||= []
                (col_nr...(col_nr + colspan)).each {|c| grid[r][c] = cell }
              end
              cells << cell
              col_nr += colspan
            end
            row_nr += 1
          end
        end

        cells.each do |cell|
          next unless cell.header
          if cell.el.attr['id']
            cell.id = cell.el.attr['id']
          elsif !accessible_table_cell_blank?(cell.el)
            cell.id = generate_accessible_table_id(cell)
          end
        end

        header_ids = {}
        cells.each {|cell| header_ids[cell.id] = true if cell.header && cell.id }

        cells.each do |cell|
          if (refs = cell.el.attr['headers'])
            refs.split.each do |ref|
              if !header_ids.key?(ref) && !accessible_reserved_ids.key?(ref)
                warning("The headers attribute of a table cell references the unknown ID '#{ref}'")
              end
            end
            next
          end
          next if cell.header
          applicable = cells.select do |other|
            next false unless other.header && other.id
            case other.scope
            when 'col', 'colgroup'
              other.row < cell.row && other.col < cell.col + cell.cols &&
                cell.col < other.col + other.cols &&
                (other.section_type == :thead || other.section.equal?(cell.section))
            when 'row', 'rowgroup'
              other.section.equal?(cell.section) && other.col + other.cols <= cell.col &&
                other.row < cell.row + cell.rows && cell.row < other.row + other.rows
            end
          end
          unless applicable.empty?
            cell.headers = applicable.sort_by {|h| [h.row, h.col] }.map(&:id).join(' ')
          end
        end

        cells.each do |cell|
          info = {}
          if native
            info[:header] = cell.header
          else
            info[:value] = (cell.header ? 'th' : 'td')
          end
          info[:id] = cell.id if cell.header && cell.id && !cell.el.attr['id']
          info[:headers] = cell.headers if cell.headers
          @accessible_cells[cell.el] = info
        end
      end

      # Return the row sections of the table element +el+ as an array of +[section, section_type,
      # rows]+ triples where +section+ is an object uniquely identifying the section. Rows of an
      # HTML table that are not wrapped in a section element are grouped into implicit body
      # sections.
      def accessible_table_sections(table, native)
        sections = []
        bare_rows = []
        flush_bare_rows = lambda do
          sections << [bare_rows, :tbody, bare_rows] unless bare_rows.empty?
          bare_rows = []
        end
        table.children.each do |child|
          if native
            next unless %i[thead tbody tfoot].include?(child.type)
            flush_bare_rows.call
            rows = child.children.select {|c| c.type == :tr }
            sections << [child, child.type, rows] unless rows.empty?
          elsif child.type == :html_element && %w[thead tbody tfoot].include?(child.value)
            flush_bare_rows.call
            rows = child.children.select {|c| c.type == :html_element && c.value == 'tr' }
            sections << [child, child.value.to_sym, rows] unless rows.empty?
          elsif child.type == :html_element && child.value == 'tr'
            bare_rows << child
          else
            flush_bare_rows.call
          end
        end
        flush_bare_rows.call
        sections
      end

      # Return the cell elements of the table row element +row+.
      def accessible_table_row_cells(row, native)
        if native
          row.children.select {|c| c.type == :td }
        else
          row.children.select {|c| c.type == :html_element && (c.value == 'td' || c.value == 'th') }
        end
      end

      # Return +true+ if the table cell element +el+ has no content other than whitespace.
      def accessible_table_cell_blank?(el)
        el.children.all? {|child| child.type == :text && !child.value.match?(/[^\s\u00A0]/) }
      end

      # Generate a stable, document-wide unique ID for the header cell +cell+ of the current
      # table, avoiding collisions with IDs already used in the document.
      def generate_accessible_table_id(cell)
        reserved = accessible_reserved_ids
        base = "tbl#{@accessible_table_nr}-h#{cell.row + 1}-#{cell.col + 1}"
        candidate = base
        counter = 0
        while reserved.key?(candidate)
          counter += 1
          candidate = "#{base}-#{counter}"
        end
        reserved[candidate] = true
        candidate
      end

      # Return a hash with all IDs that are already used as anchors in the document, i.e. explicit
      # IDs of all elements, IDs that are automatically generated for headers and footnote IDs.
      def accessible_reserved_ids
        @accessible_reserved_ids ||= begin
          ids = {}
          collect = lambda do |el|
            ids[el.attr['id']] = true if el.attr['id']
            if el.type == :header && @options[:auto_ids] && !el.attr['id']
              ids[@options[:auto_id_prefix] + basic_generate_id(el.options[:raw_text].to_s)] = true
            elsif el.type == :footnote
              name = "#{@options[:footnote_prefix]}#{el.options[:name]}"
              ids["fn:#{name}"] = true
              ids["fnref:#{name}"] = true
            end
            el.children.each {|child| collect.call(child) }
          end
          collect.call(@root)
          (@used_ids || {}).each_key do |key|
            ids[key] = true
            ids[@options[:auto_id_prefix] + key] = true
          end
          ids
        end
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
