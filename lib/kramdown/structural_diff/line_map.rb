# frozen_string_literal: true

class Kramdown::StructuralDiff::LineMap
  Range = Struct.new(:start_line, :start_column, :end_line, :end_column,
                     :start_index, :end_index, keyword_init: true)

  attr_reader :source, :lines, :starts

  def initialize(source)
    @source = source.to_s.gsub(/\r\n?/, "\n")
    @source = "#{@source.chomp}\n" unless @source.empty?
    @lines = @source.split("\n", -1)
    @starts = []
    offset = 0
    @lines.each do |line|
      @starts << offset
      offset += line.length + 1
    end
  end

  def range(start_line, end_line = start_line, start_column = 1, end_column = nil)
    start_line = [[1, start_line].max, @lines.length].min
    end_line = [[start_line, end_line].max, @lines.length].min
    start_column = [[1, start_column].max, line_length(start_line) + 1].min
    end_column ||= line_length(end_line) + 1
    end_column = [[1, end_column].max, line_length(end_line) + 1].min

    Range.new(
      start_line: start_line,
      start_column: start_column,
      end_line: end_line,
      end_column: end_column,
      start_index: @starts[start_line - 1] + start_column - 1,
      end_index: @starts[end_line - 1] + end_column - 1
    )
  end

  def slice(range)
    return nil if range.nil?
    @source[range.start_index...range.end_index]
  end

  def line_count
    @lines.length
  end

  def blank_line?(line)
    line >= 1 && line <= @lines.length && @lines[line - 1].strip.empty?
  end

  private

  def line_length(line)
    @lines[line - 1].length
  end
end
