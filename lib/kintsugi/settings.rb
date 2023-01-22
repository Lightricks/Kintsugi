# Copyright (c) 2022 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

module Kintsugi
  # Kintsugi global settings.
  class Settings
    class << self
      # `true` if Kintsugi can create entities that are identical to existing ones, `false`
      # otherwise.
      attr_writer :allow_duplicates

      # `true` if Kintsugi should ask the user for guide on how to resolve some conflicts
      # interactively, `false` otherwise.
      attr_writer :interactive_resolution

      def allow_duplicates
        @allow_duplicates || false
      end

      def interactive_resolution
        @interactive_resolution.nil? ? $stdout.isatty : @interactive_resolution
      end
    end
  end
end
