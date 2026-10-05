# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++

require 'minitest/autorun'
require 'kramdown'
require 'kramdown/converter/math_engine/mathml'
require 'rexml/document'

describe 'Kramdown::Converter::MathEngine::Mathml' do
  Mathml = Kramdown::Converter::MathEngine::Mathml

  def parse(tex)
    Mathml.parse(tex)
  end

  def render(tex, display = false)
    Mathml.render(parse(tex), display)
  end

  def xml(tex, display = false)
    REXML::Document.new(render(tex, display))
  end

  def children(node, type)
    node.children.select {|child| child.is_a?(REXML::Element) && child.name == type }
  end

  def descendant(node, type)
    result = []
    node.children.each do |child|
      next unless child.is_a?(REXML::Element)

      result << child if child.name == type
      result.concat(descendant(child, type))
    end
    result
  end

  it 'parses groups, fractions, radicals and scripts' do
    tree = parse('\\frac{a+b}{c}^2_n')
    assert_equal(:seq, tree.type)
    assert_equal(:subsup, tree.children.first.type)

    fraction, subscript, superscript = tree.children.first.children
    assert_equal(:fraction, fraction.type)
    assert_equal(%w[a b], fraction.children[0].children.select {|child| child.type == :identifier }.map(&:value))
    assert_equal('c', fraction.children[1].children.first.value)
    assert_equal('n', subscript.value)
    assert_equal('2', superscript.value)
  end

  it 'keeps a scripted fraction as one MathML base' do
    document = xml('\\frac{a}{b}^2', true)
    superscript = children(document.root, 'msup').first

    assert_equal('block', document.root.attribute('display').value)
    assert_equal('mfrac', superscript.children[0].name)
    assert_equal('mn', superscript.children[1].name)
    assert_equal('2', superscript.children[1].text)
  end

  it 'represents every matrix row and cell structurally' do
    tree = parse('\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}')
    matrix = tree.children.first
    assert_equal([:matrix_row, :matrix_row], matrix.children.map(&:type))
    assert_equal([[:matrix_cell, :matrix_cell], [:matrix_cell, :matrix_cell]],
                 matrix.children.map {|row| row.children.map(&:type) })

    document = REXML::Document.new(Mathml.render(matrix, true))
    rows = descendant(document.root, 'mtable').flat_map {|table| children(table, 'mtr') }
    assert_equal(2, rows.length)
    assert_equal([%w[a b], %w[c d]], rows.map do |row|
      children(row, 'mtd').map {|cell| descendant(cell, 'mi').map(&:text).join }
    end)
  end

  it 'renders radicals, delimiters and common symbols as parseable MathML' do
    document = xml('\\left[\\sqrt[n]{x} + \\alpha\\right]')

    assert_equal('http://www.w3.org/1998/Math/MathML', document.root.namespace)
    assert_equal('mrow', document.root.children.first.name)
    assert_equal(3, descendant(document.root, 'mo').length)
    assert_equal('mroot', descendant(document.root, 'mroot').first.name)
  end

  it 'keeps unsupported commands with a readable formula position' do
    tree = parse('a + \\unknown{b}')
    error = tree.children.find {|child| child.type == :error }
    assert_equal(:error, error.type)
    assert_equal(4, error.location.offset)
    assert_equal(1, error.location.line)
    assert_equal(5, error.location.column)
    assert_match(/unsupported command/, error.value)

    output = render('a + \\unknown{b}')
    document = REXML::Document.new(output)
    assert_equal('merror', children(document.root, 'merror').first.name)
    error_text = descendant(document.root, 'mtext').map {|node| node.texts.join }.join
    assert_match(/line 1, column 5/, error_text)
    assert_match(/\\unknown/, error_text)
  end

  it 'keeps malformed repeated scripts as structured errors' do
    document = xml('a^^b')

    assert_equal('msup', descendant(document.root, 'msup').first.name)
    assert_equal(2, descendant(document.root, 'merror').length)
    assert_match(/double superscript/, descendant(document.root, 'mtext').map(&:text).join)
    REXML::Document.new(render('a^^b'))
  end

  it 'integrates with the HTML converter without browser dependencies' do
    document = Kramdown::Document.new('$$x^2$$', math_engine: :mathml).to_html

    assert_match(/\A<math xmlns=/, document)
    assert_match(/display="block"/, document)
    REXML::Document.new(document)
  end
end
