# -*- coding: utf-8; frozen_string_literal: true -*-

require 'minitest/autorun'
require 'kramdown'
require 'rexml/document'

class TestAccessibleTables < Minitest::Test
  COMPLEX_TABLE = <<~HTML
    <table>
      <thead>
        <tr>
          <th colspan="2" rowspan="2">Name</th>
          <th colspan="2">Q1</th>
          <th colspan="2">Q2</th>
        </tr>
        <tr>
          <th>Sales</th>
          <th>Profit</th>
          <th>Sales</th>
          <th>Profit</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <th rowspan="2">Domestic</th>
          <th>Alice</th>
          <td>Alice Q1 Sales</td>
          <td>Alice Q1 Profit</td>
          <td>Alice Q2 Sales</td>
          <td>Alice Q2 Profit</td>
        </tr>
        <tr>
          <th>Bob</th>
          <td>Bob Q1 Sales</td>
          <td>Bob Q1 Profit</td>
          <td>Bob Q2 Sales</td>
          <td>Bob Q2 Profit</td>
        </tr>
      </tbody>
      <tbody>
        <tr>
          <th scope="rowgroup">International</th>
          <th>Cara</th>
          <td>Cara Q1 Sales</td>
          <td>Cara Q1 Profit</td>
          <td>Cara Q2 Sales</td>
          <td>Cara Q2 Profit</td>
        </tr>
      </tbody>
    </table>
  HTML

  def test_complex_html_table_headers
    doc = Kramdown::Document.new(COMPLEX_TABLE, accessible_tables: true, auto_ids: false)
    html = doc.to_html
    table = cell_map(html)
    rows = physical_rows(html)

    assert_equal 'table-1-r1c1', table.dig('Name', :id)
    assert_equal 'table-1-r1c3', table.dig('Q1', :id)
    assert_equal 'table-1-r1c5', table.dig('Q2', :id)
    assert_equal 'table-1-r2c3', rows[1][0][:id]
    assert_equal 'table-1-r2c4', rows[1][1][:id]

    assert_equal %w[table-1-r3c1 table-1-r3c2 table-1-r1c3 table-1-r2c3],
                 table.fetch('Alice Q1 Sales')[:headers]
    assert_equal %w[table-1-r3c1 table-1-r3c2 table-1-r1c3 table-1-r2c4],
                 table.fetch('Alice Q1 Profit')[:headers]
    assert_equal %w[table-1-r3c1 table-1-r3c2 table-1-r1c5 table-1-r2c5],
                 table.fetch('Alice Q2 Sales')[:headers]
    assert_equal %w[table-1-r3c1 table-1-r3c2 table-1-r1c5 table-1-r2c6],
                 table.fetch('Alice Q2 Profit')[:headers]
    assert_equal %w[table-1-r3c1 table-1-r4c2 table-1-r1c3 table-1-r2c3],
                 table.fetch('Bob Q1 Sales')[:headers]
    assert_equal %w[table-1-r5c1 table-1-r5c2 table-1-r1c3 table-1-r2c3],
                 table.fetch('Cara Q1 Sales')[:headers]
    assert_equal %w[table-1-r5c1 table-1-r5c2 table-1-r1c5 table-1-r2c5],
                 table.fetch('Cara Q2 Sales')[:headers]
    assert_equal %w[table-1-r5c1 table-1-r5c2 table-1-r1c5 table-1-r2c6],
                 table.fetch('Cara Q2 Profit')[:headers]
  end

  def test_generated_ids_do_not_conflict_with_existing_anchors
    source = %(<h1 id="table-1-r1c1">Existing</h1>\n) + COMPLEX_TABLE
    html = Kramdown::Document.new(source, accessible_tables: true, auto_ids: false).to_html
    table = cell_map(html)

    assert_equal 'table-1-r1c1', html_headers(html).fetch('Existing')[:id]
    assert_equal 'table-1-r1c1-2', table.fetch('Name')[:id]
  end

  def test_markdown_table_gets_column_header_associations
    source = <<~MARKDOWN
      | Name | Count |
      |------|------:|
      | A    | 1     |
    MARKDOWN
    html = Kramdown::Document.new(source, accessible_tables: true, auto_ids: false).to_html
    table = cell_map(html)

    assert_equal %w[table-1-r1c2], table.fetch('1')[:headers]
    assert_equal 'th', table.fetch('Count')[:tag]
  end

  def test_explicit_headers_and_scope_are_preserved_and_checked
    source = <<~HTML
      <table>
        <thead>
          <tr><th id="metric" scope="col">Metric</th></tr>
        </thead>
        <tbody>
          <tr><td headers="metric">Value</td></tr>
          <tr><td headers="missing">Broken</td></tr>
          <tr><th scope="invalid">Bad scope</th><td>Data</td></tr>
        </tbody>
      </table>
    HTML
    doc = Kramdown::Document.new(source, accessible_tables: true, auto_ids: false)
    html = doc.to_html
    table = physical_rows(html)

    assert_equal %w[metric], table[1][0][:headers]
    assert_equal %w[missing], table[2][0][:headers]
    assert_equal 'invalid', table[3][0][:scope]
    assert_equal 2, doc.warnings.length
    assert_equal 1, doc.warnings.count {|warning| warning.match?(/headers reference 'missing'/) }
    assert_equal 1, doc.warnings.count {|warning| warning.match?(/Invalid scope 'invalid'/) }
  end

  def test_zero_row_and_column_spans
    source = <<~HTML
      <table>
        <thead>
          <tr><th>Name</th><th colspan="0">Quarter</th></tr>
          <tr><th></th><th>Q1</th><th>Q2</th></tr>
        </thead>
        <tbody>
          <tr><th rowspan="0">Group</th><th>A</th><td>1</td><td>2</td></tr>
          <tr><th>B</th><td>3</td><td>4</td></tr>
        </tbody>
      </table>
    HTML
    html = Kramdown::Document.new(source, accessible_tables: true, auto_ids: false).to_html
    table = cell_map(html)

    assert_equal %w[table-1-r3c1 table-1-r3c2 table-1-r1c2 table-1-r2c3], table.fetch('1')[:headers]
    assert_equal %w[table-1-r3c1 table-1-r4c2 table-1-r1c2], table.fetch('4')[:headers]
  end

  private

  def cell_map(html)
    document = REXML::Document.new("<root>#{html}</root>")
    map = {}
    REXML::XPath.match(document.root, './/th | .//td').each do |cell|
      text = cell.text.to_s.strip
      map[text] = {
        tag: cell.name,
        id: cell.attribute('id')&.value,
        scope: cell.attribute('scope')&.value,
        headers: cell.attribute('headers')&.value.to_s.split(/\s+/).reject(&:empty?)
      }
    end
    map
  end

  def physical_rows(html)
    document = REXML::Document.new("<root>#{html}</root>")
    REXML::XPath.match(document.root, './/tr').map do |row|
      REXML::XPath.match(row, './th | ./td').map do |cell|
        {
          tag: cell.name,
          id: cell.attribute('id')&.value,
          scope: cell.attribute('scope')&.value,
          headers: cell.attribute('headers')&.value.to_s.split(/\s+/).reject(&:empty?)
        }
      end
    end
  end

  def html_headers(html)
    document = REXML::Document.new("<root>#{html}</root>")
    REXML::XPath.match(document.root, './/h1 | .//h2 | .//h3 | .//h4 | .//h5 | .//h6').to_h do |header|
      [header.text.to_s.strip, {id: header.attribute('id')&.value}]
    end
  end
end
