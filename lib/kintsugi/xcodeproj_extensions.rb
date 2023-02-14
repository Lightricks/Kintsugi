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
      # Modifies `PBXContainerItemProxy` to include relevant data in `displayName`.
      # Currently, its `display_name` is just a constant for all `PBXContainerItemProxy` objects.
      class PBXContainerItemProxy
        def display_name
          "#{self.remote_info} (#{self.remote_global_id_string})"
        end
      end

      # Modifies `PBXReferenceProxy` to include more data in `displayName` to make it unique.
      class PBXReferenceProxy
        @@old_display_name = instance_method(:display_name)

        def display_name
          if self.remote_ref.nil?
            @@old_display_name.bind(self).call
          else
            @@old_display_name.bind(self).call + " - " + self.remote_ref.display_name
          end
        end
      end

      # Modifies `PBXBuildFile` to calculate `ascii_plist_annotation` based on the underlying
      # object's `ascii_plist_annotation` instead of relying on its `display_name`, as
      # `display_name` might contain information that shouldn't be written to the project.
      class PBXBuildFile
        def ascii_plist_annotation
          underlying_annotation =
            if product_ref
              product_ref.ascii_plist_annotation
            elsif file_ref
              file_ref.ascii_plist_annotation
            else
              super
            end

          " #{underlying_annotation.strip} in #{GroupableHelper.parent(self).display_name} "
        end
      end

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

  module Differ
      # Replaces the implementation of `array_diff` with an implementation that takes into account
      # the number of occurrences an element is found in the array.
      # Code was mostly copied from https://github.com/CocoaPods/Xcodeproj/blob/51fb78a03f31614103815ce21c56dc25c044a10d/lib/xcodeproj/differ.rb#L111
      def self.array_diff(value_1, value_2, options)
      ensure_class(value_1, Array)
      ensure_class(value_2, Array)
      return nil if value_1 == value_2

      new_objects_value_1 = array_non_unique_diff(value_1, value_2)
      new_objects_value_2 = array_non_unique_diff(value_2, value_1)
      return nil if value_1.empty? && value_2.empty?

      matched_diff = {}
      if id_key = options[:id_key]
        matched_value_1 = []
        matched_value_2 = []
        new_objects_value_1.each do |entry_value_1|
          if entry_value_1.is_a?(Hash)
            id_value = entry_value_1[id_key]
            entry_value_2 = new_objects_value_2.find do |entry|
              entry[id_key] == id_value
            end
            if entry_value_2
              matched_value_1 << entry_value_1
              matched_value_2 << entry_value_2
              diff = diff(entry_value_1, entry_value_2, options)
              matched_diff[id_value] = diff if diff
            end
          end
        end

        new_objects_value_1 -= matched_value_1
        new_objects_value_2 -= matched_value_2
      end

      if new_objects_value_1.empty? && new_objects_value_2.empty?
        if matched_diff.empty?
          nil
        else
          matched_diff
        end
      else
        result = {}
        result[options[:key_1]] = new_objects_value_1 unless new_objects_value_1.empty?
        result[options[:key_2]] = new_objects_value_2 unless new_objects_value_2.empty?
        result[:diff] = matched_diff unless matched_diff.empty?
        result
      end
    end

    # Returns the difference between two arrays, taking into account the number of occurrences an
    # element is found in both arrays.
    #
    # @param  [Array] value_1
    #         First array to the difference operation.
    #
    # @param  [Array] value_2
    #         Second array to the difference operation.
    #
    # @return [Array]
    #
    def self.array_non_unique_diff(value_1, value_2)
      value_2_elements_by_count = value_2.reduce({}) do |hash, element|
        updated_element_hash = hash.key?(element) ? {element => hash[element] + 1} : {element => 1}
        hash.merge(updated_element_hash)
      end

      value_1_elements_by_deletions =
        value_1.to_set.map do |element|
          times_to_delete_element = value_2_elements_by_count[element] || 0
          [element, times_to_delete_element]
        end.to_h

      value_1.select do |element|
        if value_1_elements_by_deletions[element].positive?
          value_1_elements_by_deletions[element] -= 1
          next false
        end
        next true
      end
    end
  end
end
