# frozen_string_literal: true

require 'digest'

class Kramdown::StructuralDiff::Inline
  LEAF_TYPES = %i[text raw_text codespan math entity typographic_sym smart_quote br].freeze
  REGION_TYPES = %i[codespan math].freeze

  def self.text(element)
    case element.type
    when :text, :raw_text
      element.value.to_s
    when :codespan
      element.value.to_s
    when :math
      element.value.to_s
    when :br
      "\n"
    when :entity
      element.value.is_a?(Array) ? element.value.first.to_s : element.value.to_s
    when :smart_quote
      "'"
    when :typographic_sym
      element.value.to_s
    else
      element.children.map { |child| text(child) }.join
    end
  end

  def self.normalize_text(value)
    value.to_s.gsub(/[[:space:]]+/, ' ')
  end

  def self.region?(element)
    REGION_TYPES.include?(element.type)
  end

  def self.leaf?(element)
    LEAF_TYPES.include?(element.type)
  end

  def self.node_key(element)
    case element.type
    when :text, :raw_text
      [:text, normalize_text(text(element)).strip]
    when :codespan, :math
      [element.type, element.value]
    when :a, :img
      target = element.attr[element.type == :a ? 'href' : 'src']
      [element.type, normalize_text(text(element)).strip, children_key(element), target]
    else
      [element.type, normalize_text(text(element)).strip, children_key(element)]
    end
  end

  def self.children_key(element)
    element.children.map { |child| node_key(child) }
  end

end
