# frozen_string_literal: true

class Kramdown::StructuralDiff::Matcher
  Match = Struct.new(:old, :new, keyword_init: true)

  attr_reader :old_blocks, :new_blocks

  def initialize(old_blocks, new_blocks)
    @old_blocks = old_blocks
    @new_blocks = new_blocks
  end

  def call
    parent_pairs = collect_parent_pairs
    matches = container_matches(parent_pairs[1..])
    matches.concat(global_cross_parent_matches(matches))
    parent_pairs[1..].each do |old_parent, new_parent|
      matches.concat(match_parent(old_parent, new_parent, matches))
    end
    matches.concat(match_parent(parent_pairs[0][0], parent_pairs[0][1], matches))
    mark_ambiguous_matches(matches)
  end

  def ambiguous_keys
    keys = key_count(@old_blocks).select { |_key, count| count > 1 }.keys
    keys + key_count(@new_blocks).select { |_key, count| count > 1 }.keys
  end

  private

  def collect_parent_pairs
    pairs = [[nil, nil]]
    list_old = @old_blocks.find { |block| block.list? && block.parent.nil? }
    list_new = @new_blocks.find { |block| block.list? && block.parent.nil? }
    pairs << [list_old, list_new] if list_old && list_new
    pairs
  end

  def container_matches(pairs)
    pairs.filter_map do |old_parent, new_parent|
      next unless old_parent && new_parent && old_parent.type == new_parent.type
      Match.new(old: old_parent, new: new_parent)
    end
  end

  def match_parent(old_parent, new_parent, existing_matches)
    old_children = children_of(@old_blocks, old_parent)
    new_children = children_of(@new_blocks, new_parent)
    matches = []
    occupied_old = occupied_old_ids(existing_matches)
    occupied_new = occupied_new_ids(existing_matches)
    matches.concat(lcs_matches(
                    old_children.reject { |block| occupied_old.include?(block.id) },
                    new_children.reject { |block| occupied_new.include?(block.id) }
                  ) { |old_block, new_block| compatibility_score(old_block, new_block) })
    unique_matches(existing_matches + matches)
  end

  def global_cross_parent_matches(existing_matches)
    occupied_old = occupied_old_ids(existing_matches)
    occupied_new = occupied_new_ids(existing_matches)
    @old_blocks.filter_map do |old_block|
      next if occupied_old.include?(old_block.id) || !globally_unique?(old_block)
      candidates = @new_blocks.reject { |block| occupied_new.include?(block.id) }
                                        .select do |block|
        block.semantic_key == old_block.semantic_key && comparable_context?(old_block, block)
      end
      next unless candidates.length == 1
      Match.new(old: old_block, new: candidates.first)
    end
  end

  def occupied_old_ids(matches)
    matches.map { |match| match.old.id }.to_set
  end

  def occupied_new_ids(matches)
    matches.map { |match| match.new.id }.to_set
  end

  def globally_unique?(block)
    key_count(@old_blocks)[block.semantic_key].to_i == 1 &&
      key_count(@new_blocks)[block.semantic_key].to_i == 1
  end

  def lcs_matches(old_nodes, new_nodes)
    scores = Array.new(old_nodes.length) { Array.new(new_nodes.length) }
    old_nodes.each_with_index do |old_block, old_index|
      new_nodes.each_with_index do |new_block, new_index|
        scores[old_index][new_index] = yield(old_block, new_block)
      end
    end

    dp = Array.new(old_nodes.length + 1) { Array.new(new_nodes.length + 1, 0) }
    old_nodes.length.times do |old_index|
      new_nodes.length.times do |new_index|
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

    backtrack(scores, dp, old_nodes, new_nodes)
  end

  def backtrack(scores, dp, old_nodes, new_nodes, old_index = old_nodes.length,
                new_index = new_nodes.length)
    return [] if old_index.zero? || new_index.zero?

    score = scores[old_index - 1][new_index - 1]
    if score && dp[old_index][new_index] == dp[old_index - 1][new_index - 1] + score
      [Match.new(old: old_nodes[old_index - 1], new: new_nodes[new_index - 1])] +
        backtrack(scores, dp, old_nodes, new_nodes, old_index - 1, new_index - 1)
    elsif dp[old_index - 1][new_index] >= dp[old_index][new_index - 1]
      backtrack(scores, dp, old_nodes, new_nodes, old_index - 1, new_index)
    else
      backtrack(scores, dp, old_nodes, new_nodes, old_index, new_index - 1)
    end
  end

  def compatibility_score(old_block, new_block)
    return nil unless old_block.type == new_block.type
    return nil unless comparable_context?(old_block, new_block)
    return 1 if old_block.semantic_key == new_block.semantic_key
    return 0.7 if opaque_region?(old_block)
    if ambiguous_key?(old_block.semantic_key)
      return same_local_identity?(old_block, new_block) ? 0.99 : nil
    end

    candidates = new_blocks.select do |block|
      block.type == old_block.type && comparable_context?(old_block, block)
    end
    matching = candidates.filter_map do |block|
      similarity = text_similarity(old_block.text, block.text)
      similarity if similarity >= 0.35
    end
    old_candidates_count = @old_blocks.count do |block|
      block.type == new_block.type && comparable_context?(new_block, block) &&
        text_similarity(new_block.text, block.text) >= 0.35
    end
    matching.length == 1 && old_candidates_count == 1 ? matching.first : nil
  end

  def opaque_region?(block)
    return true if block.type == :codeblock
    block.type == :math && block.ast.options[:category] == :block
  end

  def same_local_identity?(old_block, new_block)
    old_block.parent&.id == new_block.parent&.id && old_block.ordinal == new_block.ordinal
  end

  def comparable_context?(old_block, new_block)
    old_context = context(old_block)
    new_context = context(new_block)
    return true if old_context.empty? && new_context.empty?
    old_context == new_context || old_block.type == :li || new_block.type == :li
  end

  def context(block)
    contexts = []
    current = block.parent
    while current
      contexts.unshift(current.type) unless current.list?
      current = current.parent
    end
    contexts
  end

  def text_similarity(old_text, new_text)
    return 1 if old_text == new_text
    return 0 if old_text.empty? || new_text.empty?
    old_bigrams = bigrams(old_text)
    new_bigrams = bigrams(new_text)
    return 0 if old_bigrams.empty? || new_bigrams.empty?
    overlap = old_bigrams.sum { |bigram, count| [count, new_bigrams[bigram].to_i].min }
    (2.0 * overlap) / (old_bigrams.values.sum + new_bigrams.values.sum)
  end

  def bigrams(value)
    value.each_char.each_cons(2).with_object(Hash.new(0)) { |pair, counts| counts[pair.join] += 1 }
  end

  def key_count(blocks)
    blocks.group_by(&:semantic_key).transform_values(&:length)
  end

  def children_of(blocks, parent)
    blocks.select { |block| parent.nil? ? block.parent.nil? : block.parent&.id == parent.id }
  end

  def unique_matches(matches)
    seen_old = Set.new
    seen_new = Set.new
    matches.select do |match|
      next false if seen_old.include?(match.old.id) || seen_new.include?(match.new.id)
      seen_old << match.old.id
      seen_new << match.new.id
    end
  end

  def ambiguous_key?(key)
    key_count(@old_blocks)[key].to_i > 1 || key_count(@new_blocks)[key].to_i > 1
  end


  def mark_ambiguous_matches(matches)
    matches.each do |match|
      match.old.ambiguous = true if ambiguous_key?(match.old.semantic_key)
      match.new.ambiguous = true if ambiguous_key?(match.new.semantic_key)
    end
    matches
  end
end
