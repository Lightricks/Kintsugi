# Copyright (c) 2023 Lightricks. All rights reserved.
# Created by Ben Yohay.
# frozen_string_literal: true

require "tty-prompt"

module Kintsugi
  class ConflictResolver
    class << self
      # Should be called when trying to add a subgroup with name `subgroup_name` whose containing
      # group with path `containing_group_path` doesn't exist. Returns `true` if the cotaining
      # group should be created and `false` if adding the subgroup should be ignored.
      def create_nonexistent_group_when_adding_subgroup?(containing_group_path, subgroup_name)
        resolve_merge_error(
          "Trying to create group '#{subgroup_name}' inside a group that doesn't exist. The " \
          "group's path is '#{containing_group_path}'",
          {
            "Create containing group with path '#{containing_group_path}'": true,
            "Ignore adding group '#{subgroup_name}'": false
          }
        )
      end

      # Should be called when trying to add a file with name `file_name` whose containing group
      # with path `containing_group_path` doesn't exist. Returns `true` if the cotaining group
      # should be created and `false` if adding the file should be ignored.
      def create_nonexistent_group_when_adding_file?(containing_group_path, file_name)
        resolve_merge_error(
          "Trying to add or move a file with name '#{file_name}' to a group that doesn't exist. " \
          "The group's path is '#{containing_group_path}'",
          {
            "Create group with path '#{containing_group_path}'": true,
            "Ignore adding file '#{file_name}'": false
          }
        )
      end

      # Should be called when trying to apply changes to a component with path `path` that doesn't
      # exist. Returns `true` if the component should be created and `false` if applying the changes
      # to it should be ignored.
      def create_nonexistent_component_when_changing_it?(path)
        resolve_merge_error(
          "Trying to apply change to a component that doesn't exist at path '#{path}'",
          {
            'Create component and the components that contain it': true,
            'Ignore change to component': false
          }
        )
      end

      # Should be called when trying to merge `new_hash` into `new_hash` but `new_hash` contains
      # keys that exist in `old_hash`. Returns `true` if the keys should be overriden from
      # `new_hash`, `false` to keep the values from `old_hash`.
      def override_values_when_keys_already_exist_in_hash?(hash_name, old_hash, new_hash)
        resolve_merge_error(
          "Trying to add values to hash of attribute named '#{hash_name}': Merging hash " \
          "#{new_hash} into existing hash #{old_hash} but it contains values that already " \
          "exist",
          {
            'Override values from new hash': true,
            'Ignore values from new hash': false
          }
        )
      end

      # Should be called when trying to remove entries from a hash of an attribute named
      # `hash_name`. The values of those entries were expected to be `expected_values` but instead
      # they are `actual_values`. Returns `true` if the entries should be removed anyway, `false`
      # to keep the entries.
      def remove_entries_when_unexpected_values_in_hash?(hash_name, expected_values, actual_values)
        resolve_merge_error(
          "Trying to remove entries from hash of attribute named '#{hash_name}': Expected values " \
          "for keys to be '#{expected_values}' but the existing values are '#{actual_values}'",
          {
            'Remove entries anyway': true,
            'Keep entries': false
          }
        )
      end

      # Should be called when setting a string named `string_name` to value `new_value` and its
      # expected value is `expected_value` but it has a value of `actual_value`. Returns `true` if
      # the string should be set to `new_value`, `false` if the `actual_value` should remain.
      def set_value_to_string_when_unxpected_value?(
        string_name, new_value, expected_value, actual_value
      )
        resolve_merge_error(
          "Trying to change value of attribute named '#{string_name} from '#{new_value}' to " \
          "'#{expected_value || "nil"}', but the existing value is '#{actual_value}'",
          {
            "Set to new value '#{new_value}'": true,
            "Keep existing value '#{actual_value}'": false
          }
        )
      end

      # Should be called when trying to remove a `component` who's expected to have a hash equal to
      # `change` but they are not equal. Returns `true` if `component` should be removed anyway,
      # `false` otherwise.
      def remove_component_when_unexpected_hash?(component, change)
        resolve_merge_error(
          "Trying to remove a component named '#{component.display_name}': Expected hash of " \
          "#{change} but its hash is #{component.to_tree_hash}",
          {
            'Remove object anyway': true,
            'Keep object': false
          }
        )
      end

      private

      def resolve_merge_error(message, options)
        unless Settings.interactive_resolution
          raise MergeError, "Merge error: #{message}"
        end

        prompt = TTY::Prompt.new
        options = options.merge(
          {Abort: -> { raise MergeError, "Merge error: #{message}" }}
        )

        prompt.select(
          "A merge conflict that needs manual intervention occurred: #{message}. Choose one:",
          options
        )
      end
    end
  end
end
