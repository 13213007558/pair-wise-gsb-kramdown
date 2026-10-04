# frozen_string_literal: true

class Kramdown::StructuralDiff::ChangeBuilder
  Change = Struct.new(:kind, :old_block_id, :new_block_id, :old_range, :new_range,
                      :details, :changes, keyword_init: true) do
    def to_h
      result = { kind: kind }
      result[:old_block_id] = old_block_id if old_block_id
      result[:new_block_id] = new_block_id if new_block_id
      result[:old_range] = range_hash(old_range) if old_range
      result[:new_range] = range_hash(new_range) if new_range
      result[:details] = details unless details.nil? || details.empty?
      result[:changes] = changes.map(&:to_h) if changes
      result
    end

    private

    def range_hash(range)
      return nil unless range
      {
        start_line: range.start_line,
        start_column: range.start_column,
        end_line: range.end_line,
        end_column: range.end_column,
        start_index: range.start_index,
        end_index: range.end_index
      }
    end
  end

  def initialize(old_map, new_map, matches, ambiguous_identities, ignore_formatting)
    @old_map = old_map
    @new_map = new_map
    @matches = matches
    @ambiguous_identities = ambiguous_identities
    @ignore_formatting = ignore_formatting
  end

  def call(old_blocks, new_blocks)
    matched_by_old = @matches.to_h { |match| [match.old.id, match] }
    matched_by_new = @matches.to_h { |match| [match.new.id, match] }
    changes = matched_changes(old_blocks, matched_by_old)
    changes.concat(unmatched_changes(old_blocks, matched_by_old, :deleted, @matches))
    changes.concat(unmatched_changes(new_blocks, matched_by_new, :inserted, @matches))
    changes.sort_by { |change| [change.old_range&.start_line || Float::INFINITY,
                               change.new_range&.start_line || Float::INFINITY,
                               change.kind.to_s] }
  end

  private

  def matched_changes(blocks, matched_by_old)
    matched_by_old.values.filter_map do |match|
      next if matched_internal_list_part?(match.old, match.new)
      build_matched_change(match)
    end
  end

  def unmatched_changes(blocks, matched, kind, all_matches)
    blocks.filter_map do |block|
      next if matched.key?(block.id)
      next if kind == :deleted && matched_descendant?(block, matched)
      next if matched_ancestor?(block, kind, all_matches)

      map = kind == :deleted ? @old_map : @new_map
      range = map.range(block.start_line, block.end_line)
      details = {}
      details[:block_type] = block.type
      details[:identity_ambiguous] = true if ambiguous_block?(block)
      Change.new(kind: kind,
                 old_block_id: kind == :deleted ? block.id : nil,
                 new_block_id: kind == :inserted ? block.id : nil,
                 old_range: kind == :deleted ? range : nil,
                 new_range: kind == :inserted ? range : nil,
                 details: details)
    end
  end

  def matched_descendant?(block, matched)
    descendants = Kramdown::StructuralDiff::Block.flatten(block.children)
    descendants.any? { |descendant| matched.key?(descendant.id) }
  end

  def matched_ancestor?(block, kind, matched)
    current = block.parent
    while current
      return true if kind == :deleted && matched_by_old?(current, matched)
      return true if kind == :inserted && matched_by_new?(current, matched)
      current = current.parent
    end
    false
  end

  def matched_by_old?(block, matched)
    matched.any? { |match| match.old.id == block.id }
  end

  def matched_by_new?(block, matched)
    matched.any? { |match| match.new.id == block.id }
  end

  def internal_list_part?(block)
    block.paragraph? && list_item_ancestor?(block)
  end

  def matched_internal_list_part?(old_block, new_block)
    internal_list_part?(old_block) && internal_list_part?(new_block)
  end

  def list_item_ancestor?(block)
    current = block.parent
    while current
      return true if current.list_item?
      current = current.parent
    end
    false
  end

  def build_matched_change(match)
    old_block = match.old
    new_block = match.new
    structural = structural_change(old_block, new_block)
    content = content_changes(old_block, new_block)
    return nil if structural.nil? && content.empty?

    Change.new(
      kind: :block_changed,
      old_block_id: old_block.id,
      new_block_id: new_block.id,
      old_range: @old_map.range(old_block.start_line, old_block.end_line),
      new_range: @new_map.range(new_block.start_line, new_block.end_line),
      details: structural || {},
      changes: content
    )
  end

  def structural_change(old_block, new_block)
    unless old_block.list_item? && new_block.list_item?
      return generic_block_moved?(old_block, new_block) ? { block_moved: true } : nil
    end
    moved = block_moved?(old_block, new_block)
    level_changed = old_block.depth != new_block.depth
    return nil unless moved || level_changed

    details = {
      old_level: old_block.depth,
      new_level: new_block.depth,
      old_position: position_details(old_block),
      new_position: position_details(new_block)
    }
    details[:block_moved] = true if moved
    details[:list_level_changed] = true if level_changed
    details[:identity_ambiguous] = true if old_block.ambiguous || new_block.ambiguous
    details
  end

  def generic_block_moved?(old_block, new_block)
    old_parent = old_block.parent ? old_block.parent.id : nil
    new_parent = new_block.parent ? new_block.parent.id : nil
    old_parent != new_parent ||
      old_block.start_line != new_block.start_line ||
      old_block.ordinal != new_block.ordinal
  end

  def block_moved?(old_block, new_block)
    old_parent_id = old_block.parent && relative_id(old_block.parent.id)
    new_parent_id = new_block.parent && relative_id(new_block.parent.id)
    return true if old_parent_id != new_parent_id
    old_previous = previous_sibling(old_block)
    new_previous = previous_sibling(new_block)
    return new_block.ordinal != 0 if old_previous.nil?
    return true if new_previous.nil?
    match = @matches.find { |candidate| candidate.old.id == old_previous.id }
    match.nil? || match.new.id != new_previous.id
  end

  def relative_id(id)
    id.sub(/\A(?:old|new):/, '')
  end

  def previous_sibling(block)
    return nil unless block.parent
    block.parent.children[block.parent.children.index(block) - 1]
  end

  def position_details(block)
    {
      ordinal: block.ordinal,
      level: block.depth,
      parent_id: block.parent&.id
    }
  end

  def content_changes(old_block, new_block)
    case old_block.type
    when :p, :header, :li
      paragraph_changes(old_block, new_block)
    when :codeblock, :math
      region_changes(old_block, new_block)
    else
      []
    end
  end

  def paragraph_elements(block)
    block.ast.children.select { |child| child.type == :p || child.type == :header }
  end

  def paragraph_node(block)
    return block.ast if block.paragraph?
    paragraph_elements(block).first
  end

  def paragraph_changes(old_block, new_block)
    old_paragraph = paragraph_node(old_block)
    new_paragraph = paragraph_node(new_block)
    return [] unless old_paragraph && new_paragraph
    old_raw, old_start, _old_leading = block_raw(old_block, @old_map)
    new_raw, new_start, _new_leading = block_raw(new_block, @new_map)
    old_locator = Kramdown::StructuralDiff::InlineLocator.new(@old_map, old_raw, old_start)
    new_locator = Kramdown::StructuralDiff::InlineLocator.new(@new_map, new_raw, new_start)
    old_nodes, old_targets = old_locator.locate(old_paragraph.children)
    new_nodes, new_targets = new_locator.locate(new_paragraph.children)

    changes = compare_sequences(old_paragraph.children, new_paragraph.children,
                                old_nodes, new_nodes, old_targets, new_targets)
    changes = changes.reject { |change| change.kind == :formatting_only } if @ignore_formatting
    changes
  end

  def block_raw(block, map)
    Kramdown::StructuralDiff::InlineLocator.block_raw(block, map)
  end

  def compare_sequences(old_elements, new_elements, old_nodes, new_nodes, old_targets, new_targets)
    pairs = lcs_pairs(old_elements, new_elements) do |old_element, new_element|
      inline_score(old_element, new_element)
    end

    old_indexes = pairs.map(&:first)
    new_indexes = pairs.map(&:last)
    changes = []
    old_elements.each_with_index do |element, index|
      next if old_indexes.include?(index)
      changes << inline_change(:inline_deleted, element, nodes: old_nodes, targets: old_targets)
    end
    new_elements.each_with_index do |element, index|
      next if new_indexes.include?(index)
      changes << inline_change(:inline_inserted, element, nodes: new_nodes, targets: new_targets)
    end
    pairs.each do |old_index, new_index|
      changes.concat(compare_inline(old_elements[old_index], new_elements[new_index],
                                    old_nodes, new_nodes, old_targets, new_targets))
    end
    changes
  end

  def inline_score(old_element, new_element)
    return nil if old_element.type != new_element.type
    if Kramdown::StructuralDiff::Inline.region?(old_element)
      old_element.value == new_element.value ? 1 : 0.7
    elsif old_element.type == :a || old_element.type == :img
      target = old_element.type == :a ? 'href' : 'src'
      same_text = Kramdown::StructuralDiff::Inline.text(old_element) ==
                  Kramdown::StructuralDiff::Inline.text(new_element)
      same_text && old_element.attr[target] == new_element.attr[target] ? 1 : 0.8
    else
      0.75
    end
  end

  def compare_inline(old_element, new_element, old_nodes, new_nodes, old_targets, new_targets)
    if Kramdown::StructuralDiff::Inline.region?(old_element)
      return old_element.value == new_element.value ? [] : [
        region_change(old_element, new_element, old_nodes, new_nodes)
      ]
    end

    changes = target_changes(old_element, new_element, old_targets, new_targets)
    if leaf_text?(old_element)
      changes.concat(text_changes(old_element, new_element, old_nodes, new_nodes))
    else
      changes.concat(compare_sequences(old_element.children, new_element.children,
                                       old_nodes, new_nodes, old_targets, new_targets))
    end
    changes
  end

  def target_changes(old_element, new_element, old_targets, new_targets)
    return [] unless old_element.type == new_element.type && %i[a img].include?(old_element.type)
    target_name = old_element.type == :a ? 'href' : 'src'
    old_target = old_element.attr[target_name]
    new_target = new_element.attr[target_name]
    return [] if old_target == new_target

    [Change.new(kind: :link_target_changed,
                old_range: old_targets[old_element.object_id],
                new_range: new_targets[new_element.object_id],
                details: { old_target: old_target, new_target: new_target })]
  end

  def text_changes(old_element, new_element, old_nodes, new_nodes)
    old_value = old_element.value.to_s.gsub(/[[:space:]]+\z/, '')
    new_value = new_element.value.to_s.gsub(/[[:space:]]+\z/, '')
    return [] if old_value == new_value

    if old_value.gsub(/[[:space:]]+/, ' ') == new_value.gsub(/[[:space:]]+/, ' ')
      [Change.new(kind: :formatting_only,
                  old_range: old_nodes[old_element.object_id],
                  new_range: new_nodes[new_element.object_id],
                  details: { reason: 'whitespace' })]
    else
      [Change.new(kind: :paragraph_content_changed,
                  old_range: old_nodes[old_element.object_id],
                  new_range: new_nodes[new_element.object_id],
                  details: { old_text: old_value, new_text: new_value })]
    end
  end

  def region_change(old_element, new_element, old_nodes, new_nodes)
    Change.new(kind: :region_content_changed,
                old_range: old_nodes[old_element.object_id] || element_fallback_range(@old_map, old_element),
                new_range: new_nodes[new_element.object_id] || element_fallback_range(@new_map, new_element),
                details: { region: old_element.type, old_text: old_element.value,
                           new_text: new_element.value })
  end

  def region_changes(old_block, new_block)
    return [] if old_block.ast.value == new_block.ast.value
    kind = old_block.type == :codeblock ? :codeblock : :math
    old_range, new_range = region_block_ranges(old_block, new_block)
    [Change.new(kind: :region_content_changed,
                old_range: old_range,
                new_range: new_range,
                details: { region: kind,
                           old_text: old_block.ast.value,
                           new_text: new_block.ast.value })]
  end

  def region_block_ranges(old_block, new_block)
    if old_block.type == :codeblock && old_block.ast.options[:fenced]
      [@old_map.range(old_block.start_line + 1, old_block.end_line - 1),
       @new_map.range(new_block.start_line + 1, new_block.end_line - 1)]
    elsif old_block.type == :math
      [math_content_range(@old_map, old_block), math_content_range(@new_map, new_block)]
    else
      [@old_map.range(old_block.start_line, old_block.end_line),
       @new_map.range(new_block.start_line, new_block.end_line)]
    end
  end

  def math_content_range(map, block)
    block_range = map.range(block.start_line, block.end_line)
    source = map.source[block_range.start_index...block_range.end_index]
    offset = source.index(block.ast.value)
    return block_range unless offset
    start_index = block_range.start_index + offset
    end_index = start_index + block.ast.value.length
    line_map = map
    start_line = line_map.starts.rindex { |start| start <= start_index } + 1
    end_line = line_map.starts.rindex { |start| start <= end_index } + 1
    line_map.range(start_line, end_line,
                   start_index - line_map.starts[start_line - 1] + 1,
                   end_index - line_map.starts[end_line - 1] + 1)
  end

  def element_fallback_range(map, element)
    line = element.options[:location]
    map.range(line)
  end

  def leaf_text?(element)
    %i[text raw_text].include?(element.type)
  end

  def inline_change(kind, element, nodes:, targets:)
    Change.new(kind: kind,
               old_range: kind == :inline_deleted ? nodes[element.object_id] : nil,
               new_range: kind == :inline_inserted ? nodes[element.object_id] : nil,
               details: { node_type: element.type,
                          target: element.attr[element.type == :a ? 'href' : 'src'] } )
  end

  def lcs_pairs(old_elements, new_elements)
    scores = Array.new(old_elements.length) { Array.new(new_elements.length) }
    old_elements.each_with_index do |old_element, old_index|
      new_elements.each_with_index do |new_element, new_index|
        scores[old_index][new_index] = yield(old_element, new_element)
      end
    end
    dp = Array.new(old_elements.length + 1) { Array.new(new_elements.length + 1, 0) }
    old_elements.length.times do |old_index|
      new_elements.length.times do |new_index|
        score = scores[old_index][new_index]
        dp[old_index + 1][new_index + 1] =
          if score
            [dp[old_index][new_index] + score,
             dp[old_index][new_index + 1],
             dp[old_index + 1][new_index]].max
          else
            [dp[old_index][new_index + 1], dp[old_index + 1][new_index]].max
          end
      end
    end
    backtrack_inline(scores, dp, old_elements.length, new_elements.length)
  end

  def backtrack_inline(scores, dp, old_count, new_count)
    return [] if old_count.zero? || new_count.zero?
    score = scores[old_count - 1][new_count - 1]
    if score && dp[old_count][new_count] == dp[old_count - 1][new_count - 1] + score
      [[old_count - 1, new_count - 1]] +
        backtrack_inline(scores, dp, old_count - 1, new_count - 1)
    elsif dp[old_count - 1][new_count] >= dp[old_count][new_count - 1]
      backtrack_inline(scores, dp, old_count - 1, new_count)
    else
      backtrack_inline(scores, dp, old_count, new_count - 1)
    end
  end

  def ambiguous_block?(block)
    @ambiguous_identities.include?(block.semantic_key) || block.ambiguous
  end
end
