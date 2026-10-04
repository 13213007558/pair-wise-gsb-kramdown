# frozen_string_literal: true

class Kramdown::StructuralDiff::Block
  attr_accessor :id, :ast, :type, :parent, :children, :depth, :ordinal,
                :start_line, :end_line, :ambiguous

  def initialize(ast, type, parent, depth, ordinal)
    @ast = ast
    @type = type
    @parent = parent
    @depth = depth
    @ordinal = ordinal
    @children = []
    @start_line = ast.options[:location]
    @ambiguous = false
  end

  def self.build(root_ast, prefix)
    nodes = build_children(root_ast.children, nil, 0, prefix)
    all_nodes = flatten(nodes)
    assign_ranges(nodes, root_ast.options[:location] || 1, largest_location(root_ast))
    all_nodes
  end

  def list?
    type == :ul || type == :ol
  end

  def list_item?
    type == :li
  end

  def paragraph?
    type == :p || type == :header
  end

  def text
    Kramdown::StructuralDiff::Inline.text(ast).gsub(/[[:space:]]+/, ' ').strip
  end

  def own_text
    first_paragraph_key
  end

  def semantic_key
    if list_item?
      key_parts = [:li, first_paragraph_key, marker_kind]
    elsif type == :a || type == :img
      key_parts = [type, text, children.map(&:semantic_key)]
    else
      key_parts = [type, text, children.map(&:semantic_key)]
    end
    require 'digest'
    Digest::SHA256.hexdigest(key_parts.inspect)
  end

  def own_semantic_key
    key_parts = [type, own_text, marker_kind]
    require 'digest'
    Digest::SHA256.hexdigest(key_parts.inspect)
  end

  def marker_kind
    parent&.type == :ol ? '1.' : (list_item? ? '-' : nil)
  end

  def first_paragraph_key
    paragraph = ast.children.find { |child| child.type == :p || child.type == :header }
    return '' unless paragraph
    Kramdown::StructuralDiff::Inline
      .text(paragraph)
      .gsub(/[[:space:]]+/, ' ')
      .strip
  end

  def self.largest_location(element)
    element.children.reduce(element.options[:location] || 1) do |maximum, child|
      [maximum, largest_location(child)].max
    end
  end

  def self.assign_ranges(nodes, parent_start, parent_end)
    nodes.each_with_index do |node, index|
      node.start_line ||= parent_start
      next_location = nodes[index + 1]&.start_line
      node.end_line = if next_location
                        [next_location - 1, parent_end].min
                      else
                        parent_end
                      end
      node.end_line = [largest_location(node.ast), node.start_line].max if node.end_line < node.start_line
      assign_ranges(node.children, node.start_line, node.end_line)

      descendants = flatten(node.children)
      node.end_line = descendants.map(&:end_line).max if descendants.any?
      node.end_line = parent_end if node.end_line > parent_end
    end
  end

  def self.flatten(nodes)
    nodes.flat_map { |node| [node, *flatten(node.children)] }
  end

  def self.build_children(elements, parent, depth, prefix)
    ordinal_by_parent = Hash.new(0)
    elements.each_with_object([]) do |element, blocks|
      next unless include?(element)

      child_depth = depth + (element.type == :li ? 1 : 0)
      node = new(element, element.type, parent, child_depth, ordinal_by_parent[[parent, element.type]])
      ordinal_by_parent[[parent, element.type]] += 1
      node.id = build_id(node, prefix)
      node.children = build_children(children_of(element), node, node.depth, prefix)
      blocks << node
    end
  end

  def self.include?(element)
    element.options[:location] && !%i[blank eob temp].include?(element.type)
  end

  def self.children_of(element)
    case element.type
    when :ul, :ol, :blockquote, :li, :td, :th, :dd
      element.children.reject { |child| child.type == :blank }
    else
      []
    end
  end

  def self.build_id(node, prefix)
    parts = []
    current = node
    while current
      parts.unshift("#{current.type}[#{current.ordinal}]")
      current = current.parent
    end
    "#{prefix}:#{parts.join('/')}"
  end

  private_class_method :build_children, :include?, :children_of, :build_id
end
