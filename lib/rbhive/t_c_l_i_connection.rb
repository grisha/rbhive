# suppress warnings
old_verbose, $VERBOSE = $VERBOSE, nil

raise 'Thrift is not loaded' unless defined?(Thrift)
raise 'RBHive is not loaded' unless defined?(RBHive)

# require thrift autogenerated files
require File.join(File.dirname(__FILE__), *%w[.. thrift t_c_l_i_service_constants])
require File.join(File.dirname(__FILE__), *%w[.. thrift t_c_l_i_service])
require File.join(File.dirname(__FILE__), *%w[.. thrift sasl_client_transport])

# restore warnings
$VERBOSE = old_verbose

# Monkey patch thrift to set an infinite read timeout
module Thrift
  class HTTPClientTransport < BaseTransport
    def flush
      http = Net::HTTP.new @url.host, @url.port
      http.use_ssl = @url.scheme == 'https'
      http.read_timeout = nil
      http.verify_mode = @ssl_verify_mode if @url.scheme == 'https'
      resp = http.post(@url.request_uri, @outbuf, @headers)
      data = resp.body
      data = Bytes.force_binary_encoding(data)
      @inbuf = StringIO.new data
      @outbuf = Bytes.empty_byte_buffer
    end
  end
end

module RBHive

  HIVE_THRIFT_MAPPING = {
    10 => 0,
    11 => 1,
    12 => 2,
    13 => 6,
    :cdh4 => 0,
    :cdh5 => 4,
    :PROTOCOL_V1 => 0,
    :PROTOCOL_V2 => 1,
    :PROTOCOL_V3 => 2,
    :PROTOCOL_V4 => 3,
    :PROTOCOL_V5 => 4,
    :PROTOCOL_V6 => 5,
    :PROTOCOL_V7 => 6
  }

  def tcli_connect(server, port=10_000, options={})
    connection = RBHive::TCLIConnection.new(server, port, options)
    ret = nil
    begin
      connection.open
      connection.open_session
      ret = yield(connection)

    ensure
      # Try to close the session and our connection if those are still open, ignore io errors
      begin
        connection.close_session if connection.session
        connection.close
      rescue IOError => e
        # noop
      end
    end

    return ret
  end
  module_function :tcli_connect

  class StdOutLogger
    %w(fatal error warn info debug).each do |level|
      define_method level.to_sym do |message|
        STDOUT.puts(message)
     end
   end
  end

  class TCLIConnection
    attr_reader :client

    def initialize(server, port=10_000, options={}, logger=StdOutLogger.new)
      options ||= {} # backwards compatibility
      raise "'options' parameter must be a hash" unless options.is_a?(Hash)

      if options[:transport] == :sasl and options[:sasl_params].nil?
        raise ":transport is set to :sasl, but no :sasl_params option was supplied"
      end

      # Defaults to buffered transport, Hive 0.10, 1800 second timeout
      options[:transport]     ||= :buffered
      options[:hive_version]  ||= 10
      options[:timeout]       ||= 1800
      @options = options

      # Look up the appropriate Thrift protocol version for the supplied Hive version
      @thrift_protocol_version = thrift_hive_protocol(options[:hive_version])

      @logger = logger
      @transport = thrift_transport(server, port)
      @protocol = Thrift::BinaryProtocol.new(@transport)
      @client = Hive2::Thrift::TCLIService::Client.new(@protocol)
      @session = nil
      @logger.info("Connecting to HiveServer2 #{server} on port #{port}")
    end

    def thrift_hive_protocol(version)
      HIVE_THRIFT_MAPPING[version] || raise("Invalid Hive version")
    end

    def thrift_transport(server, port)
      @logger.info("Initializing transport #{@options[:transport]}")
      case @options[:transport]
      when :buffered
        return Thrift::BufferedTransport.new(thrift_socket(server, port, @options[:timeout]))
      when :sasl
        return Thrift::SaslClientTransport.new(thrift_socket(server, port, @options[:timeout]),
                                               parse_sasl_params(@options[:sasl_params]))
      when :http
        return Thrift::HTTPClientTransport.new("http://#{server}:#{port}/cliservice")
      else
        raise "Unrecognised transport type '#{transport}'"
      end
    end

    def thrift_socket(server, port, timeout)
      socket = Thrift::Socket.new(server, port)
      socket.timeout = timeout
      socket
    end

    # Processes SASL connection params and returns a hash with symbol keys or a nil
    def parse_sasl_params(sasl_params)
      # Symbilize keys in a hash
      if sasl_params.kind_of?(Hash)
        return sasl_params.inject({}) do |memo,(k,v)|
          memo[k.to_sym] = v;
          memo
        end
      end
      return nil
    end

    def open
      @transport.open
    end

    def close
      @transport.close
    end

    def open_session
      @session = @client.OpenSession(prepare_open_session(@thrift_protocol_version))
    end

    def close_session
      @client.CloseSession prepare_close_session
      @session = nil
    end

    def session
      @session && @session.sessionHandle
    end

    def client
      @client
    end

    def execute(query)
      @logger.info("Executing Hive Query: #{query}")
      req = prepare_execute_statement(query)
      exec_result = client.ExecuteStatement(req)
      raise_error_if_failed!(exec_result)
      exec_result
    end

    def priority=(priority)
      set("mapred.job.priority", priority)
    end

    def queue=(queue)
      set("mapred.job.queue.name", queue)
    end

    def set(name,value)
      @logger.info("Setting #{name}=#{value}")
      self.execute("SET #{name}=#{value}")
    end

    # Async execute
    def async_execute(query)
      @logger.info("Executing query asynchronously: #{query}")
      op_handle = @client.ExecuteStatement(
        Hive2::Thrift::TExecuteStatementReq.new(
          sessionHandle: @session.sessionHandle,
          statement: query,
          runAsync: true
        )
      ).operationHandle

      # Return handles to get hold of this query / session again
      {
        session: @session.sessionHandle,
        guid: op_handle.operationId.guid,
        secret: op_handle.operationId.secret
      }
    end

    # Is the query complete?
    def async_is_complete?(handles)
      async_state(handles) == :finished
    end

    # Is the query actually running?
    def async_is_running?(handles)
      async_state(handles) == :running
    end

    # Has the query failed?
    def async_is_failed?(handles)
      async_state(handles) == :error
    end

    def async_is_cancelled?(handles)
      async_state(handles) == :cancelled
    end

    def async_cancel(handles)
      @client.CancelOperation(prepare_cancel_request(handles))
    end

    # Map states to symbols
    def async_state(handles)
      response = @client.GetOperationStatus(
        Hive2::Thrift::TGetOperationStatusReq.new(operationHandle: prepare_operation_handle(handles))
      )
      puts response.operationState
      case response.operationState
      when Hive2::Thrift::TOperationState::FINISHED_STATE
        return :finished
      when Hive2::Thrift::TOperationState::INITIALIZED_STATE
        return :initialized
      when Hive2::Thrift::TOperationState::RUNNING_STATE
        return :running
      when Hive2::Thrift::TOperationState::CANCELED_STATE
        return :cancelled
      when Hive2::Thrift::TOperationState::CLOSED_STATE
        return :closed
      when Hive2::Thrift::TOperationState::ERROR_STATE
        return :error
      when Hive2::Thrift::TOperationState::UKNOWN_STATE
        return :unknown
      when Hive2::Thrift::TOperationState::PENDING_STATE
        return :pending
      else
        return :state_not_in_protocol
      end
    end

    # Async fetch results from an async execute
    def async_fetch(handles, max_rows = 100)
      # Can't get data from an unfinished query
      unless async_is_complete?(handles)
        raise "Can't perform fetch on a query in state: #{async_state(handles)}"
      end

      # Fetch and
      fetch_rows(prepare_operation_handle(handles), :first, max_rows)
    end

    # Performs a query on the server, fetches the results in batches of *batch_size* rows
    # and yields the result batches to a given block as arrays of rows.
    def async_fetch_in_batch(handles, batch_size = 1000, &block)
      raise "No block given for the batch fetch request!" unless block_given?
      # Can't get data from an unfinished query
      unless async_is_complete?(handles)
        raise "Can't perform fetch on a query in state: #{async_state(handles)}"
      end

      # Now let's iterate over the results
      loop do
        rows = fetch_rows(prepare_operation_handle(handles), :next, batch_size)
        break if rows.empty?
        yield rows
      end
    end

    def async_close_session(handles)
      validate_handles!(handles)
      @client.CloseSession(Hive2::Thrift::TCloseSessionReq.new( sessionHandle: handles[:session] ))
    end

    # Pull rows from the query result
    def fetch_rows(op_handle, orientation = :first, max_rows = 1000)
      fetch_req = prepare_fetch_results(op_handle, orientation, max_rows)
      fetch_results = @client.FetchResults(fetch_req)
      raise_error_if_failed!(fetch_results)
      rows = fetch_results.results.rows
      TCLIResultSet.new(rows, TCLISchemaDefinition.new(get_schema_for(op_handle), rows.first))
    end

    # Performs a explain on the supplied query on the server, returns it as a ExplainResult.
    # (Only works on 0.12 if you have this patch - https://issues.apache.org/jira/browse/HIVE-5492)
    def explain(query)
      rows = []
      fetch_in_batch("EXPLAIN " + query) do |batch|
        rows << batch.map { |b| b[:Explain] }
      end
      ExplainResult.new(rows.flatten)
    end

    # Performs a query on the server, fetches up to *max_rows* rows and returns them as an array.
    def fetch(query, max_rows = 100)
      # Execute the query and check the result
      exec_result = execute(query)
      raise_error_if_failed!(exec_result)

      # Get search operation handle to fetch the results
      op_handle = exec_result.operationHandle

      # Fetch the rows
      fetch_rows(op_handle, :first, max_rows)
    end

    # Performs a query on the server, fetches the results in batches of *batch_size* rows
    # and yields the result batches to a given block as arrays of rows.
    def fetch_in_batch(query, batch_size = 1000, &block)
      raise "No block given for the batch fetch request!" unless block_given?

      # Execute the query and check the result
      exec_result = execute(query)
      raise_error_if_failed!(exec_result)

      # Get search operation handle to fetch the results
      op_handle = exec_result.operationHandle

      # Prepare fetch results request
      fetch_req = prepare_fetch_results(op_handle, :next, batch_size)

      # Now let's iterate over the results
      loop do
        rows = fetch_rows(op_handle, :next, batch_size)
        break if rows.empty?
        yield rows
      end
    end

    def create_table(schema)
      execute(schema.create_table_statement)
    end

    def drop_table(name)
      name = name.name if name.is_a?(TableSchema)
      execute("DROP TABLE `#{name}`")
    end

    def replace_columns(schema)
      execute(schema.replace_columns_statement)
    end

    def add_columns(schema)
      execute(schema.add_columns_statement)
    end

    def method_missing(meth, *args)
      client.send(meth, *args)
    end

    private

    def prepare_open_session(client_protocol)
      req = ::Hive2::Thrift::TOpenSessionReq.new( @options[:sasl_params].nil? ? [] : {
                                                    :username => @options[:sasl_params][:username],
                                                    :password => @options[:sasl_params][:password]})
      req.client_protocol = client_protocol
      req
    end

    def prepare_close_session
      ::Hive2::Thrift::TCloseSessionReq.new( sessionHandle: self.session )
    end

    def prepare_execute_statement(query)
      ::Hive2::Thrift::TExecuteStatementReq.new( sessionHandle: self.session, statement: query.to_s, confOverlay: {} )
    end

    def prepare_fetch_results(handle, orientation=:first, rows=100)
      orientation_value = "FETCH_#{orientation.to_s.upcase}"
      valid_orientations = ::Hive2::Thrift::TFetchOrientation::VALUE_MAP.values
      unless valid_orientations.include?(orientation_value)
        raise ArgumentError, "Invalid orientation: #{orientation.inspect}"
      end
      orientation_const = eval("::Hive2::Thrift::TFetchOrientation::#{orientation_value}")
      ::Hive2::Thrift::TFetchResultsReq.new(
        operationHandle: handle,
        orientation: orientation_const,
        maxRows: rows
      )
    end

    def prepare_operation_handle(handles)
      validate_handles!(handles)
      Hive2::Thrift::TOperationHandle.new(
        operationId: Hive2::Thrift::THandleIdentifier.new(guid: handles[:guid], secret: handles[:secret]),
        operationType: Hive2::Thrift::TOperationType::EXECUTE_STATEMENT,
        hasResultSet: false
      )
    end

    def prepare_cancel_request(handles)
      Hive2::Thrift::TCancelOperationReq.new(
        operationHandle: prepare_operation_handle(handles)
      )
    end

    def validate_handles!(handles)
      unless handles.has_key?(:guid) and handles.has_key?(:secret) and handles.has_key?(:session)
        raise "Invalid handles hash: #{handles.inspect}"
      end
    end

    def get_schema_for(handle)
      req = ::Hive2::Thrift::TGetResultSetMetadataReq.new( operationHandle: handle )
      metadata = client.GetResultSetMetadata( req )
      metadata.schema
    end

    # Raises an exception if given operation result is a failure
    def raise_error_if_failed!(result)
      return if result.status.statusCode == 0
      error_message = result.status.errorMessage || 'Execution failed!'
      error_code = result.status.errorCode || "-1"
      sql_state = result.status.sqlState || "unknown SQL_STATE"
      raise RBHive::HiveServerException.new(message: error_message, errorCode: error_code, SQLState: sql_state)
    end
  end

  class HiveServerException < ::Thrift::Exception
    include ::Thrift::Struct, ::Thrift::Struct_Union
    MESSAGE = 1
    ERRORCODE = 2
    SQLSTATE = 3

    FIELDS = {
      MESSAGE => {:type => ::Thrift::Types::STRING, :name => 'message'},
      ERRORCODE => {:type => ::Thrift::Types::I32, :name => 'errorCode'},
      SQLSTATE => {:type => ::Thrift::Types::STRING, :name => 'SQLState'}
    }

    def struct_fields; FIELDS; end

    def validate
    end

    ::Thrift::Struct.generate_accessors self
  end
end
