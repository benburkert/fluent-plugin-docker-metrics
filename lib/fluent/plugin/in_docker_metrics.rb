# -*- coding: iso-8859-1 -*-
module Fluent
  class DockerMetricsInput < Input
    Plugin.register_input('docker_metrics', self)

    config_param :cgroup_path, :string, :default => '/sys/fs/cgroup'
    config_param :stats_interval, :time, :default => 60 # every minute
    config_param :tag_prefix, :string, :default => "docker"
    config_param :docker_infos_path, :string, :default => '/var/lib/docker/execdriver/native'
    config_param :docker_network_stats, :string, :default => '/sys/class/net'
    config_param :docker_socket, :string, :default => 'unix:///var/run/docker.sock'

    # Parsers
    class CGroupStatsParser
      def initialize(path, metric_type)
        raise ConfigError if not File.exists?(path)
        @path = path
        @metric_type = metric_type
      end

      def parse_line(line)
      end

      def parse_each_line(&block)
        File.new(@path).each_line do |line|
          block.call(parse_line(line))
        end
      end
    end

    class KeyValueStatsParser < CGroupStatsParser
      def parse_line(line)
        k, v = line.split(/\s+/, 2)
        if k and v
          data = { key: @metric_type + "_" + k, value: v.to_i }
          if data[:key] =~ /^(?:cpuacct|blkio|memory_stat_pg)/
            return data, 'counter'
          else
            return data, 'gauge'
          end
        else
          nil
        end
      end
    end

    class BlkioStatsParser < CGroupStatsParser
      BlkioLineRegexp = /^(?<major>\d+):(?<minor>\d+) (?<key>[^ ]+) (?<value>\d+)/
      
      def parse_line(line)
        m = BlkioLineRegexp.match(line)
        if m
          data = { key: @metric_type + "_" + m["key"].downcase, value: m["value"] }
          return data, 'counter'
        else
          return nil, nil
        end
      end
    end

    # Class variables
    @@network_metrics = {'rx_bytes' => 'counter', 
      'tx_bytes' => 'counter',
      'tx_packets' => 'counter',
      'rx_packets' => 'counter',
      'tx_errors' => 'counter',
      'rx_errors' => 'counter'
    }

    @@docker_metrics = {
      "blkio" => {
        "blkio.io_serviced" => BlkioStatsParser,
        "blkio.io_service_bytes" => BlkioStatsParser,
        "blkio.io_service_queued" => BlkioStatsParser,
        "blkio.sectors" => BlkioStatsParser,
      },
      "cpu" => {
      },
      "cpuacct" => {
        "cpuacct.stat" => KeyValueStatsParser,
      },
      "cpuset" => {
      },
      "devices" => {
      },
      "freezer" => {
      },
      "memory" => {
        "memory.stat" => KeyValueStatsParser,
      },
      "perf_event" => {
      },
    }

    def initialize
      super
      require 'socket'
      @hostname = Socket.gethostname
      require 'json'
    end

    def configure(conf)
      super

    end

    def start
      @loop = Coolio::Loop.new
      tw = TimerWatcher.new(@stats_interval, true, @log, &method(:get_metrics))
      tw.attach(@loop)
      @thread = Thread.new(&method(:run))
    end
    def run
      @loop.run
    rescue
      log.error "unexpected error", :error=>$!.to_s
      log.error_backtrace
    end

    def parsed_state_of(id)
      filename = "#{@docker_infos_path}/#{id}/state.json"
      raise ConfigError if not File.exists?(filename)

      # Read JSON from file
      json = File.read(filename)

      JSON.parse(json)
    end

    def get_interface_path(id)
      parsed = parsed_state_of(id)
      interface_name =  parsed["network_state"]["veth_host"]

      interface_statistics_path = "#{@docker_network_stats}/#{interface_name}/statistics"
      return interface_name, interface_statistics_path
    end

    # Metrics collection methods
    def get_metrics
      list_containers.each do |id, name|
        docker_metric_types(id).each do |metric_type, metric_path|
          @@docker_metrics[metric_type].each do |metric_name, metric_parser|
            emit_container_metric(id, name, metric_name, metric_path, metric_parser)
          end
        end

        interface_name, interface_path = get_interface_path(id)

        @@network_metrics.each do |metric_name, metric_type|
          emit_container_network_metric(id, name, interface_name, interface_path, metric_name, metric_type)
        end
      end
    end

    def docker_metric_types(id)
      parsed_state_of(id)["cgroup_paths"]
    end


    def list_containers
      `docker -H #{@docker_socket} ps --no-trunc`.lines[1..-1].inject({}) do |h, line|
        parts = line.split(/\s+/)
        h.update(parts[0] => parts[-1])
      end
    end

    def emit_container_network_metric(id, name, interface_name, path, metric_filename, metric_type)
      filename = "#{path}/#{metric_filename}"
      raise ConfigError if not File.exists?(filename)

      data = {}

      time = Engine.now
      mes = MultiEventStream.new

      value = File.read(filename)
      data[:key] = metric_filename
      data[:value] = value.to_i
      data[:type] = metric_type
      data[:if_name] = interface_name
      data[:td_agent_hostname] = "#{@hostname}"
      data[:source] = "#{@tag_prefix}:#{@hostname}:#{name}:#{id[0,12]}"
      mes.add(time, data)

      tag = "#{@tag_prefix}.network.stat"
      Engine.emit_stream(tag, mes)
    end

    def emit_container_metric(id, name, metric_name, metric_path, metric_parser)
      path = File.join(metric_path, metric_name)
      if File.exists?(path)
        parser = metric_parser.new(path, metric_name.gsub('.', '_'))
        time = Engine.now
        tag = "#{@tag_prefix}.#{metric_name}"
        mes = MultiEventStream.new
        parser.parse_each_line do |data, type|
          next unless data

          data[:type] = type
          data[:td_agent_hostname] = "#{@hostname}"
          data[:source] = "#{@tag_prefix}:#{@hostname}:#{name}:#{id[0,12]}"
          mes.add(time, data)
        end
        Engine.emit_stream(tag, mes)
      else
        nil
      end
    end

    def shutdown
      @loop.stop
      @thread.join
    end

    class TimerWatcher < Coolio::TimerWatcher

      def initialize(interval, repeat, log, &callback)
        @callback = callback
        @log = log
        super(interval, repeat)
      end
      def on_timer
        @callback.call
      rescue
        @log.error $!.to_s
        @log.error_backtrace
      end
    end
  end
end
