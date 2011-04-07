require 'eventmachine'
require 'em/buftok'
require 'uri'
require 'simple_oauth'

module Twitter
  class JSONStream < EventMachine::Connection
    MAX_LINE_LENGTH = 1024*1024

    # network failure reconnections
    NF_RECONNECT_START = 0.25
    NF_RECONNECT_ADD   = 0.25
    NF_RECONNECT_MAX   = 16

    # app failure reconnections
    AF_RECONNECT_START = 10
    AF_RECONNECT_MUL   = 2

    RECONNECT_MAX   = 320
    RETRIES_MAX     = 10

    DEFAULT_OPTIONS = {
      :method       => 'GET',
      :path         => '/',
      :content_type => "application/x-www-form-urlencoded",
      :content      => '',
      :path         => '/1/statuses/filter.json',
      :host         => 'stream.twitter.com',
      :port         => 80,
      :ssl          => false,
      :user_agent   => 'TwitterStream',
      :timeout      => 0,
      :proxy        => ENV['HTTP_PROXY'],
      :auth         => nil,
      :oauth        => {},
      :filters      => [],
      :params       => {},
    }

    attr_accessor :code
    attr_accessor :headers
    attr_accessor :nf_last_reconnect
    attr_accessor :af_last_reconnect
    attr_accessor :reconnect_retries
    attr_accessor :proxy

    def self.connect options = {}
      options[:port] = 443 if options[:ssl] && !options.has_key?(:port)
      options = DEFAULT_OPTIONS.merge(options)

      host = options[:host]
      port = options[:port]

      if options[:proxy]
        proxy_uri = URI.parse(options[:proxy])
        host = proxy_uri.host
        port = proxy_uri.port
      end

      connection = EventMachine.connect host, port, self, options
      connection.start_tls if options[:ssl]
      connection
    end

    def initialize options = {}
      @options = DEFAULT_OPTIONS.merge(options) # merge in case initialize called directly
      @gracefully_closed = false
      @nf_last_reconnect = nil
      @af_last_reconnect = nil
      @reconnect_retries = 0
      @immediate_reconnect = false
      @on_inited_callback = options.delete(:on_inited)
      @proxy = URI.parse(options[:proxy]) if options[:proxy]
    end

    def each_item &block
      @each_item_callback = block
    end

    def on_error &block
      @error_callback = block
    end

    def on_reconnect &block
      @reconnect_callback = block
    end

    def on_max_reconnects &block
      @max_reconnects_callback = block
    end

    def stop
      @gracefully_closed = true
      close_connection
    end

    def immediate_reconnect
      @immediate_reconnect = true
      @gracefully_closed = false
      close_connection
    end

    def unbind
      receive_line(@buffer.flush) unless @buffer.empty?
      schedule_reconnect unless @gracefully_closed
    end

    def receive_data data
      begin
        @buffer.extract(data).each do |line|
          receive_line(line)
        end
      rescue Exception => e
        receive_error("#{e.class}: " + [e.message, e.backtrace].flatten.join("\n\t"))
        close_connection
        return
      end
    end

    def connection_completed
      send_request
    end

    def post_init
      reset_state
      @on_inited_callback.call if @on_inited_callback
    end

  protected
    def schedule_reconnect
      timeout = reconnect_timeout
      @reconnect_retries += 1
      if timeout <= RECONNECT_MAX && @reconnect_retries <= RETRIES_MAX
        reconnect_after(timeout)
      else
        @max_reconnects_callback.call(timeout, @reconnect_retries) if @max_reconnects_callback
      end
    end

    def reconnect_after timeout
      @reconnect_callback.call(timeout, @reconnect_retries) if @reconnect_callback

      if timeout == 0
        reconnect @options[:host], @options[:port]
      else
        EventMachine.add_timer(timeout) do
          reconnect @options[:host], @options[:port]
        end
      end
    end

    def reconnect_timeout
      if @immediate_reconnect
        @immediate_reconnect = false
        return 0
      end

      if (@code == 0) # network failure
        if @nf_last_reconnect
          @nf_last_reconnect += NF_RECONNECT_ADD
        else
          @nf_last_reconnect = NF_RECONNECT_START
        end
        [@nf_last_reconnect,NF_RECONNECT_MAX].min
      else
        if @af_last_reconnect
          @af_last_reconnect *= AF_RECONNECT_MUL
        else
          @af_last_reconnect = AF_RECONNECT_START
        end
        @af_last_reconnect
      end
    end

    def reset_state
      set_comm_inactivity_timeout @options[:timeout] if @options[:timeout] > 0
      @code    = 0
      @headers = []
      @state   = :init
      @buffer  = BufferedTokenizer.new("\r", MAX_LINE_LENGTH)
    end

    def send_request
      data = []
      request_uri = @options[:path]

      if @proxy
        # proxies need the request to be for the full url
        request_uri = "#{uri_base}:#{@options[:port]}#{request_uri}"
      end

      content = @options[:content]

      unless (q = query).empty?
        if @options[:method].to_s.upcase == 'GET'
          request_uri << "?#{q}"
        else
          content = q
        end
      end

      data << "#{@options[:method]} #{request_uri} HTTP/1.1"
      data << "Host: #{@options[:host]}"
      data << 'Accept: */*'
      data << "User-Agent: #{@options[:user_agent]}" if @options[:user_agent]

      if @options[:auth]
        data << "Authorization: Basic #{[@options[:auth]].pack('m').delete("\r\n")}"
      elsif @options[:oauth]
        data << "Authorization: #{oauth_header}"
      end

      if @proxy && @proxy.user
        data << "Proxy-Authorization: Basic " + ["#{@proxy.user}:#{@proxy.password}"].pack('m').delete("\r\n")
      end
      if @options[:method] == 'POST'
        data << "Content-type: #{@options[:content_type]}"
        data << "Content-length: #{content.length}"
      end
      data << "\r\n"

      send_data data.join("\r\n") << content
    end

    def receive_line ln
      case @state
      when :init
        parse_response_line ln
      when :headers
        parse_header_line ln
      when :stream
        parse_stream_line ln
      end
    end

    def receive_error e
      @error_callback.call(e) if @error_callback
    end

    def parse_stream_line ln
      ln.strip!
      unless ln.empty?
        if ln[0,1] == '{'
          @each_item_callback.call(ln) if @each_item_callback
        end
      end
    end

    def parse_header_line ln
      ln.strip!
      if ln.empty?
        reset_timeouts if @code == 200
        @state = :stream
      else
        headers << ln
      end
    end

    def parse_response_line ln
      if ln =~ /\AHTTP\/1\.[01] ([\d]{3})/
        @code = $1.to_i
        @state = :headers
        receive_error("invalid status code: #{@code}. #{ln}") unless @code == 200
      else
        receive_error('invalid response')
        close_connection
      end
    end

    def reset_timeouts
      @nf_last_reconnect = @af_last_reconnect = nil
      @reconnect_retries = 0
    end

    #
    # URL and request components
    #

    # :filters => %w(miama lebron jesus)
    # :oauth => {
    #   :consumer_key    => [key],
    #   :consumer_secret => [token],
    #   :access_key      => [access key],
    #   :access_secret   => [access secret]
    # }
    def oauth_header
      uri = uri_base + @options[:path]

      oauth = {
        :consumer_key => @options[:oauth][:consumer_key],
        :consumer_secret => @options[:oauth][:consumer_secret],
        :token => @options[:oauth][:access_key],
        :token_secret => @options[:oauth][:access_secret]
      }

      SimpleOAuth::Header.new(@options[:method], uri, params, oauth)
    end

    # Scheme (https if ssl, http otherwise) and host part of URL
    def uri_base
      "http#{'s' if @options[:ssl]}://#{@options[:host]}"
    end

    # Normalized query hash of escaped string keys and escaped string values
    # nil values are skipped
    def params
      flat = {}
      @options[:params].merge( :track => @options[:filters] ).each do |param, val|
        next if val.empty?
        val = val.join(",") if val.respond_to?(:join)
        flat[escape(param)] = escape(val)
      end
      flat
    end

    def query
      params.map{|pair| pair.join("=")}.sort.join("&")
    end

    def escape str
      URI.escape(str.to_s, /[^a-zA-Z0-9\-\.\_\~]/)
    end
  end
end
