require 'socket'
require 'capistrano_dsl'

module Centurion
  class Service
    extend ::Capistrano::DSL

    attr_accessor :command, :dns, :extra_hosts, :image, :name, :volumes, :port_bindings, :network_mode, :pid_mode, :cap_adds, :cap_drops, :ipc_mode, :security_opt
    attr_reader :memory, :cpu_shares, :env_vars, :labels

    def initialize(name)
      @name          = name
      @env_vars      = {}
      @volumes       = []
      @port_bindings = []
      @cap_adds      = []
      @cap_drops     = []
      @labels        = {}
      @security_opt  = []
      @network_mode  = 'bridge'
    end

    def self.from_env
      Service.new(fetch(:name)).tap do |s|
        s.image = if fetch(:tag, nil)
          "#{fetch(:image, nil)}:#{fetch(:tag)}"
        else
          fetch(:image, nil)
        end

        s.cap_adds      = fetch(:cap_adds, [])
        s.cap_drops     = fetch(:cap_drops, [])
        s.dns           = fetch(:dns, nil)
        s.extra_hosts   = fetch(:extra_hosts, nil)
        s.volumes       = fetch(:binds, [])
        s.port_bindings = fetch(:port_bindings, [])
        s.network_mode  = fetch(:network_mode, 'bridge')
        s.pid_mode      = fetch(:pid_mode, nil)
        s.command       = fetch(:command, nil)
        s.memory        = fetch(:memory, 0)
        s.cpu_shares    = fetch(:cpu_shares, 0)
        s.ipc_mode      = fetch(:ipc_mode, nil)
        s.security_opt  = fetch(:security_opt, [])

        s.add_labels(fetch(:labels, {}))
        s.add_env_vars(fetch(:env_vars, {}))
      end
    end

    def add_env_vars(new_vars)
      @env_vars.merge!(new_vars)
    end

    def add_port_bindings(host_port, container_port, type = 'tcp', host_ip = nil)
      @port_bindings << PortBinding.new(host_port, container_port, type, host_ip)
    end

    def add_volume(host_volume, container_volume)
      @volumes << Volume.new(host_volume, container_volume)
    end

    def add_labels(labels)
      @labels.merge!(Hash[labels.map { |(k,v)| [ k.to_s, v.to_s ]}])
    end

    def cap_adds=(capabilites)
      unless capabilites.is_a? Array
        raise ArgumentError, "invalid value for capability additions: #{capabilites}, value must be an array"
      end
      @cap_adds = capabilites
    end

    def cap_drops=(capabilites)
      unless capabilites.is_a? Array
        raise ArgumentError, "invalid value for capability drops: #{capabilites}, value must be an array"
      end
      @cap_drops = capabilites
    end

    def memory=(bytes)
      if !bytes || !is_a_uint64?(bytes)
        raise ArgumentError, "invalid value for cgroup memory constraint: #{bytes}, value must be a between 0 and 18446744073709551615"
      end
      @memory = bytes
    end

    def cpu_shares=(shares)
      if !shares || !is_a_uint64?(shares)
        raise ArgumentError, "invalid value for cgroup CPU constraint: #{shares}, value must be a between 0 and 18446744073709551615"
      end
      @cpu_shares = shares
    end

    def image=(image)
      @image = image
    end

    def ipc_mode=(mode)
      @ipc_mode = mode
    end

    def add_security_opt(seccomp)
      @security_opt << seccomp
    end

    def build_config(server_hostname, restart_policy, &block)
      container_config = {}.tap do |c|
        c['Image'] = image
        c['Hostname'] = block.call(server_hostname) if block_given?
        c['Cmd'] = command if command
        c['Memory'] = memory if memory
        c['CpuShares'] = cpu_shares if cpu_shares
        c['Labels'] = labels unless labels.nil? || labels.empty?
      end

      unless port_bindings.empty?
        container_config['ExposedPorts'] = port_bindings.reduce({}) do |config, binding|
          config["#{binding.container_port}/#{binding.type}"] = {}
          config
        end
      end

      unless env_vars.empty?
        container_config['Env'] = env_vars.map do |k,v|
          if v.respond_to? :call
            "#{k}=#{v.call(server_hostname)}"
          else
            "#{k}=#{interpolate_var(v, server_hostname)}"
          end
        end
      end

      unless volumes.empty?
        container_config['Volumes'] = volumes.inject({}) do |memo, v|
          memo[v.container_volume] = {}
          memo
        end
      end

      container_config['HostConfig'] = build_host_config(restart_policy)

      container_config
    end

    def build_host_config(restart_policy = nil)
      host_config = {}

      # Set capability additions and drops
      host_config['CapAdd'] = cap_adds if cap_adds
      host_config['CapDrop'] = cap_drops if cap_drops

      # Map some host volumes if needed
      host_config['Binds'] = volume_binds_config if volume_binds_config

      # Bind the ports
      host_config['PortBindings'] = port_bindings_config

      # Set the network mode
      host_config['NetworkMode'] = network_mode

      # Set the pid mode if specified
      host_config['PidMode'] = pid_mode if pid_mode

      # DNS if specified
      host_config['Dns'] = dns if dns

      # Add ExtraHosts if needed
      host_config['ExtraHosts'] = extra_hosts if extra_hosts

      # Set memory limits
      host_config['Memory'] = memory if memory

      # Set cpushare limits
      host_config['CpuShares'] = cpu_shares if cpu_shares

      # Set ipc mode
      host_config['IpcMode'] = ipc_mode if ipc_mode

      # Set seccomp profile
      host_config['SecurityOpt'] = security_opt unless security_opt.nil? || security_opt.empty?

      # Restart Policy
      if restart_policy
        host_config['RestartPolicy'] = {}

        restart_policy_name = restart_policy.name
        restart_policy_name = 'on-failure' unless ["always", "on-failure", "no", "unless-stopped"].include?(restart_policy_name)

        host_config['RestartPolicy']['Name'] = restart_policy_name
        host_config['RestartPolicy']['MaximumRetryCount'] = restart_policy.max_retry_count || 10 if restart_policy_name == 'on-failure'
      end

      host_config
    end

    def build_console_config(server_name, &block)
      build_config(server_name, &block).merge({
        'Cmd' => ['/bin/bash'],
        'AttachStdin' => true,
        'Tty'         => true,
        'OpenStdin'   => true,
      })
    end

    def volume_binds_config
      @volumes.map { |volume| "#{volume.host_volume}:#{volume.container_volume}" }
    end

    def port_bindings_config
      @port_bindings.inject({}) do |memo, binding|
        config = {}
        config['HostPort'] = binding.host_port.to_s
        config['HostIp'] = binding.host_ip if binding.host_ip
        memo["#{binding.container_port}/#{binding.type}"] = [config]
        memo
      end
    end

    def public_ports
      @port_bindings.map(&:host_port)
    end

    private

    def is_a_uint64?(value)
      result = false
      if !value.is_a? Integer
        return result
      end
      if value < 0 || value > 0xFFFFFFFFFFFFFFFF
        return result
      end
      return true
    end

    def interpolate_var(val, hostname)
      val.to_s.gsub('%DOCKER_HOSTNAME%', hostname)
        .gsub('%DOCKER_HOST_IP%', host_ip(hostname))
    end

    def host_ip(hostname)
      @host_ip ||= {}
      return @host_ip[hostname] if @host_ip.has_key?(hostname)
      @host_ip[hostname] = Socket.getaddrinfo(hostname, nil).first[2]
    end

    class RestartPolicy < Struct.new(:name, :max_retry_count)
    end

    class Volume < Struct.new(:host_volume, :container_volume)
    end

    class PortBinding < Struct.new(:host_port, :container_port, :type, :host_ip)
    end
  end
end
