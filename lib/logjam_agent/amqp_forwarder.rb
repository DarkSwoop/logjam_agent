module LogjamAgent
  class AMQPForwarder

    RETRY_AFTER = 10.seconds

    attr_reader :app, :env

    def initialize(*args)
      opts = args.extract_options!
      @app = args[0] || LogjamAgent.application_name
      @env = args[1] || LogjamAgent.environment_name
      @config = default_options(@app, @env).merge!(opts)
      @exchange = @bunny = nil
      ensure_bunny_gem_is_available
    end

    def default_options(app, env)
      {
        :host                 => "localhost",
        :exchange             => "request-stream-#{app}-#{env}",
        :exchange_durable     => true,
        :exchange_auto_delete => false,
        :routing_key          => "logs.#{app}.#{env}"
      }
    end

    # TODO: mutex!
    def forward(msg, options = {})
      return if paused? || LogjamAgent.disabled
      begin
        # $stderr.puts msg
        key = options[:routing_key] || @config[:routing_key]
        if engine = options[:engine]
          key += ".#{engine}"
        end
        exchange.publish(msg, :key => key, :persistent => false)
      rescue Exception => exception
        reraise_expectation_errors!
        pause(exception)
      end
    end

    def reset(exception=nil)
      return unless @bunny
      begin
        if exception
          @bunny.__send__(:close_socket)
        else
          @bunny.stop
        end
      rescue Exception
        # if bunny throws an exception here, its not usable anymore anyway
      ensure
        @exchange = @bunny = nil
      end
    end

    private

    if defined?(Mocha)
      def reraise_expectation_errors! #:nodoc:
        raise if $!.is_a?(Mocha::ExpectationError)
      end
    else
      def reraise_expectation_errors! #:nodoc:
        # noop
      end
    end

    def pause(exception)
      @paused = Time.now
      reset(exception)
      raise ForwardingError.new("Could not log to AMQP exchange (#{exception.message})")
    end

    def paused?
      @paused && @paused > RETRY_AFTER.ago
    end

    def exchange
      @exchange ||=
        begin
          bunny.start unless bunny.connected?
          bunny.exchange(@config[:exchange],
                         :durable => @config[:exchange_durable],
                         :auto_delete => @config[:exchange_auto_delete],
                         :type => :topic)
        end
    end

    #TODO: verify socket_timout for ruby 1.9
    def bunny
      @bunny ||= Bunny.new(:host => @config[:host], :socket_timeout => 1.0)
    end

    def ensure_bunny_gem_is_available
      require "bunny" unless defined?(Bunny)
    end
  end
end
