#--  -*- mode: ruby; encoding: utf-8 -*-
# Copyright: Copyright (c) 2011-2013 RightScale, Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# 'Software'), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#++

require 'rubygems'
require 'etc'
require 'fcntl'
require 'yaml'
require 'right_popen'
require 'right_popen/process_base'

module RightScale
  module RightPopen
    class Process < ::RightScale::RightPopen::ProcessBase

      def initialize(options={})
        super(options)
      end

      # Determines if the process is still running.
      #
      # === Return
      # @return [TrueClass|FalseClass] true if running
      def alive?
        unless @pid
          raise ::RightScale::RightPopen::ProcessError, 'Process not started'
        end
        unless @status
          begin
            ignored, status = ::Process.waitpid2(@pid, ::Process::WNOHANG)
            @status = status
          rescue
            wait_for_exit_status
          end
        end
        @status.nil?
      end

      # Linux must only read streams that are selected for read, even on child
      # death. the issue is that a child process can (inexplicably) close one of
      # the streams but continue writing to the other and this will cause the
      # parent to hang reading the stream until the child goes away.
      #
      # === Return
      # @return [TrueClass|FalseClass] true if draining all
      def drain_all_upon_death?
        false
      end

      # @return [Array] escalating termination signals for this platform
      def signals_for_interrupt
        ['INT', 'TERM', 'KILL']
      end

      # blocks waiting for process exit status.
      #
      # === Return
      # @return [ProcessStatus] exit status
      def wait_for_exit_status
        unless @pid
          raise ::RightScale::RightPopen::ProcessError, 'Process not started'
        end
        unless @status
          begin
            ignored, status = ::Process.waitpid2(@pid)
            @status = status
          rescue
            # ignored
          end
        end
        @status
      end

      # spawns (forks) a child process using given command and handler target in
      # linux-specific manner.
      #
      # must be overridden and override must call super.
      #
      # === Parameters
      # @param [String|Array] cmd as shell command or binary to execute
      # @param [Object] target that implements all handlers (see TargetProxy)
      #
      # === Return
      # @return [TrueClass] always true
      def spawn(cmd, target)
        super(cmd, target)

        # garbage collect any open file descriptors from past executions before
        # forking to prevent them being inherited. also reduces memory footprint
        # since forking will duplicate everything in memory for child process.
        ::GC.start

        # create pipes.
        stdin_r, stdin_w = IO.pipe
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe
        status_r, status_w = IO.pipe

        [stdin_r, stdin_w, stdout_r, stdout_w,
         stderr_r, stderr_w, status_r, status_w].each {|fdes| fdes.sync = true}

        @pid = ::Kernel::fork do
          begin
            stdin_w.close
            ::STDIN.reopen stdin_r

            stdout_r.close
            ::STDOUT.reopen stdout_w

            stderr_r.close
            ::STDERR.reopen stderr_w

            status_r.close
            status_w.fcntl(::Fcntl::F_SETFD, ::Fcntl::FD_CLOEXEC)

            unless @options[:inherit_io]
              ::ObjectSpace.each_object(IO) do |io|
                if ![::STDIN, ::STDOUT, ::STDERR, status_w].include?(io)
                  # be careful to not allow streams in a bad state from the
                  # parent process to prevent child process running.
                  (io.close rescue nil) unless (io.closed? rescue true)
                end
              end
            end

            if group = get_group
              ::Process.egid = group
              ::Process.gid = group
            end

            if user = get_user
              ::Process.euid = user
              ::Process.uid = user
            end

            if umask = get_umask
              ::File.umask(umask)
            end

            # avoid chdir when pwd is already correct due to asinine printed
            # warning from chdir block for what is basically a no-op.
            working_directory = @options[:directory]
            if working_directory &&
               ::File.expand_path(working_directory) != ::File.expand_path(::Dir.pwd)
              ::Dir.chdir(working_directory)
            end

            environment_hash = {}
            environment_hash['LC_ALL'] = 'C' if @options[:locale]
            environment_hash.merge!(@options[:environment]) if @options[:environment]
            environment_hash.each do |key, value|
              ::ENV[key.to_s] = value.nil? ? nil: value.to_s
            end

            if cmd.kind_of?(Array)
              cmd = cmd.map { |c| c.to_s } #exec only likes string arguments
              exec(*cmd)
            else
              exec('sh', '-c', cmd.to_s)  # allows shell commands for cmd string
            end
            raise 'Unreachable code'
          rescue ::Exception => e
            # note that Marshal.dump/load isn't reliable for all kinds of
            # exceptions or else can be truncated by I/O buffering.
            error_data = {
              'class' => e.class.name,
              'message' => e.message,
              'backtrace' => e.backtrace
            }
            status_w.puts(::YAML.dump(error_data))
          end
          status_w.close
          exit!
        end

        stdin_r.close
        stdout_w.close
        stderr_w.close
        status_w.close
        @stdin = stdin_w
        @stdout = stdout_r
        @stderr = stderr_r
        @status_fd = status_r
        start_timer
        true
      rescue
        # catch-all for failure to spawn process ensuring a non-nil status. the
        # PID most likely is nil but the exit handler can be invoked for async.
        safe_close_io
        @status = ::RightScale::RightPopen::ProcessStatus.new(@pid, 1)
        raise
      end

      private

      def get_user
        if user = @options[:user]
          user = Etc.getpwnam(user).uid unless user.kind_of?(Integer)
        end
        user
      end

      def get_group
        if group = @options[:group]
          group = Etc.getgrnam(group).gid unless group.kind_of?(Integer)
        end
        group
      end

      def get_umask
        if umask = @options[:umask]
          if umask.respond_to?(:oct)
            umask = umask.oct
          else
            umask = umask.to_i
          end
          umask = umask & 007777
        end
        umask
      end
    end
  end
end
