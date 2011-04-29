# Copyright (c) 2009-2011 VMware, Inc.
require "erb"
require "fileutils"
require "logger"
require "pp"

require "datamapper"
require "uuidtools"
require "mysql"

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', '..', '..', 'base', 'lib')
require 'base/node'
require 'base/service_error'

module VCAP
  module Services
    module Mysql
      class Node < VCAP::Services::Base::Node
      end
    end
  end
end

require "mysql_service/common"
require "mysql_service/util"
require "mysql_service/storage_quota"
require "mysql_service/mysql_error"

class VCAP::Services::Mysql::Node

  KEEP_ALIVE_INTERVAL = 15
  LONG_QUERY_INTERVAL = 1
  STORAGE_QUOTA_INTERVAL = 1

  include VCAP::Services::Mysql::Util
  include VCAP::Services::Mysql::Common
  include VCAP::Services::Mysql

  class ProvisionedService
    include DataMapper::Resource
    property :name,       String,   :key => true
    property :user,       String,   :required => true
    property :password,   String,   :required => true
    property :plan,       Enum[:free], :required => true
    property :quota_exceeded,  Boolean, :default => false
  end

  def initialize(options)
    super(options)

    @mysql_config = options[:mysql]

    @max_db_size = options[:max_db_size] * 1024 * 1024
    @max_long_query = options[:max_long_query]
    @max_long_tx = options[:max_long_tx]

    @connection = mysql_connect

    EM.add_periodic_timer(KEEP_ALIVE_INTERVAL) {mysql_keep_alive}
    EM.add_periodic_timer(LONG_QUERY_INTERVAL) {kill_long_queries}
    EM.add_periodic_timer(@max_long_tx/2) {kill_long_transaction} if @max_long_tx > 0
    EM.add_periodic_timer(STORAGE_QUOTA_INTERVAL) {enforce_storage_quota}

    @base_dir = options[:base_dir]
    FileUtils.mkdir_p(@base_dir) if @base_dir

    DataMapper.setup(:default, options[:local_db])
    DataMapper::auto_upgrade!

    check_db_consistency()

    @available_storage = options[:available_storage] * 1024 * 1024
    @node_capacity = @available_storage
    ProvisionedService.all.each do |provisioned_service|
      @available_storage -= storage_for_service(provisioned_service)
    end

    @queries_served=0
    @qps_last_updated=0
    # initialize qps counter
    get_qps
    @long_queries_killed=0
    @long_tx_killed=0
    @provision_served=0
    @binding_served=0
  end

  def announcement
    a = {
      :available_storage => @available_storage
    }
    a
  end

  def check_db_consistency()
    db_list = []
    @connection.query('select db, user from db').each{|db, user| db_list.push([db, user])}
    ProvisionedService.all.each do |service|
      db, user = service.name, service.user
      if not db_list.include?([db, user]) then
        @logger.info("Node database inconsistent!!! db:user <#{db}:#{user}> not in mysql.")
        next
      end
    end
  end

  def storage_for_service(provisioned_service)
    case provisioned_service.plan
    when :free then @max_db_size
    else
      raise MysqlError.new(MysqlError::MYSQL_INVALID_PLAN, provisioned_service.plan)
    end
  end

  def mysql_connect
    host, user, password, port, socket =  %w{host user pass port socket}.map { |opt| @mysql_config[opt] }

    5.times do
      begin
        return Mysql.real_connect(host, user, password, 'mysql', port.to_i, socket)
      rescue Mysql::Error => e
        @logger.info("MySQL connection attempt failed: [#{e.errno}] #{e.error}")
        sleep(5)
      end
    end

    @logger.fatal("MySQL connection unrecoverable")
    shutdown
    exit
  end

  #keep connection alive, and check db liveness
  def mysql_keep_alive
    @connection.ping()
  rescue Mysql::Error => e
    @logger.info("MySQL connection lost: [#{e.errno}] #{e.error}")
    @connection = mysql_connect
  end

  def kill_long_queries
    process_list = @connection.list_processes
    process_list.each do |proc|
      thread_id, user, _, db, command, time, _, info = proc
      if (time.to_i >= @max_long_query) and (command == 'Query') and (user != 'root') then
        @connection.query("KILL QUERY " + thread_id)
        @logger.info("Killed long query: user:#{user} db:#{db} time:#{time} info:#{info}")
        @long_queries_killed += 1
      end
    end
  rescue Mysql::Error => e
    @logger.info("MySQL error: [#{e.errno}] #{e.error}")
  end

  def kill_long_transaction
    # FIXME need a better transaction query solution other than parse status text
    result = @connection.query("SHOW ENGINE INNODB STATUS")
    innodb_status = nil
    result.each do |i|
      innodb_status = i[-1]
    end
    lines = innodb_status.split(/\n/).map{|line| line.strip}
    i = 0
    while i<= lines.size
      if lines[i] =~ /---TRANSACTION.*ACTIVE (\d*) sec/ && $1.to_i >= @max_long_tx
        active_time = $1
        i += 1
        # Quit if the line starts with item delimiter ---
        while (lines[i] =~ /^---/) == nil
          if lines[i] =~ /MySQL thread id (\d*).* (\w*)$/
            @connection.query("KILL QUERY #{$1}")
            @logger.info"Kill long transaction: user:#{$2} thread: #{$1} active_time:#{active_time}"
            @long_tx_killed +=1
          end
          i +=1
        end
      else
        i += 1
      end
    end
  rescue => e
    @logger.error("Error during kill long tx: #{e}. Innodb status:#{result}")
  end

  def provision(plan)
    provisioned_service = ProvisionedService.new
    provisioned_service.name = "d-#{UUIDTools::UUID.random_create.to_s}".gsub(/-/, '')
    provisioned_service.user = 'u' + generate_credential
    provisioned_service.password = 'p' + generate_credential
    provisioned_service.plan = plan

    create_database(provisioned_service)

    if not provisioned_service.save
      @logger.error("Could not save entry: #{provisioned_service.errors.pretty_inspect}")
      raise MysqlError.new(MysqlError::MYSQL_LOCAL_DB_ERROR)
    end
    response = gen_credential(provisioned_service.name, provisioned_service.user, provisioned_service.password)
    @provision_served += 1
    return response
  rescue => e
    delete_database(provisioned_service)
    raise e
  end

  def unprovision(name, credentials)
    return if name.nil?
    @logger.debug("Unprovision database:#{name}, bindings: #{credentials.inspect}")
    provisioned_service = ProvisionedService.get(name)
    raise MysqlError.new(MysqlError::MYSQL_CONFIG_NOT_FOUND, name) if provisioned_service.nil?
    delete_database(provisioned_service)
    # TODO: validate that database files are not lingering
    storage = storage_for_service(provisioned_service)
    @available_storage += storage
    # Delete all bindings, ignore not_found error since we are unprovision
    begin
      credentials.each{ |credential| unbind(credential)} if credentials
    rescue =>e
      # ignore
    end
    if not provisioned_service.destroy
      @logger.error("Could not delete service: #{provisioned_service.errors.pretty_inspect}")
      raise MysqlError.new(MysqError::MYSQL_LOCAL_DB_ERROR)
    end
    @logger.debug("Successfully fulfilled unprovision request: #{name}")
    true
  end

  def bind(name, bind_opts)
    @logger.debug("Bind service for db:#{name}, bind_opts = #{bind_opts}")
    binding = nil
    begin
      service = ProvisionedService.get(name)
      raise MysqlError.new(MysqlError::MYSQL_CONFIG_NOT_FOUND, name) unless service
      # create new credential for binding
      binding = Hash.new
      binding[:user] = 'u' + generate_credential
      binding[:password ]= 'p' + generate_credential
      binding[:bind_opts] = bind_opts
      create_database_user(name, binding[:user], binding[:password])
      response = gen_credential(name, binding[:user], binding[:password])
      @logger.debug("Bind response: #{response.inspect}")
      @binding_served += 1
      return response
    rescue => e
      delete_database_user(binding[:user]) if binding
      raise e
    end
  end

  def unbind(credential)
    return if credential.nil?
    @logger.debug("Unbind service: #{credential.inspect}")
    name, user, bind_opts,passwd = %w(name user bind_opts password).map{|k| credential[k]}
    service = ProvisionedService.get(name)
    raise MysqlError.new(MysqlError::MYSQL_CONFIG_NOT_FOUND, name) unless service
    # validate the existence of credential, in case we delete a normal account because of a malformed credential
    res = @connection.query("SELECT * from mysql.user WHERE user='#{user}' AND password=PASSWORD('#{passwd}')")
    raise MysqlError.new(MysqlError::MYSQL_CRED_NOT_FOUND, credential.inspect) if res.num_rows()<=0
    delete_database_user(user)
    true
  end

  def create_database(provisioned_service)
    name, password, user = [:name, :password, :user].map { |field| provisioned_service.send(field) }
    begin
      start = Time.now
      @logger.debug("Creating: #{provisioned_service.pretty_inspect}")
      @connection.query("CREATE DATABASE #{name}")
      create_database_user(name, user, password)
      storage = storage_for_service(provisioned_service)
      raise MysqlError.new(MysqlError::MYSQL_DISK_FULL) if @available_storage < storage
      @available_storage -= storage
      @logger.debug("Done creating #{provisioned_service.pretty_inspect}. Took #{Time.now - start}.")
    rescue Mysql::Error => e
      @logger.warn("Could not create database: [#{e.errno}] #{e.error}")
    end
  end

  def create_database_user(name, user, password)
      @logger.info("Creating credentials: #{user}/#{password} for database #{name}")
      @connection.query("GRANT ALL ON #{name}.* to #{user}@'%' IDENTIFIED BY '#{password}'")
      @connection.query("GRANT ALL ON #{name}.* to #{user}@'localhost' IDENTIFIED BY '#{password}'")
      @connection.query("FLUSH PRIVILEGES")
  end

  def delete_database(provisioned_service)
    name, user = [:name, :user].map { |field| provisioned_service.send(field) }
    begin
      @logger.info("Deleting database: #{name}")
      @connection.query("DROP DATABASE #{name}")
      delete_database_user(user)
    rescue Mysql::Error => e
      @logger.fatal("Could not delete database: [#{e.errno}] #{e.error}")
    end
  end

  def delete_database_user(user)
    @logger.info("Delete user #{user}")
    begin
      process_list = @connection.list_processes
      process_list.each do |proc|
        thread_id, user_, _, db, command, time, _, info = proc
        if user_ == user then
          @connection.query("KILL #{thread_id}")
          @logger.info("Kill session: user:#{user} db:#{db}")
        end
      end
    rescue Mysql::Error => e1
      # kill session failed error, only log it.
      @logger.error("Could not kill user session.:[#{e1.errno}] #{e1.error}")
    end
    @connection.query("DROP USER #{user}")
    @connection.query("DROP USER #{user}@'localhost'")
  rescue Mysql::Error => e
    @logger.fatal("Could not delete user '#{user}': [#{e.errno}] #{e.error}")
  end

  def varz_details()
    @logger.debug("Generate varz.")
    varz = {}
    # how many queries served since startup
    varz[:queries_since_startup] = get_queries_status
    # queries per second
    varz[:queries_per_second] = get_qps
    # disk usage per instance
    status = get_instance_status
    varz[:database_status] = status
    # node capacity
    varz[:node_storage_capacity] = @node_capacity
    varz[:node_storage_used] = @node_capacity - @available_storage
    # how many long queries and long txs are killed.
    varz[:long_queries_killed] = @long_queries_killed
    varz[:long_transactions_killed] = @long_tx_killed
    # how many provision/binding operations since startup.
    varz[:provision_served] = @provision_served
    varz[:binding_served] = @binding_served
    @logger.debug("Varz update: #{varz.inspect}")
    varz
  rescue => e
    @logger.error("Error during generate varz:"+e)
    {}
  end

  def get_queries_status()
    @logger.debug("Get mysql query status.")
    result = @connection.query("SHOW STATUS WHERE Variable_name ='QUERIES'")
    return 0 if result.num_rows == 0
    return result.fetch_row[1].to_i
  end

  def get_qps()
    @logger.debug("Calculate queries per seconds.")
    queries = get_queries_status
    ts = Time.now.to_i
    delta_t = (ts - @qps_last_updated).to_f
    qps = (queries - @queries_served)/delta_t
    @queries_served = queries
    @qps_last_updated = ts
    qps
  end

  def get_instance_status()
    @logger.debug("Get database instance status.")
    all_dbs =[]
    result = @connection.query('show databases')
    result.each {|db| all_dbs << db[0]}
    system_dbs = ['mysql', 'information_schema']
    sizes = @connection.query(
      'SELECT table_schema "name",
       sum( data_length + index_length ) "size"
       FROM information_schema.TABLES
       GROUP BY table_schema')
    result = []
    db_with_tables = []
    sizes.each do |i|
      db= {}
      name, size = i
      next if system_dbs.include?(name)
      db_with_tables << name
      db[:name] = name
      db[:size] = size.to_i
      db[:max_size] = @max_db_size
      result << db
    end
    # handle empty db without table
    (all_dbs - db_with_tables - system_dbs ).each do |db|
      result << {:name => db, :size => 0, :max_size => @max_db_size}
    end
    result
  end

  def gen_credential(name, user, passwd)
    response = {
      "name" => name,
      "hostname" => @local_ip,
      "port" => @mysql_config['port'],
      "user" => user,
      "password" => passwd,
    }
  end
end