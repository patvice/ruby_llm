# frozen_string_literal: true

class AddThinkingToMessages < ActiveRecord::Migration[7.1]
  def change
    add_column :messages, :thinking, :json unless column_exists?(:messages, :thinking)
  end
end

