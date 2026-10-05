# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++
#

require 'minitest/autorun'
require 'rexml/document'
require 'kramdown'
require 'kramdown/converter/math_engine/mathml'

class TestMathEngineMathML < Minitest::Test
  def described_class
    Kramdown::Converter::MathEngine::MathML
  end

  def children(node)
    node.children.select {|child| child.is_a?(REXML::Element) }
  end

  def tag_name(node)
    node.expanded_name.sub(/\A.*:/, '')
  end

  def test_parses_grouped_subscript_and_superscript
    root = described_class.parse('x_{1}^{2}')
    assert_equal(:root, root.type)
    assert_equal(:script, root.children.first.type)
    base, subscript, superscript = root.children.first.children
    assert_equal(:identifier, base.type)
    assert_equal('x', base.value)
    assert_equal(:number, subscript.children.first.type)
    assert_equal('1', subscript.children.first.value)
    assert_equal(:number, superscript.children.first.type)
    assert_equal('2', superscript.children.first.value)
  end

  def test_superscript_attaches_to_complete_fraction
    root = described_class.parse('\frac{a+b}{c}^2')
    fraction_with_superscript = root.children.first
    assert_equal(:superscript, fraction_with_superscript.type)
    fraction = fraction_with_superscript.children.first
    assert_equal(:fraction, fraction.type)
    assert_equal(%w[a + b], fraction.children[0].children.map(&:value))
    assert_equal(['c'], fraction.children[1].children.map(&:value))
    assert_equal('2', fraction_with_superscript.children[1].children.first.value)
  end

  def test_radical_index_is_separate_from_radicand
    root = described_class.parse('\sqrt[n]{x+1}')
    radical = root.children.first
    assert_equal(:radical, radical.type)
    assert_equal('n', radical.attrs[:index].first.value)
    assert_equal(%w[x + 1], radical.children.first.children.map(&:value))
  end

  def test_matrix_cells_keep_nested_scripts_and_fractions
    source = '\\begin{bmatrix} a_1 & \\frac{b}{c} \\\\ d^2 & e \\end{bmatrix}'
    root = described_class.parse(source)
    matrix = root.children.first
    assert_equal(:matrix, matrix.type)
    assert_equal(2, matrix.children.size)

    first_cell = matrix.children[0].children[0].children
    assert_equal(:subscript, first_cell.first.type)
    second_cell = matrix.children[0].children[1].children
    assert_equal(:fraction, second_cell.first.type)
    third_cell = matrix.children[1].children[0].children
    assert_equal(:superscript, third_cell.first.type)
    assert_equal(['e'], matrix.children[1].children[1].children.map(&:value))
  end

  def test_matrix_unsupported_command_reports_cell_position
    source = '\\begin{matrix} a & \\badcmd \\\\\\\\ c & d \\end{matrix}'
    error = assert_raises(described_class::ParseError) do
      described_class.generate(source, errors: :raise)
    end
    assert_equal(source.index('\\badcmd'), error.position)
    assert_match(/Unsupported TeX command \\badcmd/, error.message)
  end

  def test_radical_can_have_superscript
    root = described_class.parse('\\sqrt{x}^2')
    radical_with_superscript = root.children.first
    assert_equal(:superscript, radical_with_superscript.type)
    assert_equal(:radical, radical_with_superscript.children.first.type)
  end

  def test_generates_standalone_presentation_mathml
    ['x_1^2', '\frac{a}{b}', '\sqrt[3]{x}', '\left(\frac{a}{b}\right)',
     '\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}', '\alpha+\beta\leq\gamma'].each do |source|
      output = described_class.generate(source, errors: :raise)
      document = REXML::Document.new(output)
      math = document.root
      assert_equal('math', tag_name(math))
      assert_equal('http://www.w3.org/1998/Math/MathML', math.namespace)
      assert_equal('inline', math.attribute('display').value)
      assert(children(math).any?)
    end
  end

  def test_output_escapes_xml_special_character_text
    output = described_class.generate('\\text{a < b & c}', errors: :raise)
    document = REXML::Document.new(output)
    assert_equal('a < b & c', children(document.root).first.text)
  end

  def test_left_right_and_middle_delimiters
    output = described_class.generate('\\left.\\frac{a}{b}\\right| + \\left(a\\middle|b\\right)',
                                     errors: :raise)
    document = REXML::Document.new(output)
    tags = []
    document.each_recursive {|node| tags << tag_name(node) if node.is_a?(REXML::Element) }
    assert_includes(tags, 'mfrac')
    assert_equal(6, tags.count('mo'))
  end

  def test_presentation_elements_for_scripts_fractions_roots_and_matrices
    output = described_class.generate('\frac{x_1}{y}^{2} + \sqrt[3]{z}', errors: :raise)
    math = REXML::Document.new(output).root
    tags = []
    math.each_recursive {|node| tags << tag_name(node) if node.is_a?(REXML::Element) }
    assert_includes(tags, 'mfrac')
    assert_includes(tags, 'msub')
    assert_includes(tags, 'msup')
    assert_includes(tags, 'mroot')

    matrix_output = described_class.generate('\\begin{vmatrix}a&b\\\\c&d\\end{vmatrix}',
                                             errors: :raise)
    matrix = REXML::Document.new(matrix_output).root
    matrix_tags = []
    matrix.each_recursive {|node| matrix_tags << tag_name(node) if node.is_a?(REXML::Element) }
    assert_equal(%w[mrow mo mtable mtr mtd mi mtd mi mtr mtd mi mtd mi mo],
                 matrix_tags)
  end

  def test_block_math_uses_block_display
    output = described_class.generate('x', display: true, errors: :raise)
    document = REXML::Document.new(output)
    assert_equal('block', document.root.attribute('display').value)
  end

  def test_block_limits_use_under_over_scripts
    output = described_class.generate('\\lim_{x \\to 0}^{n}', display: true, errors: :raise)
    tags = []
    REXML::Document.new(output).each_recursive do |node|
      tags << tag_name(node) if node.is_a?(REXML::Element)
    end
    assert_includes(tags, 'munderover')
  end

  def test_text_and_common_symbols
    output = described_class.generate('\text{if }x\geq 0', errors: :raise)
    document = REXML::Document.new(output)
    tags = children(document.root).map {|node| tag_name(node) }
    assert_equal(%w[mtext mi mo mn], tags)
    assert_includes(output, '≥')
  end

  def test_unsupported_command_keeps_readable_position
    error = assert_raises(described_class::ParseError) do
      described_class.generate('x + \\unknown', errors: :raise)
    end
    assert_equal(4, error.position)
    assert_match(/Unsupported TeX command \\unknown/, error.message)
    assert_match(/line 1, column 5 \(offset 4\)/, error.message)

    output = described_class.generate('x + \\unknown')
    document = REXML::Document.new(output)
    assert_equal('merror', tag_name(children(document.root).first))
    assert_includes(output, 'offset 4')
  end

  def test_macros_are_not_executed
    error = assert_raises(described_class::ParseError) do
      described_class.generate('\def\foo{x}\foo', errors: :raise)
    end
    assert_equal(0, error.position)
    assert_match(/Macro \\def is not executed/, error.message)
  end

  def test_empty_input_is_an_error
    error = assert_raises(described_class::ParseError) do
      described_class.generate('   ', errors: :raise)
    end
    assert_equal(3, error.position)
    assert_match(/Empty math expression/, error.message)
  end

  def test_unclosed_text_argument_reports_position
    source = '\\text{hello'
    error = assert_raises(described_class::ParseError) do
      described_class.generate(source, errors: :raise)
    end
    assert_equal(source.index('{'), error.position)
    assert_match(/Unclosed \\text argument/, error.message)
  end

  def test_kramdown_integration
    html = Kramdown::Document.new('$$\frac{a}{b}$$', math_engine: :mathml).to_html
    document = REXML::Document.new("<root>#{html}</root>")
    assert_equal('math', tag_name(document.root.children.first))
    assert_equal('block', document.root.children.first.attribute('display').value)
  end
end
