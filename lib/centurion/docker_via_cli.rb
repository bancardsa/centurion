require 'pty'
require_relative 'logging'
require_relative 'shell'
require 'centurion/ssh'

module Centurion; end

class Centurion::DockerViaCli
  include Centurion::Logging

  def initialize(hostname, port, docker_path, connection_opts = {})
    if connection_opts[:ssh]
      @docker_host = hostname
    else
      @docker_host = "tcp://#{hostname}:#{port}"
    end
    @docker_path = docker_path
    @connection_opts = connection_opts
  end

  def pull(image, tag='latest')
    info 'Using CLI to pull'
    connect do
      Centurion::Shell.echo(build_command(:pull, "#{image}:#{tag}"))
    end
  end

  def tail(container_id)
    info "Tailing the logs on #{container_id}"
    connect do
      Centurion::Shell.echo(build_command(:logs, container_id))
    end
  end

  def attach(container_id)
    connect do
      Centurion::Shell.echo(build_command(:attach, container_id))
    end
  end

  def exec(container_id, commandline)
    connect do
      Centurion::Shell.echo(build_command(:exec, "#{container_id} #{commandline}"))
    end
  end

  def exec_it(container_id, commandline)
    # the "or true" on the command is to prevent an exception from Shell.validate_status
    # because docker exec returns the same exit code as the latest command executed on
    # the shell, which causes an exception to be raised if the latest comand executed
    # was unsuccessful when you exit the shell.
    connect do
      Centurion::Shell.echo(build_command(:exec, "-it #{container_id} #{commandline} || true"))
    end
  end

  private

  def self.tls_keys
    [:tlscacert, :tlscert, :tlskey]
  end

  def all_tls_path_available?
    self.class.tls_keys.all? { |key| @connection_opts.key?(key) }
  end

  def tls_parameters
    return '' if @connection_opts.nil? || @connection_opts.empty?

    tls_flags = ''

    # --tlsverify can be set without passing the cacert, cert and key flags
    if @connection_opts[:tls] == true || all_tls_path_available?
      tls_flags << ' --tlsverify'
    end

    self.class.tls_keys.each do |key|
      tls_flags << " --#{key}=#{@connection_opts[key]}" if @connection_opts[key]
    end

    tls_flags
  end

  def build_command(action, destination)
    host = @socket ? "unix://#{@socket}" : @docker_host
    command = "#{@docker_path} -H=#{host}"
    command << tls_parameters || ''
    command << case action
               when :pull then ' pull '
               when :logs then ' logs -f '
               when :attach then ' attach '
               when :exec then ' exec '
               end
    command << destination
    command
  end

  def connect
    if @connection_opts[:ssh]
      Centurion::SSH.with_docker_socket(@docker_host, @connection_opts[:ssh_user], @connection_opts[:ssh_log_level], @connection_opts[:ssh_socket_heartbeat]) do |socket|
        @socket = socket
        ret = yield
        @socket = nil
        ret
      end
    else
      yield
    end
  end
end
