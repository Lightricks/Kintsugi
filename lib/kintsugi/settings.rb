# Copyright (c) 2022 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

module Kintsugi
  # Kintsugi global settings.
  class Settings
    class << self
      # `true` if Kintsugi can create a component that's identical to an existing one, `false`
      # otherwise.
      attr_writer :allow_duplicates

      def allow_duplicates
        @allow_duplicates || false
      end
    end
  end
end
