# frozen_string_literal: true

class Kramdown::StructuralDiff::Differ
  def initialize(old_source, new_source, ignore_formatting: false)
    @old_source = old_source.to_s
    @new_source = new_source.to_s
    @ignore_formatting = ignore_formatting
  end

  def call
    old_map = Kramdown::StructuralDiff::LineMap.new(@old_source)
    new_map = Kramdown::StructuralDiff::LineMap.new(@new_source)
    old_doc = Kramdown::Document.new(old_map.source)
    new_doc = Kramdown::Document.new(new_map.source)
    old_blocks = Kramdown::StructuralDiff::Block.build(old_doc.root, 'old')
    new_blocks = Kramdown::StructuralDiff::Block.build(new_doc.root, 'new')
    matcher = Kramdown::StructuralDiff::Matcher.new(old_blocks, new_blocks)
    matches = matcher.call
    ambiguous = matcher.ambiguous_keys

    builder = Kramdown::StructuralDiff::ChangeBuilder.new(old_map, new_map, matches,
                                                          ambiguous, @ignore_formatting)
    changes = builder.call(old_blocks, new_blocks)
    identities = ambiguous_identities(ambiguous.to_a.uniq, old_blocks, new_blocks)

    Kramdown::StructuralDiff::Result.new(
      old_source: source_result(@old_source, old_map),
      new_source: source_result(@new_source, new_map),
      changes: changes.map(&:to_h),
      ambiguous_identities: identities
    )
  end

  private

  def source_result(original, map)
    {
      original: original,
      normalized: map.source,
      range: map.range(1, map.line_count).to_h
    }
  end

  def ambiguous_identities(keys, old_blocks, new_blocks)
    keys.filter_map do |key|
      old_matches = old_blocks.select { |block| block.semantic_key == key }
      new_matches = new_blocks.select { |block| block.semantic_key == key }
      next if old_matches.empty? || new_matches.empty?

      {
        semantic_key: key,
        old_block_ids: old_matches.map(&:id),
        new_block_ids: new_matches.map(&:id),
        text: old_matches.first.text
      }
    end
  end
end
