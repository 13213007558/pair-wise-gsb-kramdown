# frozen_string_literal: true

require 'minitest/autorun'
require 'kramdown'

describe 'structural diff' do
  let(:fixture_dir) { File.join(__dir__, 'testcases', 'structural_diff') }
  let(:old_source) { File.read(File.join(fixture_dir, 'old.md')) }
  let(:new_source) { File.read(File.join(fixture_dir, 'new.md')) }
  let(:result) { Kramdown::StructuralDiff.diff(old_source, new_source) }

  def find_change(old_id:, new_id:)
    result.changes.find do |change|
      change[:old_block_id] == old_id && change[:new_block_id] == new_id
    end
  end

  it 'keeps duplicate block identity ambiguity instead of inventing a move' do
    duplicate = result.ambiguous_identities.find do |item|
      item[:text] == 'Repeat identity paragraph.'
    end

    assert_equal(%w[old:p[0] old:p[2]], duplicate[:old_block_ids])
    assert_equal(%w[new:p[0] new:p[2] new:p[4]], duplicate[:new_block_ids])

    inserted = result.changes.find { |change| change[:kind] == :inserted }
    assert_equal('new:p[4]', inserted[:new_block_id])
    assert_equal(true, inserted[:details][:identity_ambiguous])

    moved = result.changes.select { |change| change[:details]&.dig(:block_moved) }
    assert_equal(['Apple', 'Banana'], moved.map { |change| old_source_name(change) })
  end

  it 'reports list item move and hierarchy level with ranges on both sources' do
    apple = find_change(old_id: 'old:ul[0]/li[0]',
                        new_id: 'new:ul[0]/li[0]/ul[0]/li[0]')
    banana = find_change(old_id: 'old:ul[0]/li[1]', new_id: 'new:ul[0]/li[0]')
    cherry = find_change(old_id: 'old:ul[0]/li[2]', new_id: 'new:ul[0]/li[1]')

    assert_equal(true, apple[:details][:block_moved])
    assert_equal(true, apple[:details][:list_level_changed])
    assert_equal(1, apple[:details][:old_level])
    assert_equal(2, apple[:details][:new_level])
    assert_equal(3, apple[:old_range][:start_line])
    assert_equal(4, apple[:new_range][:start_line])

    assert_equal(true, banana[:details][:block_moved])
    assert_nil(banana[:details][:list_level_changed])
    assert_nil(cherry)
  end

  it 'attributes a standalone URL change to the containing paragraph' do
    paragraph = find_change(old_id: 'old:p[1]', new_id: 'new:p[1]')
    link = paragraph[:changes].first

    assert_equal(:link_target_changed, link[:kind])
    assert_equal('https://old.example/home', link[:details][:old_target])
    assert_equal('https://new.example/home', link[:details][:new_target])
    assert_equal('https://old.example/home',
                 old_source[link[:old_range][:start_index]...link[:old_range][:end_index]])
    assert_equal('https://new.example/home',
                 new_source[link[:new_range][:start_index]...link[:new_range][:end_index]])
  end

  it 'leaves Markdown symbols inside a code block unchanged' do
    code_block = result.changes.find do |change|
      change[:changes]&.any? { |child| child[:details]&.dig(:region) == :codeblock }
    end

    assert_nil(code_block)
  end

  it 'treats block math content as its own region' do
    math = result.changes.find do |change|
      change[:changes]&.any? { |child| child[:details]&.dig(:region) == :math }
    end
    region = math[:changes].first

    assert_equal('x+y',
                 old_source[region[:old_range][:start_index]...region[:old_range][:end_index]])
    assert_equal('x-y',
                 new_source[region[:new_range][:start_index]...region[:new_range][:end_index]])
  end

  it 'treats inline code and math as opaque inline regions' do
    old_inline = 'Prefix ' + 96.chr + 'a + [x](u)' + 96.chr + ' and $$x+y$$ suffix.'
    new_inline = 'Prefix ' + 96.chr + 'b + [x](u)' + 96.chr + ' and $$x-y$$ suffix.'
    diff = Kramdown::StructuralDiff.diff(old_inline, new_inline)
    kinds = diff.changes.flat_map { |change| change[:changes] || [] }
                     .flat_map { |child| child[:kind] || child[:changes]&.map { |item| item[:kind] } }
                     .compact
    regions = diff.changes.flat_map { |change| change[:changes] || [] }
                       .select { |child| child[:kind] == :region_content_changed }

    assert_includes(kinds, :region_content_changed)
    refute_includes(kinds, :link_target_changed)
    extracted = regions.map do |child|
      old_inline[child[:old_range][:start_index]...child[:old_range][:end_index]]
    end.sort
    assert_equal(['a + [x](u)', 'x+y'], extracted)
  end

  it 'exposes soft wrapping as formatting that callers can ignore' do
    wrapping = find_change(old_id: 'old:p[3]', new_id: 'new:p[3]')

    assert_equal(:formatting_only, wrapping[:changes].first[:kind])

    ignored = Kramdown::StructuralDiff.diff(old_source, new_source, ignore_formatting: true)
    formatting = ignored.changes.flat_map { |change| change[:changes] || [] }
                           .select { |child| child[:kind] == :formatting_only }

    assert_empty(formatting)
  end

  def old_source_name(change)
    range = change[:old_range]
    old_source.lines[range[:start_line] - 1].sub(/\A\s*[-*+]\s*/, '').strip
  end
end
