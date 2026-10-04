# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++
#

require 'minitest/autorun'
require 'kramdown'

class TestAccessibleTables < Minitest::Test

  def test_rowspan_and_colspan_coverage_in_native_table
    src = <<~EOF
      | H1 | H2 |
      |----|----|
      | G  | a  |
      | b  | c  |
    EOF
    doc = Kramdown::Document.new(src, accessible_tables: true)
    table = doc.root.children.first
    table.children[0].children[0].children[0].attr['colspan'] = '2'
    cell_g = table.children[1].children[0].children[0]
    cell_g.attr['rowspan'] = '2'
    cell_g.attr['scope'] = 'rowgroup'
    html = doc.to_html

    assert_includes(html, '<th colspan="2" id="tbl1-h1-1">H1</th>')
    assert_includes(html, '<th id="tbl1-h1-3">H2</th>')
    assert_includes(html, '<th rowspan="2" scope="rowgroup" id="tbl1-h2-1">G</th>')
    assert_includes(html, '<td headers="tbl1-h1-1 tbl1-h2-1">a</td>')
    assert_includes(html, '<td headers="tbl1-h1-1 tbl1-h2-1">b</td>')
    assert_includes(html, '<td headers="tbl1-h1-3 tbl1-h2-1">c</td>')
  end

  def test_dangling_headers_reference_generates_warning
    src = <<~EOF
      <table>
        <tbody>
          <tr><td headers="no-such-id">a</td></tr>
        </tbody>
      </table>
    EOF
    doc = Kramdown::Document.new(src, accessible_tables: true, parse_block_html: true)
    html = doc.to_html

    assert_includes(html, 'headers="no-such-id"')
    assert(doc.warnings.any? {|w| w.include?("no-such-id") },
           "expected a warning about the unknown ID reference")
  end

  def test_invalid_scope_value_generates_warning_and_is_ignored
    src = <<~EOF
      <table>
        <tbody>
          <tr><td scope="sideways">a</td></tr>
        </tbody>
      </table>
    EOF
    doc = Kramdown::Document.new(src, accessible_tables: true, parse_block_html: true)
    html = doc.to_html

    assert_includes(html, '<td scope="sideways">a</td>')
    assert(doc.warnings.any? {|w| w.include?("sideways") },
           "expected a warning about the invalid scope value")
  end

  def test_explicit_id_scope_and_headers_attributes_are_respected
    src = <<~EOF
      <table>
        <thead>
          <tr><th id="my-header">H</th></tr>
        </thead>
        <tbody>
          <tr><td headers="my-header">a</td></tr>
        </tbody>
      </table>
    EOF
    doc = Kramdown::Document.new(src, accessible_tables: true, parse_block_html: true)
    html = doc.to_html

    assert_includes(html, '<th id="my-header">H</th>')
    assert_includes(html, '<td headers="my-header">a</td>')
    assert_empty(doc.warnings)
  end

  def test_generated_ids_do_not_collide_with_later_header_ids
    src = <<~EOF
      | H |
      |---|
      | a |

      ## tbl1 h1 1
    EOF
    doc = Kramdown::Document.new(src, accessible_tables: true)
    html = doc.to_html

    assert_includes(html, '<th id="tbl1-h1-1-1">H</th>')
    assert_includes(html, '<h2 id="tbl1-h1-1">tbl1 h1 1</h2>')
  end

  def test_tables_are_not_modified_when_option_is_disabled
    doc = Kramdown::Document.new("| H |\n|---|\n| a |\n")
    html = doc.to_html

    refute_includes(html, 'headers=')
    refute_includes(html, 'id="tbl')
  end

end
