# Copyright (c) 2021 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "xcodeproj"

module Xcodeproj
  class Project
    # Extends `ObjectDictionary` to act like an `Object` if `self` repreresents a project reference.
    class ObjectDictionary
      @@old_to_tree_hash = instance_method(:to_tree_hash)

      def to_tree_hash
        result = @@old_to_tree_hash.bind(self).call
        self[:project_ref] ? result.merge("displayName" => display_name) : result
      end

      def display_name
        project_ref.display_name
      end

      def product_group
        self[:product_group]
      end

      def project_ref
        self[:project_ref]
      end
    end
  end
end
