Puppet::Functions.create_function(:consul_lookup_key) do
  require 'net/http'
  require 'net/https'
  require 'json'


  dispatch :consul_lookup_key do
    param 'Variant[String, Numeric]', :key
    param 'Hash', :options
    param 'Puppet::LookupContext', :context
  end

  def consul_init_key (options)
    @options = options
    unless @options.include?('host')
      raise ArgumentError, "'consul_lookup_key': 'host' must be declared in hiera.yaml when using this lookup_key function"
    end

    unless @options.include?('port')
      raise ArgumentError, "'consul_lookup_key': 'port' must be declared in hiera.yaml when using this lookup_key function"
    end

    @consul = Net::HTTP.new(@options['host'], @options['port'])

    @consul.read_timeout = @options['http_read_timeout'] || 10
    @consul.open_timeout = @options['http_connect_timeout'] || 10

    if @options['use_ssl']
      @consul.use_ssl = true

      if !@options['ssl_verify']
        @consul.verify_mode = OpenSSL::SSL::VERIFY_NONE
      else
        @consul.verify_mode = OpenSSL::SSL::VERIFY_PEER
      end

      if @options['ssl_cert']
        store = OpenSSL::X509::Store.new
        store.add_cert(OpenSSL::X509::Certificate.new(File.read(@options['ssl_ca_cert'])))
        @consul.cert_store = store

        @consul.key = OpenSSL::PKey::RSA.new(File.read(options['ssl_cert']))
        @consul.cert = OpenSSL::X509::Certificate.new(File.read(@options['ssl_cert']))
      end
    else
      @consul.use_ssl = false
    end

  end


  def consul_lookup_key(key, options, context)

    if context.cache_has_key(key)
      cached_value = context.cached_value(key)
      Puppet.debug("[hiera-consul]: returning cached value #{cached_value} for #{key}")
      return cached_value
    end

    consul_init_key(options)
    answer = nil

    uri = options['uri']
    Puppet.debug("[hiera-consul]: Looking up #{uri}")

    Puppet.debug("[hiera-consul]: Lookup Path/key: #{uri} #{key}")

    if uri.start_with?('::consul_node::')
      return uri
    end


    Puppet.debug("[hiera-consul]: Lookup #{uri}/#{key} on #{options['host']}:#{options['port']}")
    # Check that we are not looking somewhere that will make hiera crash subsequent lookups
    if "#{uri}/#{key}".match('//')
      Puppet.debug("[hiera-consul]: The specified path #{uri}/#{key} is malformed, skipping")
      return context.not_found()
    end
    # We only support querying the catalog or the kv store
    if uri !~ /^\/v\d\/(catalog|kv)\//
      Puppet.debug("[hiera-consul]: We only support queries to catalog and kv and you asked #{uri}, skipping")
      return context.not_found()
    end
    answer = wrap_key_query("#{uri}/#{key}", options)

    return context.not_found() unless answer
    context.cache(key, answer)
  end

  def parse_result(res)
    require 'base64'
    answer = nil
    if res == 'null'
      Puppet.debug('[hiera-consul]: Jumped as consul null is not valid')
      return answer
    end
    # Consul always returns an array
    res_array = JSON.parse(res)
    # See if we are a k/v return or a catalog return
    if !res_array.empty?
      if res_array.first.include? 'Value'
        if res_array.first['Value'].nil?
          # The Value is nil so we return it directly without trying to decode it ( which would fail )
          return answer
        else
          answer = Base64.decode64(res_array.first['Value'])
        end
      else
        answer = res_array
      end
    else
      Puppet.debug('[hiera-consul]: Jumped as array empty')
    end
    answer
  end

  private

  def key_token(path, options)
    # Token is passed only when querying kv store
    "?token=#{options['token']}" if options['token'] && path =~ /^\/v\d\/kv\//
  end

  def wrap_key_query(path, options)
    httpreq = Net::HTTP::Get.new("#{path}#{key_token(path, options)}")
    answer = nil
    begin
      result = @consul.request(httpreq)
    rescue Exception => e
      Puppet.warning('[hiera-consul]: Could not connect to Consul')
      raise Exception, e.message unless options['failure'] == 'graceful'
      return answer
    end
    unless result.is_a?(Net::HTTPSuccess)
      Puppet.debug("[hiera-consul]: HTTP response code was #{result.code}")
      return answer
    end
    Puppet.debug("[hiera-consul]: Answer was #{result.body}")
    answer = parse_result(result.body)
    answer
  end
end
