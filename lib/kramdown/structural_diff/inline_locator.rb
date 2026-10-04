# frozen_string_literal: true

class Kramdown::StructuralDiff::InlineLocator
  Node = Struct.new(:range, :target_range, keyword_init: true)

  attr_reader :line_map

  def initialize(line_map, raw, start_line)
    @line_map = line_map
    @raw = raw
    @start_line = start_line
    @line_offsets = []
    offset = 0
    raw.lines.each do |line|
      @line_offsets << offset
      offset += line.length
    end
  end

  def self.block_raw(block, line_map)
    lines = (block.start_line..block.end_line).map { |line| line_map.lines[line - 1].to_s }
    sanitized = lines.map { |line| sanitize_line(line) }
    raw = sanitized.join("\n")
    leading = raw[/\A\s*/].to_s.length
    [raw.sub(/\A\s+/, ''), block.start_line, leading]
  end

  def self.sanitize_line(line)
    result = line.dup
    result.sub!(/\A(\s*)> ?/) { ' ' * Regexp.last_match(0).length }
    result.sub!(/\A(\s*)(?:[*+-]|\d+\.)(\s+)/) { ' ' * Regexp.last_match(0).length }
    result
  end

  def locate(elements)
    @nodes = {}
    @targets = {}
    locate_children(elements, 0)
    [@nodes, @targets]
  end

  private

  def locate_children(elements, position)
    @nodes ||= {}
    @targets ||= {}
    cursor = position
    elements.each do |element|
      range, cursor = locate_element(element, cursor)
      @nodes[element.object_id] ||= range if range
    end
    cursor
  end

  def locate_element(element, cursor)
    case element.type
    when :text, :raw_text
      locate_text(element, cursor)
    when :em, :strong
      marker = element.type == :strong ? /\*\*|__/ : /\*|_/
      locate_wrapper(element, cursor, marker)
    when :codespan
      delimiter = Regexp.escape(element.options[:codespan_delimiter] || 96.chr)
      locate_delimited_region(element, cursor, delimiter)
    when :math
      locate_delimited_region(element, cursor, Regexp.escape('$$'))
    when :a, :img
      locate_link(element, cursor)
    when :html_element
      locate_html(element, cursor)
    when :br
      range = range_for(cursor...[cursor + 1, @raw.length].min)
      [range, cursor + 1]
    else
      locate_container(element, cursor)
    end
  end

  def locate_text(element, cursor)
    words = element.value.to_s.scan(/\S+/)
    first = last = nil
    words.each do |word|
      simplified = word.sub(/[[:punct:]]+\z/, '')
      exact = @raw.index(Regexp.escape(word), cursor)
      simple = simplified == word ? nil : @raw.index(Regexp.escape(simplified), cursor)
      index = exact || simple
      break unless index
      found = exact == index ? word : simplified
      range = range_for(index...(index + found.length))
      first ||= range
      last = range
      cursor = index + found.length
    end
    [first ? join_ranges(first, last || first) : nil, cursor]
  end

  def locate_wrapper(element, cursor, marker_pattern)
    match = marker_pattern.match(@raw, cursor)
    return locate_container(element, cursor) unless match
    marker = match[0]
    ending = locate_children(element.children, match.end(0))
    closing = marker_pattern.match(@raw, ending)
    end_position = closing ? closing.end(0) : ending
    [range_for(match.begin(0)...end_position), end_position]
  end

  def locate_pattern(element, cursor, pattern)
    match = pattern.match(@raw, cursor)
    return locate_container(element, cursor) unless match
    [range_for(match.begin(0)...match.end(0)), match.end(0)]
  end

  def locate_delimited_region(element, cursor, delimiter_source)
    delimiter = /#{delimiter_source}/
    opening = delimiter.match(@raw, cursor)
    return locate_container(element, cursor) unless opening
    closing = delimiter.match(@raw, opening.end(0))
    return locate_container(element, cursor) unless closing
    inner = range_for(opening.end(0)...closing.begin(0))
    outer = range_for(opening.begin(0)...closing.end(0))
    @nodes[element.object_id] = inner
    [outer, closing.end(0)]
  end

  def locate_link(element, cursor)
    opening = element.type == :img ? /!\[/ : /\[/
    match = opening.match(@raw, cursor)
    match ||= /</.match(@raw, cursor)
    return locate_container(element, cursor) unless match

    end_position = locate_children(element.children, match.end(0))
    closing = link_end(match.begin(0))
    end_position = closing if closing
    range = range_for(match.begin(0)...end_position)
    record_target(element, match.begin(0), end_position)
    [range, end_position]
  end

  def locate_html(element, cursor)
    name = Regexp.escape(element.value.to_s)
    match = /<#{name}\b/i.match(@raw, cursor)
    return locate_container(element, cursor) unless match
    end_match = /<\/#{name}\s*>/mi.match(@raw, match.end(0))
    end_position = end_match ? end_match.end(0) : link_end(match.begin(0)) || @raw.length
    locate_children(element.children, match.end(0))
    [range_for(match.begin(0)...end_position), end_position]
  end

  def locate_container(element, cursor)
    return [nil, cursor] if element.children.empty?
    ending = locate_children(element.children, cursor)
    ranges = element.children.map { |child| @nodes[child.object_id] }.compact
    return [nil, ending] if ranges.empty?
    [join_ranges(ranges.first, ranges.last), ending]
  end

  def record_target(element, start, end_position)
    target = element.attr[element.type == :a ? 'href' : 'src']
    open_paren = @raw.index('(', start)
    close_paren = @raw.index(')', open_paren.to_i + 1)
    return unless target && open_paren && close_paren
    target_index = @raw.index(target, open_paren + 1)
    return unless target_index
    @targets[element.object_id] = range_for(target_index...(target_index + target.length))
  end

  def link_end(start)
    close = @raw.index(')', start)
    bracket = @raw.index(']', start)
    [close, bracket].compact.max
  end

  def join_ranges(first, last)
    @line_map.range(first.start_line, last.end_line, first.start_column, last.end_column)
  end

  def range_for(character_range)
    start = character_position(character_range.begin)
    finish = character_position(character_range.end)
    @line_map.range(start[:line], finish[:line], start[:column], finish[:column])
  end

  def character_position(offset)
    line_index = @line_offsets.rindex { |line_offset| line_offset <= offset } || 0
    { line: @start_line + line_index, column: offset - @line_offsets[line_index] + 1 }
  end
end
