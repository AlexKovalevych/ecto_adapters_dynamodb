# Ecto.Adapters.DynamoDB

This is a partial implementation of an Elixir Ecto adapter for Amazon's DynamoDB. It's very much a work in progress, and has plenty of rough edges. It's complete enough that we're actually using it in other projects, so we're opening it up to the community in hopes that others will find it useful as well :-)

Keep in mind that DynamoDB is a key-value store designed for very high scale, while the Ecto abstractions are primarily designed to work with relational databases. As such, we've had to make significant compromises in the implementation of this adapter to make it work. Please understand that while we are using it in production, it's currently in use in non-critical systems and should be considered **beta**. Do not deploy it without thouroughly testing it for your use cases.

If you wish to contribute, please run `$ mix test` and confirm that the test results are error-free before you push your commits. (Bonus points for improving our tests and adding your own tests for your changes. Patches with corresponding tests are more likely to be accepted, especially if they are significant.)

### Special thanks to ExAws project
We use [ExAws](https://github.com/CargoSense/ex_aws/) to wrap the actual DynamoDB API and requests. This project would not be possible without the extensive work in ExAws.

### Design limitations
There are a lot of common things you can do in Ecto with a SQL database that you just can't do (or can't do efficiently) with DynamoDB. If you expect to pick up your existing Ecto-based app and just swap in DynamoDB, you're going to be disappointed. You still have to use this adapter the same way you would approach using a key-value store, and avoid the kinds of patterns you'd use with a relational database.

**Is DynamoDB the right choice for you?**
It may not be.
Understand the DynamoDB limitations. It's designed for very high scale, throughput, and reliability. As a result of this design, there are many kinds of operations that are impossible. Other things are technically possible but not advisable, due to high costs in terms of performance and/or money.

