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

    module Object
      # Extends `XCBuildConfiguration` to convert array settings (which might be either array or
      # string) to actual arrays in `to_tree_hash` so diffs are always between arrays. This means
      # that if the values in both `ours` and `theirs` are different strings, we will know to solve
      # the conflict into an array containing both strings.
      # Code was mostly copied from https://github.com/CocoaPods/Xcodeproj/blob/master/lib/xcodeproj/project/object/build_configuration.rb#L211
      class XCBuildConfiguration
        @@old_to_tree_hash = instance_method(:to_tree_hash)

        def to_tree_hash
          @@old_to_tree_hash.bind(self).call.tap do |hash|
            convert_array_settings_to_arrays(hash['buildSettings'])
          end
        end

        def convert_array_settings_to_arrays(settings)
          return unless settings

          array_settings = BuildSettingsArraySettingsByObjectVersion[project.object_version]

          settings.each_key do |key|
            value = settings[key]
            next unless value.is_a?(String)

            stripped_key = key.sub(/\[[^\]]+\]$/, '')
            next unless array_settings.include?(stripped_key)

            array_value = split_string_setting_into_array(value)
            settings[key] = array_value
          end
        end

        def split_string_setting_into_array(string)
          string.scan(/ *((['"]?).*?[^\\]\2)(?=( |\z))/).map(&:first)
        end
      end
    end
  end
end
