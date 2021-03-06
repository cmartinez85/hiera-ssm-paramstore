Puppet::Functions.create_function(:hiera_ssm_paramstore) do
  begin
    require 'aws-sdk-ssm'
  rescue LoadError => e
    raise Puppet::DataBinding::LookupError, "Must install gem aws-sdk-ssm to use hiera_ssm_paramstore"
  end

  dispatch :lookup_key do
    param 'Variant[String, Numeric]', :key
    param 'Hash', :options
    param 'Puppet::LookupContext', :context
  end

  def lookup_key(key, options, context)
    key_path = context.interpolate(options['uri'] + key.gsub('::', '/'))

    # Searches for key and key path due to ssm return just the key for keys on the root path (/)
    # and the full path for the rest (/path/key)
    if options['get_all']
      if not context.cache_has_key('ssm_cached') 
        context.explain { "No cache, caching..." } 
        get_all_parameters(options, context) 
      else 
        context.explain { "Cache populated!!!" } 
      end
      if context.cache_has_key(key)
        context.explain { "Returning value for key #{key}" }
        return context.cached_value(key)
      elsif context.cache_has_key(key_path)
        context.explain { "Returning value for #{key}" }
        return context.cached_value(key_path)
      else
        context.explain { "Key #{key} not found" }
        return context.not_found
      end
    else
      result = get_parameter(key, options, context, key_path)
      return result
    end
  end

  def resolve_credentials(options)
    priority_profile =  [ENV['AWS_PROFILE'], options['aws_profile'], "instance_profile"]
    profile = priority_profile.find{|i| !i.nil?}
    if profile == "instance_profile"
      credentials = Aws::InstanceProfileCredentials.new()
    else
      credentials = Aws::SharedCredentials.new(profile_name: profile)
    end
    return credentials
  end

  def ssm_get_connection(options)
    begin

      if options['region'].nil?
        Aws::SSM::Client.new(credentials: resolve_credentials(options))
      else
        Aws::SSM::Client.new(region: options['region'], credentials: resolve_credentials(options))
      end
    rescue Aws::SSM::Errors::ServiceError => e
      raise Puppet::DataBinding::LookupError, "Fail to connect to aws ssm #{e.message}"
    end
  end

  def get_all_parameters(options, context)
    token = nil
    options['recursive'] ||= false
    ssmclient = ssm_get_connection(options)

    loop do
      begin
        context.explain { "Getting keys on #{options['uri']} ..." }
        data = ssmclient.get_parameters_by_path({
          path: options['uri'],
          with_decryption: true,
          recursive: options['recursive'],
          next_token: token
        })
        context.explain { "Adding keys on cache ..." }
        data['parameters'].each do |k|
          context.cache(k['name'], k['value'])
        end
        
        context.explain { "Marking cache as populated" }
        context.cache('ssm_cached', 'true')

        break if (data.next_token.nil?)
        token = data.next_token
      rescue Aws::SSM::Errors::ServiceError => e
        raise Puppet::DataBinding::LookupError, "AWS SSM Service error #{e.message}"
      end
    end
  end

  def get_parameter(key, options, context, key_path)
    ssmclient = ssm_get_connection(options)

    if context.cache_has_key(key_path)
      context.explain { "Returning cached value for #{key_path}" }
      return context.cached_value(key_path)
    else
      context.explain {"Looking for #{key_path}"}

      begin
        resp = ssmclient.get_parameters({
          names: [key_path],
          with_decryption: true
        })
        if !resp.parameters.empty?
          value = resp.parameters[0].value
          context.cache(key_path, value)
          return value
        else
          context.explain { "Key #{key_path} not found" }
          context.not_found
        end
      rescue Aws::SSM::Errors::ServiceError => e
        raise Puppet::DataBinding::LookupError, "AWS SSM Service error #{e.message}"
      end
    end
  end
end