A good starting point is Amazon's own documentation:
[Amazon: Best Practices for DynamoDB](http://docs.aws.amazon.com/amazondynamodb/latest/developerguide/BestPractices.html)

Our philophy when creating this adapter can generally be summed up as:

 *Try to do what the end user will expect the adapter to do, **unless** it's likely to ruin DynamoDB's performance.*

An example of this is our handling of table scans (see below).
Lastly, please read and understand how DynamoDB and its queries and indexes work. If you don't, then a lot of the following behaviour is going to seem random, and you'll be frustrated trying to figure out why things don't work the way you expect them to. We've done our best to simplify what we can, but underneath it all, it's still DynamoDB.


#### How we use indexes
In DynamoDB, we can fetch individual records or batches of records *very* quickly if we know the primary key to look up, or the key of an indexed field. We **can't** easily perform queries which don't have a simple key or ID to look up:

Will work: (note that this will be a *case sensitive* match as well.)

`select * from people where name = 'ALICE'`

Won't Work:

`select * from people where name like 'Ali%'`

(Obviously these are SQL queries, not Ecto queries, but the above examples just provide a general illustration of what sorts of limitations to expect.)

We will try our best to parse queries and find any relevant DynamoDB indexes that exists. (This includes both HASH indexes, and HASH+RANGE indexes.) As long as the FROM clause contains at least **one** HASH key from a DynamoDB index, a query will be constructed using our best guess at the most specific matching index. (This may not be the best index - unlike a SQL server, we don't understand the data in the table, so the adapter may have to guess.) Any other fields in the FROM criteria will be converted to DynamoDB filters as required to ensure you only get back the data you requested. We also support `is_nil` in queries. This will test whether the attribute is either set to `null` *or* whether the attribute is missing from the record altogether. Please note that DynamoDB does not allow for this type of filtering on attributes that are being queried against, whether in the primary key or in a secondary index.

If we do not find any matching table index for the query (either a HASH key of an index or the HASH part of a composite HASH+RANGE key), the query will fail by default. It is possible to override this behaviour and have the adapter perform a dynamoDB *scan* instead. Since scans do not scale well, they can potentially be very costly with large data sets, and we have configured the adapter not to scan unless scanning is explicitly enabled. This can be done via global configuration options, or inline as an option to 'Repo.all' and other query functions. See the section below on **scan** for more info.

The adapter will query DynamoDB for a list of indexes and indexed fields on the table, and by default it will cache the results to avoid the overhead of repeatedly pulling the same lists of indexes on every query. This does mean that if you update the indexes on a table in DynamoDB, you will need to execute the **Ecto.Adapters.DynamoDB.Cache.update_table_info!** function or restart the adapter.


#### Limited support for fetching all records. 'scan' disabled by default
Fetching records based on a hash of the primary key allows DynamoDB to distribute its data across many partitions on many servers, resulting in high scalability and reliability. It also means that you can't do arbitrary queries based on unindexed fields.

Well, that's not quite true, but running queries against un-indexed fields is usually a terrible idea. We can translate queries without any matching indexes to a DynamoDB `scan` operation, but this is not recommended as it can easily burn through all your read capacity. By default, attempting to perform these kinds of queries will raise an error. You can allow them to succeed by enabling the 'scan' option at the adapter level for all queries, or by specifying the corresponding option on individual queries. See 'scan' options below for more information.

If you need to do this a lot, you're losing most of the benefits of DynamoDB, so think carefully before you do.


#### No joins
DynamoDB does not support joins. Thus, neither do we. Pretty simple.
While it's technically possible for us to decompose the query into multiple individual requests against each table and then perform the join ourselves, this will likely result in very poor performance, and burning through excess read units to do so. It's better to construct these 'joins' manually using key/value lookups against indexes carefully chosen to preserve your predictable key/value store performance.

This is one of those things that are technically possible, but would result in very unpredictable performance that could drag down your entire app, reducing or eliminating any benefit from DynamoDB. You're probably better off using another DB if this is a requirement.

That said, for very simple joins that match a limited number of keys where all the relevant fields are indexed, joins could probably be emulated pretty reasonably. We'd entertain the notion of accepting a patch for this, if anyone wants to go to the trouble, and if the code contains some reasonable safeguards to avoid executing big, expensive joins by accident. It would be tricky though, and it's certainly not a priority for us right now.


#### No transactions
Similar deal as with joins. DynamoDB does not support transactions, so neither do we. And, unlike joins where we could theoretically emulate them, there's simply no way to provide support for transactions in the adapter.


#### Limited sorting
DynamoDB can ONLY return sorted results if there is a matching HASH+RANGE index where the desired sort key is the RANGE portion of the index. In this case we support the **:scan_index_forward** [option](http://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html) as a parameter to Repo queries. However, writing queries like 'select * from person order by last_name limit 50' may not be practical; we'd have to retrieve every record from the table to do this. (See also *DynamoDB LIMIT & Paging* below.)

From DynamoDB's [Query API](http://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html):
>Query results are always sorted by the sort key value. If the data type of the sort key is Number, the results are returned in numeric order; otherwise, the results are returned in order of UTF-8 bytes. By default, the sort order is ascending. To reverse the order, set the ScanIndexForward parameter to false.


#### Update support
We currently support both `update` and `update_all` with some performance caveats. Since DynamoDB currently does not offer a batch update operation, we emulate it in `update_all` (and `update` if the full primary-key is not provided). The adapter first fetches the query results to get all the relevant keys, then updates the records one by one (paging as it goes, see *DynamoDB LIMIT & Paging* below). Consequently, performance might be slower than expected due to the need to execute individual fetches followed by individual inserts. Also please note that this means that update operations are *not atomic*! Multiple concurrent updates to the same record can race with each other, causing some updates to be silently lost.

All of these caveats can be especially pernicious if you're performing eventually consistent reads, as is the default for DynamoDB: you could write a new version of a record to a key, then attempt to perform an update to the same key, which could read from a zone that hasn't received your write yet. This would cause the update's fetch to return an older version of the record, which will then be modified and written back to DDB, overwriting your changes from the previous write! Thus, even if a single client synchronously updates a key, waits for success, then does another update, you may still experience a complete loss of the first of those two updates! So, the moral of the story is, be really careful with updates; and, you may want to use consistent reads unless you really know what you're doing (see the `consistent_read` option for more info).

#### DynamoDB BatchGetItem

We currently support DynamoDB's **BatchGetItem** via an **:in** clause in `Repo.all`. For example, `Repo.all(from m in Model, where: m.id in ["id_1", "id_2"])`. For tables with a composite primary key, range keys must be supplied in another **:in** clause in matching order.

#### DynamoDB LIMIT & Paging
By default, we configure the adapter to fetch all pages recursively for a DynamoDB `query` operation, and to *not* fetch all pages recursively in the case of a DynamoDB `scan` operation. This default can be overridden with the inline **:recursive** and **:page_limit** options (see below). We do not respond to the Ecto `limit` option; rather, we support a **:scan_limit** option, which corresponds with DynamoDB's [limit option](http://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Query.html#Query.Limit), limiting "the number of items that it returns in the result."

#### Only ONE DynamoDB adapter can be configured
We only launch one instance of ExAws application (and have not yet investigated running multiple instances). This means we can only point to a single amazon Dynamo instance. It's currently not possible to run against two different amazon AWS accounts concurrently. Hopefully this won't be a problem for most users.

#### Adapter.Migration
We support Ecto migration tasks via **create_table** and **alter_table** only. The functions, `add`, `remove` and `modify` work with corresponding indexes on the DynamoDB table. The adapter will automatically wait and retry requests when encountering DynamoDB errors that have "OK to retry? Yes" listed in the DynamoDB docs, according to an exponential backoff schedule. Since working with DynamoDB indexes and describing tables includes many options outside of Ecto's scope, for our supported syntax, please see details and examples in the **Ecto.Adapters.DynamoDB.Migration** moduledoc, as well as the configuration options, `:migration_initial_wait`, `:migration_wait_exponent`, `:migration_max_wait`, `:migration_table_capacity`.

Please note: Ecto migration calls Repo.all on the *schema_migrations* table, which corresponds with a DynamoDB scan. To run migrations, add "schema_migrations" (or the alternate name you've configured for it) in the configuration file to the config variable, **:scan_tables**. Additionally, note that the creation of the schema-migration records table takes time - if you have not created it yourself already, we recommend running `mix ecto.migrate --step 0`, then confirming the table is up, which will prevent the adapter from attempting to retrieve records from the schema-migrations table before it's ready.

### Unimplemented Features
While the previous section listed limitations that we're unlikely to work around due to philosphical differences between DynamoDB as a key/value store vs an SQL relational database, there are some features that we just haven't implemented yet. Feel free to help out if any of these are important to you!

#### Adapter.Storage
In the current release, we do not support Adapter.Storage callbacks.

#### Adapter.Structure
Look, I have to be honest - I don't even know what this is for. So it's not going to work :)

#### Associations & Embeds
While we've not tested these, without joins it's unlikely they work well (if at all).


### So what DOES work?
Well, basic CRUD really, which is all you should really expect from a key/value store :).

Get, Insert, Delete and Update. As long as it's simple queries against single tables, it's probably going to work. Anything beyond that probably isn't. All of the following Ecto functions should work to some extent, if not necessarily in every scenario.

* all/2
* delete/2
* delete!/2
* delete_all/2
* get/3
* get!/3
* get_by/3
* get_by!/3
* insert/2
* insert!/2
* insert_all/3
* one/2
* one!/2
* update/2
* update!/2
* update_all/3


## Installation

Install the [Hex](https://hex.pm/packages/ecto_adapters_dynamodb) package by adding `ecto_adapters_dynamodb` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [{:ecto_adapters_dynamodb, "~> 0.1.2"}]
end
```

Otherwise, to fetch from GitHub:

```elixir
def deps do
  [{:ecto_adapters_dynamodb, git: "https://github.com/circles-learning-labs/ecto_adapters_dynamodb", branch: "master"}]
end
```


### Configuration
Configuring a repository to use the DynamoDB ecto adapter is pretty similar to most other Ecto adapters. Change the *adapter* option in the Repo configuration to 'Ecto.Adapters.DynamoDB', and then set the required (or optional) values in the keyword list that follows.

These are **different** from the normal Ecto options. For example, in DynamoDB you don't have username, password or database options. You'll need to delete these lines. Instead you'll add amazon access keys and secrets, your region and the optional dynamo host and scheme options if you're not running gainst the default live amazon instances ( for example, running the local amazon dev version of dynamo for testing and development. )

All these options are quietly passed through to ExAws. See [https://hexdocs.pm/ex_aws/ExAws.html#module-getting-started]( ExAws Getting Started) for more information on these options.

A note on `access_key_id` and `secret_access_key`: This can simply be the actual key string, or it can be set to pull these from environment variables or amazon roles (as per ExAws configuration.) Some basic examples follow.

You may also omit all these ExAws options from the adapter config if you wish to configure ExAws manually (for example if you're using other features from ExAws such as S3, or dynamo_streams.)

Include the repo module that's configured for the adapter among the project's Ecto repos. File, "config/config.exs"
```
  config :my_app, ecto_repos: [MyModule.Repo]
```
Include the adapter in the project's applications list. File, "mix.exs":

```
  def application do
    [...
    applications: [..., :ecto_adapters_dynamodb, ...]
    ...
  end
```

#### Configuring a Development Environment against a local instance of Dynamo
For development, we use the [local version](http://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.html) of DynamoDB, and some dummy variable assignments. Note that the access key/secret here are hardcoded in to the config, and that we set a 'dynamo' key that overrides the connection parameters from the defaults for AWS. We point it to localhost:8000 - the default for a local dynamoDB test server.

File, "config/dev.exs":
```               
config :my_app, MyModule.Repo,
  adapter: Ecto.Adapters.DynamoDB,
  # ExAws configuration
  access_key_id: "abcd",
  secret_access_key: "1234",
  region: "us-east-1",
  debug_requests: true,	# ExAws option to enable debug on aws http request.
  dynamodb: [
    scheme: "http://",
    host: "localhost",
    port: 8000,
    region: "us-east-1"
  ]
```

#### Configuring a Production environment using Dynamo running on AWS
For a production setup, it's much simpler. No need to specify the host/ports for dynamo, as it will default to the appriopriate AWS service in the region selected.

In this example configration we do not hard code the secret or access key. These following settings tell ExAws to first attempt to pull the secret and access key from environment variables labelled `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. If it cannot find those environment variables, it will attempt to fall back on AWS role based authentication (This only applies if this instance is running in an appropriately configured amazon instance.)

To reiterate, this is just standard ExAws configuration that we're wrapping up in our adapter config. Please consult the ExAws docs for further information.

File, "config/prod.exs"
```
config :my_app, MyModule.Repo,
  adapter: Ecto.Adapters.DynamoDB,
  # ExAws configuration
  access_key_id: [{:system, "AWS_ACCESS_KEY_ID"}, :instance_role],
  secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}, :instance_role],
  region: "us-east-1"
```

### Other adapter options
The following are adapter options that apply to the Ecto adapter, and are NOT related to ExAws configuration. They control certain behavioural aspects for the driver, enabling and disabling default behaviours and features on queries.

```
config :ecto_adapters_dynamodb,
  insert_nil_fields: false,
  remove_nil_fields_on_update: true,
  cached_tables: ["colour"]
```
The above snippet will (1) set the adapter to ignore fields that are set to `nil` in the changeset, inserting the record without those attributes, (2) set the adapter to remove attributes in a record during an update where those fields are set to `nil` in the changeset, and (3) cache scan results from the "colour" table, providing the cached result in subsequent calls. More details for each of those options follow.

#### `nil` value handling options

**:insert_nil_fields** :: boolean, *default:* `true`

Determines if fields in the changeset with `nil` values will be inserted as DynamoDB `null` values or not set at all. This option is also available inline per query. Please note that DynamoDB does not allow setting indexed attributes to `null` and will respond with an error. It does allow removal of those attributes.

**:remove_nil_fields_on_update** :: boolean, *default:* `false`

Determines if, during **Repo.update** or **Repo.update_all**, fields in the changeset with `nil` values will be removed from the record/s or set to the DynamoDB `null` value. This option is also available inline per query.

#### Logging Configuration
The adapter's logging options are configured during compile time, and can be altered in the application's configuration files ("config/config.exs", "config/dev.exs", "config/test.exs" and "config/test.exs"). 

We provide a few informational log lines, such as which adapter call is being processed, as well as the table, lookup fields, and options detected. Configure an optional log path to have the messages recorded on file.

**:log_levels** :: [log-level-atom], *default:* `[:info]`, *log-level-atom can be :info and/or :debug*

**:log_colors** :: %{log-level-atom: IO.ANSI-color-atom}, *default:* `info: :green, debug: :normal`

**:log_path** :: string, *default:* `""`

#### Scan-related options
**:scan_tables** :: [string], *default:* `[]`

A list of table names for tables pre-approved for a DynamoDB **scan** command in case an indexed field is not provided in the query *wheres*. By default, scans are completely disabled on all tables. Use this option carefully; you may be better off using the inline query options to make sure you only perform table scans when you explicitly expect to do so.

**:scan_limit** :: integer, *default:* `100`

Sets the default limit on the number of records scanned when calling DynamoDB's **scan** command. This can be overridden by the inline **:scan_limit** option. Included as **limit** in the DynamoDB query. (This option does not apply to queries performing recursive fetches.)

**:scan_all** :: boolean, *default:* `false`

Pre-approves all tables for a DynamoDB **scan** command in case an indexed field is not provided in the query *wheres*.

**:cached_tables** :: [string], *default:* `[]`

A list of table names for tables assigned for caching of the first page of results (without setting DynamoDB's **limit** parameter in the scan request). For a set table, call `Repo.all(Model)` to cache the first page of results. To override the caching for a table in this list, and perform a regular scan with associated inline options (see below), provide an additional `scan: true` option with the query; for example, `Repo.all(Model, scan: true, recursive: true)`.

#### Migration-related options
**:migration_initial_wait** :: integer, *default:* `1000`

The time in milliseconds of the first wait period before retrying a DynamoDB **create_table** or **update_table** request.

**:migration_wait_exponent** :: float, *default:* `1.05`

The exponent to which the wait time between sequential retries of **create_table** or **update_table** requests is raised.

**:migration_max_wait** :: integer, *default:* `15000`

The maximum wait time in milliseconds over sequential retries of a particular **create_table** or **update_table** request. Set this to zero to avoid retries altogether. 

**:migration_table_capacity** :: [integer, integer], *default:* `[1,1]`

ProvisionedThroughput as `[ReadCapacityUnits, WriteCapacityUnits]`, for the Schema Migrations table only, automatically created by Ecto if it does not exist.

## Inline Options

The adapter supports a mix of Ecto options and custom inline options; if the Ecto option is not listed here, assume the adapter will ignored it. The following options can be passed during runtime in the Ecto calls. For example, consider a DynamoDB table with a composite index (HASH + RANGE):
```
MyModule.Repo.all(
  (from MyModule.HikingTrip, where: [location_id: "grand_canyon"]),
  recursive: false,
  scan_limit: 5
)
```
will retrieve the first five results from the record set for the indexed HASH, "location_id" = "grand_canyon", disabling the default recursive page fetch for queries. (Please note that without `recursive: false`, the adapter would ignore the scan limit.)

### Supported Ecto Options

**:on_conflict** :: :raise | :nothing | :replace_all, *default:* :raise

By default, the adapter will provide the condition expression, `attribute_not_exists(PARTITION_KEY_ATTRIBUTE)` with the DynamoDB query, failing to insert if the record already exists. To perform an uncoditional insert, possibly overwriting an existing record, provide the option `on_conflict: :replace_all` in the insert query. If `on_conflict: :nothing` is provided, a struct will be returned with the primary key field/s set to `nil`.

### Custom Inline Options

#### **Inline Options:** *Repo.update*, *Repo.delete*

**:range_key** :: {attribute_name_atom, value}, *default:* none

If the DynamoDB table queried has a composite primary key, an update or delete query must supply both the `HASH` and the `RANGE` parts of the key. We assume that your Ecto model schema will correlate its primary id with DynamoDB's `HASH` part of the key. However, since Ecto will normally only supply the adapter with the primary id along with the changeset, we offer the range_key option to avoid an extra query to retrieve the complete key. The adapter will attempt to query the table for the complete key if the **:range_key** option is not supplied.

#### **Inline Options:** *Repo.update_all*

**:add / :delete** :: [{field_atom, MapSet}], *default:* none

Ecto does not currently support :push and :pull on fields that are not :array type. To perform DynamoDB's **add** and **delete** on sets, pass the action, field and value as an option.

**:prepend_to_list** :: [field_atom], *default:* none

To prepend a value during a :push action, include the field in this option.
For example: `Repo.update_all((from Country, where: [name: "New Zealand"]), [push: [tags: "adventure"]], prepend_to_list: [:tags])`

**:pull_indexes** :: [{field_atom, [integer]}], *default:* none

To remove an element in a DynamoDB list, we must supply the list index of the element/s. Include them in this option. If :pull_indexes is not specified, the adapter will attempt to find and remove all the occurrences of the value in the :pull keyword in the corresponding list field.

Here's an example including both of the options above:
```
Repo.update_all(
  (from Model, where: [id: "fffx"]), 
  [set: [name: "Speedy"], inc: [int_field: 2], pull: [list_field_1: "value to remove"], list_field_2: "value will be ignored"],
  add: [set_field_1: MapSet.new(["add_this"])], delete: [set_field_2: MapSet.new(["remove_this"])], pull_indexes: [list_field_2: [5]]
)
```

#### DynamoDBSet

For convenience, we have added an Ecto type, **Ecto.Adapters.DynamoDB.DynamoDBSet**, which casts and validates an elixir MapSet type. Once you've included it in your schema, or extended the Ecto.Type behaviour to MapSet, Ecto Repo insert, update and get commands; and the adapter's DynamoDb set related options, :add and :delete (mentioned in, *Inline Options: Repo.update_all*); will apply to the MapSet type.

Here's an example of how to declare the DynamoDBSet type in an Ecto schema,

```
defmodule Model do
  use Ecto.Schema
  
  schema "model" do
    ...
    field :set,  Ecto.Adapters.DynamoDB.DynamoDBSet
    ...
```

#### **Inline Options:** *Repo.all, Repo.update_all, Repo.delete_all*

**:scan_limit** :: integer, *default:* none, except configuration default applies to the DynamoDB `scan` command

Sets the limit on the number of records scanned in the current query. Included as **limit** in the DynamoDB query.

**:scan** :: boolean, *default:* `false` (also depends on scan-related configuration)

Approves a DynamoDB **scan** command for the current query in case an indexed field is not provided in the query *wheres*.

**:exclusive_start_key** :: [key_atom: value], *default:* none

Adds DynamoDB's **ExclusiveStartKey** to the current query, providing a starting offset.

**:scan_index_forward** :: boolean, *default:* none

Adds DynamoDB's **ScanIndexForward** to the current query, specifying ascending (true/default) or descending (false) traversal of the index. (Quoted from DynamoDB's [documentation](http://docs.aws.amazon.com/sdkfornet1/latest/apidocs/html/P_Amazon_DynamoDBv2_Model_QueryRequest_ScanIndexForward.htm).)

**:consistent_read** :: boolean, *default:* none

If set to `true`, then the operation uses strongly consistent reads; otherwise, eventually consistent reads are used. Strongly consistent reads are not supported on global secondary indexes. If you query a global secondary index with ConsistentRead set to true, you will receive an error message. (Quoted from DynamoDB's [documentation](http://docs.aws.amazon.com/sdkfornet1/latest/apidocs/html/P_Amazon_DynamoDBv2_Model_QueryRequest_ConsistentRead.htm).)

**:recursive** :: boolean, *default:* `true`, except for DynamoDB `scan` where default is `false`

Fetches all pages recursively and performs the relevant operation on results in the case of *Repo.update_all* and *Repo.delete_all*

**:page_limit** :: integer, *default:* none

Sets the maximum number of pages to access. The query will execute recursively until the page limit has been reached or there are no more pages (overrides **:recursive** option).

#### QueryInfo agent

**:query_info_key** :: string, *default:* none

If you would like the query information provided by DynamoDB (for example, to retrieve the LastEvaluatedKey even when no results are returned from the current page), include the option, **query_info_key:** *key_string*.

After the query is completed, retrieve the query info from the adapter's **QueryInfo** agent (the key is automatically deleted from the agent upon retrieval):

`Ecto.Adapters.DynamoDB.QueryInfo.get(key_string)`

The returned map corresponds with DynamoDB's return values:

`%{"Count" => 10, "LastEvaluatedKey" => %{"id" => %{"S" => "6814"}}, "ScannedCount" => 100}`

**Ecto.Adapters.DynamoDB.QueryInfo.get_key** provides a 32-character random string for convenience.

#### **Inline Options:** *Repo.insert, Repo.insert_all*

**:insert_nil_fields** :: boolean, *default:* set in configuration

Determines if fields in the changeset with `nil` values will be inserted as DynamoDB `null` values or not set at all.

#### **Inline Options:** *Repo.update, Repo.update_all*

**:remove_nil_fields** :: boolean, *default:* set in configuration

Determines if fields in the changeset with `nil` values will be removed from the record/s or set to the DynamoDB `null` value.

### DynamoDB `between` and Ecto `:fragment`

We currently only support the Ecto fragments of the form:

`from(m in Model, where: fragment("? between ? and ?", m.attribute, ^range_start, ^range_end))`

`from(m in Model, where: fragment("begins_with(?, ?)", m.attribute, ^prefix))`

## Caching

The adapter automatically caches its own calls to **describe_table** for retrieval of table information. We also offer the option to configure tables for scan caching. To update the cache after making a change in a table, the cache offers two functions:

**Ecto.Adapters.DynamoDB.Cache.update_table_info!(table_name)**, *table_name* :: string

This re-fetches and caches the index data for the given table.

**Ecto.Adapters.DynamoDB.Cache.update_cached_table!(table_name)**, *table_name* :: string

This runs a scan against the given table and updates the in-memory cached copy of it.

## Developer Notes

The **projection_expression** option is used internally during **delete_all** to select only the key attributes and is recognized during query construction.

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at [https://hexdocs.pm/ecto_adapters_dynamodb](https://hexdocs.pm/ecto_adapters_dynamodb).


# License
Copyright Circles Learning Labs

Licensed under the Apache License, Version 2.0 (the "License"); you may not use this project except in compliance with the License.
