# The "Load history" runs of Avito accounts (AvitoHistoryLoad), kept in the database: Rails' cache, where
# they lived first, is cleared on every start of the Docker image's zammad-init.
class AvitoHistoryLoads < ActiveRecord::Migration[8.0]
  def up
    return if table_exists?(:avito_history_loads)

    create_table :avito_history_loads, id: :integer do |t|
      t.integer  :channel_id,     null: false
      t.integer  :days,           null: false
      t.datetime :since,          null: false, limit: 3
      t.string   :phase,          null: false, limit: 10, default: 'walk'
      t.integer  :list_offset,    null: false, default: 0
      t.string   :chat_id,        null: true,  limit: 255
      t.integer  :message_offset, null: false, default: 0
      t.integer  :chats,          null: false, default: 0
      t.integer  :imported,       null: false, default: 0
      t.integer  :unavailable,    null: false, default: 0
      t.string   :error,          null: true,  limit: 500
      t.datetime :finished_at,    null: true,  limit: 3
      t.timestamps limit: 3, null: false
    end
    add_index :avito_history_loads, :channel_id
    # One running load per account, held by the database even against two starts at once.
    add_index :avito_history_loads, :channel_id, unique: true, where: 'finished_at IS NULL',
                                                 name: 'index_avito_history_loads_running'
  end

  def down
    drop_table :avito_history_loads, if_exists: true
  end
end
