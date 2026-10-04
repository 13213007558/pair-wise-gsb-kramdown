# frozen_string_literal: true

require 'kramdown'
require 'set'
require 'digest'

module Kramdown
  # Structural Markdown diffing.
  #
  # This API compares two Markdown documents through their block and inline syntax trees instead
  # of comparing raw lines. The returned change tree attributes every change to matched old/new
  # blocks and includes half-open source ranges for both documents.
  #
  # Equal blocks occurring more than once are never arbitrarily paired as a move. Their unresolved
  # identities are returned in +ambiguous_identities+. Code blocks, code spans and math nodes are
  # compared as opaque regions, so Markdown punctuation inside them is never parsed as a link or a
  # list.
  #
  # Set +ignore_formatting:+ to omit soft wrapping and other whitespace-only presentation changes.
  module StructuralDiff
    autoload :Block, 'kramdown/structural_diff/block'
    autoload :ChangeBuilder, 'kramdown/structural_diff/change_builder'
    autoload :Differ, 'kramdown/structural_diff/differ'
    autoload :Inline, 'kramdown/structural_diff/inline'
    autoload :InlineLocator, 'kramdown/structural_diff/inline_locator'
    autoload :LineMap, 'kramdown/structural_diff/line_map'
    autoload :Matcher, 'kramdown/structural_diff/matcher'

    Result = Struct.new(:old_source, :new_source, :changes, :ambiguous_identities,
                        keyword_init: true)

    # Return a structural diff for +old_source+ and +new_source+.
    def self.diff(old_source, new_source, ignore_formatting: false)
      Differ.new(old_source, new_source, ignore_formatting: ignore_formatting).call
    end
  end
end
