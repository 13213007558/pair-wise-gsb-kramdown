# -*- coding: utf-8; frozen_string_literal: true -*-
#
#--
# Copyright (C) 2009-2026 Thomas Leitner <t_leitner@gmx.at>
#
# This file is part of kramdown which is licensed under the MIT.
#++
#

require 'minitest/autorun'
require 'kramdown'
require 'kramdown/translation'

Encoding.default_external = 'utf-8'

describe 'translation extraction/backfill' do
  LINK_DOC = <<~DOC.freeze
    See [the *bold* site](http://a.example) and `alpha`.

    See [the *bold* site](http://b.example).
  DOC

  def extract(source, **options)
    Kramdown::Translation.extract(Kramdown::Document.new(source, **options))
  end

  def roundtrip(source)
    document = Kramdown::Document.new(source)
    package = Kramdown::Translation.extract(document)
    translations = {}
    package.units.each {|unit| translations[unit.id] = unit.source }
    document.apply_translations(translations)
    document
  end

  it 'extracts paragraphs as independent units with identity placeholders' do
    package = extract(LINK_DOC)
    assert_equal(%i[paragraph paragraph], package.units.map(&:type))
    first, second = package.units
    assert_equal(1, first.location)
    assert_equal(3, second.location)
    assert_includes first.source, '{{KD:'
    # same visible text, different placeholders/URLs
    refute_equal first.source, second.source
    assert_match(/u1:n\d+:a/, first.source)
    assert_match(/u2:n\d+:a/, second.source)
  end

  it 'preserves the document on identity backfill including to_kramdown' do
    document = roundtrip(LINK_DOC)
    html = document.to_html
    expected_html = Kramdown::Document.new(LINK_DOC).to_html
    assert_equal(expected_html, html)
    expected_kd = Kramdown::Document.new(LINK_DOC).to_kramdown
    assert_equal(expected_kd, document.to_kramdown)
  end

  it 'keeps the two links pointed at their distinct URLs' do
    document = Kramdown::Document.new(LINK_DOC)
    package = Kramdown::Translation.extract(document)
    first, second = package.units
    package.translate(first.id, first.source)
    package.translate(second.id, second.source)
    package.apply!
    html = document.to_html
    first_link = html.index('href="http://a.example"')
    second_link = html.index('href="http://b.example"')
    refute_nil first_link
    refute_nil second_link
    assert_operator first_link, :<, second_link
  end

  it 'allows word order changes while keeping link text, emphasis and code' do
    document = Kramdown::Document.new(LINK_DOC)
    package = Kramdown::Translation.extract(document)
    first, second = package.units

    code_token = first.source[/\{\{KD:#{first.id}:n\d+:codespan\}\}/]
    link_token = first.source[/\{\{KD:#{first.id}:(n\d+):a\}\}.*\{\{KD:\/u1:\1:a\}\}/m]
    reordered = "See #{code_token} and #{link_token}."

    package.translate(first.id, reordered)
    package.translate(second.id, second.source)
    package.apply!
    html = document.to_html
    assert_match(/<p>See <code>alpha<\/code> and <a href="http:\/\/a.example">the <em>bold<\/em> site<\/a>.<\/p>/,
                 html)
    assert_includes html, 'href="http://b.example"'
  end

  it 'allows rearranging emphasis text inside link text' do
    source = 'Read [the *good* guide](http://x.test).'
    document = Kramdown::Document.new(source)
    package = Kramdown::Translation.extract(document)
    unit = package.units.first
    link_open = unit.source[/\{\{KD:#{unit.id}:(n\d+):a\}\}/]
    link_close = unit.source[/\{\{KD:\/u1:(\w+):a\}\}/]
    em_open = unit.source[/\{\{KD:#{unit.id}:(n\d+):em\}\}/]
    em_close = unit.source[/\{\{KD:\/u1:(\w+):em\}\}/]
    reordered = "Read #{link_open}#{em_open}good#{em_close} the guide#{link_close} now."
    package.translate(unit.id, reordered)
    package.apply!
    assert_includes document.to_html,
                    '<a href="http://x.test"><em>good</em> the guide</a>'
  end

  it 'protects math expressions and code spans verbatim' do
    source = "Sum $$a^2+b^2$$ with `x = 1` end"
    package = extract(source)
    unit = package.units.first
    assert_includes unit.source, ':math}'
    assert_includes unit.source, ':codespan}'
    document = Kramdown::Document.new(source, math_engine: :mathjax)
    same = Kramdown::Translation.extract(document)
    document.apply_translations(same.units.each_with_object({}) do |u, h|
      h[u.id] = u.source
    end)
    html = document.to_html
    assert_includes html, 'a^2+b^2'
    assert_includes html, '<code>x = 1</code>'
  end

  it 'supports multi-segment list items with separators' do
    source = "- first *a*\n\n  second `c`\n\n  - nested $$z$$\n"
    package = extract(source)
    outer, inner = package.units
    assert_equal(:list_item, outer.type)
    assert_equal(:list_item, inner.type)
    assert_equal(1, outer.source.scan(/:separator\}/).length)
    assert_equal(1, inner.source.scan(/:math\}/).length)

    document = Kramdown::Document.new(source)
    same = Kramdown::Translation.extract(document)
    translations = same.units.each_with_object({}) {|u, h| h[u.id] = u.source }
    document.apply_translations(translations)
    assert_equal(Kramdown::Document.new(source).to_html, document.to_html)
  end

  it 'leaves code blocks and block math untouched and requires all translations' do
    source = "Text *a*.\n\n    x = 1\n\n$$\nE = mc^2\n$$\n"
    document = Kramdown::Document.new(source)
    package = Kramdown::Translation.extract(document)
    assert_equal(%i[paragraph], package.units.map(&:type))
    before = document.to_html
    error = assert_raises(Kramdown::Translation::Error) { package.apply! }
    assert_includes error.message, package.units.first.id
    assert_equal before, document.to_html

    package.translate(package.units.first.id, package.units.first.source)
    package.apply!
    html = document.to_html
    assert_includes html, 'x = 1'
    assert_includes html, 'E = mc^2'
    assert_includes html, '<em>a</em>'
  end

  it 'exposes the convenience Document API' do
    document = Kramdown::Document.new('Hello *world*')
    package = document.translation_package
    document.apply_translations(package.units.first.id => package.units.first.source)
    assert_includes document.to_html, '<p>Hello <em>world</em></p>'
  end

  it 'rejects an atomic placeholder used with a closing token' do
    source = 'a `c` b'
    package, document, before, unit = invalid_translation_for(source) do |unit_source|
      node = unit_source[/n(\d+):codespan/, 1]
      "a {{KD:/u1:n#{node}:codespan}} b"
    end
    error = assert_raises(Kramdown::Translation::Error) { package.apply! }
    assert_includes error.message, unit.id
    assert_match(/without an open placeholder/, error.message)
    assert_equal before, document.to_html
  end

  def invalid_translation_for(source)
    document = Kramdown::Document.new(source)
    package = Kramdown::Translation.extract(document)
    before = document.to_html
    unit = package.units.first
    package.units.each {|u| package.translate(u.id, u.source) }
    package.translate(unit.id, yield(unit.source))
    [package, document, before, unit]
  end

  it 'rejects a missing closing placeholder, locates the unit and writes nothing' do
    package, document, before, unit = invalid_translation_for(LINK_DOC) do |source|
      source.sub(/\{\{KD:\/u1:n\d+:em\}\}/, '')
    end
    error = assert_raises(Kramdown::Translation::Error) { package.apply! }
    assert_includes error.message, unit.id
    assert_includes error.message, 'line 1'
    assert_equal before, document.to_html
  end

  it 'rejects a duplicated code placeholder' do
    package, document, before, unit = invalid_translation_for(LINK_DOC) do |source|
      code = source[/\{\{KD:u1:n\d+:codespan\}\}/]
      source + code
    end
    error = assert_raises(Kramdown::Translation::Error) { package.apply! }
    assert_includes error.message, unit.id
    assert_match(/more than once/, error.message)
    assert_equal before, document.to_html
  end

  it 'rejects placeholders taken from another unit' do
    foreign_package = extract(LINK_DOC)
    foreign_link = foreign_package.units.last.source[/\{\{KD:u2:(n\d+):a\}\}/]
    package, document, before, unit = invalid_translation_for(LINK_DOC) do |source|
      source.sub(/\{\{KD:u1:n\d+:codespan\}\}/, foreign_link)
    end
    error = assert_raises(Kramdown::Translation::Error) { package.apply! }
    assert_includes error.message, unit.id
    assert_match(/belongs to unit u2/, error.message)
    assert_equal before, document.to_html
  end

  it 'rejects links nested inside links' do
    source = 'A [one](u) [two](v) c.'
    package, document, before, unit = invalid_translation_for(source) do |unit_source|
      first_open = unit_source[/\{\{KD:u1:(n\d+):a\}\}/]
      first_close = unit_source[/\{\{KD:\/u1:n\d+:a\}\}/]
      second_open = unit_source[/(?=\{\{KD:u1:n\d+:a\}\}).*?(\{\{KD:u1:n\d+:a\}\})/m, 1]
      second_close = unit_source.scan(/\{\{KD:\/u1:n\d+:a\}\}/).last
      "A #{first_open}x #{second_open}y#{second_close}#{first_close} c."
    end
    error = assert_raises(Kramdown::Translation::Error) { package.apply! }
    assert_includes error.message, unit.id
    assert_match(/not allowed directly inside a/, error.message)
    assert_equal before, document.to_html
  end

  it 'rejects translations missing required placeholders' do
    package, document, before, unit = invalid_translation_for(LINK_DOC) do |unit_source|
      unit_source.gsub(/\{\{KD:\/?u1:n\d+:[a-z_]+\}\}/, '')
    end
    error = assert_raises(Kramdown::Translation::Error) { package.apply! }
    assert_includes error.message, unit.id
    assert_match(/missing/, error.message)
    assert_equal before, document.to_html
  end
end
