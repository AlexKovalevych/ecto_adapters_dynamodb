defmodule Ecto.Adapters.DynamoDB.Migration do
  import Ecto.Adapters.DynamoDB, only: [ecto_dynamo_log: 2]

  alias ExAws.Dynamo

  @moduledoc"""
  Implements Ecto migrations for `create table` and `alter table`.
  
  The functions, `add`, `remove` and `modify` correspond to indexes on the DynamoDB table. Using `add`, the second parameter, field type (which corresponds with the DynamoDB attribute) must be specified. Use the third parameter to specify a primary key not already specified. For a HASH-only primary key, use `primary_key: true` as the third parameter. For a composite primary key (HASH and RANGE), in addition to the `primary_key` specification, set the third parameter on the range key attribute to `range_key: true`. There should be only one primary key (hash or composite) specified per table.
 
  To specify index details, such as provisioned throughput, global and local indexes, use the `options` keyword in `create table` and `alter table`, please see the examples below for greater detail.

  *Please note that `change` may not work as expected on rollback. We recommend specifying `up` and `down` instead.*

  ```
  Example:

  #Migration file 1:

    def change do
      create table(:post,
        primary_key: false,
        options: [
          global_indexes: [
            [index_name: "email_content",
             keys: [:email, :content],
             provisioned_throughput: [100, 100]] # [read_capacity, write_capacity]
            ],
          provisioned_throughput: [20,20]
        ]) do

        add :email,   :string, primary_key: true  # primary composite key
        add :title,   :string, range_key: true    # primary composite key
        add :content, :string

        timestamps()
      end
    end


  # Migration file 2:

    def up do
      alter table(:post,
        options: [
          global_indexes: [
            [index_name: "content",
             keys: [:content],
             projection: [projection_type: :include, non_key_attributes: [:email]]]
          ]
        ]) do

        add :content, string
      end
    end

    def down do
      alter table(:post) do
        remove :content
      end
    end


  # Migration file 3:
    def up do
      alter table(:post) do
        # modify will not be processed in a rollback if 'change' is used
        modify :"email_content", :string, provisioned_throughput: [2,2]
        remove :content
      end
    end

    def down do
      alter table(:post,
        options: [
          global_indexes: [
            [index_name: "content",
             keys: [:content],
             projection: [projection_type: :include, non_key_attributes: [:email]]]
          ]
        ]) do

        modify :"email_content", :string, provisioned_throughput: [100,100]
        add :content, :string
      end
    end
 ```
  """


  # DynamoDB has restrictions on what can be done while tables are being created or
  # updated so we allow for a custom wait between requests if certain resource-access
  # errors are returned
  @initial_wait Application.get_env(:ecto_adapters_dynamodb, :migration_initial_wait) || 1000
  @wait_exponent Application.get_env(:ecto_adapters_dynamodb, :migration_wait_exponent) || 1.05
  @max_wait Application.get_env(:ecto_adapters_dynamodb, :migration_max_wait) || 10 * 60 * 1000 # 10 minutes


  # Adapted from line 620, https://github.com/michalmuskala/mongodb_ecto/blob/master/lib/mongo_ecto.ex
  def execute_ddl(_repo, string, _opts) when is_binary(string) do
    raise ArgumentError, message: "Ecto.Adapters.Dynamodb does not support SQL statements in `execute`"
  end

  def execute_ddl(repo, command, options) do
    ecto_dynamo_log(:debug, "EXECUTE_DDL:::")
    ecto_dynamo_log(:debug, "repo: #{inspect repo}")
    ecto_dynamo_log(:debug, "command: #{inspect command}")
    ecto_dynamo_log(:debug, "options: #{inspect options}")

    # We provide a configuration option for migration_table_capacity
    updated_command = maybe_add_schema_migration_table_capacity(repo, command)

    execute_ddl(updated_command)
  end

  def execute_ddl({:create_if_not_exists, %Ecto.Migration.Table{} = table, field_clauses}) do
    # :schema_migrations might be provided as an atom, while 'table.name' is now usually a binary
    table_name = if is_atom(table.name), do: Atom.to_string(table.name), else: table.name
    %{"TableNames" => table_list} = Dynamo.list_tables |> ExAws.request!

    ecto_dynamo_log(:info, "#{inspect __MODULE__}.execute_ddl: create_if_not_exists (table)")
    
    if not Enum.member?(table_list, table_name) do
      ecto_dynamo_log(:info, "Creating table #{inspect table.name}")
      create_table(table_name, field_clauses, table.options)
    else
      ecto_dynamo_log(:info, "add_if_exists table #{inspect table.name}: table already exists. Done.")
    end

    :ok
  end

  def execute_ddl({:create, %Ecto.Migration.Table{} = table, field_clauses}) do
    ecto_dynamo_log(:info, "#{inspect __MODULE__}.execute_ddl: create table")
    ecto_dynamo_log(:info, "Creating table #{inspect table.name}")

    create_table(table.name, field_clauses, table.options)
    :ok
  end

  def execute_ddl({command, %Ecto.Migration.Index{}}) do
    raise ArgumentError, message: "Ecto.Adapters.Dynamodb migration does not support '" <> to_string(command) <> " index', please use 'alter table' instead, see README.md"
  end

  def execute_ddl({:drop, %Ecto.Migration.Table{} = table}) do
    ecto_dynamo_log(:info, "#{inspect __MODULE__}.execute_ddl: drop")
    ecto_dynamo_log(:info, "Removing table #{inspect table.name}")

    Dynamo.delete_table(table.name) |> ExAws.request!
    :ok
  end

  def execute_ddl({:drop_if_exists, %Ecto.Migration.Table{} = table}) do
    %{"TableNames" => table_list} = Dynamo.list_tables |> ExAws.request!

    ecto_dynamo_log(:info, "#{inspect __MODULE__}.execute_ddl: drop_if_exists (table)")
    
    if Enum.member?(table_list, table.name) do
      ecto_dynamo_log(:info, "#{inspect __MODULE__}.execute_ddl: drop_if_exists")
      ecto_dynamo_log(:info, "Removing table #{inspect table.name}")

      Dynamo.delete_table(table.name) |> ExAws.request!
    else
      ecto_dynamo_log(:info, "drop_if_exists table #{inspect table.name}: table does not exist. Done.")
    end

    :ok
  end

  def execute_ddl({:alter, %Ecto.Migration.Table{} = table, field_clauses}) do
    ecto_dynamo_log(:info, "#{inspect __MODULE__}.execute_ddl: alter table")

    {delete, update, key_list} = build_delete_and_update(field_clauses)

    attribute_definitions = for {field, type} <- key_list do
      %{attribute_name: field, attribute_type: Dynamo.Encoder.atom_to_dynamo_type(convert_type(type))}
    end

    to_create = case table.options[:global_indexes] do
      nil -> nil
      global_indexes ->
        Enum.filter(global_indexes, fn index -> index[:keys] |> Enum.all?(fn key -> Keyword.has_key?(key_list, key) end) end)
    end

    create = build_secondary_indexes(to_create) |> Enum.map(fn index -> %{create: index} end)

    data = %{global_secondary_index_updates: create ++ delete ++ update}
           |> Map.merge(if create == [], do: %{}, else: %{attribute_definitions: attribute_definitions})

    update_table_recursive(table.name, data, @initial_wait, 0)
  end

  def execute_ddl({command, struct, _}), do:
  raise ArgumentError, message: "#{inspect __MODULE__}.execute_ddl error: '" <> to_string(command) <> " #{extract_ecto_migration_type(inspect struct.__struct__)}' is not supported"

  def execute_ddl({command, struct}), do:
  raise ArgumentError, message: "#{inspect __MODULE__}.execute_ddl error: '" <> to_string(command) <> " #{extract_ecto_migration_type(inspect struct.__struct__)}' is not supported"


  # We provide a configuration option for migration_table_capacity
  defp maybe_add_schema_migration_table_capacity(repo, {:create_if_not_exists, %Ecto.Migration.Table{} = table, field_clauses} = command) do
    migration_source = Keyword.get(repo.config, :migration_source, "schema_migrations")

    if to_string(table.name) == migration_source do
      migration_table_capacity = Application.get_env(:ecto_adapters_dynamodb, :migration_table_capacity) || [1,1]
      updated_table_options = case table.options do
        nil  -> [provisioned_throughput: migration_table_capacity]
		opts -> Keyword.put(opts, :provisioned_throughput, migration_table_capacity)
      end
	  {:create_if_not_exists, Map.put(table, :options, updated_table_options), field_clauses}
    else
      command
    end
  end
  defp maybe_add_schema_migration_table_capacity(_repo, command), do: command

  defp poll_table(table_name) do
    table_info = Dynamo.describe_table(table_name) |> ExAws.request

    case table_info do
      {:ok, %{"Table" => table}} -> 
        ecto_dynamo_log(:info, "poll_table: table #{inspect table_name} ::: #{inspect table}")
        table

      {:error, error_tuple} ->
        ecto_dynamo_log(:info, "Error attempting to poll table #{inspect table_name}: #{inspect error_tuple}. Stopping...")
        raise ExAws.Error, message: "ExAws Request Error! #{inspect error_tuple}"
    end
  end

  defp list_non_active_statuses(table_info) do
    secondary_index_statuses = (table_info["GlobalSecondaryIndexes"] || []) |> Enum.map(fn index -> {index["IndexName"], index["IndexStatus"]} end)

    [{"TableStatus", table_info["TableStatus"]}] ++ secondary_index_statuses |> Enum.filter(fn {_, y} -> y != "ACTIVE" end)
  end

  defp update_table_recursive(table_name, data, wait_interval, time_waited) do
    ecto_dynamo_log(:info, "update_table_recursive: polling table #{inspect table_name}...")
    table_info = poll_table(table_name)
    non_active_statuses = list_non_active_statuses(table_info)

    if non_active_statuses != [] do
      ecto_dynamo_log(:info, "update_table_recursive: non-active status found in table #{inspect table_name}: #{inspect non_active_statuses}")
      to_wait = if time_waited == 0, do: wait_interval, else: round(:math.pow(wait_interval, @wait_exponent))
      if (time_waited + to_wait) <= @max_wait do
        ecto_dynamo_log(:info, "Waiting #{inspect to_wait} milliseconds (waited so far: #{inspect time_waited} ms)")
        :timer.sleep(to_wait)
        update_table_recursive(table_name, data, to_wait, time_waited + to_wait)
      else
        raise "Wait exceeding configured max wait time, stopping migration at update table #{inspect table_name}...\nData: #{inspect data}"
      end

    else
      result = Dynamo.update_table(table_name, data) |> ExAws.request

      ecto_dynamo_log(:info, "update_table_recursive DynamoDB/ExAws response ::: #{inspect result}")

      case result do
        {:ok, _} ->
          ecto_dynamo_log(:info, "Table #{inspect table_name} altered successfully")
          :ok

        {:error, {error, _message}} when (error in ["LimitExceededException", "ProvisionedThroughputExceededException", "ThrottlingException"]) ->
          to_wait = if time_waited == 0, do: wait_interval, else: round(:math.pow(wait_interval, @wait_exponent))

          if (time_waited + to_wait) <= @max_wait do
            ecto_dynamo_log(:info, "#{inspect error} ... waiting #{inspect to_wait} milliseconds (waited so far: #{inspect time_waited} ms)")
            :timer.sleep(to_wait)
            update_table_recursive(table_name, data, to_wait, time_waited + to_wait)
          else
            raise "#{inspect error} ... wait exceeding configured max wait time, stopping migration at update table #{inspect table_name}...\nData: #{inspect data}"
          end

        {:error, error_tuple} ->
          ecto_dynamo_log(:info, "Error attempting to update table #{inspect table_name}: #{inspect error_tuple}. Stopping...\nData: #{inspect data}")
          raise ExAws.Error, message: "ExAws Request Error! #{inspect error_tuple}"
      end

    end
  end

  defp create_table(table_name, field_clauses, options) do
    {key_schema, key_definitions} = build_key_schema_and_definitions(table_name, field_clauses, options)
    [read_capacity, write_capacity] = options[:provisioned_throughput] || [1,1]
    global_indexes = build_secondary_indexes(options[:global_indexes])
    local_indexes = build_secondary_indexes(options[:local_indexes])

    create_table_recursive(table_name, key_schema, key_definitions, read_capacity, write_capacity, global_indexes, local_indexes, @initial_wait, 0)
  end

  defp create_table_recursive(table_name, key_schema, key_definitions, read_capacity, write_capacity, global_indexes, local_indexes, wait_interval, time_waited) do
    result = Dynamo.create_table(table_name, key_schema, key_definitions, read_capacity, write_capacity, global_indexes, local_indexes) |> ExAws.request

    ecto_dynamo_log(:info, "create_table_recursive: DynamoDB/ExAws response ::: #{inspect result}")

    case result do
      {:ok, _} ->
        ecto_dynamo_log(:info, "Table #{inspect table_name} created successfully")
        :ok

      {:error, {error, _message}} when (error in ["LimitExceededException", "ProvisionedThroughputExceededException", "ThrottlingException"]) ->
        to_wait = if time_waited == 0, do: wait_interval, else: round(:math.pow(wait_interval, @wait_exponent))

        if (time_waited + to_wait) <= @max_wait do
          ecto_dynamo_log(:info, "#{inspect error} ... waiting #{inspect to_wait} milliseconds (waited so far: #{inspect time_waited} ms)")
          :timer.sleep(to_wait)
          create_table_recursive(table_name, key_schema, key_definitions, read_capacity, write_capacity, global_indexes, local_indexes, to_wait, time_waited + to_wait)
        else
          raise "#{inspect error} ... wait exceeding configured max wait time, stopping migration at create table #{inspect table_name}..."
        end

      {:error, error_tuple} ->
        ecto_dynamo_log(:info, "Error attempting to create table #{inspect table_name}: #{inspect error_tuple}. Stopping...")
        raise ExAws.Error, message: "ExAws Request Error! #{inspect error_tuple}"
    end
  end

  defp build_key_schema_and_definitions(table_name, field_clauses, options) do
    secondary_index_atoms =
      (options[:global_indexes] || []) ++ (options[:local_indexes] || [])
      |> Enum.flat_map(fn indexes -> indexes[:keys] || [] end)

    {hash_key, range_key, key_list} = Enum.reduce(field_clauses, {nil, nil, []}, fn({cmd, field, type, opts}, {hash, range, key_list}) ->
      cond do      
        cmd == :add and opts[:primary_key] == true ->
          {field, range, [{field, type} | key_list]}
        cmd == :add and opts[:range_key] == true ->
          {hash, field, [{field, type} | key_list]}
        cmd == :add and Enum.member?(secondary_index_atoms, field) ->
          {hash, range, [{field, type} | key_list]}
        true ->
          {hash, range, key_list}
      end
    end)

    if is_nil(hash_key), do: raise "#{inspect __MODULE__}.build_key_schema error: no primary key was found for table #{inspect table_name}. Please specify one primary key in migration."

    key_definitions = for {field, type} <- key_list, into: %{}, do: {field, convert_type(type)}

    case range_key do
      nil ->
        {[{hash_key, :hash}], key_definitions}

      range_key ->
        {[{hash_key, :hash}, {range_key, :range}], key_definitions}
    end
  end

  defp build_secondary_indexes(nil), do: []
  defp build_secondary_indexes(global_indexes) do
    Enum.map(global_indexes, fn index ->
      [read_capacity, write_capacity] = index[:provisioned_throughput] || [1,1]

      %{index_name: index[:index_name],
        key_schema: build_secondary_key_schema(index[:keys]),
        provisioned_throughput: %{read_capacity_units: read_capacity,
                                  write_capacity_units: write_capacity},
        projection: build_secondary_projection(index[:projection])}
    end)
  end

  defp build_secondary_key_schema(keys) do
    case keys do
      [hash]        -> [%{attribute_name: Atom.to_string(hash), key_type: "HASH"}]
      [hash, range] -> [%{attribute_name: Atom.to_string(hash), key_type: "HASH"},
                        %{attribute_name: Atom.to_string(range), key_type: "RANGE"}]
    end
  end

  defp build_secondary_projection(nil), do: %{projection_type: "ALL"}
  defp build_secondary_projection(projection) do
    case projection[:projection_type] do
      :include ->
        %{projection_type: "INCLUDE",
          non_key_attributes: projection[:non_key_attributes]}

      type when type in [:all, :keys_only] ->
        %{projection_type: ExAws.Utils.upcase(type)}
    end
  end

  defp build_delete_and_update(field_clauses) do
    Enum.reduce(proper_list(field_clauses), {[],[],[]}, fn (field_clause, {delete, update, key_list}) ->
      case field_clause do
        {:remove, field} ->
          {[%{delete: %{index_name: field}} | delete], update, key_list}
        {:modify, field, _type, opts} ->
          [read_capacity, write_capacity] = opts[:provisioned_throughput] || [1,1]
          provisioned_throughput =  %{read_capacity_units: read_capacity, write_capacity_units: write_capacity}
          {delete, [%{update: %{index_name: field, provisioned_throughput: provisioned_throughput}} | update], key_list}
        {:add, field, type, _opts} ->
          {delete, update, [{field, type} | key_list]}
        _ ->
          {delete, update, key_list}
      end
    end)
  end

  defp convert_type(type) do
    case type do
      :bigint    -> :number
      :serial    -> :number
      :binary    -> :blob
      :binary_id -> :blob
      _          -> type
    end
  end

  defp proper_list(l), do: proper_list(l, [])
  defp proper_list([], res), do: Enum.reverse(res)
  defp proper_list([a | b], res) when not (is_list b), do: Enum.reverse([a | res])
  defp proper_list([a | b], res), do: proper_list(b, [a | res])

  defp extract_ecto_migration_type(str),
  do: str |> String.split(".") |> List.last |> String.downcase
end
