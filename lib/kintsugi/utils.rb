# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

class Array
  # Provides a deep clone of `self`
  #
  # @return [Array]
  def deep_clone
    map do |value|
      begin
        value.deep_clone
      rescue NoMethodError
        value.clone
      end
    rescue NoMethodError
      value
    end
  end
end

class Hash
  # Provides a deep clone of `self`
  #
  # @return [Hash]
  def deep_clone
    transform_values do |value|
      begin
        value.deep_clone
      rescue NoMethodError
        value.clone
      end
    rescue NoMethodError
      value
    end
  end
end
