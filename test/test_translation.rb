# -*- coding: utf-8; frozen_string_literal: true -*-

require 'minitest/autorun'
require 'kramdown'

describe 'translation' do
  it 'extracts semantic units and preserves protected values during a round trip' do
    source = <<~SOURCE
      # Title *emphasis*

      [Read *this*](https://example.test/one) and `CODE_ONE` $$x + y$$

      [Read *this*](https://example.test/two) and `CODE_TWO`

      * [List *item*](https://list.test) `LIST_CODE`
    SOURCE

    doc = Kramdown::Document.new(source)
    bundle = doc.translation_units

    assert_equal(%w[header paragraph paragraph list_item], bundle.units.map(&:type))
    assert_equal(1, bundle.units[0].location)
    assert_equal(3, bundle.units[1].location)
    assert_equal(5, bundle.units[2].location)
    assert_equal(7, bundle.units[3].location)

    translated = translated_sources(bundle) do |unit|
      unit.source
        .sub('Title', 'Titre')
        .sub('Read ', '')
        .sub('and', 'et')
        .sub('List ', 'Liste ')
    end

    bundle.apply(translated)
    result = doc.to_kramdown

    assert_includes(result, '# Titre *emphasis*')
    assert_includes(result, '`CODE_ONE` $$x + y$$')
    assert_includes(result, '`CODE_TWO`')
    assert_includes(result, '`LIST_CODE`')

    links = link_hrefs(doc)
    assert_equal(
      ['https://example.test/one', 'https://example.test/two', 'https://list.test'],
      links
    )
    assert_equal('Titre', doc.root.children.first.children.first.value)
    assert_equal('this', doc.root.children[2].children.first.children.first.children.first.value)
  end

  it 'keeps legal word order changes around emphasis inside links' do
    source = '[Read *this*](https://example.test)\n'
    doc = Kramdown::Document.new(source)
    bundle = doc.translation_units
    link = node(bundle, 0, 0)
    emphasis = node(bundle, 0, 1)

    bundle.apply(bundle.units.first.id => wrap(link, wrap(emphasis, 'this') + ' read'))

    link = doc.root.children.first.children.first
    assert_equal('https://example.test', link.attr['href'])
    assert_equal(:em, link.children.first.type)
    assert_equal('this', link.children.first.children.first.value)
    assert_equal('this', link.children[0].children.first.value)
    assert_equal(' read', link.children[1].value + link.children[2].value)
  end

  it 'rejects a deleted closing placeholder and reports the unit' do
    doc = Kramdown::Document.new('See [text](https://example.test)\n')
    bundle = doc.translation_units
    link = node(bundle, 0, 0)
    before = doc.to_kramdown

    error = assert_raises(Kramdown::Translation::InvalidTranslation) do
      bundle.apply(bundle.units.first.id => token(link, 'o') + 'text')
    end

    assert_equal(bundle.units.first.id, error.unit_id)
    assert_match(/missing closing placeholder/, error.message)
    assert_equal(before, doc.to_kramdown)
  end

  it 'rejects a duplicated code placeholder and reports the unit' do
    doc = Kramdown::Document.new('Run `CODE` now\n')
    bundle = doc.translation_units
    code = node(bundle, 0, 0)
    before = doc.to_kramdown

    error = assert_raises(Kramdown::Translation::InvalidTranslation) do
      bundle.apply(bundle.units.first.id => token(code, 's') + ' ' + token(code, 's'))
    end

    assert_equal(bundle.units.first.id, error.unit_id)
    assert_match(/may not be repeated/, error.message)
    assert_equal(before, doc.to_kramdown)
  end

  it 'allows a protected code placeholder to move once within its unit' do
    doc = Kramdown::Document.new('Run `CODE` now\n')
    bundle = doc.translation_units
    code = node(bundle, 0, 0)

    bundle.apply(bundle.units.first.id => 'now ' + token(code, 's') + ' run')

    code_element = doc.root.children.first.children.find {|element| element.type == :codespan }
    assert_equal('CODE', code_element.value)
  end

  it 'rejects a closing placeholder with the wrong kind' do
    doc = Kramdown::Document.new('Run `CODE` now\n')
    bundle = doc.translation_units
    code = node(bundle, 0, 0)
    before = doc.to_kramdown

    error = assert_raises(Kramdown::Translation::InvalidTranslation) do
      bundle.apply(bundle.units.first.id => token(code, 'o'))
    end

    assert_equal(bundle.units.first.id, error.unit_id)
    assert_match(/must not be paired/, error.message)
    assert_equal(before, doc.to_kramdown)
  end

  it 'does not allow a placeholder from one unit in another unit' do
    doc = Kramdown::Document.new("First [one](u1)\n\nSecond [two](u2)\n")
    bundle = doc.translation_units
    first_link = node(bundle, 0, 0)
    second_link = node(bundle, 1, 0)
    before = doc.to_kramdown

    error = assert_raises(Kramdown::Translation::InvalidTranslation) do
      bundle.apply(
        bundle.units[0].id => token(first_link, 'o') + 'one' + token(first_link, 'c'),
        bundle.units[1].id => token(first_link, 'o') + 'two' + token(second_link, 'c')
      )
    end

    assert_equal(bundle.units[1].id, error.unit_id)
    assert_match(/unknown placeholder/, error.message)
    assert_equal(before, doc.to_kramdown)
  end

  it 'rejects placeholders crossing a protected boundary' do
    doc = Kramdown::Document.new('[Read *this*](https://example.test)\n')
    bundle = doc.translation_units
    link = node(bundle, 0, 0)
    emphasis = node(bundle, 0, 1)

    assert_raises(Kramdown::Translation::InvalidTranslation) do
      bundle.apply(
        bundle.units.first.id =>
          token(emphasis, 'o') + token(link, 'o') + 'this' + token(emphasis, 'c') + token(link, 'c')
      )
    end
  end

  it 'does not allow newly introduced unprotected code or links' do
    doc = Kramdown::Document.new('Read text\n')
    bundle = doc.translation_units

    ['Read `new code`', 'Read [new link](u)'].each do |translation|
      assert_raises(Kramdown::Translation::InvalidTranslation) do
        bundle.apply(bundle.units.first.id => translation)
      end
    end
  end

  private

  def node(bundle, unit_index, node_index)
    bundle.units[unit_index].nodes.values[node_index].id
  end

  def token(node_id, kind)
    bundle_identifier, unit_number, node_number = node_id.split('-')
    "\u27e6KD-#{bundle_identifier}-#{unit_number}-#{node_number}-#{kind}\u27e7"
  end

  def wrap(node_id, text)
    token(node_id, 'o') + text + token(node_id, 'c')
  end

def translated_sources(bundle)
    bundle.units.map {|unit| [unit.id, yield(unit)] }.to_h
end

def link_hrefs(document)
  collect_links(document.root).map {|element| element.attr['href'] }
end

def collect_links(element)
  links = element.type == :a ? [element] : []
  element.children.each {|child| links.concat(collect_links(child)) }
  links
end
end
